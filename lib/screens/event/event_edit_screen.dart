import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/diag_logger.dart';
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
import '../../features/groups/widgets/group_multi_select_sheet.dart';
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
import '../../widgets/planflow_action_buttons.dart';
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
  final AppPermissionService? permissionService;
  final ManualEventSideEffectService sideEffectService;
  final HomeWidgetService homeWidgetService;

  /// 저장 대상 일정 id를 결정한다. 세 후보 중 공백이 아닌 첫 값을 반환하고,
  /// 모두 비어 있으면(= 새 일정 draft) null을 반환한다.
  /// draft는 id가 "" 이므로 반드시 새 일정(createEvent)으로 분기해야 한다 —
  /// 빈 id로 updateEvent를 타면 "Event id is required"로 저장이 실패한다.
  @visibleForTesting
  static String? resolvePersistedEventId({
    required String? loadedEventId,
    required String? routeEventId,
    required String? extraEventId,
  }) {
    for (final candidate in <String?>[
      loadedEventId,
      routeEventId,
      extraEventId,
    ]) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  /// 장소 텍스트 변경 시 이미 저장된 좌표를 지워야 하는지 판정한다.
  /// [isApplyingLoadedEvent]가 true면(서버에서 불러온 값을 프로그램적으로
  /// 채우는 중) 항상 false를 반환한다 — TextField는 프로그램적 대입에도
  /// onChanged를 호출하므로, 이 가드가 없으면 방금 불러온 정상 좌표를
  /// '사용자가 지운 것'으로 오인해 지워버려 다음날 알람이 엉뚱한 장소로 울린다.
  @visibleForTesting
  static bool shouldClearLocationCoordinatesOnTextChange({
    required bool isApplyingLoadedEvent,
    required String changedText,
    required String? resolvedLocationLabel,
    required bool hasCoordinates,
  }) {
    if (isApplyingLoadedEvent) {
      return false;
    }
    final trimmed = changedText.trim();
    if (resolvedLocationLabel != null &&
        trimmed == resolvedLocationLabel.trim()) {
      return false;
    }
    return hasCoordinates;
  }

  /// DB 저장 `notify_at`에서 역산한 분 단위 오프셋을 검증하고,
  /// 유효 범위(0~1440분)를 벗어나면 기본값으로 폴백한다.
  /// 예: 일정이 7일 뒤로 이동했으나 notify_at이 예전 값이면
  /// 역산값이 10000분+ 같은 비정상값이 되는데, 이를 60분(기본값)으로 클램프.
  @visibleForTesting
  static Duration? normalizeReminderOffset(int minutesDifference) {
    if (minutesDifference < 0 || minutesDifference > 1440) {
      return const Duration(minutes: 60); // 유효 범위 벗어남 → 기본값(1시간)으로 폴백
    }
    return Duration(minutes: minutesDifference);
  }

  @override
  State<EventEditScreen> createState() => _EventEditScreenState();
}

/// 그룹 리더의 "그룹에 일정을 공유할까요?" 다이얼로그 응답.
class _LeaderShareChoice {
  const _LeaderShareChoice({
    required this.share,
    required this.dontAskAgain,
  });

  final bool share;
  final bool dontAskAgain;
}

