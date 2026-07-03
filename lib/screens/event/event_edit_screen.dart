import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/models/user_settings_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../features/groups/models/group_event_comment_model.dart';
import '../../features/groups/models/group_event_model.dart';
import '../../features/groups/models/group_model.dart';
import '../../features/groups/providers/group_context_provider.dart';
import '../../features/groups/repositories/group_event_comment_repository.dart';
import '../../features/groups/repositories/group_event_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/auth_provider.dart';
import '../location/location_pick_flow.dart';
import '../../services/app_permission_service.dart';
import '../../services/app_feedback_service.dart';
import '../../services/event_range_utils.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/calendar_auto_sync_service.dart';
import '../../services/event_preparation_service.dart';
import '../../services/departure_alarm_service.dart';
import '../../services/home_widget_service.dart';
import '../../services/location_lookup_service.dart';
import '../../services/manual_event_side_effect_service.dart';
import '../../services/notification_service.dart';
import '../../services/smart_preparation_alarm_service.dart';
import '../../l10n/app_l10n.dart';
import '../../widgets/calendar_style_event_editor.dart';
import '../../widgets/overlap_warning_dialog.dart';
import '../../widgets/recurrence_selector.dart';
import '../../widgets/reminder_offset_selector.dart';
import '../../widgets/schedule_save_scope_card.dart';

class EventEditScreen extends StatefulWidget {
  EventEditScreen({
    super.key,
    this.event,
    this.eventId,
    this.initialDate,
    this.eventRepository,
    this.groupContextProvider,
    this.groupEventRepository,
    this.currentUserIdOverride,
    this.permissionService,
    ManualEventSideEffectService? sideEffectService,
    HomeWidgetService? homeWidgetService,
  })  : sideEffectService =
            sideEffectService ?? const ManualEventSideEffectService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService();

  final EventModel? event;
  final String? eventId;
  final DateTime? initialDate;
  final EventRepository? eventRepository;
  final GroupContextProvider? groupContextProvider;
  final GroupEventRepository? groupEventRepository;
  final String? currentUserIdOverride;
  final AppPermissionService? permissionService;
  final ManualEventSideEffectService sideEffectService;
  final HomeWidgetService homeWidgetService;

  @override
  State<EventEditScreen> createState() => _EventEditScreenState();
}

enum _LinkedGroupEditScope {
  personalOnly,
  personalAndGroup,
}

