import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/event_metadata.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../core/analytics_service.dart';
import '../../providers/auth_provider.dart';
import '../location/location_pick_flow.dart';
import '../../services/review_service.dart';
import '../../services/calendar_auto_sync_service.dart';
import '../../services/departure_alarm_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/event_preparation_service.dart';
import '../../services/app_permission_service.dart';
import '../../services/gpt_service.dart';
import '../../services/home_widget_service.dart';
import '../../data/models/user_settings_model.dart';
import '../../services/location_lookup_service.dart';
import '../../services/manual_event_side_effect_service.dart';
import '../../services/notification_service.dart';
import '../../services/smart_preparation_alarm_service.dart';
import '../../services/travel_time_buffer_service.dart';
import '../../widgets/calendar_style_event_editor.dart';
import '../../widgets/overlap_warning_dialog.dart';
import '../../widgets/recurrence_selector.dart';
import '../../widgets/reminder_offset_selector.dart';

class ConfirmScreen extends StatefulWidget {
  ConfirmScreen({
    super.key,
    this.parsedSchedule = const <String, dynamic>{},
    this.userId,
    this.eventRepository,
    GptService? gptService,
    ConfirmScreenBackend? backend,
    NotificationService? notificationService,
    HomeWidgetService? homeWidgetService,
    LocationLookupService? locationLookupService,
    SmartPreparationAlarmService? smartPreparationAlarmService,
    this.permissionService,
    TravelTimeBufferService? travelTimeBufferService,
  })  : backend = backend ?? const SupabaseConfirmScreenBackend(),
        gptService = gptService ?? GptService(),
        notificationService = notificationService ?? NotificationService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService(),
        locationLookupService =
            locationLookupService ?? LocationLookupService(),
        smartPreparationAlarmService = smartPreparationAlarmService ??
            SmartPreparationAlarmService(
              notificationService: notificationService,
            ),
        travelTimeBufferService =
            travelTimeBufferService ?? TravelTimeBufferService();

  final Map<String, dynamic> parsedSchedule;
  final String? userId;
  final EventRepository? eventRepository;
  final GptService gptService;
  final ConfirmScreenBackend backend;
  final NotificationService notificationService;
  final HomeWidgetService homeWidgetService;
  final LocationLookupService locationLookupService;
  final SmartPreparationAlarmService smartPreparationAlarmService;
  final AppPermissionService? permissionService;
  final TravelTimeBufferService travelTimeBufferService;

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

abstract class ConfirmScreenBackend {
  const ConfirmScreenBackend();

  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  });

  Future<void> insertPreActions(List<Map<String, dynamic>> payloads);

  Future<void> insertReminders(List<Map<String, dynamic>> payloads);

  Future<void> insertLocationHistory(Map<String, dynamic> payload);

  Future<void> insertVoiceLog(Map<String, dynamic> payload);
}

