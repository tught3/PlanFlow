import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/diag_logger.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/models/voice_correction_rule.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/voice_correction_rule_repository.dart';
import '../../core/analytics_service.dart';
import '../../providers/auth_provider.dart';
import '../location/location_pick_flow.dart';
import '../../services/review_service.dart';
import '../../services/calendar_auto_sync_service.dart';
import '../../services/departure_alarm_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/event_preparation_service.dart';
import '../../services/app_permission_service.dart';
import '../../services/app_feedback_service.dart';
import '../../services/event_range_utils.dart';
import '../../services/gpt_service.dart';
import '../../services/home_widget_service.dart';
import '../../services/voice_correction_learning_service.dart';
import '../../services/voice_schedule_structure_service.dart';
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
part 'confirm_widgets.dart';

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
    this.voiceCorrectionRuleRepository,
    VoiceCorrectionLearningService? voiceCorrectionLearningService,
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
        voiceCorrectionLearningService = voiceCorrectionLearningService ??
            const VoiceCorrectionLearningService(),
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
  final VoiceCorrectionRuleRepository? voiceCorrectionRuleRepository;
  final VoiceCorrectionLearningService voiceCorrectionLearningService;
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

class _PostSaveFollowUpResult {
  const _PostSaveFollowUpResult({
    this.alarmFailures = const <_AlarmScheduleFailure>[],
  });

  final List<_AlarmScheduleFailure> alarmFailures;

  String? get alarmWarningMessage {
    if (alarmFailures.isEmpty) {
      return null;
    }
    if (alarmFailures.any(
      (failure) =>
          failure.status == NotificationScheduleStatus.permissionBlocked,
    )) {
      return '일정은 저장했지만 알림 권한이 꺼져 있어 알람을 예약하지 못했어요.';
    }
    return '일정은 저장했지만 알람 예약에 실패했어요. 알림 설정을 확인해 주세요.';
  }
}

class _AlarmScheduleFailure {
  const _AlarmScheduleFailure({
    required this.label,
    required this.status,
    required this.message,
  });

  final String label;
  final NotificationScheduleStatus status;
  final String message;
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

class _ConfirmScreenState extends State<ConfirmScreen>
    with WidgetsBindingObserver {
  // 권한 설정 화면으로 이동 중일 때 true — 앱 복귀(resumed) 시 저장 후 목적지로 이동
  bool _pendingNavigateAfterSave = false;

  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _newSupplyController;
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );
  final FocusNode _newSupplyFocusNode = FocusNode();
  final GlobalKey _suppliesKey = GlobalKey();
  late final List<_SupplyDraft> _supplies;
  late final List<_PreActionDraft> _preActions;
  late List<String> _participants;
  late List<String> _targets;
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
  bool _strongAlarm = false;
  bool _isSaving = false;
  bool _isLookingUpLocation = false;
  bool _isHydratingParsedSchedule = false;
  Duration? _reminderOffset = ReminderOffsetSelector.defaultValue;
  bool _detailsSectionInitiallyExpanded = false;
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
  bool _timePeriodAmbiguous = false;
  int? _ambiguousTimeHour;
  int? _ambiguousTimeMinute;
  Map<String, dynamic>? _initialParsedForLearning;