class _EventEditScreenState extends State<EventEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _suppliesController;
  GroupContextProvider? _groupContextProvider;
  bool _ownsGroupContextProvider = false;
  late DateTime _startAt;
  DateTime? _endAt;
  double? _locationLat;
  double? _locationLng;
  String? _resolvedLocationLabel;
  late bool _critical;
  late bool _strongAlarm;
  late RecurrenceSelection _recurrenceSelection;
  bool _isAllDay = false;
  String _category = '기타';
  Duration? _reminderOffset = ReminderOffsetSelector.defaultValue;
  EventModel? _loadedEvent;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isLookingUpLocation = false;
  bool _endEditedByUser = false;
  ScheduleSaveTarget _saveTarget = ScheduleSaveTarget.personalOnly;
  // 사용자가 저장 범위를 직접 바꾼 뒤에는 자동 공유 기본값이 덮어쓰지 않도록 표시.
  bool _saveTargetTouchedByUser = false;
  Timer? _locationDebounceTimer;

  // 리더 지시(그룹 이벤트 코멘트) 관련
  List<GroupEventCommentModel> _leaderInstructions = const [];
  bool _isLoadingInstructions = false;
  bool _isConfirmingInstruction = false;

  bool get _isNewEvent => _loadedEvent == null && _resolvedEventId == null;

  String? get _resolvedEventId {
    final routeId = widget.eventId?.trim();
    if (routeId != null && routeId.isNotEmpty) {
      return routeId;
    }
    final extraId = widget.event?.id.trim();
    if (extraId != null && extraId.isNotEmpty) {
      return extraId;
    }
    return null;
  }

  EventRepository get _repository =>
      widget.eventRepository ?? EventRepository.supabase();

  GroupEventRepository get _groupEventRepository =>
      widget.groupEventRepository ?? GroupEventRepository.supabase();

  AppPermissionService get _permissionService =>
      widget.permissionService ?? AppPermissionService();

  DateTime _eventRangeEnd(DateTime startAt, DateTime? endAt) {
    if (endAt != null && endAt.isAfter(startAt)) {
      return endAt;
    }
    if (_isAllDay || (endAt != null && !DateUtils.isSameDay(startAt, endAt))) {
      return startAt.add(const Duration(days: 1));
    }
    return startAt.add(const Duration(minutes: 30));
  }

  Future<bool> _showOverlapWarning(List<EventModel> overlappingEvents) {
    return showOverlapWarningDialog(
      context: context,
      overlappingEvents: overlappingEvents,
    );
  }

  void _handleLocationTextChanged(String value) {
    final trimmed = value.trim();
    if (_resolvedLocationLabel != null &&
        trimmed == _resolvedLocationLabel!.trim()) {
      return;
    }
    if (_locationLat != null || _locationLng != null) {
      setState(() {
        _locationLat = null;
        _locationLng = null;
        _resolvedLocationLabel = null;
      });
    }
    _locationDebounceTimer?.cancel();
    if (trimmed.isNotEmpty) {
      _locationDebounceTimer = Timer(
        const Duration(milliseconds: 800),
        _autoResolveLocation,
      );
    }
  }

  Future<void> _autoResolveLocation() async {
    final query = _locationController.text.trim();
    if (query.isEmpty || (_locationLat != null && _locationLng != null)) return;
    if (!mounted) return;
    setState(() {
      _isLookingUpLocation = true;
    });
    try {
      final results = await LocationLookupService().search(query, origin: null);
      if (!mounted ||
          query != _locationController.text.trim() ||
          results.isEmpty) {
        return;
      }
      final best = results.first;
      setState(() {
        // 텍스트는 보존 - 사용자가 입력한 지역 컨텍스트("강릉" 등) 유지
        _locationLat = best.latitude;
        _locationLng = best.longitude;
        _resolvedLocationLabel = query;
      });
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen auto location resolve failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _isLookingUpLocation = false;
        });
      }
    }
  }

  void _handleCriticalChanged(bool value) {
    setState(() {
      _critical = value;
      if (!value) _strongAlarm = false;
    });
    if (value) {
      unawaited(_ensureCriticalAlarmPermissions());
    }
  }

  void _handleStrongAlarmChanged(bool value) {
    setState(() {
      _strongAlarm = value;
    });
    if (value) {
      unawaited(_ensureCriticalAlarmPermissions());
    }
  }

  Future<void> _ensureLocationCoordinatesBeforeSave() async {
    final query = _locationController.text.trim();
    if (query.isEmpty || (_locationLat != null && _locationLng != null)) {
      return;
    }

    if (mounted) {
      setState(() {
        _isLookingUpLocation = true;
      });
    }
    try {
      final gpsFuture = _permissionService
          .getCurrentLocationWithPermission(
        requestIfMissing: false,
      )
          .catchError((Object error, StackTrace stackTrace) {
        debugPrint('EventEditScreen background GPS lookup skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
        return null;
      });
      unawaited(gpsFuture);
      final results = await LocationLookupService().search(
        query,
        origin: null,
      );
      if (!mounted ||
          query != _locationController.text.trim() ||
          results.isEmpty) {
        return;
      }

      final selected = results.first;
      final resolvedLabel = selected.bestPlaceLabel.trim();
      setState(() {
        if (resolvedLabel.isNotEmpty) {
          _locationController.text = resolvedLabel;
        }
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel =
            resolvedLabel.isNotEmpty ? resolvedLabel : query;
      });
    } catch (error, stackTrace) {
      debugPrint(
          'EventEditScreen save-time location resolution failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _isLookingUpLocation = false;
        });
      }
    }
  }

  void _handleBackNavigation() {
    if (Navigator.of(context).canPop()) {
      context.pop();
      return;
    }
    context.go(AppRoutes.home);
  }

  Future<void> _ensureCriticalAlarmPermissions() async {
    try {
      final snapshot = await _permissionService.checkAll();
      if (_criticalAlarmPermissionsReady(snapshot) || !mounted) {
        return;
      }
      final shouldOpen = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('중요한 일정 알림 권한이 필요해요'),
              content: const Text(
                '중요한 일정을 시작 시점에 더 강한 소리와 진동으로 알려드리려면 앱 알림, 정확한 알람, 전체 화면 알림 권한이 필요합니다. 지금 권한을 확인할게요.',
              ),
              actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              actions: [
                SizedBox(
                  width: double.maxFinite,
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: const Text('나중에'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: const Text('허용하러 가기'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ) ??
          false;
      if (!shouldOpen || !mounted) {
        return;
      }
      final granted = await _requestCriticalAlarmPermissions();
      if (!mounted) {
        return;
      }
      _showMessage(
        granted
            ? '중요한 일정 알림 권한을 확인했습니다.'
            : '설정에서 PlanFlow의 알림, 정확한 알람, 전체 화면 알림을 허용한 뒤 돌아와 주세요.',
      );
    } catch (error, stackTrace) {
      debugPrint('Critical alarm permission request skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  bool _criticalAlarmPermissionsReady(AppPermissionSnapshot snapshot) {
    return snapshot.notificationsGranted &&
        snapshot.exactAlarmsGranted &&
        snapshot.fullScreenIntentGranted;
  }

  Future<bool> _requestCriticalAlarmPermissions() async {
    final notificationStatus =
        await _permissionService.requestNotificationPermissions();
    final notificationsGranted =
        notificationStatus.notificationsEnabled == true;
    final exactAlarmsGranted = notificationStatus.exactAlarmsEnabled == true ||
        await _permissionService.requestExactAlarmPermission();
    final fullScreenIntentGranted = notificationStatus.fullScreenIntentStatus ==
            PermissionCheckState.granted ||
        await _permissionService.requestFullScreenIntentPermission();
    final latest = await _permissionService.checkAll();
    return notificationsGranted &&
        exactAlarmsGranted &&
        fullScreenIntentGranted &&
        _criticalAlarmPermissionsReady(latest);
  }

  @override
  void initState() {
    super.initState();
    final event = widget.event;
    _loadedEvent = event;
    _titleController = TextEditingController(text: event?.title ?? '');
    _locationController = TextEditingController(text: event?.location ?? '');
    _memoController = TextEditingController(text: event?.memo ?? '');
    _suppliesController = TextEditingController(
      text: event?.supplies.join(', ') ?? '',
    );
    _startAt = event?.startAt == null
        ? _initialStartAtForNewEvent()
        : planflowLocal(event!.startAt!);
    _endAt = event?.endAt == null ? null : planflowLocal(event!.endAt!);
    _locationLat = event?.locationLat;
    _locationLng = event?.locationLng;
    if (_locationLat != null && _locationLng != null) {
      _resolvedLocationLabel = _locationController.text.trim();
    }
    _critical = event?.isCritical ?? false;
    _strongAlarm = event?.useStrongAlarm ?? false;
    _recurrenceSelection = RecurrenceSelection.fromRRule(event?.recurrenceRule);
    _isAllDay = event?.isAllDay ?? false;
    _category = event?.category ?? '기타';
    _groupContextProvider = widget.groupContextProvider;
    if (_groupContextProvider == null && AppEnv.isSupabaseReady) {
      try {
        _groupContextProvider = GroupContextProvider();
        _ownsGroupContextProvider = true;
      } catch (error) {
        debugPrint('EventEditScreen group context unavailable: $error');
      }
    }
    unawaited(_loadGroupContextIfNeeded());
    _loadEventIfNeeded();
    if (event != null && AppEnv.isSupabaseReady) {
      unawaited(_loadReminderOffsetIfNeeded(event));
    }
  }

  DateTime _initialStartAtForNewEvent() {
    final fallback = planflowNow().add(const Duration(hours: 1));
    final initialDate = widget.initialDate;
    if (initialDate == null) {
      return fallback;
    }
    return DateTime(
      initialDate.year,
      initialDate.month,
      initialDate.day,
      fallback.hour,
      fallback.minute,
    );
  }

  @override
  void dispose() {
    _locationDebounceTimer?.cancel();
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    _suppliesController.dispose();
    if (_ownsGroupContextProvider) {
      _groupContextProvider?.dispose();
    }
    super.dispose();
  }

  Future<void> _loadGroupContextIfNeeded() async {
    final provider = _groupContextProvider;
    if (provider == null) {
      return;
    }
    var userId = widget.currentUserIdOverride ?? authProvider.userId;
    if (userId == null || userId.trim().isEmpty) {
      try {
        userId = Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        userId = null;
      }
    }
    if (userId == null || userId.trim().isEmpty) {
      return;
    }
    await provider.load(userId.trim());
    if (mounted) {
      setState(() {});
      unawaited(_applyAutoShareDefaultIfNeeded());
    }
  }

  GroupModel? get _selectedGroupForSharing {
    final group = _groupContextProvider?.selectedGroup;
    if (group == null || !group.isActive) {
      return null;
    }
    return group;
  }

  bool get _canShareToSelectedGroup => _selectedGroupForSharing != null;

  bool get _shouldSavePersonalEvent =>
      !_canShareToSelectedGroup ||
      _saveTarget == ScheduleSaveTarget.personalOnly ||
      _saveTarget == ScheduleSaveTarget.personalAndGroup;

  bool get _shouldSaveGroupEvent =>
      _canShareToSelectedGroup &&
      (_saveTarget == ScheduleSaveTarget.personalAndGroup ||
          _saveTarget == ScheduleSaveTarget.groupOnly);

  String? _currentUserId() {
    final override = widget.currentUserIdOverride?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return Supabase.instance.client.auth.currentUser?.id;
  }

  String _autoSharePrefKey(String userId, String groupId) =>
      'planflow:group_auto_share:v1:$userId:$groupId';

  Future<void> _applyAutoShareDefaultIfNeeded() async {
    // Only apply to NEW events, not edits
    if (!_isNewEvent) {
      return;
    }

    // 사용자가 이미 저장 범위를 직접 골랐으면 자동 공유 기본값으로 덮어쓰지 않는다.
    if (_saveTargetTouchedByUser) {
      return;
    }

    // Must have an active selected group
    final group = _selectedGroupForSharing;
    if (group == null) {
      return;
    }

    final userId = _currentUserId();
    if (userId == null || userId.trim().isEmpty) {
      return;
    }

    try {
      final preferences = await SharedPreferences.getInstance();
      final key = _autoSharePrefKey(userId, group.id);
      final autoShareEnabled = preferences.getBool(key) ?? false;

      // await 사이에 사용자가 직접 골랐을 수 있으므로 적용 직전에 다시 확인.
      if (autoShareEnabled && mounted && !_saveTargetTouchedByUser) {
        setState(() {
          _saveTarget = ScheduleSaveTarget.personalAndGroup;
        });
      }
    } catch (error) {
      debugPrint('EventEditScreen auto-share default error: $error');
    }
  }

  Future<GroupEventModel?> _createGroupEventFromDraft(
    EventModel draft, {
    String? personalEventId,
  }) async {
    final group = _selectedGroupForSharing;
    if (group == null) {
      return null;
    }
    final startAt = draft.startAt;
    if (startAt == null) {
      throw StateError('그룹 일정에는 시작 시간이 필요합니다.');
    }
    final endAt = draft.endAt ?? _eventRangeEnd(startAt, draft.endAt);
    final recurrenceType = _groupRecurrenceTypeFor(draft.recurrenceRule);
    return _groupEventRepository.createGroupEvent(
      GroupEventModel(
        id: '',
        groupId: group.id,
        title: draft.title,
        description: draft.memo,
        location: draft.location,
        startAt: startAt,
        endAt: endAt,
        allDay: draft.isAllDay,
        recurrenceType: recurrenceType,
        createdBy: draft.userId,
        personalEventId: personalEventId,
        status: 'active',
      ),
    );
  }

  Future<GroupEventModel> _updateLinkedGroupEventFromDraft(
    EventModel draft,
    String groupEventId,
  ) async {
    final existing = await _groupEventRepository.fetchGroupEvent(groupEventId);
    final startAt = draft.startAt;
    if (startAt == null) {
      throw StateError('그룹 일정에는 시작 시간이 필요합니다.');
    }
    return _groupEventRepository.updateGroupEvent(
      existing.copyWith(
        title: draft.title,
        description: draft.memo,
        location: draft.location,
        startAt: startAt,
        endAt: draft.endAt ?? _eventRangeEnd(startAt, draft.endAt),
        allDay: draft.isAllDay,
        recurrenceType: _groupRecurrenceTypeFor(draft.recurrenceRule),
        personalEventId:
            draft.id.trim().isEmpty ? existing.personalEventId : draft.id,
      ),
    );
  }

  Future<_LinkedGroupEditScope?> _chooseLinkedGroupEditScope() {
    return showDialog<_LinkedGroupEditScope>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('그룹 일정도 같이 수정할까요?'),
        content: const Text(
          '이 일정은 그룹 일정과 연결되어 있어요. 개인 일정만 바꾸거나, 그룹 일정도 같은 내용으로 바꿀 수 있습니다.',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx)
                        .pop(_LinkedGroupEditScope.personalOnly),
                    child: const Text('개인만 수정'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx)
                        .pop(_LinkedGroupEditScope.personalAndGroup),
                    child: const Text('그룹도 같이 수정'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _groupRecurrenceTypeFor(String? recurrenceRule) {
    final rule = recurrenceRule?.toUpperCase() ?? '';
    if (rule.contains('FREQ=DAILY')) {
      return 'daily';
    }
    if (rule.contains('FREQ=WEEKLY')) {
      return 'weekly';
    }
    if (rule.contains('FREQ=MONTHLY')) {
      return 'monthly';
    }
    return 'none';
  }

  Future<void> _handleSave() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      if (!AppEnv.isSupabaseReady && widget.currentUserIdOverride == null) {
        _showMessage('Supabase 빌드 설정값이 주입되지 않았습니다.');
        return;
      }

      if (widget.currentUserIdOverride == null) {
        try {
          await authProvider.syncCurrentSession();
        } catch (error) {
          debugPrint('EventEditScreen session sync failed before save: $error');
        }
      }

      final userId = _currentUserId();
      if (userId == null || userId.trim().isEmpty) {
        _showMessage('로그인 후 저장할 수 있습니다.');
        return;
      }

      if (_critical) {
        await _ensureCriticalAlarmPermissions();
      }

      String? recurrenceScope;
      if (!_isNewEvent &&
          _loadedEvent?.recurrenceRule?.trim().isNotEmpty == true) {
        recurrenceScope = await _chooseRecurrenceEditScopeSafe();
        if (recurrenceScope == null) {
          return;
        }
      }

      await _ensureLocationCoordinatesBeforeSave();
      if (!mounted) {
        return;
      }

      final supplies = _suppliesController.text
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);

      final normalizedStartAt = planflowLocalDateTimeToUtc(_startAt);
      final normalizedEndAt =
          _endAt == null ? null : planflowLocalDateTimeToUtc(_endAt!);
      final isMultiDayByRange =
          _endAt != null && !DateUtils.isSameDay(_startAt, _endAt);

      final updatedEvent = EventModel(
        id: _loadedEvent?.id ?? _resolvedEventId ?? '',
        userId: userId,
        title: _titleController.text.trim(),
        startAt: normalizedStartAt,
        endAt: normalizedEndAt,
        location: _emptyToNull(_locationController.text),
        locationLat: _locationLat,
        locationLng: _locationLng,
        memo: _emptyToNull(_memoController.text),
        supplies: supplies,
        suppliesChecked: _loadedEvent?.suppliesChecked ?? const <String>[],
        participants: _loadedEvent?.participants ?? const <String>[],
        targets: _loadedEvent?.targets ?? const <String>[],
        isCritical: _critical,
        useStrongAlarm: _strongAlarm,
        recurrenceRule: _recurrenceSelection.toRRule(),
        isAllDay: _isAllDay,
        isMultiDay: isMultiDayByRange,
        parentEventId: _loadedEvent?.parentEventId,
        groupEventId: _loadedEvent?.groupEventId,
        category: _category,
        source: _loadedEvent?.source ?? 'manual',
        externalId: _loadedEvent?.externalId,
        externalCalendarId: _loadedEvent?.externalCalendarId,
        externalEtag: _loadedEvent?.externalEtag,
        externalUpdatedAt: _loadedEvent?.externalUpdatedAt,
        lastSyncedAt: _loadedEvent?.lastSyncedAt,
        createdAt: _loadedEvent?.createdAt,
        updatedAt: _loadedEvent?.updatedAt,
      );

      if (_shouldSavePersonalEvent) {
        final overlapStart = updatedEvent.startAt ?? _startAt;
        final overlappingEvents = await _repository.findOverlappingEvents(
          rangeStart: overlapStart,
          rangeEnd: _eventRangeEnd(overlapStart, updatedEvent.endAt),
          userId: userId,
          excludedEventId: _loadedEvent?.id ?? updatedEvent.id,
        );
        final duplicateWarningEvents = filterDuplicateWarningEvents(
          draft: updatedEvent,
          candidates: overlappingEvents,
        );
        if (!mounted) {
          return;
        }
        if (duplicateWarningEvents.isNotEmpty) {
          final shouldContinue =
              await _showOverlapWarning(duplicateWarningEvents);
          if (!shouldContinue || !mounted) {
            return;
          }
        }
      }

      final previousStartAt = _loadedEvent?.startAt;
      _LinkedGroupEditScope? linkedGroupEditScope;
      final linkedGroupEventId = _loadedEvent?.groupEventId?.trim();
      if (!_isNewEvent &&
          linkedGroupEventId != null &&
          linkedGroupEventId.isNotEmpty &&
          _shouldSavePersonalEvent) {
        linkedGroupEditScope = await _chooseLinkedGroupEditScope();
        if (linkedGroupEditScope == null || !mounted) {
          return;
        }
      }

      EventModel? savedEvent;
      if (_shouldSavePersonalEvent) {
        if (_isNewEvent) {
          savedEvent = await _repository.createEvent(updatedEvent);
        } else if (recurrenceScope == 'single' && _loadedEvent != null) {
          savedEvent = await _repository.createEvent(
            _detachedRecurringEvent(
              updatedEvent,
              parentEventId: _loadedEvent!.id,
              keepRecurrence: false,
            ),
          );
        } else if (recurrenceScope == 'future' && _loadedEvent != null) {
          final original = _loadedEvent!;
          final originalStart = original.startAt;
          final isFirstOccurrence = originalStart == null ||
              planflowIsSameLocalDay(originalStart, normalizedStartAt);
          if (isFirstOccurrence) {
            savedEvent = await _repository.updateEvent(updatedEvent);
          } else {
            await _repository.updateEvent(
              _eventWithRecurrenceRule(
                original,
                _truncateRRuleBefore(original.recurrenceRule, _startAt),
              ),
            );
            savedEvent = await _repository.createEvent(
              _detachedRecurringEvent(
                updatedEvent,
                parentEventId: original.id,
                keepRecurrence: true,
              ),
            );
          }
        } else {
          savedEvent = await _repository.updateEvent(updatedEvent);
        }
      }

      if (_shouldSaveGroupEvent) {
        if (savedEvent == null) {
          await _createGroupEventFromDraft(updatedEvent);
        } else {
          final createdGroupEvent = await _createGroupEventFromDraft(
            savedEvent,
            personalEventId: savedEvent.id,
          );
          if (createdGroupEvent != null) {
            savedEvent = await _repository.updateEvent(
              savedEvent.copyWith(groupEventId: createdGroupEvent.id),
            );
          }
        }
      } else if (linkedGroupEditScope ==
              _LinkedGroupEditScope.personalAndGroup &&
          savedEvent != null &&
          linkedGroupEventId != null &&
          linkedGroupEventId.isNotEmpty) {
        await _updateLinkedGroupEventFromDraft(savedEvent, linkedGroupEventId);
      }

      if (savedEvent != null) {
        unawaited(
          _runPostSaveSideEffects(
            userId: userId,
            savedEvent: savedEvent,
            previousStartAt: previousStartAt,
          ),
        );
      }

      if (mounted) {
        final actionText = _isNewEvent ? '일정을 만들었습니다.' : '일정을 수정했습니다.';
        _showMessage(actionText);
        EventRefreshBus.instance.notifyChanged(
          reason: _isNewEvent ? 'event_created' : 'event_updated',
          eventId: savedEvent?.id,
          startAt: savedEvent?.startAt ?? updatedEvent.startAt,
        );
        context.go(AppRoutes.calendar);
      }
    } on StateError catch (error) {
      debugPrint('EventEditScreen save state error: $error');
      if (mounted) {
        _showMessage(_messageForSaveStateError(error));
      }
    } on PostgrestException catch (error) {
      debugPrint(
        'EventEditScreen save postgrest error: '
        'code=${error.code} message=${error.message} details=${error.details}',
      );
      if (mounted) {
        _showMessage(_messageForPostgrestError(error));
      }
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('일정 저장에 실패했어요. 잠시 후 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  String _messageForSaveStateError(StateError error) {
    final text = error.message.toLowerCase();
    if (text.contains('signed-in user') || text.contains('current user')) {
      return '로그인 상태를 다시 확인해 주세요.';
    }
    if (text.contains('must match the signed-in user')) {
      return '로그인한 계정과 저장하려는 일정의 사용자 정보가 맞지 않아요. 다시 로그인해 주세요.';
    }
    return '저장할 준비가 아직 안 되었어요. 로그인 상태를 다시 확인해 주세요.';
  }

  String _messageForPostgrestError(PostgrestException error) {
    final code = error.code?.toUpperCase() ?? '';
    final text =
        '${error.message} ${error.details} ${error.hint}'.toLowerCase();
    if (code == '42501' ||
        text.contains('row-level security') ||
        text.contains('permission denied')) {
      return 'Supabase 권한 설정이 막고 있어요. 로그인 상태와 RLS를 확인해 주세요.';
    }
    if (code == '23503' || text.contains('foreign key')) {
      return '로그인 프로필이 아직 준비되지 않았어요. 다시 로그인한 뒤 저장해 주세요.';
    }
    if (text.contains('users') && text.contains('does not exist')) {
      return '사용자 정보가 아직 준비되지 않았어요. 잠시 후 다시 시도해 주세요.';
    }
    if (text.contains('events') && text.contains('does not exist')) {
      return '일정 저장 테이블이 아직 준비되지 않았어요. Supabase 설정을 확인해 주세요.';
    }
    return '저장하지 못했어요. Supabase 연결 상태를 확인해 주세요.';
  }

  EventModel _detachedRecurringEvent(
    EventModel event, {
    required String parentEventId,
    required bool keepRecurrence,
  }) {
    return EventModel(
      id: '',
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      participants: event.participants,
      targets: event.targets,
      isCritical: event.isCritical,
      recurrenceRule: keepRecurrence ? event.recurrenceRule : null,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: parentEventId,
      groupEventId: null,
      category: event.category,
      source: 'manual',
      externalId: null,
      externalCalendarId: null,
      externalEtag: null,
      externalUpdatedAt: null,
      lastSyncedAt: null,
      createdAt: null,
      updatedAt: null,
    );
  }

  EventModel _eventWithRecurrenceRule(EventModel event, String? rule) {
    return EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      participants: event.participants,
      targets: event.targets,
      isCritical: event.isCritical,
      recurrenceRule: rule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: event.parentEventId,
      groupEventId: event.groupEventId,
      category: event.category,
      source: event.source,
      externalId: event.externalId,
      externalCalendarId: event.externalCalendarId,
      externalEtag: event.externalEtag,
      externalUpdatedAt: event.externalUpdatedAt,
      lastSyncedAt: event.lastSyncedAt,
      createdAt: event.createdAt,
      updatedAt: event.updatedAt,
    );
  }

  String? _truncateRRuleBefore(String? rule, DateTime boundary) {
    if (rule == null || rule.trim().isEmpty) {
      return null;
    }
    final until = DateTime(boundary.year, boundary.month, boundary.day)
        .subtract(const Duration(days: 1));
    return RecurrenceSelection.fromRRule(rule).copyWith(until: until).toRRule();
  }

  Future<void> _loadEventIfNeeded() async {
    final eventId = _resolvedEventId;
    if (_loadedEvent != null || eventId == null || !AppEnv.isSupabaseReady) {
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      _showMessage('로그인 후 일정 정보를 불러올 수 있습니다.');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final event = await _repository.fetchEvent(eventId, userId: user.id);
      if (!mounted) {
        return;
      }
      if (event == null) {
        _showMessage('수정할 일정을 찾지 못했습니다.');
        return;
      }
      setState(() {
        _loadedEvent = event;
        _titleController.text = event.title;
        _locationController.text = event.location ?? '';
        _locationLat = event.locationLat;
        _locationLng = event.locationLng;
        _resolvedLocationLabel = _locationLat != null && _locationLng != null
            ? _locationController.text.trim()
            : null;
        _memoController.text = event.memo ?? '';
        _suppliesController.text = event.supplies.join(', ');
        _startAt =
            event.startAt == null ? _startAt : planflowLocal(event.startAt!);
        _endAt = event.endAt == null ? null : planflowLocal(event.endAt!);
        _critical = event.isCritical;
        _strongAlarm = event.useStrongAlarm;
        _recurrenceSelection =
            RecurrenceSelection.fromRRule(event.recurrenceRule);
        _isAllDay = event.isAllDay;
        _category = event.category;
      });
      unawaited(_loadReminderOffsetIfNeeded(event));
      // 그룹 연결 이벤트라면 리더 지시 로드
      if (event.groupEventId != null) {
        unawaited(_loadGroupInstructions(event));
      }
    } catch (_) {
      if (mounted) {
        _showMessage('일정 정보를 불러오지 못했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 그룹 이벤트 코멘트(리더 지시)를 로드하고 현재 사용자를 대상으로 필터링한다.
  Future<void> _loadGroupInstructions(EventModel event) async {
    final groupEventId = event.groupEventId;
    if (groupEventId == null || groupEventId.isEmpty) return;
    if (!AppEnv.isSupabaseReady) return;

    String? currentUserId;
    try {
      currentUserId = widget.currentUserIdOverride ??
          Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return;
    }
    if (currentUserId == null || currentUserId.isEmpty) return;

    if (mounted) {
      setState(() {
        _isLoadingInstructions = true;
      });
    }
    try {
      final repo = GroupEventCommentRepository.supabase();
      final all = await repo.getCommentsForEvent(groupEventId);
      final filtered = all
          .where((c) => c.targetUserId == currentUserId)
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _leaderInstructions = filtered;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen 리더 지시 로드 실패: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingInstructions = false;
        });
      }
    }
  }

  /// 리더 지시 확인 처리 (확인 버튼 탭)
  Future<void> _confirmInstruction(String commentId) async {
    if (_isConfirmingInstruction) return;
    if (mounted) {
      setState(() {
        _isConfirmingInstruction = true;
      });
    }
    try {
      final repo = GroupEventCommentRepository.supabase();
      await repo.confirmComment(commentId);
      // 재로드
      final loadedEvent = _loadedEvent;
      if (loadedEvent != null) {
        await _loadGroupInstructions(loadedEvent);
      }
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen 리더 지시 확인 실패: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('지시 확인 중 오류가 발생했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConfirmingInstruction = false;
        });
      }
    }
  }

  /// 리더 지시 섹션 위젯을 빌드한다.
  ///
  /// - [_loadedEvent.groupEventId] 가 null 이면 빈 위젯 반환
  /// - 지시가 없어도 '없음' 표기 없이 섹션 자체를 숨김
  Widget _buildLeaderInstructionsSection(BuildContext context) {
    final event = _loadedEvent;
    if (event == null || event.groupEventId == null) {
      return const SizedBox.shrink();
    }
    if (_isLoadingInstructions) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    if (_leaderInstructions.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppConstants.sectionSpacing),
        Card(
          color: PlanFlowColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(
              color: PlanFlowColors.primaryFaint,
              width: 0.8,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.record_voice_over_outlined,
                      size: 16,
                      color: PlanFlowColors.primaryMid,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '리더 지시',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ..._leaderInstructions.map((instruction) {
                  final timeLabel = instruction.createdAt != null
                      ? _formatInstructionTime(instruction.createdAt!)
                      : '';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: instruction.isConfirmed
                            ? PlanFlowColors.surface
                            : PlanFlowColors.primaryFaint.withValues(
                                alpha: 0.5,
                              ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: instruction.isConfirmed
                              ? PlanFlowColors.primaryFaint
                              : PlanFlowColors.primaryMid
                                  .withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            instruction.content,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: PlanFlowColors.textPrimary,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              if (timeLabel.isNotEmpty)
                                Text(
                                  timeLabel,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: PlanFlowColors.textSecondary,
                                  ),
                                ),
                              const Spacer(),
                              if (instruction.isConfirmed)
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.check_circle_outline,
                                      size: 13,
                                      color: PlanFlowColors.primaryMid,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '확인됨',
                                      style:
                                          theme.textTheme.labelSmall?.copyWith(
                                        color: PlanFlowColors.primaryMid,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                )
                              else
                                FilledButton.tonal(
                                  onPressed: _isConfirmingInstruction
                                      ? null
                                      : () => unawaited(
                                            _confirmInstruction(instruction.id),
                                          ),
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(60, 28),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    textStyle:
                                        theme.textTheme.labelMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  child: const Text('확인'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatInstructionTime(DateTime dt) {
    final local = planflowLocal(dt);
    return '${local.month}/${local.day} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _loadReminderOffsetIfNeeded(EventModel event) async {
    final startAt = event.startAt;
    if (event.id.trim().isEmpty || startAt == null || !AppEnv.isSupabaseReady) {
      return;
    }

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        return;
      }
      final row = await Supabase.instance.client
          .from('reminders')
          .select('notify_at')
          .eq('event_id', event.id)
          .eq('user_id', user.id)
          .eq('type', 'push')
          .maybeSingle();
      if (!mounted) {
        return;
      }
      if (row == null) {
        setState(() {
          _reminderOffset = null;
        });
        return;
      }
      final notifyAt = DateTime.tryParse(row['notify_at'].toString());
      if (notifyAt == null) {
        return;
      }
      final minutes = startAt.difference(notifyAt).inMinutes;
      if (minutes < 0) {
        return;
      }
      setState(() {
        _reminderOffset = Duration(minutes: minutes);
      });
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen reminder load skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _runPostSaveSideEffects({
    required String userId,
    required EventModel savedEvent,
    DateTime? previousStartAt,
  }) async {
    try {
      final settings = await SettingsRepository.supabase().fetchSettings(
        userId,
      );
      final departureSafetyMargin = Duration(
        minutes: settings?.departureSafetyMarginMin ??
            DepartureAlarmService.safetyMargin.inMinutes,
      );
      final sideEffectResult = await widget.sideEffectService.syncAfterSave(
        event: savedEvent,
        userId: userId,
        reminderOffset: _reminderOffset,
        criticalAlarmOffset: _reminderOffset,
        prepTimeMin: settings?.prepTimeMin ??
            SmartPreparationAlarmService.defaultPrepTimeMin,
        prepPreAlarmOffset: settings?.prepPreAlarmOffset ??
            SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
        departPreAlarmOffset: settings?.departPreAlarmOffset ??
            SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
        departureSafetyMargin: departureSafetyMargin,
        travelMode: settings?.travelMode ?? 'car',
        isFirstExternalEventOfDay: await _isFirstExternalEventOfDay(
          userId: userId,
          event: savedEvent,
        ),
      );
      await _resyncExternalPreparationForDay(
        userId: userId,
        event: savedEvent,
        settings: settings,
      );
      if (previousStartAt != null &&
          savedEvent.startAt != null &&
          !planflowIsSameLocalDay(previousStartAt, savedEvent.startAt!)) {
        await _resyncExternalPreparationForDay(
          userId: userId,
          event: savedEvent,
          settings: settings,
          dayReference: previousStartAt,
        );
      }
      unawaited(CalendarAutoSyncService().syncAfterEventSave(savedEvent));
      unawaited(
        EventPreparationService().prepareAfterSave(
          savedEvent,
          departureSafetyMargin: departureSafetyMargin,
        ),
      );
      final widgetRefreshed = await _refreshHomeWidget(_repository, savedEvent);
      debugPrint(
        'EventEditScreen post-save side effects finished: '
        'synced=${sideEffectResult.isFullySynced}, '
        'widgetRefreshed=$widgetRefreshed',
      );
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen post-save side effects failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool> _refreshHomeWidget(
    EventRepository repository,
    EventModel fallbackEvent,
  ) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        return false;
      }
      final now = DateTime.now();
      final events = await repository.listEvents(userId: user.id);
      return widget.homeWidgetService.updateSchedulePayload(
        HomeWidgetSchedulePayloadBuilder.fromEvents(
          events: events,
          now: now,
          emptyTitle: fallbackEvent.startAt == null
              ? '예정된 일정이 없어요'
              : fallbackEvent.title,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen widget refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _isFirstExternalEventOfDay({
    required String userId,
    required EventModel event,
  }) async {
    try {
      final dayEvents = await _repository.listEvents(userId: userId);
      return const SmartPreparationAlarmService().isFirstExternalEventOfDay(
        event: event,
        dayEvents: dayEvents,
      );
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen first external lookup skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return true;
    }
  }

  Future<void> _resyncExternalPreparationForDay({
    required String userId,
    required EventModel event,
    required UserSettingsModel? settings,
    DateTime? dayReference,
  }) async {
    final startAt = event.startAt;
    final reference = dayReference ?? startAt;
    if (reference == null) {
      return;
    }
    try {
      final events = await _repository.listEvents(userId: userId);
      final updatedEvents = <EventModel>[
        for (final candidate in events)
          if (candidate.id == event.id) event else candidate,
      ];
      if (updatedEvents.every((candidate) => candidate.id != event.id)) {
        updatedEvents.add(event);
      }
      await widget.sideEffectService.resyncExternalPreparationForDay(
        dayEvents: updatedEvents,
        userId: userId,
        dayReference: reference,
        prepTimeMin: settings?.prepTimeMin ??
            SmartPreparationAlarmService.defaultPrepTimeMin,
        prepPreAlarmOffset: settings?.prepPreAlarmOffset ??
            SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
        departPreAlarmOffset: settings?.departPreAlarmOffset ??
            SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
        departureSafetyMargin: Duration(
          minutes: settings?.departureSafetyMarginMin ??
              DepartureAlarmService.safetyMargin.inMinutes,
        ),
        travelMode: settings?.travelMode ?? 'car',
      );
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen external prep resync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<String?> _chooseRecurrenceEditScopeSafe() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('반복 일정 수정'),
        content: const Text(
          '반복 일정입니다. 어떤 범위에 수정 내용을 적용할까요?',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(null),
                        child: const Text('취소'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop('single'),
                        child: const Text('이 일정만'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop('future'),
                        child: const Text('이후 모든 일정'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop('all'),
                        child: const Text('전체 반복 일정'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _showMessage(String message) {
    AppFeedbackService.showSnackBar(message, context: context);
  }

  Future<void> _pickLocationOnMap() async {
    final query = _locationController.text.trim();
    try {
      debugPrint('PlanFlow operation start: event_edit.pick_location');

      // 좌표가 이미 고정된 경우: 현재 좌표로 바로 지도 열기 (검색 재실행 없음)
      LocationLookupResult? lockedResult;
      if (_locationLat != null && _locationLng != null) {
        lockedResult = LocationLookupResult(
          name: query.isNotEmpty ? query : '현재 위치',
          address: query,
          latitude: _locationLat!,
          longitude: _locationLng!,
          provider: LocationLookupProvider.manual,
        );
      }

      final selected = await pickLocationFromQuery(
        context: context,
        query: query,
        locationLookupService: LocationLookupService(),
        appPermissionService: _permissionService,
        lockedResult: lockedResult,
      );
      if (!mounted || selected == null) {
        return;
      }
      final resolvedLabel = selected.bestPlaceLabel.trim();
      setState(() {
        _locationController.text =
            resolvedLabel.isNotEmpty ? resolvedLabel : selected.label;
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel =
            resolvedLabel.isNotEmpty ? resolvedLabel : selected.label.trim();
      });
      _showMessage('정확한 위치를 선택했어요.');
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen location pick failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('위치 선택을 열지 못했어요. 지도 키와 네트워크를 확인해 주세요.');
      }
    } finally {
      debugPrint('PlanFlow operation end: event_edit.pick_location');
    }
  }

  Widget _buildSaveTargetCard(BuildContext context) {
    final group = _selectedGroupForSharing;
    if (group == null) {
      return const SizedBox.shrink();
    }

    return ScheduleSaveScopeCard(
      groupName: group.name,
      selected: _saveTarget,
      onChanged: (target) {
        setState(() {
          _saveTarget = target;
          _saveTargetTouchedByUser = true;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = appL10n(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: Text(_isNewEvent ? l10n.eventCreateTitle : l10n.eventEditTitle),
        leading: BackButton(onPressed: _handleBackNavigation),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _handleSave,
              icon: _isSaving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: const Text('저장'),
              style: FilledButton.styleFrom(
                backgroundColor: PlanFlowColors.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(92, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ResponsiveContent(
            maxWidth: context.planflowWindowInfo.contentMaxWidth,
            child: ListView(
              padding: const EdgeInsets.all(AppConstants.defaultPadding),
              children: [
                Text(
                  _isLoading
                      ? '일정 정보를 불러오는 중입니다.'
                      : _isNewEvent
                          ? '새 일정의 정보를 입력해 주세요.'
                          : '필요한 정보만 수정하고 저장해 주세요.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
                if (_isLoading) ...[
                  const SizedBox(height: AppConstants.sectionSpacing),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: AppConstants.sectionSpacing),
                _buildSaveTargetCard(context),
                if (_selectedGroupForSharing != null)
                  const SizedBox(height: AppConstants.sectionSpacing),
                _buildLeaderInstructionsSection(context),
                CalendarStyleEventEditor(
                  titleController: _titleController,
                  locationController: _locationController,
                  memoController: _memoController,
                  startAt: _startAt,
                  endAt: _endAt,
                  isAllDay: _isAllDay,
                  category: _category,
                  recurrence: _recurrenceSelection,
                  reminderOffset: _reminderOffset,
                  isCritical: _critical,
                  useStrongAlarm: _strongAlarm,
                  locationLat: _locationLat,
                  locationLng: _locationLng,
                  memoMaxLines: 5,
                  initiallyExpandClassification: !_recurrenceSelection.isNone,
                  initiallyExpandCriticalAlarm: _critical,
                  titleValidator: (value) =>
                      (value == null || value.trim().isEmpty)
                          ? '제목을 입력해 주세요.'
                          : null,
                  onStartChanged: (value) {
                    setState(() {
                      final previousStart = _startAt;
                      _startAt = value;
                      _endAt = shiftEventEndWhenStartChanges(
                        previousStart: previousStart,
                        newStart: _startAt,
                        currentEnd: _endAt,
                        endEditedByUser: _endEditedByUser,
                      );
                    });
                  },
                  onEndChanged: (value) {
                    setState(() {
                      _endEditedByUser = true;
                      _endAt = value;
                    });
                  },
                  onAllDayChanged: (value) {
                    setState(() {
                      _isAllDay = value;
                      if (value) {
                        _startAt = DateTime(
                          _startAt.year,
                          _startAt.month,
                          _startAt.day,
                        );
                        if (_endAt != null) {
                          _endAt = DateTime(
                            _endAt!.year,
                            _endAt!.month,
                            _endAt!.day,
                          );
                        }
                      }
                    });
                  },
                  onCategoryChanged: (value) {
                    setState(() {
                      _category = value;
                    });
                  },
                  onRecurrenceChanged: (value) {
                    setState(() {
                      _recurrenceSelection = value;
                    });
                  },
                  onReminderChanged: (value) {
                    setState(() {
                      _reminderOffset = value;
                    });
                  },
                  onCriticalChanged: _handleCriticalChanged,
                  onStrongAlarmChanged: _handleStrongAlarmChanged,
                  onLocationTextChanged: _handleLocationTextChanged,
                  onLocationPick: _pickLocationOnMap,
                  isSearchingLocation: _isLookingUpLocation,
                  extraAfterMemo: TextFormField(
                    controller: _suppliesController,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
                    decoration: const InputDecoration(
                      labelText: '준비물',
                      helperText: '쉼표로 구분해서 입력해 주세요.',
                      prefixIcon: Icon(Icons.checklist_outlined),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _isSaving ? null : _handleSave,
                  icon: _isSaving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_isSaving ? l10n.saving : l10n.save),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _handleBackNavigation,
                  child: Text(l10n.cancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