class SupabaseConfirmScreenBackend extends ConfirmScreenBackend {
  const SupabaseConfirmScreenBackend();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<String>> fetchPastSupplies({
    required String userId,
    required String location,
  }) async {
    final response = await _client
        .from('location_history')
        .select('supplies, visited_at')
        .eq('user_id', userId)
        .eq('location', location)
        .order('visited_at', ascending: false)
        .limit(10);

    final supplies = <String>[];
    final seen = <String>{};

    for (final row in response as List<dynamic>) {
      final rowMap = Map<String, dynamic>.from(row as Map);
      final rowSupplies = rowMap['supplies'];
      if (rowSupplies is! List) {
        continue;
      }

      for (final item in rowSupplies) {
        final supply = item.toString().trim();
        if (supply.isEmpty || seen.contains(supply)) {
          continue;
        }
        seen.add(supply);
        supplies.add(supply);
      }
    }

    return supplies;
  }

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _client.from('pre_actions').insert(payloads);
  }

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _client.from('reminders').insert(payloads);
  }

  @override
  Future<void> insertLocationHistory(Map<String, dynamic> payload) async {
    await _client.from('location_history').insert(payload);
  }

  @override
  Future<void> insertVoiceLog(Map<String, dynamic> payload) async {
    await _client.from('voice_logs').insert(payload);
  }
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _newSupplyController;
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );
  final FocusNode _newSupplyFocusNode = FocusNode();
  final GlobalKey _suppliesKey = GlobalKey();
  final GlobalKey _preActionsKey = GlobalKey();
  late final List<_SupplyDraft> _supplies;
  late final List<_PreActionDraft> _preActions;
  late DateTime _startAt;
  DateTime? _endAt;
  double? _locationLat;
  double? _locationLng;
  String? _resolvedLocationLabel;
  late RecurrenceSelection _recurrenceSelection;
  bool _isAllDay = false;
  bool _isMultiDay = false;
  String _category = '기타';
  late bool _isCritical;
  bool _isSaving = false;
  bool _isLoadingPastSupplies = false;
  bool _isLookingUpLocation = false;
  bool _isHydratingParsedSchedule = false;
  Duration? _reminderOffset = ReminderOffsetSelector.defaultValue;
  List<String> _pastSupplies = const <String>[];
  List<String> _participants = const <String>[];
  List<String> _targets = const <String>[];
  Timer? _locationDebounce;
  String? _supplyErrorText;
  String? _hydrateMessage;
  String? _selectedAmbiguousPurpose;
  bool _isApplyingHydration = false;
  bool _titleEditedByUser = false;
  bool _locationEditedByUser = false;
  bool _memoEditedByUser = false;
  bool _startEditedByUser = false;
  bool _endEditedByUser = false;

  bool get _parseFailed => widget.parsedSchedule['parse_failed'] == true;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['title']) ?? '',
    );
    _locationController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['location']) ?? '',
    );
    _memoController = TextEditingController(
      text: _stringValue(widget.parsedSchedule['memo']) ?? '',
    );
    _newSupplyController = TextEditingController();
    _supplies = _stringListValue(
      widget.parsedSchedule['supplies'],
    ).map(_SupplyDraft.new).toList(growable: true);
    _participants = _stringListValue(widget.parsedSchedule['participants']);
    _targets = _stringListValue(widget.parsedSchedule['targets']);
    _preActions = _initialPreActions();
    _startAt = _safeStartAt(widget.parsedSchedule['start_at']);
    _endAt = _safeEndAt(widget.parsedSchedule['end_at'], _startAt);
    _locationLat = _doubleValue(widget.parsedSchedule['location_lat']);
    _locationLng = _doubleValue(widget.parsedSchedule['location_lng']);
    if (_locationLat != null && _locationLng != null) {
      _resolvedLocationLabel = _locationController.text.trim();
    }
    _recurrenceSelection = RecurrenceSelection.fromRRule(
      _stringValue(widget.parsedSchedule['recurrence_rule']),
    );
    _isAllDay = widget.parsedSchedule['is_all_day'] == true;
    _isMultiDay = widget.parsedSchedule['is_multi_day'] == true;
    _category = _categoryValue(widget.parsedSchedule['category']);
    _isCritical = widget.parsedSchedule['is_critical'] == true;
    _titleController.addListener(_markTitleEdited);
    _locationController.addListener(_markLocationEdited);
    _memoController.addListener(_markMemoEdited);
    _locationController.addListener(_schedulePastSupplyLookup);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPastSupplies();
      _maybeHydrateParsedSchedule();
      unawaited(_resolveLocationCoordinatesIfNeeded());
    });
  }

  @override
  void dispose() {
    _locationDebounce?.cancel();
    _titleController.removeListener(_markTitleEdited);
    _locationController.removeListener(_markLocationEdited);
    _memoController.removeListener(_markMemoEdited);
    _locationController.removeListener(_schedulePastSupplyLookup);
    _titleController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    _newSupplyController.dispose();
    _scrollController.dispose();
    _newSupplyFocusNode.dispose();
    for (final draft in _supplies) {
      draft.dispose();
    }
    for (final draft in _preActions) {
      draft.dispose();
    }
    super.dispose();
  }

  void _markTitleEdited() {
    if (!_isApplyingHydration) {
      _titleEditedByUser = true;
    }
  }

  void _markLocationEdited() {
    if (!_isApplyingHydration) {
      _locationEditedByUser = true;
    }
  }

  void _handleLocationTextChanged(String value) {
    if (_isApplyingHydration) {
      return;
    }
    final trimmed = value.trim();
    if (_resolvedLocationLabel != null &&
        trimmed == _resolvedLocationLabel!.trim()) {
      return;
    }
    if (_locationLat == null && _locationLng == null) {
      return;
    }
    setState(() {
      _locationLat = null;
      _locationLng = null;
      _resolvedLocationLabel = null;
    });
  }

  void _markMemoEdited() {
    if (!_isApplyingHydration) {
      _memoEditedByUser = true;
    }
  }

  void _schedulePastSupplyLookup() {
    _locationDebounce?.cancel();
    _locationDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _loadPastSupplies();
      }
    });
  }

  Future<void> _loadPastSupplies() async {
    final location = _locationController.text.trim();
    final userId = _resolveUserId();
    if (location.isEmpty || userId == null) {
      if (mounted) {
        setState(() {
          _pastSupplies = const <String>[];
          _isLoadingPastSupplies = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingPastSupplies = true;
      });
    }

    try {
      final pastSupplies = await widget.backend.fetchPastSupplies(
        userId: userId,
        location: location,
      );
      if (!mounted || location != _locationController.text.trim()) {
        return;
      }
      setState(() {
        _pastSupplies = pastSupplies;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _pastSupplies = const <String>[];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingPastSupplies = false;
        });
      }
    }
  }

  Future<void> _lookupLocation() async {
    final query = _locationController.text.trim();
    if (_isLookingUpLocation) {
      return;
    }

    setState(() {
      _isLookingUpLocation = true;
    });

    try {
      debugPrint('PlanFlow operation start: confirm.pick_location');
      final selected = await pickLocationFromQuery(
        context: context,
        query: query,
        locationLookupService: widget.locationLookupService,
      );

      if (!mounted || selected == null) {
        return;
      }

      setState(() {
        _locationController.text = selected.label;
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel = selected.label.trim();
      });
      _showMessage('정확한 위치를 선택했어요.');
    } catch (error, stackTrace) {
      debugPrint('ConfirmScreen location pick failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showMessage('위치 선택에 실패했어요. 잠시 후 다시 시도해 주세요.');
    } finally {
      debugPrint('PlanFlow operation end: confirm.pick_location');
      if (mounted) {
        setState(() {
          _isLookingUpLocation = false;
        });
      }
    }
  }

  Future<void> _resolveLocationCoordinatesIfNeeded() async {
    final query = _locationController.text.trim();
    if (_locationEditedByUser ||
        query.isEmpty ||
        (_locationLat != null && _locationLng != null)) {
      return;
    }

    try {
      final results = await widget.locationLookupService.search(query);
      if (!mounted ||
          _locationEditedByUser ||
          query != _locationController.text.trim() ||
          results.isEmpty) {
        return;
      }

      final selected = results.first;
      _isApplyingHydration = true;
      setState(() {
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel = query;
      });
      _isApplyingHydration = false;
    } catch (error) {
      debugPrint('ConfirmScreen automatic location resolution failed: $error');
    }
  }

  void _maybeHydrateParsedSchedule() {
    if (widget.parsedSchedule['manual_text_confirmed'] == true &&
        widget.parsedSchedule['parse_pending'] != true) {
      return;
    }
    final rawText = _stringValue(widget.parsedSchedule['raw_text']);
    final shouldHydrate = widget.parsedSchedule['parse_pending'] == true ||
        widget.parsedSchedule['parse_failed'] == true ||
        (_titleController.text.trim().isEmpty &&
            rawText != null &&
            rawText.isNotEmpty);
    if (!shouldHydrate || rawText == null || rawText.isEmpty) {
      return;
    }
    _hydrateParsedSchedule(rawText);
  }

  Future<void> _hydrateParsedSchedule(String rawText) async {
    if (_isHydratingParsedSchedule) {
      return;
    }

    setState(() {
      _isHydratingParsedSchedule = true;
      _hydrateMessage = null;
    });

    try {
      final parsed = await widget.gptService.parseSchedule(rawText);
      if (!mounted) {
        return;
      }

      if (parsed['parse_failed'] == true) {
        unawaited(
          AnalyticsService.logScheduleParseFailed(reason: 'fallback'),
        );
      }

      if (parsed['parse_failed'] != true) {
        unawaited(
          AnalyticsService.logScheduleParsed(
            hasTime: parsed['start_at'] != null || parsed['end_at'] != null,
            hasLocation: _stringValue(parsed['location'])?.isNotEmpty == true,
          ),
        );
      }

      _isApplyingHydration = true;
      setState(() {
        final title = _stringValue(parsed['title']);
        if (!_titleEditedByUser && title != null && title.isNotEmpty) {
          _titleController.text = title;
        }

        final location = _stringValue(parsed['location']);
        if (!_locationEditedByUser && location != null && location.isNotEmpty) {
          _locationController.text = location;
        }
        if (!_locationEditedByUser) {
          _locationLat = _doubleValue(parsed['location_lat']) ?? _locationLat;
          _locationLng = _doubleValue(parsed['location_lng']) ?? _locationLng;
          if (_locationLat != null && _locationLng != null) {
            _resolvedLocationLabel = _locationController.text.trim();
          }
        }

        final memo = _stringValue(parsed['memo']);
        if (!_memoEditedByUser && memo != null && memo.isNotEmpty) {
          _memoController.text = memo;
        }

        final supplies = _stringListValue(parsed['supplies']);
        if (supplies.isNotEmpty && _supplies.isEmpty) {
          _supplies.addAll(supplies.map(_SupplyDraft.new));
        }

        final participants = _stringListValue(parsed['participants']);
        final targets = _stringListValue(parsed['targets']);
        if (participants.isNotEmpty) {
          _participants = participants;
        }
        if (targets.isNotEmpty) {
          _targets = targets;
        }

        final parsedPreActions = _preActionsFromValue(
          _smartPreparationAlarmValues(parsed),
        );
        if (parsedPreActions.isNotEmpty && _preActions.isEmpty) {
          _preActions.addAll(parsedPreActions);
        }

        if (!_startEditedByUser) {
          _startAt = _safeStartAt(parsed['start_at'] ?? _startAt);
        }
        if (!_endEditedByUser) {
          _endAt = _safeEndAt(parsed['end_at'], _startAt);
        }
        if (parsed['is_critical'] == true) {
          _isCritical = true;
        }
      });
      _isApplyingHydration = false;
      unawaited(_resolveLocationCoordinatesIfNeeded());
    } catch (error) {
      if (mounted) {
        unawaited(
          AnalyticsService.logScheduleParseFailed(reason: 'gpt_error'),
        );
        setState(() {
          _hydrateMessage = '일정을 바로 정리하지 못했어요. 필요한 내용만 직접 수정해 주세요.';
        });
      }
      debugPrint('ConfirmScreen hydration failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isHydratingParsedSchedule = false;
        });
      }
    }
  }

  String? _resolveUserId() {
    final userId = widget.userId ??
        authProvider.userId ??
        Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      return null;
    }
    return userId.trim();
  }

  EventRepository? _resolveEventRepository() {
    if (widget.eventRepository != null) {
      return widget.eventRepository;
    }
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    return EventRepository.supabase();
  }

  DateTime _eventRangeEnd(DateTime startAt, DateTime? endAt) {
    if (endAt != null && endAt.isAfter(startAt)) {
      return endAt;
    }
    if (_isAllDay || _isMultiDay) {
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

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      _showMessage('제목을 입력해 주세요.');
      return;
    }

    if (AppEnv.isSupabaseReady) {
      try {
        await authProvider.syncCurrentSession();
      } catch (error) {
        debugPrint('ConfirmScreen session sync failed before save: $error');
      }
    }

    final userId = _resolveUserId();
    if (userId == null) {
      _showMessage('로그인이 필요합니다.');
      return;
    }

    final repository = _resolveEventRepository();
    if (repository == null) {
      _showMessage('Supabase 환경이 설정되지 않아 저장할 수 없어요.');
      if (mounted) {
        context.go(AppRoutes.home);
      }
      return;
    }

    final normalizedStartAt = planflowLocalDateTimeToUtc(_startAt);
    final normalizedEndAt =
        _endAt == null ? null : planflowLocalDateTimeToUtc(_endAt!);
    final isMultiDayByRange =
        _endAt != null && !DateUtils.isSameDay(_startAt, _endAt);

    final draftEvent = EventModel(
      id: '',
      userId: userId,
      title: title,
      startAt: normalizedStartAt,
      endAt: normalizedEndAt,
      location: _emptyToNull(_locationController.text),
      locationLat: _locationLat,
      locationLng: _locationLng,
      memo: _emptyToNull(_memoController.text),
      supplies: List<String>.unmodifiable(
        _supplies
            .map((draft) => draft.titleController.text.trim())
            .where((item) => item.isNotEmpty),
      ),
      participants: _participants,
      targets: _targets,
      isCritical: _isCritical,
      recurrenceRule: _recurrenceSelection.toRRule(),
      isAllDay: _isAllDay,
      isMultiDay: isMultiDayByRange,
      category: _category,
    );

    final eventStart = draftEvent.startAt ?? _startAt;
    final overlappingEvents = await repository.findOverlappingEvents(
      rangeStart: eventStart,
      rangeEnd: _eventRangeEnd(eventStart, draftEvent.endAt),
      userId: userId,
    );
    if (!mounted) {
      return;
    }
    if (overlappingEvents.isNotEmpty) {
      unawaited(AnalyticsService.logConflictDetected());
      final shouldContinue = await _showOverlapWarning(overlappingEvents);
      if (!shouldContinue || !mounted) {
        return;
      }
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final savedEvent = await repository.createEvent(draftEvent);

      unawaited(
        _runPostSaveFollowUps(
          userId: userId,
          event: savedEvent,
          repository: repository,
        ),
      );

      if (mounted) {
        _showMessage('일정을 저장했어요.');
        EventRefreshBus.instance.notifyChanged(
          reason: 'confirm_saved',
          eventId: savedEvent.id,
          startAt: savedEvent.startAt,
        );
        unawaited(AnalyticsService.logScheduleConfirmed());
        unawaited(AnalyticsService.logEventCreated(source: 'voice'));
        unawaited(ReviewService.onEventSaved());
        context.go(AppRoutes.home);
      }
    } on StateError catch (error) {
      debugPrint('ConfirmScreen save state error: $error');
      if (mounted) {
        _showMessage(_messageForSaveStateError(error));
      }
    } on PostgrestException catch (error) {
      debugPrint(
        'ConfirmScreen save postgrest error: '
        'code=${error.code} message=${error.message} details=${error.details}',
      );
      if (mounted) {
        _showMessage(_messageForPostgrestError(error));
      }
    } catch (error, stackTrace) {
      debugPrint('ConfirmScreen save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('저장하지 못했어요. 잠시 후 다시 시도해 주세요.');
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

  Future<void> _saveRelatedRecords({
    required String userId,
    required EventModel event,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
  }) async {
    final eventStartAt = event.startAt ?? _startAt;
    final preActionPayloads = _buildPreActionPayloads(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
    );
    final travelPreAction = await _buildTravelPreActionPayload(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
    );
    if (travelPreAction != null) {
      preActionPayloads.add(travelPreAction);
    }
    final reminderPayloads = _buildReminderPayloads(
      userId: userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
      reminderOffset: _reminderOffset,
      criticalAlarmOffset: _reminderOffset,
    );

    await _tryFollowUp(
      () => widget.backend.insertPreActions(preActionPayloads),
      label: 'pre_actions',
    );
    await _tryFollowUp(
      () => widget.smartPreparationAlarmService.schedulePayloads(
        eventId: event.id,
        eventTitle: event.title,
        payloads: preActionPayloads,
        notificationKeyPrefix: 'pre_action',
      ),
      label: 'smart_preparation_alarm_notifications',
    );
    await _tryFollowUp(
      () => widget.backend.insertReminders(reminderPayloads),
      label: 'reminders',
    );
    await _scheduleCriticalAlarmFromReminderPayloads(
      event: event,
      reminderPayloads: reminderPayloads,
    );
    await _tryFollowUp(
      () async {
        final result = await const DepartureAlarmService().scheduleForEvent(
          event,
          safetyMarginOverride: departureSafetyMargin,
        );
        if (!result.isScheduled) {
          debugPrint(
            'Departure alarm skipped: ${result.skippedReason ?? 'unknown'}',
          );
        }
      },
      label: 'departure_alarm',
    );

    final location = _emptyToNull(_locationController.text);
    if (location != null) {
      await _tryFollowUp(
        () => widget.backend.insertLocationHistory(<String, dynamic>{
          'user_id': userId,
          'event_id': event.id,
          'location': location,
          'supplies': event.supplies,
        }),
        label: 'location_history',
      );
    }

    final rawText = _stringValue(widget.parsedSchedule['raw_text']);
    if (rawText != null) {
      await _tryFollowUp(
        () => widget.backend.insertVoiceLog(<String, dynamic>{
          'user_id': userId,
          'event_id': event.id,
          'raw_text': rawText,
          'parsed_json': widget.parsedSchedule,
        }),
        label: 'voice_logs',
      );
    }

    final reminderOffset = _reminderOffset;
    if (reminderOffset != null) {
      final eventReminderNotifyAt = eventStartAt.subtract(reminderOffset);
      await _tryFollowUp(
        () => widget.notificationService.scheduleEventReminder(
          id: widget.notificationService.notificationIdFor('${event.id}:push'),
          title: event.title,
          body: '일정 시작: ${event.title}',
          notifyAt: eventReminderNotifyAt,
        ),
        label: 'local_event_reminder',
      );
    }
  }

  Future<void> _scheduleCriticalAlarmFromReminderPayloads({
    required EventModel event,
    required List<Map<String, dynamic>> reminderPayloads,
  }) async {
    final payload = reminderPayloads
        .where((row) => row['type'] == 'system_alarm')
        .firstOrNull;
    if (payload == null) {
      return;
    }
    final notifyAtValue = payload['notify_at'];
    final notifyAt = notifyAtValue is DateTime
        ? notifyAtValue
        : DateTime.tryParse(notifyAtValue?.toString() ?? '');
    if (notifyAt == null || !notifyAt.isAfter(DateTime.now())) {
      debugPrint(
        'ConfirmScreen critical alarm skipped because notify_at is invalid.',
      );
      return;
    }

    await _tryFollowUp(
      () async {
        final result =
            await widget.notificationService.scheduleCriticalAlarmWithResult(
          id: widget.notificationService.notificationIdFor(
            '${event.id}:critical',
          ),
          title: event.title,
          notifyAt: notifyAt,
          body: '중요 일정이 곧 시작됩니다.',
        );
        if (!result.isScheduled) {
          throw StateError(result.message ?? '중요 알람 예약 실패');
        }
      },
      label: 'critical_alarm',
    );
  }

  Future<void> _tryFollowUp(
    Future<void> Function() action, {
    required String label,
  }) async {
    try {
      await action();
    } catch (error, stackTrace) {
      debugPrint('ConfirmScreen follow-up save failed ($label): $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _runPostSaveFollowUps({
    required String userId,
    required EventModel event,
    required EventRepository repository,
  }) async {
    UserSettingsModel? settings;
    if (AppEnv.isSupabaseReady) {
      try {
        settings = await SettingsRepository.supabase().fetchSettings(userId);
      } catch (error, stackTrace) {
        debugPrint('ConfirmScreen settings load skipped after save: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    final departureSafetyMargin = Duration(
      minutes: settings?.departureSafetyMarginMin ??
          DepartureAlarmService.safetyMargin.inMinutes,
    );
    await _saveRelatedRecords(
      userId: userId,
      event: event,
      departureSafetyMargin: departureSafetyMargin,
    );
    await _resyncExternalPreparationForDay(
      userId: userId,
      event: event,
      settings: settings,
    );
    await _updateHomeWidget(repository, event);
    unawaited(CalendarAutoSyncService().syncAfterEventSave(event));
    unawaited(
      EventPreparationService().prepareAfterSave(
        event,
        departureSafetyMargin: departureSafetyMargin,
      ),
    );
  }

  List<Map<String, dynamic>> _buildPreActionPayloads({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
  }) {
    return _preActions
        .map((draft) {
          final title = draft.titleController.text.trim();
          if (title.isEmpty) {
            return null;
          }

          final offsetHours =
              int.tryParse(draft.offsetController.text.trim()) ?? 1;
          final notifyAt = eventStartAt.subtract(
            Duration(hours: offsetHours < 0 ? 0 : offsetHours),
          );

          return <String, dynamic>{
            'event_id': eventId,
            'user_id': userId,
            'title': title,
            'notify_at': notifyAt.toIso8601String(),
            'is_done': false,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList(growable: true);
  }

  Future<void> _resyncExternalPreparationForDay({
    required String userId,
    required EventModel event,
    UserSettingsModel? settings,
  }) async {
    final eventStartAt = event.startAt;
    final repository = _resolveEventRepository();
    if (eventStartAt == null || repository == null) {
      return;
    }
    try {
      final resolvedSettings =
          settings ?? await SettingsRepository.supabase().fetchSettings(userId);
      final events = await repository.listEvents(userId: userId);
      final updatedEvents = <EventModel>[
        for (final candidate in events)
          if (candidate.id == event.id) event else candidate,
      ];
      if (updatedEvents.every((candidate) => candidate.id != event.id)) {
        updatedEvents.add(event);
      }
      await ManualEventSideEffectService(
        notificationService: widget.notificationService,
      ).resyncExternalPreparationForDay(
        dayEvents: updatedEvents,
        userId: userId,
        dayReference: eventStartAt,
        prepTimeMin: resolvedSettings?.prepTimeMin ??
            SmartPreparationAlarmService.defaultPrepTimeMin,
        prepPreAlarmOffset: resolvedSettings?.prepPreAlarmOffset ??
            SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
        departPreAlarmOffset: resolvedSettings?.departPreAlarmOffset ??
            SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
        departureSafetyMargin: Duration(
          minutes: resolvedSettings?.departureSafetyMarginMin ??
              DepartureAlarmService.safetyMargin.inMinutes,
        ),
        travelMode: resolvedSettings?.travelMode ?? 'car',
      );
    } catch (error, stackTrace) {
      debugPrint('ConfirmScreen external prep resync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<Map<String, dynamic>?> _buildTravelPreActionPayload({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
  }) async {
    try {
      final destinationLat = _locationLat;
      final destinationLng = _locationLng;
      if (destinationLat == null || destinationLng == null) {
        return null;
      }

      final permissionService =
          widget.permissionService ?? AppPermissionService();
      final origin = await permissionService.getLastKnownLocation();
      if (origin == null) {
        return null;
      }

      final estimate = await widget.travelTimeBufferService.estimateWithMapApis(
        originLat: origin.latitude,
        originLng: origin.longitude,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        locationText: _emptyToNull(_locationController.text),
      );
      final notifyAt = eventStartAt.subtract(estimate.buffer);
      if (!notifyAt.isAfter(DateTime.now())) {
        return null;
      }

      return <String, dynamic>{
        'event_id': eventId,
        'user_id': userId,
        'title':
            '출발 준비 (${_travelSourceLabel(estimate.source)} 기준 ${estimate.minutes}분)',
        'notify_at': notifyAt.toIso8601String(),
        'is_done': false,
      };
    } catch (error, stackTrace) {
      debugPrint('Travel pre-action calculation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  String _travelSourceLabel(TravelTimeBufferSource source) {
    return switch (source) {
      TravelTimeBufferSource.tmap => 'T맵',
      TravelTimeBufferSource.naverMap => '네이버 지도',
      TravelTimeBufferSource.googleMaps => 'Google 지도',
      TravelTimeBufferSource.coordinates => '좌표 추정',
      TravelTimeBufferSource.locationText => '장소명 추정',
      TravelTimeBufferSource.defaultFallback => '기본값',
    };
  }

  List<Map<String, dynamic>> _buildReminderPayloads({
    required String userId,
    required String eventId,
    required DateTime eventStartAt,
    required Duration? reminderOffset,
    required Duration? criticalAlarmOffset,
  }) {
    final now = DateTime.now();
    final pushNotifyAt =
        reminderOffset == null ? null : eventStartAt.subtract(reminderOffset);
    final payloads = <Map<String, dynamic>>[
      if (pushNotifyAt != null && pushNotifyAt.isAfter(now))
        _reminderPayload(
          userId: userId,
          eventId: eventId,
          type: 'push',
          notifyAt: pushNotifyAt,
        ),
    ];

    final criticalNotifyAt = criticalAlarmOffset == null
        ? null
        : _resolveCriticalNotifyAt(
            eventStartAt: eventStartAt,
            offset: criticalAlarmOffset,
          );
    if (_isCritical &&
        criticalNotifyAt != null &&
        criticalNotifyAt.isAfter(now)) {
      payloads.add(
        _reminderPayload(
          userId: userId,
          eventId: eventId,
          type: 'system_alarm',
          notifyAt: criticalNotifyAt,
        ),
      );
    }

    return payloads;
  }

  DateTime? _resolveCriticalNotifyAt({
    required DateTime eventStartAt,
    required Duration offset,
  }) {
    final now = DateTime.now();
    if (!eventStartAt.isAfter(now)) {
      return null;
    }
    final desired = eventStartAt.subtract(offset);
    if (desired.isAfter(now)) {
      return desired;
    }
    return now.add(const Duration(seconds: 10));
  }

  Future<void> _updateHomeWidget(
    EventRepository repository,
    EventModel fallbackEvent,
  ) async {
    try {
      final userId = _resolveUserId();
      if (userId == null) {
        return;
      }
      final now = DateTime.now();
      final events = await repository.listEvents(userId: userId);
      final nextEvent = _nextFutureEvent(events, now) ?? fallbackEvent;
      await widget.homeWidgetService.updateSchedulePayload(
        HomeWidgetSchedulePayloadBuilder.fromEvents(
          events: events,
          now: now,
          emptyTitle: fallbackEvent.startAt == null
              ? '예정된 일정이 없어요'
              : fallbackEvent.title,
          nextTravelBufferMinutes:
              await _resolveTravelBufferMinutesForWidget(nextEvent),
        ),
      );
    } catch (_) {}
  }

  Future<int> _resolveTravelBufferMinutesForWidget(EventModel event) {
    return widget.travelTimeBufferService.estimateMinutesWithGoogleMaps(
      origin: _resolveTravelOrigin() ?? '',
      destination: event.location ?? '',
      latitude: event.locationLat,
      longitude: event.locationLng,
      locationText: event.location,
    );
  }

  EventModel? _nextFutureEvent(List<EventModel> events, DateTime now) {
    final futureEvents = events.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      return !startAt.isBefore(now);
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    return futureEvents.isEmpty ? null : futureEvents.first;
  }

  String? _resolveTravelOrigin() {
    const keys = <String>[
      'travel_origin',
      'origin_location',
      'origin',
      'departure_location',
    ];
    for (final key in keys) {
      final value = _stringValue(widget.parsedSchedule[key]);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  Future<void> _addSupplyFromInput() async {
    final supply = _newSupplyController.text.trim();
    if (supply.isEmpty) {
      setState(() {
        _supplyErrorText = '추가할 준비물을 먼저 입력해 주세요.';
      });
      _newSupplyFocusNode.requestFocus();
      return;
    }

    late final bool wasAdded;
    setState(() {
      wasAdded = _addSupply(supply);
      _newSupplyController.clear();
      _supplyErrorText = wasAdded ? null : '이미 추가된 준비물이에요.';
    });
    _showMessage(wasAdded ? '$supply 준비물을 추가했어요.' : '이미 추가된 준비물이에요.');
    if (wasAdded) {
      _scrollToKey(_suppliesKey);
    } else {
      _newSupplyFocusNode.requestFocus();
    }
  }

  bool _addSupply(String supply) {
    if (_supplies.any((draft) => draft.titleController.text.trim() == supply)) {
      return false;
    }
    _supplies.add(_SupplyDraft(supply));
    return true;
  }

  void _removeSupply(_SupplyDraft draft) {
    setState(() {
      _supplies.remove(draft);
      draft.dispose();
    });
  }

  void _addPreAction() {
    final draft = _PreActionDraft.manual();
    setState(() {
      _preActions.add(draft);
    });
    _showMessage('스마트 준비 알람을 추가했어요. 내용을 바로 입력해 주세요.');
    _focusNewPreAction(draft);
  }

  void _removePreAction(_PreActionDraft draft) {
    setState(() {
      _preActions.remove(draft);
      draft.dispose();
    });
  }

  bool _addAutoPreAction(String title, int offsetHours) {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty ||
        _preActions.any(
          (draft) => draft.titleController.text.trim() == normalizedTitle,
        )) {
      return false;
    }
    _preActions.add(
      _PreActionDraft.auto(title: normalizedTitle, offsetHours: offsetHours),
    );
    return true;
  }

  bool get _shouldShowPurposeClarification {
    if (_selectedAmbiguousPurpose != null || _preActions.isNotEmpty) {
      return false;
    }

    final text = [
      _titleController.text,
      _locationController.text,
      _memoController.text,
      _stringValue(widget.parsedSchedule['raw_text']) ?? '',
    ].join(' ').replaceAll(RegExp(r'\s+'), '');

    if (text.isEmpty) {
      return false;
    }

    final hasAmbiguousPlace = _containsAnyText(text, const <String>[
      '병원',
      '의원',
      '치과',
      '한의원',
      '검진센터',
      '법원',
      '학교',
    ]);
    if (!hasAmbiguousPlace) {
      return false;
    }

    final hasClearPurpose = _containsAnyText(text, const <String>[
      '진료',
      '검사',
      '검진',
      '수술',
      '입원',
      '시술',
      '미팅',
      '영업',
      '방문',
      '상담',
      '계약',
      '업무',
      '회의',
      '재판',
      '소송',
      '병문안',
      '문병',
      '학부모',
    ]);
    return !hasClearPurpose;
  }

  bool _containsAnyText(String text, List<String> keywords) {
    return keywords.any(text.contains);
  }

  void _selectAmbiguousPurpose(String purpose) {
    bool added = false;
    setState(() {
      _selectedAmbiguousPurpose = purpose;
      if (purpose == 'medical') {
        _category = '건강';
        added = _addAutoPreAction('병원 준비사항 확인', 24) || added;
        added = _addAutoPreAction('금식/복약 안내 확인', 12) || added;
        added = _addAutoPreAction('신분증과 서류 챙기기', 3) || added;
      } else if (purpose == 'work') {
        _category = '업무';
        added = _addAutoPreAction('이동시간과 출발 시간 확인', 2) || added;
      } else if (purpose == 'visit') {
        _category = '개인';
        added = _addAutoPreAction('꽃이나 선물 챙기기', 3) || added;
      }
    });

    if (added) {
      _scrollToKey(_preActionsKey);
    }
  }

  void _applyPastSupply(String supply) {
    late final bool wasAdded;
    setState(() {
      wasAdded = _addSupply(supply);
    });
    _showMessage(wasAdded ? '$supply 준비물을 추가했어요.' : '이미 추가된 준비물이에요.');
    _scrollToKey(_suppliesKey);
  }

  List<_PreActionDraft> _initialPreActions() {
    return _preActionsFromValue(
      _smartPreparationAlarmValues(widget.parsedSchedule),
    );
  }

  List<Map<String, dynamic>> _smartPreparationAlarmValues(
    Map<String, dynamic> schedule,
  ) {
    return widget.smartPreparationAlarmService.enrichParsedSchedule(
      schedule,
      rawText: _stringValue(schedule['raw_text']) ??
          _stringValue(schedule['title']) ??
          '',
    );
  }

  List<_PreActionDraft> _preActionsFromValue(Object? rawPreActions) {
    if (rawPreActions is! List) {
      return <_PreActionDraft>[];
    }

    return rawPreActions
        .whereType<Map>()
        .map(
          (item) => _PreActionDraft.auto(
            title: _stringValue(item['title']),
            offsetHours: _intValue(item['offset_hours']) ?? 1,
          ),
        )
        .toList(growable: true);
  }

  Map<String, dynamic> _reminderPayload({
    required String userId,
    required String eventId,
    required String type,
    required DateTime notifyAt,
  }) {
    return <String, dynamic>{
      'event_id': eventId,
      'user_id': userId,
      'type': type,
      'notify_at': notifyAt.toIso8601String(),
      'is_sent': false,
    };
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showSmartPreparationAlarmInfo() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  SmartPreparationAlarmService.label,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '일정 등록 시 AI가 준비물, 이동시간, 금식/출발처럼 미리 해야 할 일을 감지해 적절한 시간에 알려주는 기능입니다.',
                ),
                const SizedBox(height: 10),
                const Text(
                  '자동으로 제안된 항목도 저장 전에 직접 수정하거나 삭제할 수 있어요.',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _scrollToKey(GlobalKey key, {FocusNode? focusNode}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = key.currentContext;
      if (!mounted || targetContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
      focusNode?.requestFocus();
    });
  }

  void _focusNewPreAction(_PreActionDraft draft) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final targetContext = draft.key.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.2,
        );
      }
      draft.titleFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = _locationController.text.trim();

    return Scaffold(
      appBar: AppBar(
        title: const Text('일정 확인'),
        leading: IconButton(
          tooltip: '취소',
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            unawaited(AnalyticsService.logScheduleCancelled());
            context.pop();
          },
        ),
      ),
      bottomNavigationBar: _ConfirmBottomNavigation(
        onHome: () => context.go(AppRoutes.home),
        onCalendar: () => context.go(AppRoutes.calendar),
        onSettings: () => context.go(AppRoutes.settings),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(AppConstants.defaultPadding),
                child: ResponsiveContent(
                  maxWidth: 760,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: PlanFlowColors.briefing,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'GPT가 정리한 내용을 확인하고 바로 저장할 수 있어요. 필요한 항목은 지금 수정해도 됩니다.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (_isHydratingParsedSchedule ||
                          _hydrateMessage != null) ...[
                        const SizedBox(height: AppConstants.sectionSpacing),
                        Card(
                          color: const Color(0xFFF7F9FF),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: const BorderSide(
                              color: PlanFlowColors.primaryFaint,
                              width: 0.5,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                if (_isHydratingParsedSchedule)
                                  const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.info_outline,
                                    color: PlanFlowColors.primaryMid,
                                  ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _hydrateMessage ??
                                        '음성 내용을 정리하는 중이에요. 화면은 바로 열렸고, 아래 항목은 곧 채워집니다.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: PlanFlowColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppConstants.sectionSpacing),
                      if (_parseFailed)
                        Card(
                          color: theme.colorScheme.errorContainer,
                          child: const Padding(
                            padding:
                                EdgeInsets.all(AppConstants.defaultPadding),
                            child: Text('자동 파싱에 실패했어요. 내용을 확인하고 직접 입력해 주세요.'),
                          ),
                        ),
                      const SizedBox(height: AppConstants.sectionSpacing),
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
                        isCritical: _isCritical,
                        isLookingUpLocation: _isLookingUpLocation,
                        locationLat: _locationLat,
                        locationLng: _locationLng,
                        locationHelperText: '같은 장소의 과거 준비물을 아래에서 다시 쓸 수 있어요.',
                        onLocationTextChanged: _handleLocationTextChanged,
                        onStartChanged: (value) {
                          setState(() {
                            _startEditedByUser = true;
                            _startAt = value;
                            if (_endAt != null && !_endAt!.isAfter(_startAt)) {
                              _endAt = _startAt.add(const Duration(hours: 1));
                            }
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
                        onCriticalChanged: (value) {
                          setState(() {
                            _isCritical = value;
                          });
                        },
                        onLocationPick: _lookupLocation,
                        extraAfterLocation: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_isLoadingPastSupplies)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: LinearProgressIndicator(),
                              )
                            else if (_pastSupplies.isNotEmpty &&
                                location.isNotEmpty)
                              _SuggestionsCard(
                                title: '같은 장소의 준비물',
                                subtitle: '이전 일정에서 자주 쓰던 준비물을 눌러 바로 추가할 수 있어요.',
                                chips: _pastSupplies
                                    .map(
                                      (supply) => ActionChip(
                                        label: Text(supply),
                                        onPressed: () =>
                                            _applyPastSupply(supply),
                                      ),
                                    )
                                    .toList(growable: false),
                              ),
                            KeyedSubtree(
                              key: _suppliesKey,
                              child: _SuppliesEditor(
                                supplies: _supplies,
                                newSupplyController: _newSupplyController,
                                newSupplyFocusNode: _newSupplyFocusNode,
                                errorText: _supplyErrorText,
                                onAdd: _addSupplyFromInput,
                                onRemove: _removeSupply,
                              ),
                            ),
                            const SizedBox(height: AppConstants.sectionSpacing),
                            KeyedSubtree(
                              key: _preActionsKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _SectionHeader(
                                    title: SmartPreparationAlarmService.label,
                                    actionLabel: '추가',
                                    onAction: _addPreAction,
                                    infoTooltip: '스마트 준비 알람 안내',
                                    onInfo: _showSmartPreparationAlarmInfo,
                                  ),
                                  const SizedBox(height: 8),
                                  if (_shouldShowPurposeClarification) ...[
                                    _PurposeClarificationCard(
                                      onSelected: _selectAmbiguousPurpose,
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                  if (_preActions.isEmpty)
                                    _EmptyInlineHint(
                                      message:
                                          '스마트 준비 알람이 없어요. 추가 버튼을 누르면 바로 아래에 입력 카드가 생겨요.',
                                      actionLabel: '스마트 준비 알람 추가',
                                      onAction: _addPreAction,
                                    )
                                  else
                                    ..._preActions.asMap().entries.map(
                                          (entry) => Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 8,
                                            ),
                                            child: KeyedSubtree(
                                              key: entry.value.key,
                                              child: _PreActionEditorCard(
                                                draft: entry.value,
                                                index: entry.key + 1,
                                                onDelete: () =>
                                                    _removePreAction(
                                                  entry.value,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _isSaving ? null : _save,
                        icon: _isSaving
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save),
                        label: Text(_isSaving ? '저장 중' : '일정 저장'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _stringValue(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  String? _emptyToNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  String _categoryValue(Object? value) {
    return PlanFlowEventCategories.normalize(value);
  }

  List<String> _stringListValue(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: true);
    }
    return const <String>[];
  }

  DateTime? _dateTimeValue(Object? value) {
    if (value is DateTime) {
      return value.isUtc ? planflowLocal(value) : value;
    }
    final text = _stringValue(value);
    if (text == null) {
      return null;
    }
    final parsed = DateTime.tryParse(text);
    if (parsed == null) {
      return null;
    }
    return parsed.isUtc ? planflowLocal(parsed) : parsed;
  }

  DateTime _safeStartAt(Object? value) {
    final now = planflowNow();
    final parsed = _dateTimeValue(value);
    if (parsed == null) {
      return now;
    }
    if (parsed.isBefore(now.subtract(const Duration(days: 1)))) {
      return now;
    }
    return parsed;
  }

  DateTime? _safeEndAt(Object? value, DateTime startAt) {
    final parsed = _dateTimeValue(value);
    if (parsed == null || parsed.isBefore(startAt)) {
      return null;
    }
    return parsed;
  }

  int? _intValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  double? _doubleValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }
}

class _ConfirmBottomNavigation extends StatelessWidget {
  const _ConfirmBottomNavigation({
    required this.onHome,
    required this.onCalendar,
    required this.onSettings,
  });

  final VoidCallback onHome;
  final VoidCallback onCalendar;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: 1,
      onDestinationSelected: (index) {
        switch (index) {
          case 0:
            onHome();
            break;
          case 1:
            onCalendar();
            break;
          case 2:
            onSettings();
            break;
        }
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: '홈',
        ),
        NavigationDestination(
          icon: Icon(Icons.event_note_outlined),
          selectedIcon: Icon(Icons.event_note),
          label: '일정',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '설정',
        ),
      ],
    );
  }
}

class _PreActionDraft {
  _PreActionDraft.auto({String? title, int? offsetHours})
      : isAuto = true,
        key = GlobalKey(),
        titleController = TextEditingController(text: title ?? ''),
        offsetController = TextEditingController(
          text: (offsetHours ?? 1).toString(),
        ),
        titleFocusNode = FocusNode();

  _PreActionDraft.manual()
      : isAuto = false,
        key = GlobalKey(),
        titleController = TextEditingController(),
        offsetController = TextEditingController(text: '1'),
        titleFocusNode = FocusNode();

  final bool isAuto;
  final GlobalKey key;
  final TextEditingController titleController;
  final TextEditingController offsetController;
  final FocusNode titleFocusNode;

  void dispose() {
    titleController.dispose();
    offsetController.dispose();
    titleFocusNode.dispose();
  }
}

class _SupplyDraft {
  _SupplyDraft(String title)
      : key = GlobalKey(),
        titleController = TextEditingController(text: title),
        focusNode = FocusNode();

  final GlobalKey key;
  final TextEditingController titleController;
  final FocusNode focusNode;

  void dispose() {
    titleController.dispose();
    focusNode.dispose();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
    this.infoTooltip,
    this.onInfo,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onAction;
  final String? infoTooltip;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onInfo != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: infoTooltip,
                  onPressed: onInfo,
                  icon: const Icon(Icons.help_outline, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
              ],
            ],
          ),
        ),
        TextButton.icon(
          onPressed: onAction,
          icon: const Icon(Icons.add, size: 18),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}

class _SuppliesEditor extends StatelessWidget {
  const _SuppliesEditor({
    required this.supplies,
    required this.newSupplyController,
    required this.newSupplyFocusNode,
    required this.errorText,
    required this.onAdd,
    required this.onRemove,
  });

  final List<_SupplyDraft> supplies;
  final TextEditingController newSupplyController;
  final FocusNode newSupplyFocusNode;
  final String? errorText;
  final VoidCallback onAdd;
  final ValueChanged<_SupplyDraft> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '준비물',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '일정에 필요한 준비물을 한 줄씩 정리해 주세요. 실제 체크는 일정 상세에서 할 수 있어요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            if (supplies.isEmpty)
              Text(
                '아직 준비물이 없어요. 아래에서 하나씩 추가해 보세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              )
            else ...[
              Column(
                children: supplies
                    .map(
                      (draft) => _SupplyInputRow(
                        draft: draft,
                        onDelete: () => onRemove(draft),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: newSupplyController,
                    focusNode: newSupplyFocusNode,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: '준비물 추가',
                      hintText: '예: 물, 여권, 충전기',
                      helperText: '입력 후 추가 버튼을 누르세요.',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                    ),
                    onSubmitted: (_) {
                      onAdd();
                      FocusScope.of(context).unfocus();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: onAdd,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 56),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('추가'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SupplyInputRow extends StatelessWidget {
  const _SupplyInputRow({required this.draft, required this.onDelete});

  final _SupplyDraft draft;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: PlanFlowColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              Icons.backpack_outlined,
              size: 18,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: draft.titleController,
                focusNode: draft.focusNode,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                style: theme.textTheme.bodyMedium,
                decoration: const InputDecoration(
                  hintText: '준비물 입력',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                ),
                maxLines: 1,
              ),
            ),
            IconButton(
              tooltip: '삭제',
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionsCard extends StatelessWidget {
  const _SuggestionsCard({
    required this.title,
    required this.subtitle,
    required this.chips,
  });

  final String title;
  final String subtitle;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          ],
        ),
      ),
    );
  }
}

class _PurposeClarificationCard extends StatelessWidget {
  const _PurposeClarificationCard({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '일정 목적을 선택해 주세요',
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '장소만으로 준비 알람을 단정하지 않아요. 목적을 고르면 알맞은 준비 알림만 추가합니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('진료/검사'),
                  onPressed: () => onSelected('medical'),
                ),
                ActionChip(
                  label: const Text('업무/영업'),
                  onPressed: () => onSelected('work'),
                ),
                ActionChip(
                  label: const Text('병문안'),
                  onPressed: () => onSelected('visit'),
                ),
                ActionChip(
                  label: const Text('기타'),
                  onPressed: () => onSelected('other'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreActionEditorCard extends StatelessWidget {
  const _PreActionEditorCard({
    required this.draft,
    required this.index,
    required this.onDelete,
  });

  final _PreActionDraft draft;
  final int index;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(draft.isAuto ? '자동' : '수동'),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(
                    color: PlanFlowColors.primaryFaint,
                    width: 0.5,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('삭제'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '스마트 준비 알람 $index',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: draft.titleController,
              focusNode: draft.titleFocusNode,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
              decoration: const InputDecoration(
                labelText: '행동 이름',
                hintText: '예: 준비물 다시 확인',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: draft.offsetController,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
              decoration: const InputDecoration(
                labelText: '몇 시간 전',
                helperText: '예: 2는 시작 2시간 전',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyInlineHint extends StatelessWidget {
  const _EmptyInlineHint({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: onAction,
              icon: const Icon(Icons.add, size: 18),
              label: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}