  bool get _parseFailed => widget.parsedSchedule['parse_failed'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialParsedForLearning = Map<String, dynamic>.from(
      widget.parsedSchedule,
    );
    final rawTextForLocalParse = _stringValue(
      widget.parsedSchedule['raw_text'],
    );
    final parsedTitle = _stringValue(widget.parsedSchedule['title']) ?? '';
    // parse_pending이면 GPT 결과를 기다리는 동안 제목이 비어 보임.
    // rawText로 로컬 파싱 제목을 즉시 채워 1초대에 표시되도록 한다.
    // GPT hydrate 완료 시 _titleEditedByUser=false라 덮어씌워진다.
    final initialTitle = parsedTitle.isNotEmpty
        ? parsedTitle
        : (rawTextForLocalParse != null && rawTextForLocalParse.isNotEmpty
            ? const VoiceScheduleStructureService().normalizeLocalVoiceTitle(
                rawTextForLocalParse,
              )
            : '');
    _titleController = TextEditingController(text: initialTitle);
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
    _preActions = _initialPreActions();
    _participants = _stringListValue(widget.parsedSchedule['participants']);
    _targets = _stringListValue(widget.parsedSchedule['targets']);
    _detailsSectionInitiallyExpanded = _supplies.isNotEmpty ||
        _participants.isNotEmpty ||
        _targets.isNotEmpty ||
        _hasExplicitPreActions(widget.parsedSchedule);
    _startAt = _safeStartAt(widget.parsedSchedule['start_at']);
    _endAt = _safeEndAt(widget.parsedSchedule['end_at'], _startAt);
    _setAmbiguousTimeFromParsed(widget.parsedSchedule);
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
    _category = '기타';
    _isCritical = widget.parsedSchedule['is_critical'] == true;
    _titleController.addListener(_markTitleEdited);
    _locationController.addListener(_markLocationEdited);
    _memoController.addListener(_markMemoEdited);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeHydrateParsedSchedule();
      unawaited(_resolveLocationCoordinatesIfNeeded());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 권한 설정 화면에서 돌아왔을 때 저장된 일정을 바로 확인하게 이동.
    if (state == AppLifecycleState.resumed &&
        _pendingNavigateAfterSave &&
        mounted) {
      _pendingNavigateAfterSave = false;
      _navigateAfterSave();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationDebounce?.cancel();
    _titleController.removeListener(_markTitleEdited);
    _locationController.removeListener(_markLocationEdited);
    _memoController.removeListener(_markMemoEdited);
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

  void _removeResolvedLocationFromTitle({
    required String previousLocationText,
    required String? resolvedLocationText,
  }) {
    if (_titleEditedByUser) {
      return;
    }

    final candidates = <String>{
      previousLocationText,
      if (resolvedLocationText != null) resolvedLocationText,
    };
    var title = _titleController.text.trim();
    for (final candidate in candidates) {
      title = _stripLocationCandidateFromTitle(title, candidate);
    }

    if (title.isEmpty || title == _titleController.text.trim()) {
      return;
    }

    _isApplyingHydration = true;
    _titleController.text = title;
    _isApplyingHydration = false;
  }

  String _stripLocationCandidateFromTitle(String title, String candidate) {
    final normalizedCandidate = candidate
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\s*(?:에서|으로|로|에)$'), '')
        .trim();
    if (normalizedCandidate.length < 2) {
      return title;
    }

    final escaped = RegExp.escape(normalizedCandidate);
    final compactEscaped = RegExp.escape(
      normalizedCandidate.replaceAll(RegExp(r'\s+'), ''),
    );
    return title
        .replaceFirst(RegExp('^\\s*$escaped\\s*(?:에서|으로|로|에)?\\s*'), '')
        .replaceFirst(RegExp('^\\s*$compactEscaped\\s*(?:에서|으로|로|에)?\\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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

      // 좌표가 이미 고정된 경우: 현재 좌표로 바로 지도 열기
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
        locationLookupService: widget.locationLookupService,
        appPermissionService: widget.permissionService,
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
      _removeResolvedLocationFromTitle(
        previousLocationText: query,
        resolvedLocationText: _resolvedLocationLabel,
      );
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
        _shouldSkipAutomaticLocationResolution(query) ||
        (_locationLat != null && _locationLng != null)) {
      return;
    }

    if (mounted) {
      setState(() {
        _isLookingUpLocation = true;
      });
    }
    try {
      final gpsFuture = _permissionService
          .getCurrentLocationWithPermission(requestIfMissing: false)
          .catchError((Object error, StackTrace stackTrace) {
        debugPrint('ConfirmScreen background GPS lookup skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
        return null;
      });
      unawaited(gpsFuture);
      final results = await widget.locationLookupService.search(
        query,
        origin: null,
      );
      if (!mounted ||
          _locationEditedByUser ||
          query != _locationController.text.trim() ||
          results.isEmpty) {
        return;
      }

      final selected = results.first;
      final resolvedLabel = selected.bestPlaceLabel.trim();
      _isApplyingHydration = true;
      setState(() {
        if (resolvedLabel.isNotEmpty) {
          _locationController.text = resolvedLabel;
        }
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel =
            resolvedLabel.isNotEmpty ? resolvedLabel : query;
      });
      _isApplyingHydration = false;
      _removeResolvedLocationFromTitle(
        previousLocationText: query,
        resolvedLocationText: _resolvedLocationLabel,
      );
    } catch (error) {
      debugPrint('ConfirmScreen automatic location resolution failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isLookingUpLocation = false;
        });
      }
    }
  }

  Future<void> _ensureLocationCoordinatesBeforeSave() async {
    final query = _locationController.text.trim();
    if (query.isEmpty ||
        _shouldSkipAutomaticLocationResolution(query) ||
        (_locationLat != null && _locationLng != null)) {
      // 이미 좌표가 있거나 개인 별칭이면 스킵
      DiagLogger.log(
        'GeoResolve',
        '스킵: 쿼리="${query.isEmpty ? '(빈값)' : query}" '
            '이미보유=${_locationLat != null && _locationLng != null} '
            '개인별칭=${query.isNotEmpty && _shouldSkipAutomaticLocationResolution(query)}',
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
          .getCurrentLocationWithPermission(requestIfMissing: false)
          .catchError((Object error, StackTrace stackTrace) {
        debugPrint('ConfirmScreen save-time GPS lookup skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
        return null;
      });
      unawaited(gpsFuture);
      DiagLogger.log('GeoResolve', '검색시작: 쿼리="$query"');
      final results = await widget.locationLookupService.search(
        query,
        origin: null,
      );
      DiagLogger.log(
        'GeoResolve',
        '검색결과: 쿼리="$query" 결과수=${results.length}'
            '${results.isNotEmpty ? ' 1위="${results.first.name}" lat=${results.first.latitude} lng=${results.first.longitude}' : ''}',
      );
      if (!mounted ||
          query != _locationController.text.trim() ||
          results.isEmpty) {
        if (results.isEmpty) {
          DiagLogger.log('GeoResolve', '실패: 쿼리="$query" 결과없음 → 좌표 미설정');
        }
        return;
      }

      final selected = results.first;
      final resolvedLabel = selected.bestPlaceLabel.trim();
      _isApplyingHydration = true;
      setState(() {
        if (resolvedLabel.isNotEmpty) {
          _locationController.text = resolvedLabel;
        }
        _locationLat = selected.latitude;
        _locationLng = selected.longitude;
        _resolvedLocationLabel =
            resolvedLabel.isNotEmpty ? resolvedLabel : query;
      });
      _isApplyingHydration = false;
      DiagLogger.log(
        'GeoResolve',
        '성공: 쿼리="$query" 선택="${selected.name}" lat=${selected.latitude} lng=${selected.longitude}',
      );
      _removeResolvedLocationFromTitle(
        previousLocationText: query,
        resolvedLocationText: _resolvedLocationLabel,
      );
    } catch (error) {
      debugPrint('ConfirmScreen save-time location resolution failed: $error');
      DiagLogger.log('GeoResolve', '오류: 쿼리="$query" error=$error');
    } finally {
      _isApplyingHydration = false;
      if (mounted) {
        setState(() {
          _isLookingUpLocation = false;
        });
      }
    }
  }

  bool _shouldSkipAutomaticLocationResolution(String query) {
    final normalized = query.replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) {
      return true;
    }
    if (_looksLikePersonalPlaceAlias(normalized)) {
      return true;
    }
    return false;
  }

  bool _looksLikePersonalPlaceAlias(String normalized) {
    const exactAliases = <String>{
      '집',
      '우리집',
      '내집',
      '자택',
      '본가',
      '처가',
      '시댁',
      '회사',
      '사무실',
    };
    if (exactAliases.contains(normalized)) {
      return true;
    }
    if (RegExp(r'^(우리|내|친정|부모님|엄마|아빠|할머니|할아버지).*(집|댁)$').hasMatch(normalized)) {
      return true;
    }
    if (normalized.length <= 6 &&
        (normalized.endsWith('집') ||
            normalized.endsWith('자택') ||
            normalized.endsWith('본가') ||
            normalized.endsWith('회사') ||
            normalized.endsWith('사무실'))) {
      return true;
    }
    return false;
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
        unawaited(AnalyticsService.logScheduleParseFailed(reason: 'fallback'));
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
      _initialParsedForLearning = Map<String, dynamic>.from(parsed);
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
          _detailsSectionInitiallyExpanded = true;
        }

        final participants = _stringListValue(parsed['participants']);
        if (participants.isNotEmpty && _participants.isEmpty) {
          _participants = participants;
        }
        final targets = _stringListValue(parsed['targets']);
        if (targets.isNotEmpty && _targets.isEmpty) {
          _targets = targets;
        }

        final parsedPreActions = _preActionsFromValue(
          _smartPreparationAlarmValues(parsed),
        );
        if (parsedPreActions.isNotEmpty && _preActions.isEmpty) {
          _preActions.addAll(parsedPreActions);
          if (_preActionsFromValue(parsed['pre_actions']).isNotEmpty) {
            _detailsSectionInitiallyExpanded = true;
          }
        }

        final parsedRecurrence = RecurrenceSelection.fromRRule(
          _stringValue(parsed['recurrence_rule']),
        );
        if (!parsedRecurrence.isNone) {
          _recurrenceSelection = parsedRecurrence;
        }

        if (!_startEditedByUser) {
          _startAt = _safeStartAt(parsed['start_at'] ?? _startAt);
        }
        _setAmbiguousTimeFromParsed(parsed);
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
        unawaited(AnalyticsService.logScheduleParseFailed(reason: 'gpt_error'));
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

  AppPermissionService get _permissionService =>
      widget.permissionService ?? AppPermissionService();

  bool get _shouldExpandDetailsSection =>
      _detailsSectionInitiallyExpanded || _shouldShowPurposeClarification;

  /// 알람 예약 후 권한이 부족한 경우 사용자에게 안내 다이얼로그를 표시.
  ///
  /// 정확한 알람 권한 또는 배터리 최적화 예외가 꺼져 있을 때만 표시.
  /// 저장 자체를 막지 않으며, 다이얼로그는 권한 화면으로 이동하는 버튼을 제공.
  /// 알람 권한이 부족할 때 안내 다이얼로그를 표시한다.
  /// 사용자가 "설정하기"를 눌러 시스템 권한 화면으로 이동하면 true를 반환한다.
  /// 단순 dismiss 또는 권한이 이미 충분한 경우 false를 반환한다.
  Future<bool> _showAlarmPermissionGuardIfNeeded() async {
    if (!mounted) {
      return false;
    }
    try {
      final snapshot = await _permissionService.checkAll();
      if (!mounted) {
        return false;
      }
      // 둘 다 허용된 경우 다이얼로그 없이 조용히 진행.
      if (snapshot.alarmWillFire) {
        return false;
      }

      final missingExact = !snapshot.exactAlarmsGranted;
      final missingBattery = !snapshot.batteryOptimizationIgnored;

      var openedSystemSettings = false;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _AlarmPermissionGuardDialog(
          missingExactAlarm: missingExact,
          missingBatteryOptimization: missingBattery,
          onFixExactAlarm: () async {
            openedSystemSettings = true;
            Navigator.of(dialogContext).pop();
            await _permissionService.openAlarmSettings();
          },
          onFixBatteryOptimization: () async {
            openedSystemSettings = true;
            Navigator.of(dialogContext).pop();
            await _permissionService.requestIgnoreBatteryOptimizations();
          },
        ),
      );
      return openedSystemSettings;
    } catch (error) {
      debugPrint('Alarm permission guard check failed (non-blocking): $error');
      return false;
    }
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

    await _ensureLocationCoordinatesBeforeSave();
    if (!mounted) {
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
      participants: List<String>.unmodifiable(_participants),
      targets: List<String>.unmodifiable(_targets),
      isCritical: _isCritical,
      useStrongAlarm: _strongAlarm,
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
    final duplicateWarningEvents = filterDuplicateWarningEvents(
      draft: draftEvent,
      candidates: overlappingEvents,
    );
    if (!mounted) {
      return;
    }
    if (duplicateWarningEvents.isNotEmpty) {
      unawaited(AnalyticsService.logConflictDetected());
      final shouldContinue = await _showOverlapWarning(duplicateWarningEvents);
      if (!shouldContinue || !mounted) {
        return;
      }
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final savedEvent = await repository.createEvent(draftEvent);
      unawaited(_recordVoiceCorrectionLearning(userId: userId));

      final postSaveResult = await _scheduleImmediateAlarmNotifications(
        event: savedEvent,
      );

      unawaited(
        _runPostSaveFollowUps(
          userId: userId,
          event: savedEvent,
          repository: repository,
        ),
      );

      if (mounted) {
        // 저장 성공 SnackBar는 바로 뒤이은 홈 화면 전환과 겹쳐 잔상으로 보이므로
        // 띄우지 않는다. 홈 진입 + 목록에 새 일정 표시가 저장 완료 피드백을 대신한다.
        // (저장 실패 시에는 화면이 그대로라 SnackBar를 정상 표시한다.)
        EventRefreshBus.instance.notifyChanged(
          reason: 'confirm_saved',
          eventId: savedEvent.id,
          startAt: savedEvent.startAt,
        );
        unawaited(AnalyticsService.logScheduleConfirmed());
        unawaited(AnalyticsService.logEventCreated(source: 'voice'));
        unawaited(ReviewService.onEventSaved());
        final alarmWarning = postSaveResult.alarmWarningMessage;
        if (alarmWarning != null) {
          _showMessage(alarmWarning);
        }
        // 알람 권한 가드 — 저장 성공 후 권한이 누락된 경우 안내 다이얼로그.
        // 시스템 설정 화면이 열렸으면 true 반환 → 앱 복귀(resumed) 시 홈 이동.
        // 다이얼로그만 닫혔거나 권한 충분이면 false → 즉시 홈 이동.
        final openedPermissionSettings =
            await _showAlarmPermissionGuardIfNeeded();
        if (mounted) {
          if (openedPermissionSettings) {
            // 시스템 설정으로 이동 중 — didChangeAppLifecycleState(resumed)에서 처리
            _pendingNavigateAfterSave = true;
          } else {
            _navigateAfterSave();
          }
        }
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

  bool get _shouldShowTimePeriodClarification {
    return _timePeriodAmbiguous &&
        !_isAllDay &&
        _ambiguousTimeHour != null &&
        _ambiguousTimeMinute != null;
  }

  void _applyAmbiguousTimePeriod({required bool afternoon}) {
    final hour = _ambiguousTimeHour;
    final minute = _ambiguousTimeMinute;
    if (hour == null || minute == null) {
      return;
    }
    final resolvedHour = afternoon
        ? hour == 12
            ? 12
            : hour + 12
        : hour == 12
            ? 0
            : hour;
    final previousStart = _startAt;
    final nextStart = DateTime(
      _startAt.year,
      _startAt.month,
      _startAt.day,
      resolvedHour,
      minute,
    );
    setState(() {
      _startEditedByUser = true;
      _startAt = nextStart;
      _endAt = shiftEventEndWhenStartChanges(
        previousStart: previousStart,
        newStart: _startAt,
        currentEnd: _endAt,
        endEditedByUser: _endEditedByUser,
      );
      if (_endAt != null && _endAt!.isBefore(_startAt)) {
        _endAt = _startAt;
      }
    });
  }

  String _ambiguousTimeLabel({required bool afternoon}) {
    final hour = _ambiguousTimeHour ?? _startAt.hour;
    final minute = _ambiguousTimeMinute ?? _startAt.minute;
    final minuteText = minute.toString().padLeft(2, '0');
    return '${afternoon ? '오후' : '오전'} $hour:$minuteText';
  }

  bool _isAmbiguousPeriodSelected({required bool afternoon}) {
    final hour = _ambiguousTimeHour;
    if (hour == null) {
      return false;
    }
    final resolvedHour = afternoon
        ? hour == 12
            ? 12
            : hour + 12
        : hour == 12
            ? 0
            : hour;
    return _startAt.hour == resolvedHour;
  }

  void _navigateAfterSave() {
    if (!mounted) {
      return;
    }
    context.go(AppRoutes.calendar);
  }

  Widget _buildTimePeriodClarificationCard() {
    final theme = Theme.of(context);
    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '오전/오후를 확인해 주세요',
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '말한 시간이 오전과 오후 모두 가능한 시간대라 저장 전에 확정이 필요해요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: Text(_ambiguousTimeLabel(afternoon: false)),
                  avatar: _isAmbiguousPeriodSelected(afternoon: false)
                      ? const Icon(Icons.check, size: 16)
                      : null,
                  onPressed: () => _applyAmbiguousTimePeriod(afternoon: false),
                ),
                ActionChip(
                  label: Text(_ambiguousTimeLabel(afternoon: true)),
                  avatar: _isAmbiguousPeriodSelected(afternoon: true)
                      ? const Icon(Icons.check, size: 16)
                      : null,
                  onPressed: () => _applyAmbiguousTimePeriod(afternoon: true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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

  void _setAmbiguousTimeFromParsed(Map<String, dynamic> parsed) {
    final rawText = _stringValue(parsed['raw_text']);
    final clock = _ambiguousClockFromRawText(rawText) ??
        (parsed['time_period_ambiguous'] == true
            ? _AmbiguousMeridiemClock.fromDateTime(_startAt)
            : null);
    _timePeriodAmbiguous = clock != null;
    _ambiguousTimeHour = clock?.hour;
    _ambiguousTimeMinute = clock?.minute;
  }

  _AmbiguousMeridiemClock? _ambiguousClockFromRawText(String? rawText) {
    if (rawText == null || rawText.trim().isEmpty) {
      return null;
    }
    final text = rawText.replaceAll(RegExp(r'\s+'), '');
    final numericMatch = RegExp(
      r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽))?(\d{1,2})시(?:(\d{1,2})분?|(반))?',
    ).firstMatch(text);
    if (numericMatch != null) {
      if (numericMatch.group(1) != null) {
        return null;
      }
      final hour = int.tryParse(numericMatch.group(2) ?? '');
      final minute = numericMatch.group(4) != null
          ? 30
          : int.tryParse(numericMatch.group(3) ?? '') ?? 0;
      return _ambiguousClockFromParts(hour: hour, minute: minute);
    }
    final koreanMatch = RegExp(
      r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽))?([가-힣]{1,8})시(?:([가-힣]{1,8}|\d{1,2})분?|(반))?',
    ).firstMatch(text);
    if (koreanMatch == null || koreanMatch.group(1) != null) {
      return null;
    }
    final minuteText = koreanMatch.group(3);
    final minute = koreanMatch.group(4) != null || minuteText == '반'
        ? 30
        : int.tryParse(minuteText ?? '') ?? _koreanNumber(minuteText) ?? 0;
    return _ambiguousClockFromParts(
      hour: _koreanNumber(koreanMatch.group(2)),
      minute: minute,
    );
  }

  _AmbiguousMeridiemClock? _ambiguousClockFromParts({
    required int? hour,
    required int minute,
  }) {
    if (hour == null || hour < 7 || hour > 12 || minute < 0 || minute > 59) {
      return null;
    }
    return _AmbiguousMeridiemClock(hour: hour, minute: minute);
  }

  int? _koreanNumber(String? rawText) {
    if (rawText == null || rawText.isEmpty) {
      return null;
    }
    const values = <String, int>{
      '영': 0,
      '공': 0,
      '한': 1,
      '하나': 1,
      '일': 1,
      '두': 2,
      '둘': 2,
      '이': 2,
      '세': 3,
      '셋': 3,
      '삼': 3,
      '네': 4,
      '넷': 4,
      '사': 4,
      '다섯': 5,
      '오': 5,
      '여섯': 6,
      '육': 6,
      '일곱': 7,
      '칠': 7,
      '여덟': 8,
      '팔': 8,
      '아홉': 9,
      '구': 9,
      '열': 10,
      '십': 10,
      '열한': 11,
      '열하나': 11,
      '십일': 11,
      '열두': 12,
      '열둘': 12,
      '십이': 12,
      '삼십': 30,
      '사십': 40,
      '오십': 50,
    };
    return values[rawText.replaceAll(' ', '')];
  }

  Future<void> _recordVoiceCorrectionLearning({required String userId}) async {
    if (!AppEnv.isSupabaseReady) {
      return;
    }
    try {
      final settings = await SettingsRepository.supabase().fetchSettings(
        userId,
      );
      if (settings?.voiceCorrectionLearningEnabled == false) {
        return;
      }
      final repository = widget.voiceCorrectionRuleRepository ??
          VoiceCorrectionRuleRepository.supabase();
      final rules = <VoiceCorrectionRule>[];

      final originalStt = _stringValue(
        widget.parsedSchedule['stt_original_text'],
      );
      final rawText = _stringValue(widget.parsedSchedule['raw_text']);
      if (widget.parsedSchedule['manual_text_confirmed'] == true &&
          originalStt != null &&
          rawText != null &&
          originalStt != rawText) {
        rules.addAll(
          widget.voiceCorrectionLearningService.extractRules(
            originalText: originalStt,
            correctedText: rawText,
            stage: VoiceCorrectionStage.stt,
            field: VoiceCorrectionField.transcript,
            userId: userId,
          ),
        );
      }

      final initial = _initialParsedForLearning ?? widget.parsedSchedule;
      rules.addAll(
        _extractParseCorrectionRules(userId: userId, initial: initial),
      );

      var recorded = false;
      for (final rule in rules) {
        if (!widget.voiceCorrectionLearningService.shouldRecordRule(rule)) {
          continue;
        }
        await repository.recordPersonalRule(rule);
        recorded = true;
      }
      if (recorded && mounted) {
        _showMessage('이 수정 패턴을 다음에도 참고할게요.');
      }
    } catch (error, stackTrace) {
      debugPrint('ConfirmScreen correction learning skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  List<VoiceCorrectionRule> _extractParseCorrectionRules({
    required String userId,
    required Map<String, dynamic> initial,
  }) {
    final rules = <VoiceCorrectionRule>[];
    void addRule({
      required VoiceCorrectionField field,
      required String? original,
      required String corrected,
    }) {
      if (original == null || original.trim() == corrected.trim()) {
        return;
      }
      rules.addAll(
        widget.voiceCorrectionLearningService.extractRules(
          originalText: original,
          correctedText: corrected,
          stage: VoiceCorrectionStage.parse,
          field: field,
          userId: userId,
        ),
      );
    }

    addRule(
      field: VoiceCorrectionField.title,
      original: _stringValue(initial['title']),
      corrected: _titleController.text.trim(),
    );
    addRule(
      field: VoiceCorrectionField.location,
      original: _stringValue(initial['location']),
      corrected: _locationController.text.trim(),
    );
    addRule(
      field: VoiceCorrectionField.supplies,
      original: _stringListValue(initial['supplies']).join(', '),
      corrected: _supplies
          .map((draft) => draft.titleController.text.trim())
          .where((item) => item.isNotEmpty)
          .join(', '),
    );
    addRule(
      field: VoiceCorrectionField.recurrence,
      original: _stringValue(initial['recurrence_rule']),
      corrected: _recurrenceSelection.toRRule() ?? '',
    );
    return rules;
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
    );

    await _tryFollowUp(
      () => widget.backend.insertPreActions(preActionPayloads),
      label: 'pre_actions',
    );
    await _tryFollowUp(() {
      DiagLogger.log(
        'SmartPrep',
        'payloads=${preActionPayloads.length} loc="${event.location ?? ''}"',
      );
      return widget.smartPreparationAlarmService.schedulePayloads(
        eventId: event.id,
        eventTitle: event.title,
        payloads: preActionPayloads,
        notificationKeyPrefix: 'pre_action',
      );
    }, label: 'smart_preparation_alarm_notifications');
    await _tryFollowUp(
      () => widget.backend.insertReminders(reminderPayloads),
      label: 'reminders',
    );
    await _tryFollowUp(() async {
      final result = await const DepartureAlarmService().scheduleForEvent(
        event,
        safetyMarginOverride: departureSafetyMargin,
      );
      final hasCoords = event.locationLat != null && event.locationLng != null;
      // 릴리즈 기기에서도 확인 가능하도록 DiagLogger로 등록/스킵 사유를 남긴다.
      DiagLogger.log(
        'DepartureAlarm',
        result.isScheduled
            ? 'scheduled hasCoords=$hasCoords loc="${event.location ?? ''}"'
            : 'skipped reason=${result.skippedReason ?? 'unknown'} '
                'hasCoords=$hasCoords loc="${event.location ?? ''}"',
      );
    }, label: 'departure_alarm');

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
  }

  Future<_PostSaveFollowUpResult> _scheduleImmediateAlarmNotifications({
    required EventModel event,
  }) async {
    final alarmFailures = <_AlarmScheduleFailure>[];
    final eventStartAt = event.startAt ?? _startAt;
    final reminderPayloads = _buildReminderPayloads(
      userId: event.userId,
      eventId: event.id,
      eventStartAt: eventStartAt,
      reminderOffset: _reminderOffset,
    );
    await _scheduleCriticalAlarmFromReminderPayloads(
      event: event,
      reminderPayloads: reminderPayloads,
      alarmFailures: alarmFailures,
    );

    final reminderOffset = _reminderOffset;
    if (reminderOffset != null) {
      var eventReminderNotifyAt = eventStartAt.subtract(reminderOffset);
      // 기본 60분 전 알림 시각이 이미 과거지만 일정 시작은 아직 미래라면
      // (= 1시간 이내 시작 일정) 스킵되지 않도록 시작 정각으로 보정한다.
      final reminderNow = DateTime.now();
      if (!eventReminderNotifyAt.isAfter(reminderNow) &&
          eventStartAt.isAfter(reminderNow)) {
        eventReminderNotifyAt = eventStartAt;
      }
      await _tryFollowUp(() async {
        final result =
            await widget.notificationService.scheduleEventReminderWithResult(
          id: widget.notificationService.notificationIdFor(
            '${event.id}:push',
          ),
          title: event.title,
          body: '일정 시작: ${event.title}',
          notifyAt: eventReminderNotifyAt,
          payload: 'event:${event.id}',
        );
        _recordAlarmScheduleResult(
          result,
          label: 'local_event_reminder',
          failures: alarmFailures,
        );
      }, label: 'local_event_reminder');
    }
    return _PostSaveFollowUpResult(alarmFailures: alarmFailures);
  }

  Future<void> _scheduleCriticalAlarmFromReminderPayloads({
    required EventModel event,
    required List<Map<String, dynamic>> reminderPayloads,
    required List<_AlarmScheduleFailure> alarmFailures,
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

    await _tryFollowUp(() async {
      final result =
          await widget.notificationService.scheduleCriticalAlarmWithResult(
        id: widget.notificationService.notificationIdFor(
          '${event.id}:critical',
        ),
        title: event.title,
        notifyAt: notifyAt,
        body: '중요 일정이 곧 시작됩니다.',
        payload: 'event:${event.id}',
      );
      _recordAlarmScheduleResult(
        result,
        label: 'critical_alarm',
        failures: alarmFailures,
      );
    }, label: 'critical_alarm');
  }

  void _recordAlarmScheduleResult(
    NotificationScheduleResult result, {
    required String label,
    required List<_AlarmScheduleFailure> failures,
  }) {
    if (result.isScheduled) {
      DiagLogger.log(
        'ConfirmScreen',
        '$label scheduled notifyAt=${result.notifyAt.toIso8601String()}',
      );
      return;
    }
    final message = result.message ?? '알림을 예약하지 못했습니다.';
    DiagLogger.log(
      'ConfirmScreen',
      '$label failed status=${result.status.name} '
          'notifyAt=${result.notifyAt.toIso8601String()} message=$message',
    );
    if (result.status == NotificationScheduleStatus.skippedPast) {
      return;
    }
    failures.add(
      _AlarmScheduleFailure(
        label: label,
        status: result.status,
        message: message,
      ),
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

    final criticalNotifyAt = _resolveCriticalNotifyAt(
      eventStartAt: eventStartAt,
      offset: Duration.zero,
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
          nextTravelBufferMinutes: await _resolveTravelBufferMinutesForWidget(
            nextEvent,
          ),
        ),
      );
    } catch (e) {
      debugPrint('ConfirmScreen 위젯 갱신 무시: $e');
    }
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

  List<_PreActionDraft> _initialPreActions() {
    return _preActionsFromValue(
      _smartPreparationAlarmValues(widget.parsedSchedule),
    );
  }

  bool _hasExplicitPreActions(Map<String, dynamic> schedule) {
    return _preActionsFromValue(schedule['pre_actions']).isNotEmpty;
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
    AppFeedbackService.showSnackBar(message, context: context);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('일정 확인'),
        leading: IconButton(
          tooltip: '취소',
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            unawaited(AnalyticsService.logScheduleCancelled());
            context.pop('cancelled');
          },
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _save,
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
                  maxWidth: context.planflowWindowInfo.contentMaxWidth,
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
                            padding: EdgeInsets.all(
                              AppConstants.defaultPadding,
                            ),
                            child: Text('자동 파싱에 실패했어요. 내용을 확인하고 직접 입력해 주세요.'),
                          ),
                        ),
                      if (_shouldShowTimePeriodClarification) ...[
                        const SizedBox(height: AppConstants.sectionSpacing),
                        _buildTimePeriodClarificationCard(),
                      ],
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
                        useStrongAlarm: _strongAlarm,
                        isLookingUpLocation: _isLookingUpLocation,
                        isSearchingLocation: _isLookingUpLocation,
                        locationLat: _locationLat,
                        locationLng: _locationLng,
                        locationHelperText: '같은 장소의 과거 준비물을 아래에서 다시 쓸 수 있어요.',
                        initiallyExpandClassification:
                            !_recurrenceSelection.isNone,
                        initiallyExpandDetails: _shouldExpandDetailsSection,
                        initiallyExpandAlarm: _isCritical,
                        initiallyExpandCriticalAlarm: _isCritical,
                        onLocationTextChanged: _handleLocationTextChanged,
                        onStartChanged: (value) {
                          setState(() {
                            final previousStart = _startAt;
                            _startEditedByUser = true;
                            _startAt = value;
                            _endAt = shiftEventEndWhenStartChanges(
                              previousStart: previousStart,
                              newStart: _startAt,
                              currentEnd: _endAt,
                              endEditedByUser: _endEditedByUser,
                            );
                            if (_endAt != null && _endAt!.isBefore(_startAt)) {
                              _endAt = _startAt;
                            }
                          });
                        },
                        onEndChanged: (value) {
                          setState(() {
                            _endEditedByUser = true;
                            if (value != null && value.isBefore(_startAt)) {
                              _endAt = _startAt;
                            } else {
                              _endAt = value;
                            }
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
                            if (!value) _strongAlarm = false;
                          });
                        },
                        onStrongAlarmChanged: (value) {
                          setState(() {
                            _strongAlarm = value;
                          });
                        },
                        onLocationPick: _lookupLocation,
                        extraAfterLocation: KeyedSubtree(
                          key: _suppliesKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_participants.isNotEmpty ||
                                  _targets.isNotEmpty) ...[
                                _PeopleFieldsCard(
                                  participants: _participants,
                                  targets: _targets,
                                ),
                                const SizedBox(height: 12),
                              ],
                              _SuppliesEditor(
                                supplies: _supplies,
                                newSupplyController: _newSupplyController,
                                newSupplyFocusNode: _newSupplyFocusNode,
                                errorText: _supplyErrorText,
                                onAdd: _addSupplyFromInput,
                                onRemove: _removeSupply,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _isSaving ? null : _save,
                        icon: _isSaving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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

class _AmbiguousMeridiemClock {
  const _AmbiguousMeridiemClock({required this.hour, required this.minute});

  factory _AmbiguousMeridiemClock.fromDateTime(DateTime value) {
    final hour = value.hour == 0
        ? 12
        : value.hour > 12
            ? value.hour - 12
            : value.hour;
    return _AmbiguousMeridiemClock(hour: hour, minute: value.minute);
  }

  final int hour;
  final int minute;
}

/// 알람 권한이 부족할 때 저장 직후 표시하는 안내 다이얼로그.
///
/// 정확한 알람 권한 누락 / 배터리 최적화 예외 미적용 여부에 따라
/// 해당 설정 화면으로 이동하는 버튼을 표시한다.
/// [저장을 막지 않으며] dismiss 후 홈으로 이동한다.
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('나중에'),
        ),
      ],
    );
  }
}