class _EventEditScreenState extends State<EventEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _suppliesController;
  GroupContextProvider? _groupContextProvider;
  bool _ownsGroupContextProvider = false;
  ScheduleSaveTarget _saveTarget = ScheduleSaveTarget.personalOnly;
  // 사용자가 저장 범위를 직접 바꾼 뒤에는 자동 공유 기본값이 덮어쓰지 않도록 표시.
  bool _saveTargetTouchedByUser = false;
  // 여러 그룹에 소속된 경우 공유할 그룹 id 집합. 기본값=자동선택된 대표 그룹 1개.
  final Set<String> _selectedGroupIds = <String>{};

  // 리더 지시(그룹 이벤트 코멘트) 관련
  List<GroupEventCommentModel> _leaderInstructions = const [];
  bool _isLoadingInstructions = false;
  bool _isConfirmingInstruction = false;
  late DateTime _startAt;
  DateTime? _endAt;
  double? _locationLat;
  double? _locationLng;
  String? _resolvedLocationLabel;
  late bool _critical;
  late bool _strongAlarm;
  late RecurrenceSelection _recurrenceSelection;
  String _category = '기타';
  Duration? _reminderOffset = ReminderOffsetSelector.defaultValue;
  EventModel? _loadedEvent;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isLookingUpLocation = false;
  bool _endEditedByUser = false;
  // 서버에서 불러온 값을 컨트롤러에 프로그램적으로 채우는 동안 true.
  // 이 사이 _locationController.text 대입도 TextField.onChanged를 그대로
  // 발생시키므로(confirm_screen.dart의 _isApplyingHydration과 동일 이유),
  // 이 플래그가 없으면 방금 불러온 정상 좌표를 '사용자가 지운 것'으로 오인해
  // _handleLocationTextChanged가 null로 지워버릴 수 있다.
  bool _isApplyingLoadedEvent = false;
  Timer? _locationDebounceTimer;

  // 저장 대상이 될 실제 일정 id(빈 문자열 제외). AI 대화에서 넘어온 새 일정
  // draft는 id가 비어 있으므로, _loadedEvent가 있어도 id가 비면 새 일정으로 본다.
  String? get _persistedEventId => EventEditScreen.resolvePersistedEventId(
        loadedEventId: _loadedEvent?.id,
        routeEventId: widget.eventId,
        extraEventId: widget.event?.id,
      );

  bool get _isNewEvent => _persistedEventId == null;

  // route/extra로 넘어온 id만(로드된 이벤트 제외). 저장 전 상세 재조회 판단용.
  String? get _resolvedEventId => EventEditScreen.resolvePersistedEventId(
        loadedEventId: null,
        routeEventId: widget.eventId,
        extraEventId: widget.event?.id,
      );

  EventRepository get _repository =>
      widget.eventRepository ?? EventRepository.supabase();

  GroupEventRepository get _groupEventRepository =>
      widget.groupEventRepository ?? GroupEventRepository.supabase();

  AppPermissionService get _permissionService =>
      widget.permissionService ?? AppPermissionService();

  /// 알람 예약 후 권한이 부족한 경우 사용자에게 안내 다이얼로그를 표시.
  ///
  /// 정확한 알람 권한 또는 배터리 최적화 예외가 꺼져 있을 때만 표시.
  /// 저장 자체를 막지 않으며, 다이얼로그는 권한 화면으로 이동하는 버튼을 제공.
  Future<void> _showAlarmPermissionGuardIfNeeded() async {
    if (!mounted) {
      return;
    }
    try {
      final snapshot = await _permissionService.checkAll();
      if (!mounted) {
        return;
      }
      // 둘 다 허용된 경우 다이얼로그 없이 조용히 진행.
      if (snapshot.alarmWillFire) {
        return;
      }

      final missingExact = !snapshot.exactAlarmsGranted;
      final missingBattery = !snapshot.batteryOptimizationIgnored;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _AlarmPermissionGuardDialog(
          missingExactAlarm: missingExact,
          missingBatteryOptimization: missingBattery,
          onFixExactAlarm: () async {
            Navigator.of(dialogContext).pop();
            await _permissionService.openAlarmSettings();
          },
          onFixBatteryOptimization: () async {
            Navigator.of(dialogContext).pop();
            await _permissionService.requestIgnoreBatteryOptimizations();
          },
        ),
      );
    } catch (error) {
      debugPrint('Alarm permission guard check failed (non-blocking): $error');
    }
  }

  DateTime _eventRangeEnd(DateTime startAt, DateTime? endAt) {
    if (endAt != null && endAt.isAfter(startAt)) {
      return endAt;
    }
    if (endAt != null && !DateUtils.isSameDay(startAt, endAt)) {
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
    final shouldClear = EventEditScreen.shouldClearLocationCoordinatesOnTextChange(
      isApplyingLoadedEvent: _isApplyingLoadedEvent,
      changedText: value,
      resolvedLocationLabel: _resolvedLocationLabel,
      hasCoordinates: _locationLat != null || _locationLng != null,
    );
    if (shouldClear) {
      DiagLogger.log(
        'GeoResolve',
        '[EditScreen] 좌표 초기화: 텍스트변경 "$value" '
            '이전좌표=($_locationLat,$_locationLng)',
      );
      setState(() {
        _locationLat = null;
        _locationLng = null;
        _resolvedLocationLabel = null;
      });
    }
    if (_isApplyingLoadedEvent) {
      // 서버에서 불러온 값을 채우는 중 발생한 이벤트 — 자동 재검색은 트리거하지 않는다.
      return;
    }
    final trimmed = value.trim();
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
      DiagLogger.log(
        'GeoResolve',
        '[EditScreen] 자동해석 성공: "$query" -> "${best.name}" '
            'lat=${best.latitude} lng=${best.longitude}',
      );
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
      DiagLogger.log(
        'GeoResolve',
        '[EditScreen] 스킵: 쿼리="${query.isEmpty ? '(빈값)' : query}" '
        '이미보유=${_locationLat != null && _locationLng != null}',
      );
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
      DiagLogger.log('GeoResolve', '[EditScreen] 검색시작: 쿼리="$query"');
      final results = await LocationLookupService().search(
        query,
        origin: null,
      );
      DiagLogger.log(
        'GeoResolve',
        '[EditScreen] 검색결과: 쿼리="$query" 결과수=${results.length}'
        '${results.isNotEmpty ? ' 1위="${results.first.name}" lat=${results.first.latitude} lng=${results.first.longitude}' : ''}',
      );
      if (!mounted ||
          query != _locationController.text.trim() ||
          results.isEmpty) {
        if (results.isEmpty) {
          DiagLogger.log(
            'GeoResolve',
            '[EditScreen] 실패: 쿼리="$query" 결과없음 → 좌표 미설정',
          );
        }
        return;
      }

      final selected = results.first;
      final resolvedLabel = selected.bestPlaceLabel.trim();
      _isApplyingLoadedEvent = true;
      setState(() {
        if (resolvedLabel.isNotEmpty) {
          _locationController.text = resolvedLabel;
        }
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel =
            resolvedLabel.isNotEmpty ? resolvedLabel : query;
      });
      _isApplyingLoadedEvent = false;
      DiagLogger.log(
        'GeoResolve',
        '[EditScreen] 성공: 쿼리="$query" 선택="${selected.name}" lat=${selected.latitude} lng=${selected.longitude}',
      );
    } catch (error, stackTrace) {
      debugPrint(
          'EventEditScreen save-time location resolution failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      DiagLogger.log('GeoResolve', '[EditScreen] 오류: 쿼리="$query" error=$error');
    } finally {
      if (mounted) {
        setState(() {
          _isLookingUpLocation = false;
        });
      }
    }
  }

  void _handleBackNavigation() {
    if (context.canPop()) {
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
                planflowCancelConfirmButtons(
                  onCancel: () => Navigator.of(dialogContext).pop(false),
                  onConfirm: () => Navigator.of(dialogContext).pop(true),
                  cancelLabel: '나중에',
                  confirmLabel: '허용하러 가기',
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
    var userId = authProvider.userId;
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
      await _ensureDefaultGroupSelection(userId.trim());
      unawaited(_applyAutoShareDefaultIfNeeded());
    }
  }

  /// 소속된 활성 그룹 전체.
  List<GroupModel> get _allActiveGroups =>
      _groupContextProvider?.groups
          .where((group) => group.isActive)
          .toList(growable: false) ??
      const <GroupModel>[];

  /// 공유 대상으로 선택된 활성 그룹들.
  List<GroupModel> get _selectedGroupsForSharing => _allActiveGroups
      .where((group) => _selectedGroupIds.contains(group.id))
      .toList(growable: false);

  /// 아직 그룹 선택이 없으면 가장 최근에 공유했던 그룹(들)을, 없으면 자동선택된
  /// 대표 그룹 1개를 기본 선택한다.
  Future<void> _ensureDefaultGroupSelection(String? userId) async {
    if (_selectedGroupIds.isNotEmpty) {
      return;
    }
    final activeIds = _allActiveGroups.map((group) => group.id).toSet();
    if (activeIds.isEmpty) {
      return;
    }

    if (userId != null && userId.trim().isNotEmpty) {
      final lastUsed = await _readLastSharedGroupIds(userId.trim());
      final restored = lastUsed.where(activeIds.contains).toSet();
      if (restored.isNotEmpty) {
        if (mounted) {
          setState(() {
            _selectedGroupIds.addAll(restored);
          });
        }
        return;
      }
    }

    final primary = _groupContextProvider?.selectedGroup;
    if (primary != null && primary.isActive) {
      if (mounted) {
        setState(() {
          _selectedGroupIds.add(primary.id);
        });
      }
    }
  }

  String _lastSharedGroupsPrefKey(String userId) =>
      'planflow:group_last_shared_ids:v1:$userId';

  Future<Set<String>> _readLastSharedGroupIds(String userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored =
          preferences.getStringList(_lastSharedGroupsPrefKey(userId));
      if (stored == null || stored.isEmpty) {
        return const <String>{};
      }
      return stored.toSet();
    } catch (error) {
      debugPrint('EventEditScreen last shared groups read error: $error');
      return const <String>{};
    }
  }

  Future<void> _persistLastSharedGroupIds(
    String userId,
    Set<String> groupIds,
  ) async {
    if (groupIds.isEmpty) {
      return;
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(
        _lastSharedGroupsPrefKey(userId),
        groupIds.toList(growable: false),
      );
    } catch (error) {
      debugPrint('EventEditScreen last shared groups persist error: $error');
    }
  }

  /// 저장범위 카드 표시/자동공유 기본값 계산에 쓸 대표 그룹.
  GroupModel? get _selectedGroupForSharing {
    final selected = _selectedGroupsForSharing;
    if (selected.isNotEmpty) {
      return selected.first;
    }
    final primary = _groupContextProvider?.selectedGroup;
    if (primary != null && primary.isActive) {
      return primary;
    }
    return null;
  }

  bool get _canShareToSelectedGroup => _selectedGroupForSharing != null;

  Future<void> _pickGroupsForSharing() async {
    final all = _allActiveGroups;
    if (all.isEmpty) {
      return;
    }
    final result = await showGroupMultiSelectSheet(
      context,
      options: all
          .map((group) => GroupSelectOption(id: group.id, name: group.name))
          .toList(growable: false),
      initiallySelected: Set<String>.from(_selectedGroupIds),
      title: '공유할 그룹 선택',
    );
    if (result != null && mounted) {
      setState(() {
        _selectedGroupIds
          ..clear()
          ..addAll(result);
        _saveTargetTouchedByUser = true;
      });
    }
  }

  bool get _shouldSavePersonalEvent =>
      !_canShareToSelectedGroup ||
      _saveTarget == ScheduleSaveTarget.personalOnly ||
      _saveTarget == ScheduleSaveTarget.personalAndGroup;

  bool get _shouldSaveGroupEvent =>
      _canShareToSelectedGroup &&
      (_saveTarget == ScheduleSaveTarget.personalAndGroup ||
          _saveTarget == ScheduleSaveTarget.groupOnly);

  /// 그룹 공유 관련 로직(자동 공유 기본값, 리더 지시 로드)에서 쓸 현재
  /// 사용자 id를 해석한다. _loadGroupContextIfNeeded와 동일하게
  /// authProvider.userId를 우선하고, 없으면 Supabase currentUser로
  /// 폴백한다. 이 화면의 저장 로직(_handleSave)은 여전히
  /// Supabase.instance.client.auth.currentUser에서 직접 user.id를 읽으므로
  /// (이 파일에 별도 _currentUserId() 헬퍼가 없었음), 저장 자체는 그대로 두고
  /// 그룹 공유 판단에만 이 헬퍼를 사용한다.
  String? _currentUserIdForGroupSharing() {
    final fromAuthProvider = authProvider.userId;
    if (fromAuthProvider != null && fromAuthProvider.trim().isNotEmpty) {
      return fromAuthProvider;
    }
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
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

    final userId = _currentUserIdForGroupSharing();
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

  /// 그룹 리더가 저장 범위를 직접 고르지 않았고, 이 그룹에 대한 공유 여부를
  /// 아직 결정(다시 보지 않기/설정탭 토글)한 적이 없으면 등록 직전에 물어본다.
  /// 새 일정 등록에만 적용(기존 일정 수정은 대상 아님).
  Future<void> _maybePromptLeaderAutoShareIfNeeded() async {
    if (!_isNewEvent) {
      return;
    }
    if (_saveTargetTouchedByUser) {
      return;
    }
    final group = _selectedGroupForSharing;
    if (group == null) {
      return;
    }
    final isLeaderOfGroup = _groupContextProvider?.leaderGroups
            .any((leaderGroup) => leaderGroup.id == group.id) ??
        false;
    if (!isLeaderOfGroup) {
      return;
    }

    final userId = _currentUserIdForGroupSharing();
    if (userId == null || userId.trim().isEmpty) {
      return;
    }

    try {
      final preferences = await SharedPreferences.getInstance();
      final key = _autoSharePrefKey(userId, group.id);
      if (preferences.containsKey(key)) {
        // 이미 결정된 값이 있으면(다시 보지 않기 또는 설정탭) 물어보지 않고 그대로 적용.
        final enabled = preferences.getBool(key) ?? false;
        if (enabled && mounted && !_saveTargetTouchedByUser) {
          setState(() {
            _saveTarget = ScheduleSaveTarget.personalAndGroup;
          });
        }
        return;
      }

      if (!mounted) {
        return;
      }
      final choice = await _showLeaderShareConfirmDialog(group.name);
      if (choice == null || !mounted || _saveTargetTouchedByUser) {
        return;
      }

      if (choice.dontAskAgain) {
        await preferences.setBool(key, choice.share);
      }
      setState(() {
        _saveTarget = choice.share
            ? ScheduleSaveTarget.personalAndGroup
            : ScheduleSaveTarget.personalOnly;
      });
    } catch (error) {
      debugPrint('EventEditScreen leader auto-share prompt error: $error');
    }
  }

  Future<_LeaderShareChoice?> _showLeaderShareConfirmDialog(
    String groupName,
  ) {
    var dontAskAgain = false;
    return showDialog<_LeaderShareChoice>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('그룹에 일정을 공유할까요?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('"$groupName" 그룹의 리더로서 이 일정을 그룹에도 공유할 수 있어요.'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const ValueKey('leader-share-dialog-dont-ask-again'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: dontAskAgain,
                    onChanged: (value) {
                      setDialogState(() {
                        dontAskAgain = value ?? false;
                      });
                    },
                    title: const Text('다시 보지 않기'),
                  ),
                ],
              ),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              actions: [
                PlanFlowActionButtons(
                  buttons: [
                    PlanFlowActionButton(
                      buttonKey:
                          const ValueKey('leader-share-decline-button'),
                      label: '아니요',
                      type: ActionButtonType.secondary,
                      flex: 1,
                      onPressed: () => Navigator.of(dialogContext).pop(
                        _LeaderShareChoice(
                          share: false,
                          dontAskAgain: dontAskAgain,
                        ),
                      ),
                    ),
                    PlanFlowActionButton(
                      buttonKey: const ValueKey('leader-share-accept-button'),
                      label: '공유',
                      type: ActionButtonType.primary,
                      flex: 1,
                      onPressed: () => Navigator.of(dialogContext).pop(
                        _LeaderShareChoice(
                          share: true,
                          dontAskAgain: dontAskAgain,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<GroupEventModel?> _createGroupEventFromDraft(
    EventModel draft, {
    required GroupModel group,
    String? personalEventId,
  }) async {
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

  /// 이미 공유된 그룹일정들 중 이번 수정 내용을 반영할 그룹을 고른다.
  /// 기본은 전체 선택. 반환=선택된 group_event id 집합(빈 집합이면 개인만 수정),
  /// null이면 사용자가 취소(저장 자체를 중단).
  Future<Set<String>?> _chooseLinkedGroupsToUpdate(
    List<GroupEventModel> linkedGroupEvents,
  ) {
    return showGroupMultiSelectSheet(
      context,
      options: linkedGroupEvents
          .map((groupEvent) => GroupSelectOption(
                id: groupEvent.id,
                name: _groupNameForId(groupEvent.groupId),
              ))
          .toList(growable: false),
      initiallySelected:
          linkedGroupEvents.map((groupEvent) => groupEvent.id).toSet(),
      title: '수정 내용을 반영할 그룹',
      confirmLabel: '수정',
      allowEmpty: true,
    );
  }

  String _groupNameForId(String groupId) {
    for (final group in _allActiveGroups) {
      if (group.id == groupId) {
        return group.name;
      }
    }
    return '그룹';
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
    debugPrint('EventEditScreen save start');
    final formState = _formKey.currentState;
    if (formState == null) {
      debugPrint('EventEditScreen save blocked: form state missing');
      _showMessage('저장 폼 상태를 찾지 못했어요. 화면을 다시 열어 주세요.');
      return;
    }
    final isValid = formState.validate();
    if (!isValid) {
      debugPrint('EventEditScreen save blocked: form validation failed');
      _showMessage('필수 항목(제목 등)을 확인해 주세요.');
      _revealFirstFormError();
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      debugPrint('EventEditScreen save try entered');
      if (!AppEnv.isSupabaseReady) {
        debugPrint('EventEditScreen save blocked: supabase env missing');
        _showMessage('Supabase 빌드 설정값이 주입되지 않았습니다.');
        return;
      }

      try {
        debugPrint('EventEditScreen save before syncCurrentSession');
        await authProvider.syncCurrentSession();
        debugPrint('EventEditScreen save after syncCurrentSession');
      } catch (error) {
        debugPrint('EventEditScreen session sync failed before save: $error');
      }

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        debugPrint('EventEditScreen save blocked: user missing');
        _showMessage('로그인 후 저장할 수 있습니다.');
        return;
      }

      await _maybePromptLeaderAutoShareIfNeeded();
      if (!mounted) {
        debugPrint(
          'EventEditScreen save stopped: unmounted after leader share prompt',
        );
        return;
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
        id: _persistedEventId ?? '',
        userId: user.id,
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
        debugPrint('EventEditScreen save before findOverlappingEvents');
        final overlappingEvents = await _repository.findOverlappingEvents(
          rangeStart: overlapStart,
          rangeEnd: _eventRangeEnd(overlapStart, updatedEvent.endAt),
          userId: user.id,
          excludedEventId: _loadedEvent?.id ?? updatedEvent.id,
        );
        debugPrint('EventEditScreen save after findOverlappingEvents');
        final duplicateWarningEvents = filterDuplicateWarningEvents(
          draft: updatedEvent,
          candidates: overlappingEvents,
        );
        if (!mounted) {
          debugPrint(
              'EventEditScreen save stopped: unmounted after overlap check');
          return;
        }
        if (duplicateWarningEvents.isNotEmpty) {
          final shouldContinue =
              await _showOverlapWarning(duplicateWarningEvents);
          if (!mounted) {
            debugPrint(
                'EventEditScreen save stopped: unmounted after overlap warning');
            return;
          }
          if (!shouldContinue) {
            debugPrint('EventEditScreen save canceled: overlap warning');
            _showMessage('중복 일정 경고에서 저장을 취소했어요.');
            return;
          }
        }
      }

      final previousStartAt = _loadedEvent?.startAt;
      // 이미 여러 그룹에 공유된 일정이면, 연동된 그룹일정 전체를 불러와
      // "어느 그룹에 변경을 반영할지" 체크리스트로 물어본다(기본 전체 선택).
      final existingLinkedGroupEvents = (!_isNewEvent && _loadedEvent != null)
          ? await _groupEventRepository
              .getGroupEventsByPersonalEventId(_loadedEvent!.id)
          : const <GroupEventModel>[];
      Set<String>? groupEventIdsToUpdate;
      // 저장 범위를 "개인 일정만"으로 명시적으로 고른 경우엔 그룹을 전혀
      // 건드리지 않으므로 "반영할 그룹" 시트를 띄우면 안 된다. 예전엔
      // _shouldSavePersonalEvent(=개인 저장 여부)만 봐서, personalOnly를
      // 골라도 이미 다른 그룹에 공유돼 있던 일정이면 이 시트가 떴다.
      if (existingLinkedGroupEvents.isNotEmpty &&
          _shouldSavePersonalEvent &&
          _saveTarget != ScheduleSaveTarget.personalOnly) {
        groupEventIdsToUpdate =
            await _chooseLinkedGroupsToUpdate(existingLinkedGroupEvents);
        if (groupEventIdsToUpdate == null || !mounted) {
          debugPrint(
              'EventEditScreen save canceled: linked group edit scope sheet');
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

      if (existingLinkedGroupEvents.isNotEmpty) {
        // 이미 공유된 일정 수정: 선택된 연동 그룹일정에만 변경을 전파한다.
        // (신규 그룹 추가는 생성 흐름에서만, 여기선 기존 공유 그룹만 대상)
        if (savedEvent != null && groupEventIdsToUpdate != null) {
          for (final groupEvent in existingLinkedGroupEvents) {
            if (groupEventIdsToUpdate.contains(groupEvent.id)) {
              await _updateLinkedGroupEventFromDraft(savedEvent, groupEvent.id);
            }
          }
        }
      } else if (_shouldSaveGroupEvent) {
        // 아직 공유 안 된 일정을 그룹에 공유: 선택한 그룹마다 그룹일정 생성.
        final targetGroups = _selectedGroupsForSharing;
        if (savedEvent == null) {
          for (final group in targetGroups) {
            await _createGroupEventFromDraft(updatedEvent, group: group);
          }
        } else {
          String? primaryGroupEventId;
          for (final group in targetGroups) {
            final createdGroupEvent = await _createGroupEventFromDraft(
              savedEvent,
              group: group,
              personalEventId: savedEvent.id,
            );
            primaryGroupEventId ??= createdGroupEvent?.id;
          }
          if (primaryGroupEventId != null) {
            savedEvent = await _repository.updateEvent(
              savedEvent.copyWith(groupEventId: primaryGroupEventId),
            );
          }
        }
        unawaited(
          _persistLastSharedGroupIds(
            user.id,
            targetGroups.map((group) => group.id).toSet(),
          ),
        );
      }

      if (savedEvent != null) {
        unawaited(
          _runPostSaveSideEffects(
            userId: user.id,
            savedEvent: savedEvent,
            previousStartAt: previousStartAt,
          ),
        );
      }

      if (mounted) {
        final actionText = savedEvent == null
            ? '그룹에 일정을 공유했어요.'
            : _isNewEvent
                ? '일정을 만들었습니다.'
                : '일정을 수정했습니다.';
        _showMessage(actionText);
        EventRefreshBus.instance.notifyChanged(
          reason: _isNewEvent ? 'event_created' : 'event_updated',
          eventId: savedEvent?.id,
          startAt: savedEvent?.startAt ?? updatedEvent.startAt,
        );
        if (savedEvent != null) {
          // 알람 권한 가드 — 저장 성공 후 권한이 누락된 경우 안내 다이얼로그.
          // 저장 자체는 항상 성공 처리. 다이얼로그 dismiss 후 캘린더로 이동.
          await _showAlarmPermissionGuardIfNeeded();
        }
        if (mounted) {
          context.go(AppRoutes.calendar);
        }
      }
    } on StateError catch (error) {
      debugPrint('EventEditScreen save state error: $error');
      DiagLogger.log('EventEditSave', 'state_error error=$error');
      if (mounted) {
        _showMessage(_messageForSaveStateError(error));
      }
    } on PostgrestException catch (error) {
      debugPrint(
        'EventEditScreen save postgrest error: '
        'code=${error.code} message=${error.message} details=${error.details}',
      );
      DiagLogger.log(
        'EventEditSave',
        'postgrest_error code=${error.code} message=${error.message} '
            'details=${error.details}',
      );
      if (mounted) {
        _showMessage(_messageForPostgrestError(error));
      }
    } catch (error, stackTrace) {
      debugPrint('EventEditScreen save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      DiagLogger.log(
        'EventEditSave',
        'unexpected_error error=$error stack=$stackTrace',
      );
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

  void _revealFirstFormError() {
    final formContext = _formKey.currentContext;
    if (formContext == null) {
      return;
    }

    BuildContext? firstErrorContext;
    void visit(Element element) {
      if (firstErrorContext != null) {
        return;
      }
      if (element is StatefulElement) {
        final state = element.state;
        if (state is FormFieldState<dynamic> && state.hasError) {
          firstErrorContext = element;
          return;
        }
      }
      element.visitChildren(visit);
    }

    (formContext as Element).visitChildren(visit);
    final targetContext = firstErrorContext ?? formContext;
    Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 250),
      alignment: 0.1,
    );
    Focus.maybeOf(targetContext)?.requestFocus();
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
      _isApplyingLoadedEvent = true;
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
        _category = event.category;
      });
      _isApplyingLoadedEvent = false;
      DiagLogger.log(
        'GeoResolve',
        '[EditScreen] fetchEvent 로드 완료 id=${event.id} '
            'loc="${event.location ?? ''}" '
            'lat=${event.locationLat} lng=${event.locationLng}',
      );
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
      currentUserId = Supabase.instance.client.auth.currentUser?.id;
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
      final normalized = EventEditScreen.normalizeReminderOffset(minutes);
      setState(() {
        _reminderOffset = normalized;
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
          PlanFlowActionButtons(
            buttons: [
              PlanFlowActionButton(
                label: '이 일정만',
                onPressed: () => Navigator.of(context).pop('single'),
                type: ActionButtonType.secondary,
                flex: 1,
              ),
              PlanFlowActionButton(
                label: '이후 모든 일정',
                onPressed: () => Navigator.of(context).pop('future'),
                type: ActionButtonType.secondary,
                flex: 1,
              ),
              PlanFlowActionButton(
                label: '전체 반복 일정',
                onPressed: () => Navigator.of(context).pop('all'),
                type: ActionButtonType.primary,
                flex: 2,
              ),
            ],
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
      _isApplyingLoadedEvent = true;
      setState(() {
        _locationController.text =
            resolvedLabel.isNotEmpty ? resolvedLabel : selected.label;
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel =
            resolvedLabel.isNotEmpty ? resolvedLabel : selected.label.trim();
      });
      _isApplyingLoadedEvent = false;
      DiagLogger.log(
        'GeoResolve',
        '[EditScreen] 지도 선택 저장: "$resolvedLabel" '
            'lat=${selected.latitude} lng=${selected.longitude}',
      );
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

    final selectedGroups = _selectedGroupsForSharing;
    final summary = selectedGroups.length <= 1
        ? group.name
        : '${selectedGroups.first.name} 외 ${selectedGroups.length - 1}곳';

    return ScheduleSaveScopeCard(
      groupName: summary,
      selected: _saveTarget,
      onChanged: (target) {
        setState(() {
          _saveTarget = target;
          _saveTargetTouchedByUser = true;
        });
      },
      onPickGroups:
          _allActiveGroups.length > 1 ? _pickGroupsForSharing : null,
      selectedGroupCount:
          selectedGroups.isEmpty ? 1 : selectedGroups.length,
      totalGroupCount: _allActiveGroups.length,
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

/// 알람 권한이 부족할 때 저장 직후 표시하는 안내 다이얼로그.
///
/// 정확한 알람 권한 누락 / 배터리 최적화 예외 미적용 여부에 따라
/// 해당 설정 화면으로 이동하는 버튼을 표시한다.
/// [저장을 막지 않으며] dismiss 후 캘린더로 이동한다.
class _AlarmPermissionGuardDialog extends StatelessWidget {
  const _AlarmPermissionGuardDialog({
    required this.missingExactAlarm,
    required this.missingBatteryOptimization,
    required this.onFixExactAlarm,
    required this.onFixBatteryOptimization,
  });

  final bool missingExactAlarm;
  final bool missingBatteryOptimization;
  final VoidCallback onFixExactAlarm;
  final VoidCallback onFixBatteryOptimization;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missingBoth = missingExactAlarm && missingBatteryOptimization;

    return AlertDialog(
      icon: const Icon(
        Icons.alarm_off_outlined,
        color: PlanFlowColors.primaryMid,
        size: 32,
      ),
      title: const Text('알람이 제때 울리지 않을 수 있어요'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            missingBoth
                ? '정확한 알람 권한과 절전(배터리 최적화) 예외가 꺼져 있습니다. '
                    '두 가지 모두 켜야 알람이 정확한 시각에 울립니다.'
                : missingExactAlarm
                    ? '정확한 알람 권한이 꺼져 있습니다. '
                        'Android 알람 설정에서 PlanFlow를 허용해야 알람이 정확한 시각에 울립니다.'
                    : '절전(배터리 최적화) 예외가 꺼져 있습니다. '
                        '삼성·샤오미 등 일부 기기에서 백그라운드 알람을 막을 수 있어요.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          if (missingExactAlarm) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onFixExactAlarm,
              icon: const Icon(Icons.alarm_outlined, size: 18),
              label: const Text('정확한 알람 설정으로 이동'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                foregroundColor: PlanFlowColors.primaryMid,
                side: const BorderSide(color: PlanFlowColors.primaryFaint),
              ),
            ),
          ],
          if (missingBatteryOptimization) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onFixBatteryOptimization,
              icon: const Icon(Icons.battery_saver_outlined, size: 18),
              label: const Text('절전 예외 설정으로 이동'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                foregroundColor: PlanFlowColors.primaryMid,
                side: const BorderSide(color: PlanFlowColors.primaryFaint),
              ),
            ),
          ],
        ],
      ),
      actions: [
        PlanFlowActionButtons(
          buttons: [
            PlanFlowActionButton(
              label: '나중에',
              onPressed: () => Navigator.of(context).pop(),
              type: ActionButtonType.secondary,
            ),
          ],
        ),
      ],
    );
  }
}
