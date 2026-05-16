import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/models/user_settings_model.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/calendar_auto_sync_service.dart';
import '../../services/event_preparation_service.dart';
import '../../services/gpt_service.dart';
import '../../services/home_widget_service.dart';
import '../../services/manual_event_side_effect_service.dart';
import '../../services/smart_preparation_alarm_service.dart';
import '../../services/voice_command_router.dart';
import '../../services/voice_text_cleanup_service.dart';

enum VoiceScheduleAction { add, edit, delete, query, choose }

class VoiceActionScreen extends StatefulWidget {
  VoiceActionScreen({
    super.key,
    required this.rawText,
    required this.action,
    this.eventRepository,
    this.gptService,
    ManualEventSideEffectService? sideEffectService,
    HomeWidgetService? homeWidgetService,
    this.forceSyncCalendars,
    this.userIdOverride,
  })  : sideEffectService =
            sideEffectService ?? const ManualEventSideEffectService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService();

  final String rawText;
  final VoiceScheduleAction action;
  final EventRepository? eventRepository;
  final GptService? gptService;
  final ManualEventSideEffectService sideEffectService;
  final HomeWidgetService homeWidgetService;
  final Future<void> Function({required String reason, required bool force})?
      forceSyncCalendars;
  final String? userIdOverride;

  @override
  State<VoiceActionScreen> createState() => _VoiceActionScreenState();
}

class _VoiceActionScreenState extends State<VoiceActionScreen>
    with WidgetsBindingObserver {
  final List<EventModel> _events = <EventModel>[];
  final Set<String> _selectedDeleteEventIds = <String>{};
  bool _isLoading = true;
  bool _isDeleting = false;
  bool _isSaving = false;
  String? _message;
  bool _hasChosenAction = false;
  VoiceTextCleanupResult? _cleanupResult;
  VoiceCommandRouteResult? _routeResult;
  _CandidateLoadDiagnostics? _candidateLoadDiagnostics;
  _CandidateLoadSnapshot? _candidateLoadSnapshot;

  late VoiceScheduleAction _selectedAction;
  late final VoiceCommandRouter _voiceCommandRouter;

  EventRepository get _repository =>
      widget.eventRepository ?? EventRepository.supabase();

  bool get _isDelete => _selectedAction == VoiceScheduleAction.delete;
  bool get _isEdit => _selectedAction == VoiceScheduleAction.edit;
  bool get _isAdd => _selectedAction == VoiceScheduleAction.add;
  bool get _isQuery => _selectedAction == VoiceScheduleAction.query;
  bool get _isChoose => _selectedAction == VoiceScheduleAction.choose;
  String get _normalizedRawText =>
      _cleanupResult?.cleanedText ??
      _voiceCommandRouter.normalizeManagementText(widget.rawText);
  List<String> get _requestedChanges =>
      _routeResult?.requestedChanges ?? const <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voiceCommandRouter = const VoiceCommandRouter();
    _selectedAction = widget.action;
    unawaited(_loadCandidates());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _isAdd) {
      return;
    }
    unawaited(_loadCandidates(allowAutoSyncRetry: false));
  }

  @override
  void didUpdateWidget(covariant VoiceActionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final rawTextChanged = oldWidget.rawText != widget.rawText;
    final actionChanged = oldWidget.action != widget.action;
    if (!rawTextChanged && !actionChanged) {
      return;
    }
    _selectedAction = widget.action;
    _hasChosenAction = false;
    _cleanupResult = null;
    _routeResult = null;
    _candidateLoadDiagnostics = null;
    _candidateLoadSnapshot = null;
    _events.clear();
    _selectedDeleteEventIds.clear();
    unawaited(_loadCandidates(allowAutoSyncRetry: false));
  }

  String _actionTitle() {
    switch (_selectedAction) {
      case VoiceScheduleAction.add:
        return '음성으로 일정 추가';
      case VoiceScheduleAction.edit:
        return '음성으로 일정 수정';
      case VoiceScheduleAction.delete:
        return '음성으로 일정 삭제';
      case VoiceScheduleAction.query:
        return '음성으로 일정 조회';
      case VoiceScheduleAction.choose:
        return '음성으로 일정 관리';
    }
  }

  String _actionDescription() {
    switch (_selectedAction) {
      case VoiceScheduleAction.add:
        return '인식된 내용을 바로 저장하지 않고, 확인 화면으로 먼저 보냅니다.';
      case VoiceScheduleAction.edit:
        return '말한 내용과 가장 가까운 일정을 고른 뒤 편집 화면에서 다시 확인해 주세요.';
      case VoiceScheduleAction.delete:
        return '말한 내용과 가장 가까운 일정을 고른 뒤 삭제를 다시 확인해 주세요.';
      case VoiceScheduleAction.query:
        return 'DB에서 직접 일정을 찾아 카드로 보여드립니다.';
      case VoiceScheduleAction.choose:
        return '무엇을 할지 먼저 고른 뒤 그에 맞는 일정 후보를 확인해 주세요.';
    }
  }

  String _candidateActionLabel() {
    if (_isDelete) {
      return '삭제하기';
    }
    if (_isEdit) {
      return '수정하기';
    }
    return '상세 보기';
  }

  IconData _candidateActionIcon() {
    if (_isDelete) {
      return Icons.delete_outline;
    }
    if (_isEdit) {
      return Icons.edit_note;
    }
    return Icons.visibility_outlined;
  }

  Future<void> _openAddConfirm() async {
    await _recordVoiceLog(
      action: 'add',
      result: 'confirm_opened',
    );
    if (!mounted) {
      return;
    }
    final parsed = <String, dynamic>{
      'raw_text': _normalizedRawText,
      'parse_pending': true,
    };
    await context.push(AppRoutes.confirm, extra: parsed);
  }

  Future<void> _openQueryResult(EventModel event) async {
    await _recordVoiceLog(
      action: 'query',
      targetEventId: event.id,
      result: 'opened',
    );
    if (!mounted) {
      return;
    }
    await context.push(
      '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}',
      extra: event,
    );
  }

  Future<void> _loadCandidates({bool allowAutoSyncRetry = true}) async {
    if (_isAdd) {
      setState(() {
        _events.clear();
        _message = null;
        _candidateLoadDiagnostics = null;
        _candidateLoadSnapshot = null;
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
      _events.clear();
      _selectedDeleteEventIds.clear();
      _candidateLoadSnapshot = null;
    });

    try {
      final userId = _resolveUserId();
      if (userId == null) {
        setState(() {
          _message = '로그인 후 음성으로 일정을 관리할 수 있어요.';
          _candidateLoadDiagnostics = null;
          _candidateLoadSnapshot = null;
          _isLoading = false;
        });
        return;
      }

      if (!AppEnv.isSupabaseReady && widget.eventRepository == null) {
        setState(() {
          _message = 'Supabase 설정이 없어 저장된 일정을 불러올 수 없어요.';
          _candidateLoadDiagnostics = null;
          _candidateLoadSnapshot = null;
          _isLoading = false;
        });
        return;
      }

      final events = await _repository.listEvents(userId: userId);
      if (events.isEmpty && allowAutoSyncRetry && _canAutoRetryEmptyLoad) {
        await _syncAndReloadCandidates();
        return;
      }
      var filteredEvents = _filterEventsForAction(events);
      var cleanup = VoiceTextCleanupService.cleanLocally(
        widget.rawText,
        context: _cleanupContext(),
        candidates: _cleanupCandidates(filteredEvents),
      );
      var routeResult = _routeResultForText(
        cleanup.cleanedText,
        filteredEvents,
      );
      var rankedItems =
          _rankEventItems(filteredEvents, routeResult.targetQuery);

      if (_shouldTryAiCleanup(cleanup, rankedItems)) {
        cleanup = await _cleanupWithAi(
          cleanup.cleanedText,
          filteredEvents,
        );
        filteredEvents = _filterEventsForAction(events, cleanup.cleanedText);
        routeResult = _routeResultForText(
          cleanup.cleanedText,
          filteredEvents,
        );
        rankedItems = _rankEventItems(filteredEvents, routeResult.targetQuery);
      }

      final candidateDateRange = _candidateDateRangeForAction(
        routeResult: routeResult,
      );
      final rankedCandidates = _candidateEventsForDisplay(
        rankedItems,
        filteredEvents,
        candidateDateRange: candidateDateRange,
      ).map((item) => item.event).toList(growable: false);
      final maxCount = _candidateMaxTake(
        rankedCandidates: rankedCandidates,
        candidateDateRange: candidateDateRange,
      );
      final ranked = maxCount == null
          ? rankedCandidates
          : rankedCandidates.take(maxCount).toList(growable: false);
      final diagnostics = _CandidateLoadDiagnostics(
        action: _selectedAction.name,
        userIdAvailable: userId.isNotEmpty,
        totalEventCount: events.length,
        filteredCount: filteredEvents.length,
        displayedCount: ranked.length,
        targetQuery: routeResult.targetQuery,
      );
      debugPrint(
        'VoiceActionScreen candidate load: ${diagnostics.toLogLine()}',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cleanupResult = cleanup;
        _routeResult = routeResult;
        _candidateLoadDiagnostics = diagnostics;
        _candidateLoadSnapshot = _CandidateLoadSnapshot(
          diagnostics: diagnostics,
          events: ranked,
        );
        _events
          ..clear()
          ..addAll(ranked);
        _selectedDeleteEventIds.removeWhere(
          (id) => !ranked.any((event) => event.id == id),
        );
        _message =
            events.isEmpty && !allowAutoSyncRetry && _canAutoRetryEmptyLoad
                ? '앱 DB에서 일정을 못 불러왔어요'
                : _emptyMessageForAction(
                    ranked: ranked,
                    totalEvents: events,
                    filteredEvents: filteredEvents,
                  );
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '저장된 일정을 불러오지 못했어요. 로그인 상태와 스토리지를 확인해 주세요.';
        _candidateLoadDiagnostics = null;
        _candidateLoadSnapshot = null;
        _isLoading = false;
      });
    }
  }

  List<_RankedEvent> _candidateEventsForDisplay(
    List<_RankedEvent> rankedItems,
    List<EventModel> filteredEvents, {
    _DateRange? candidateDateRange,
  }) {
    if (_isQuery) {
      return rankedItems;
    }

    final scoredItems = rankedItems
        .where((item) => item.matchScore > 0)
        .toList(growable: false);
    if (scoredItems.isNotEmpty) {
      if (candidateDateRange != null) {
        final dateMatched = scoredItems
            .where(
              (item) => _isEventInCandidateDateRange(
                item.event,
                candidateDateRange,
              ),
            )
            .toList(growable: false);
        if (dateMatched.isNotEmpty) {
          return dateMatched;
        }
      }
      return scoredItems.take(5).toList(growable: false);
    }

    if (candidateDateRange != null) {
      final inRange = filteredEvents
          .where(
            (event) => _isEventInCandidateDateRange(event, candidateDateRange),
          )
          .toList(growable: false);
      if (inRange.isNotEmpty) {
        final ranked = inRange
            .map(
              (event) => _RankedEvent(
                event: event,
                score: 0,
                matchScore: 0,
              ),
            )
            .toList(growable: false);
        ranked.sort((a, b) {
          return _compareDateForCandidate(
            a.event.startAt,
            b.event.startAt,
          );
        });
        return ranked;
      }

      final now = DateTime.now();
      final fallback = filteredEvents.map((event) {
        return _RankedEvent(
          event: event,
          score: _fallbackCandidateScore(event.startAt, now),
          matchScore: 0,
        );
      }).toList(growable: false);
      fallback.sort((a, b) {
        return _compareRecentAndUpcoming(
          a.event.startAt,
          b.event.startAt,
          now,
        );
      });
      return fallback;
    }

    if (filteredEvents.isEmpty) {
      return const [];
    }

    final now = DateTime.now();
    final fallback = filteredEvents.map((event) {
      return _RankedEvent(
        event: event,
        score: _fallbackCandidateScore(event.startAt, now),
        matchScore: 0,
      );
    }).toList(growable: false);

    fallback.sort((a, b) {
      return _compareRecentAndUpcoming(
        a.event.startAt,
        b.event.startAt,
        now,
      );
    });
    return fallback.take(3).toList(growable: false);
  }

  int? _candidateMaxTake({
    required List<EventModel> rankedCandidates,
    _DateRange? candidateDateRange,
  }) {
    if (_isQuery) {
      return 10;
    }
    if ((_isEdit || _isDelete) && candidateDateRange != null) {
      final hasDateScopedCandidate = rankedCandidates.any(
        (candidate) =>
            _isEventInCandidateDateRange(candidate, candidateDateRange),
      );
      if (hasDateScopedCandidate) {
        return null;
      }
      return 3;
    }
    return 5;
  }

  _DateRange? _candidateDateRangeForAction({
    required VoiceCommandRouteResult routeResult,
  }) {
    if (!_isEdit && !_isDelete) {
      return null;
    }

    final targetRange = _queryDateRange(routeResult.targetQuery);
    if (targetRange != null) {
      return targetRange;
    }

    final normalized = routeResult.cleanedText.replaceAll(RegExp(r'\s+'), ' ');
    final firstDateRange = _firstDateRangeInText(normalized);
    if (firstDateRange != null) {
      return firstDateRange;
    }

    return _queryDateRange(normalized);
  }

  _DateRange? _firstDateRangeInText(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final matches = RegExp(
      r'((?:이번|다음)\s*주\s*)?[월화수목금토일]요일|오늘|내일|모레|글피|(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일',
    ).allMatches(normalized).toList(growable: false);
    if (matches.isEmpty) {
      return null;
    }
    final first = matches.first.group(0) ?? '';
    final inferred =
        GptService(now: () => planflowNow()).inferStartAtFromRawText(
      first,
    );
    if (inferred != null) {
      final local = planflowLocal(inferred);
      final day = DateTime(local.year, local.month, local.day);
      return _DateRange(day, day.add(const Duration(days: 1)));
    }

    if (first.contains('오늘')) {
      return _DateRange(today, today.add(const Duration(days: 1)));
    }
    if (first.contains('내일')) {
      final start = today.add(const Duration(days: 1));
      return _DateRange(start, start.add(const Duration(days: 1)));
    }
    if (first.contains('모레') || first.contains('글피')) {
      final start = today.add(const Duration(days: 2));
      return _DateRange(start, start.add(const Duration(days: 1)));
    }
    if (RegExp(r'(이번\s*주|이번주)').hasMatch(first)) {
      final start = today.subtract(Duration(days: today.weekday - 1));
      return _DateRange(start, start.add(const Duration(days: 7)));
    }
    if (RegExp(r'(다음\s*주|다음주)').hasMatch(first)) {
      final start = today
          .subtract(Duration(days: today.weekday - 1))
          .add(const Duration(days: 7));
      return _DateRange(start, start.add(const Duration(days: 7)));
    }

    return null;
  }

  bool _isEventInCandidateDateRange(
    EventModel event,
    _DateRange? candidateDateRange,
  ) {
    if (candidateDateRange == null) {
      return false;
    }
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final local = planflowLocal(startAt);
    return !local.isBefore(candidateDateRange.start) &&
        local.isBefore(candidateDateRange.end);
  }

  int _compareDateForCandidate(DateTime? aStart, DateTime? bStart) {
    if (aStart == null && bStart == null) {
      return 0;
    }
    if (aStart == null) {
      return 1;
    }
    if (bStart == null) {
      return -1;
    }
    final a = planflowLocal(aStart);
    final b = planflowLocal(bStart);
    return a.compareTo(b);
  }

  Future<void> _syncAndReloadCandidates() async {
    try {
      await _invokeForceSyncCalendars(
        reason: 'voice_action_manual_retry',
        force: true,
      );
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen manual sync failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    await _loadCandidates(allowAutoSyncRetry: false);
  }

  int _fallbackCandidateScore(DateTime? startAt, DateTime now) {
    if (startAt == null) {
      return 0;
    }
    return startAt.isBefore(now) ? 0 : 1;
  }

  int _compareRecentAndUpcoming(
    DateTime? aStart,
    DateTime? bStart,
    DateTime now,
  ) {
    if (aStart == null && bStart == null) {
      return 0;
    }
    if (aStart == null) {
      return 1;
    }
    if (bStart == null) {
      return -1;
    }

    final aIsUpcoming = !aStart.isBefore(now);
    final bIsUpcoming = !bStart.isBefore(now);
    if (aIsUpcoming != bIsUpcoming) {
      return aIsUpcoming ? -1 : 1;
    }

    if (aIsUpcoming) {
      return aStart.compareTo(bStart);
    }
    return bStart.compareTo(aStart);
  }

  Future<void> _selectAction(VoiceScheduleAction action) async {
    setState(() {
      _selectedAction = action;
      _hasChosenAction = true;
      _events.clear();
      _selectedDeleteEventIds.clear();
      _message = action == VoiceScheduleAction.add ? '일정 확인 화면으로 이동합니다.' : null;
      _candidateLoadDiagnostics = null;
      _candidateLoadSnapshot = null;
      _isLoading = action != VoiceScheduleAction.add;
    });

    if (action == VoiceScheduleAction.add) {
      await _openAddConfirm();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    await _loadCandidates();
  }

  List<EventModel> _filterEventsForAction(
    List<EventModel> events, [
    String? rawText,
  ]) {
    if (!_isQuery) {
      return events;
    }

    final range = _queryDateRange(rawText ?? _normalizedRawText);
    if (range == null) {
      return events;
    }

    return events.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      final localStart = planflowLocal(startAt);
      return !localStart.isBefore(range.start) &&
          localStart.isBefore(range.end);
    }).toList(growable: false);
  }

  String? _emptyMessageForAction({
    required List<EventModel> ranked,
    required List<EventModel> totalEvents,
    required List<EventModel> filteredEvents,
  }) {
    if (ranked.isNotEmpty) {
      return null;
    }
    if (totalEvents.isEmpty) {
      return '동기화 후 다시 찾아보거나 새 일정으로 추가해 주세요.';
    }
    if (!_isQuery && filteredEvents.isEmpty) {
      return '동기화 후 다시 찾아보거나 새 일정으로 추가해 주세요.';
    }
    if (!_isQuery) {
      return '조건에 맞는 일정을 찾지 못했어요. 최근 또는 다가오는 일정 후보를 다시 보여드릴게요.';
    }

    final rangeLabel = _queryRangeLabel(_normalizedRawText);
    return '$rangeLabel 일정은 아직 없어요. 새 일정이 필요하면 “추가”로 바로 등록할 수 있습니다.';
  }

  bool get _canAutoRetryEmptyLoad =>
      widget.eventRepository == null || widget.forceSyncCalendars != null;

  Future<void> _invokeForceSyncCalendars({
    required String reason,
    required bool force,
  }) async {
    final override = widget.forceSyncCalendars;
    if (override != null) {
      await override(reason: reason, force: force);
      return;
    }
    await CalendarAutoSyncService().syncConnectedCalendars(
      reason: reason,
      force: force,
    );
  }

  _DateRange? _queryDateRange(String rawText) {
    final normalized = rawText.replaceAll(RegExp(r'\s+'), ' ');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (normalized.contains('내일')) {
      final start = today.add(const Duration(days: 1));
      return _DateRange(start, start.add(const Duration(days: 1)));
    }
    if (normalized.contains('모레')) {
      final start = today.add(const Duration(days: 2));
      return _DateRange(start, start.add(const Duration(days: 1)));
    }
    if (RegExp(r'(이번\s*주|이번주|주간)').hasMatch(normalized)) {
      final start = today.subtract(Duration(days: today.weekday - 1));
      return _DateRange(start, start.add(const Duration(days: 7)));
    }
    if (normalized.contains('오늘')) {
      return _DateRange(today, today.add(const Duration(days: 1)));
    }
    return null;
  }

  String _queryRangeLabel(String rawText) {
    final normalized = rawText.replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.contains('내일')) {
      return '내일';
    }
    if (normalized.contains('모레')) {
      return '모레';
    }
    if (RegExp(r'(이번\s*주|이번주|주간)').hasMatch(normalized)) {
      return '이번 주';
    }
    if (normalized.contains('오늘')) {
      return '오늘';
    }
    return '다가오는';
  }

  String _querySummaryText(List<EventModel> events) {
    final rangeLabel = _queryRangeLabel(_normalizedRawText);
    if (events.isEmpty) {
      return '$rangeLabel 일정은 아직 없습니다.';
    }

    return '$rangeLabel 일정은 ${events.length}개입니다.';
  }

  List<_QueryDayGroup> _buildQueryTimeline(List<EventModel> events) {
    final ordered = [...events]..sort((a, b) {
        final aStart = a.startAt;
        final bStart = b.startAt;
        if (aStart == null && bStart == null) {
          return a.title.compareTo(b.title);
        }
        if (aStart == null) {
          return 1;
        }
        if (bStart == null) {
          return -1;
        }
        final compare = aStart.compareTo(bStart);
        if (compare != 0) {
          return compare;
        }
        return a.title.compareTo(b.title);
      });

    final grouped = <DateTime, List<EventModel>>{};
    final nullStartEvents = <EventModel>[];
    for (final event in ordered) {
      final startAt = event.startAt;
      if (startAt == null) {
        nullStartEvents.add(event);
        continue;
      }
      final dayKey = planflowLocalDay(startAt);
      grouped.putIfAbsent(dayKey, () => <EventModel>[]).add(event);
    }

    final dayGroups = grouped.entries.map((entry) {
      final buckets = <String, List<EventModel>>{
        '오전': <EventModel>[],
        '오후': <EventModel>[],
        '저녁': <EventModel>[],
        '시간 미정': <EventModel>[],
      };

      for (final event in entry.value) {
        final label = _queryBucketLabel(event.startAt);
        buckets.putIfAbsent(label, () => <EventModel>[]).add(event);
      }

      return _QueryDayGroup(
        label: _koreanDateLabel(entry.key),
        events: entry.value,
        buckets: buckets.entries
            .where((bucket) => bucket.value.isNotEmpty)
            .map((bucket) => MapEntry(bucket.key, bucket.value))
            .toList(growable: false),
      );
    }).toList(growable: false);

    if (nullStartEvents.isNotEmpty) {
      dayGroups.add(
        _QueryDayGroup(
          label: '시간 미정',
          events: nullStartEvents,
          buckets: <MapEntry<String, List<EventModel>>>[
            MapEntry<String, List<EventModel>>('시간 미정', nullStartEvents),
          ],
        ),
      );
    }

    return dayGroups;
  }

  String _queryBucketLabel(DateTime? value) {
    if (value == null) {
      return '시간 미정';
    }
    final local = planflowLocal(value);
    if (local.hour < 12) {
      return '오전';
    }
    if (local.hour < 18) {
      return '오후';
    }
    return '저녁';
  }

  String _koreanDateLabel(DateTime value) {
    const weekdays = <int, String>{
      DateTime.monday: '월요일',
      DateTime.tuesday: '화요일',
      DateTime.wednesday: '수요일',
      DateTime.thursday: '목요일',
      DateTime.friday: '금요일',
      DateTime.saturday: '토요일',
      DateTime.sunday: '일요일',
    };
    return '${value.month}월 ${value.day}일 ${weekdays[value.weekday]}';
  }

  String? _resolveUserId() {
    final override = widget.userIdOverride?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return Supabase.instance.client.auth.currentUser?.id;
  }

  List<_RankedEvent> _rankEventItems(List<EventModel> events, String rawText) {
    final now = DateTime.now();
    final tokens = _voiceCommandRouter.searchTokens(rawText);
    final ranked = events.map((event) {
      final searchable = _voiceCommandRouter.normalizeManagementText([
        event.title,
        event.location ?? '',
        event.memo ?? '',
        event.supplies.join(' '),
      ].join(' '));
      final searchableTokens = _voiceCommandRouter.searchTokens(searchable);
      var matchScore = 0;
      for (final token in tokens) {
        if (searchable.contains(token)) {
          matchScore += token.length >= 3 ? 2 : 1;
          continue;
        }
        if (_voiceCommandRouter.hasFuzzyTokenMatch(token, searchableTokens)) {
          matchScore += 2;
          continue;
        }
        if (_voiceCommandRouter.hasPrefixMatch(token, searchableTokens)) {
          matchScore += 1;
        }
      }
      var score = matchScore;
      final startAt = event.startAt;
      if (startAt != null && !startAt.isBefore(now)) {
        score += 1;
      }
      return _RankedEvent(event: event, score: score, matchScore: matchScore);
    }).toList(growable: false);

    ranked.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      final aStart = a.event.startAt;
      final bStart = b.event.startAt;
      if (aStart == null && bStart == null) {
        return 0;
      }
      if (aStart == null) {
        return 1;
      }
      if (bStart == null) {
        return -1;
      }
      return aStart.compareTo(bStart);
    });

    return ranked;
  }

  bool _shouldTryAiCleanup(
    VoiceTextCleanupResult cleanup,
    List<_RankedEvent> rankedItems,
  ) {
    if (!VoiceTextCleanupService.shouldAskAi(cleanup.cleanedText)) {
      return false;
    }
    if (cleanup.method == VoiceTextCleanupMethod.ai) {
      return false;
    }
    return rankedItems.isEmpty || rankedItems.first.matchScore == 0;
  }

  Future<VoiceTextCleanupResult> _cleanupWithAi(
    String text,
    List<EventModel> events,
  ) async {
    final local = VoiceTextCleanupService.cleanLocally(
      text,
      context: _cleanupContext(),
      candidates: _cleanupCandidates(events),
    );
    try {
      return await (widget.gptService ?? GptService()).cleanupVoiceText(
        local.cleanedText,
        context: _cleanupContext(),
        candidates: _cleanupCandidates(events),
      );
    } catch (error) {
      debugPrint('VoiceActionScreen text cleanup failed: $error');
      return local;
    }
  }

  VoiceTextCleanupContext _cleanupContext() {
    return switch (_selectedAction) {
      VoiceScheduleAction.add => VoiceTextCleanupContext.add,
      VoiceScheduleAction.edit => VoiceTextCleanupContext.edit,
      VoiceScheduleAction.delete => VoiceTextCleanupContext.delete,
      VoiceScheduleAction.query => VoiceTextCleanupContext.query,
      VoiceScheduleAction.choose => VoiceTextCleanupContext.query,
    };
  }

  List<VoiceTextCleanupCandidate> _cleanupCandidates(List<EventModel> events) {
    return events
        .map(
          (event) => VoiceTextCleanupCandidate(
            title: event.title,
            location: event.location,
            startAt: event.startAt,
          ),
        )
        .toList(growable: false);
  }

  VoiceCommandRouteResult _routeResultForText(
    String text,
    List<EventModel> events,
  ) {
    return _voiceCommandRouter.route(
      text,
      intent: _routeIntentFromAction(_selectedAction),
      context: _cleanupContext(),
      candidates: _cleanupCandidates(events),
    );
  }

  VoiceCommandRouteIntent _routeIntentFromAction(VoiceScheduleAction action) {
    return switch (action) {
      VoiceScheduleAction.add => VoiceCommandRouteIntent.add,
      VoiceScheduleAction.edit => VoiceCommandRouteIntent.edit,
      VoiceScheduleAction.delete => VoiceCommandRouteIntent.delete,
      VoiceScheduleAction.query => VoiceCommandRouteIntent.query,
      VoiceScheduleAction.choose => VoiceCommandRouteIntent.query,
    };
  }

  /// 음성 명령으로 파악한 변경값을 편집화면 없이 바로 저장한다.
  Future<void> _applyAndSave(EventModel event) async {
    final editedEvent = _eventWithRequestedVoiceChanges(event);
    final previousStartAt = event.startAt;
    setState(() => _isSaving = true);
    try {
      final savedEvent = await _repository.updateEvent(editedEvent);
      final userId = _resolveUserId();
      if (userId != null) {
        final settings = await SettingsRepository.supabase().fetchSettings(
          userId,
        );
        await widget.sideEffectService.syncAfterSave(
          event: savedEvent,
          userId: userId,
          prepTimeMin: settings?.prepTimeMin ??
              SmartPreparationAlarmService.defaultPrepTimeMin,
          prepPreAlarmOffset: settings?.prepPreAlarmOffset ??
              SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
          departPreAlarmOffset: settings?.departPreAlarmOffset ??
              SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
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
        await _refreshHomeWidget(userId);
      }
      unawaited(CalendarAutoSyncService().syncAfterEventSave(savedEvent));
      unawaited(
        EventPreparationService(eventRepository: _repository)
            .prepareAfterSave(savedEvent),
      );
      await _recordVoiceLog(
        action: 'edit',
        targetEventId: savedEvent.id,
        result: 'applied_directly',
      );
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_direct_apply',
        eventId: savedEvent.id,
        startAt: savedEvent.startAt,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('일정이 변경되었어요.')),
      );
      context.pop();
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen direct save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장하지 못했어요. 다시 시도해 주세요.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 카드에 표시할 변경 미리보기 문자열을 반환한다.
  /// 감지된 변경이 없으면 null 반환.
  String? _buildChangePreviewText(EventModel original) {
    final edited = _eventWithRequestedVoiceChanges(original);
    final parts = <String>[];

    if (edited.startAt != original.startAt && edited.startAt != null) {
      final newStart = planflowLocal(edited.startAt!);
      const weekdays = ['', '월', '화', '수', '목', '금', '토', '일'];
      final period = newStart.hour < 12 ? '오전' : '오후';
      final h = newStart.hour % 12 == 0 ? 12 : newStart.hour % 12;
      final m = newStart.minute > 0
          ? ' ${newStart.minute.toString().padLeft(2, '0')}분'
          : '';
      parts.add(
        '${newStart.month}/${newStart.day}'
        '(${weekdays[newStart.weekday]}) '
        '$period $h시$m',
      );
    }

    if (edited.location != original.location &&
        (edited.location?.trim().isNotEmpty ?? false)) {
      parts.add(edited.location!.trim());
    }

    return parts.isEmpty ? null : parts.join(', ');
  }

  Future<void> _openEdit(EventModel event) async {
    final editedEvent = _eventWithRequestedVoiceChanges(event);
    final appliedVoiceChange = editedEvent.startAt != event.startAt ||
        editedEvent.endAt != event.endAt ||
        editedEvent.location != event.location;
    await _recordVoiceLog(
      action: 'edit',
      targetEventId: event.id,
      result: 'opened',
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          appliedVoiceChange
              ? '말한 변경값을 반영해 열었어요. 확인 후 저장해 주세요.'
              : '수정할 일정을 열었어요. 확인 후 저장해 주세요.',
        ),
      ),
    );
    await context.push(
      '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}',
      extra: editedEvent,
    );
  }

  EventModel _eventWithRequestedVoiceChanges(EventModel event) {
    final requestedStartLocal = _inferRequestedStartLocal(event);
    final requestedLocation = _inferRequestedLocation();
    if (requestedStartLocal == null && requestedLocation == null) {
      return event;
    }

    final originalStartLocal =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final originalEndLocal =
        event.endAt == null ? null : planflowLocal(event.endAt!);
    final duration = originalStartLocal == null || originalEndLocal == null
        ? null
        : originalEndLocal.difference(originalStartLocal);
    final nextStartUtc = requestedStartLocal == null
        ? event.startAt
        : planflowLocalDateTimeToUtc(requestedStartLocal);
    final nextEndUtc = requestedStartLocal == null
        ? event.endAt
        : duration == null || duration.isNegative || duration == Duration.zero
            ? event.endAt
            : planflowLocalDateTimeToUtc(requestedStartLocal.add(duration));

    return EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: nextStartUtc,
      endAt: nextEndUtc,
      location: requestedLocation ?? event.location,
      locationLat: requestedLocation == null ? event.locationLat : null,
      locationLng: requestedLocation == null ? event.locationLng : null,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      isCritical: event.isCritical,
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: event.parentEventId,
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

  DateTime? _inferRequestedStartLocal(EventModel event) {
    if (_requestedChanges.isNotEmpty &&
        !_requestedChanges.contains('start_at')) {
      return null;
    }
    final text = _normalizedRawText;
    final originalStartLocal =
        event.startAt == null ? planflowNow() : planflowLocal(event.startAt!);
    final dateCandidate = _inferLastDateCandidate(text, originalStartLocal);
    final timeCandidate = _inferLastTimeCandidate(text);
    if (dateCandidate == null && timeCandidate == null) {
      return null;
    }

    final baseDate = dateCandidate ??
        DateTime(
          originalStartLocal.year,
          originalStartLocal.month,
          originalStartLocal.day,
        );
    final hour = timeCandidate?.hour ?? originalStartLocal.hour;
    final minute = timeCandidate?.minute ?? originalStartLocal.minute;
    return DateTime(baseDate.year, baseDate.month, baseDate.day, hour, minute);
  }

  DateTime? _inferLastDateCandidate(String text, DateTime referenceLocal) {
    final dateMatches = RegExp(
      r'((?:이번|다음)\s*주\s*)?[월화수목금토일]요일|오늘|내일|모레|글피|(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일',
    ).allMatches(text).toList(growable: false);
    if (dateMatches.isEmpty) {
      return null;
    }
    final match = dateMatches.last;
    final snippet = text.substring(
      match.start,
      (match.end + 20).clamp(0, text.length),
    );
    return GptService(now: () => referenceLocal).inferStartAtFromRawText(
      snippet,
    );
  }

  _VoiceRequestedTime? _inferLastTimeCandidate(String text) {
    final matches = RegExp(
      r'(오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*([0-9]{1,2}|[가-힣]{1,8})\s*시(?:\s*([0-9]{1,2}|[가-힣]{1,8})\s*분?|\s*(반))?',
    ).allMatches(text).toList(growable: false);
    if (matches.isEmpty) {
      return null;
    }
    final match = matches.last;
    final hourValue = _koreanNumber(match.group(2));
    if (hourValue == null) {
      return null;
    }
    final period = match.group(1) ?? '';
    var hour = hourValue;
    if (RegExp(r'(오후|낮|점심|저녁|밤)').hasMatch(period) && hour < 12) {
      hour += 12;
    }
    if (period == '새벽' && hour == 12) {
      hour = 0;
    }
    final minute =
        match.group(4) != null ? 30 : (_koreanNumber(match.group(3)) ?? 0);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return null;
    }
    return _VoiceRequestedTime(hour, minute);
  }

  int? _koreanNumber(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    final numeric = int.tryParse(text);
    if (numeric != null) {
      return numeric;
    }
    const numbers = <String, int>{
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
    };
    return numbers[text];
  }

  String? _inferRequestedLocation() {
    if (_requestedChanges.isNotEmpty &&
        !_requestedChanges.contains('location')) {
      return null;
    }
    final match = RegExp(r'(?:장소|위치)\s*(?:를|을)?\s*(.+?)(?:로|으로)\s*(?:변경|바꿔|수정)')
        .firstMatch(_normalizedRawText);
    final location = match?.group(1)?.trim();
    return location == null || location.isEmpty ? null : location;
  }

  Future<void> _confirmDelete(EventModel event) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('음성으로 일정 삭제'),
          content: Text('"${event.title}" 일정을 삭제할까요? 이 작업은 되돌릴 수 없습니다.'),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actions: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      foregroundColor: PlanFlowColors.primary,
                      backgroundColor: PlanFlowColors.primaryFaint,
                    ),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: ValueKey('voice-confirm-delete-${event.id}'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: colorScheme.error,
                      foregroundColor: colorScheme.onError,
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('삭제'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );

    if (shouldDelete == true) {
      await _deleteEvent(event);
    }
  }

  void _toggleDeleteSelection(EventModel event, bool selected) {
    if (!_isDelete) {
      return;
    }
    setState(() {
      if (selected) {
        _selectedDeleteEventIds.add(event.id);
      } else {
        _selectedDeleteEventIds.remove(event.id);
      }
    });
  }

  Future<void> _confirmSelectedDelete() async {
    final selectedEvents = _events
        .where((event) => _selectedDeleteEventIds.contains(event.id))
        .toList(growable: false);
    if (selectedEvents.isEmpty) {
      _showMessage('삭제할 일정을 먼저 선택해 주세요.');
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('선택한 일정 삭제'),
          content: Text(
            '${selectedEvents.length}개 일정을 삭제할까요? 이 작업은 되돌릴 수 없습니다.',
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actions: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      foregroundColor: PlanFlowColors.primary,
                      backgroundColor: PlanFlowColors.primaryFaint,
                    ),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('voice-confirm-selected-delete'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: colorScheme.error,
                      foregroundColor: colorScheme.onError,
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('선택 삭제'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );

    if (shouldDelete == true) {
      await _deleteEvents(selectedEvents);
    }
  }

  Future<void> _deleteEvent(EventModel event) async {
    await _deleteEvents(<EventModel>[event]);
  }

  Future<void> _deleteEvents(List<EventModel> events) async {
    final userId = _resolveUserId();
    if (userId == null) {
      _showMessage('로그인 후 삭제할 수 있어요.');
      return;
    }

    setState(() {
      _isDeleting = true;
    });

    try {
      for (final event in events) {
        await _repository.deleteEvent(event.id, userId: userId);
        await widget.sideEffectService.cleanupAfterDelete(
          event.id,
          userId: userId,
        );
        await _resyncExternalPreparationAfterDelete(event, userId: userId);
      }
      await _refreshHomeWidget(userId);
      if (!mounted) {
        return;
      }
      final deletedIds = events.map((event) => event.id).toSet();
      await _recordVoiceLog(
        action: 'delete',
        targetEventId: events.length == 1 ? events.single.id : null,
        result: events.length == 1 ? 'deleted' : 'selected_deleted',
      );
      for (final event in events) {
        EventRefreshBus.instance.notifyChanged(
          reason: 'voice_event_deleted',
          eventId: event.id,
          startAt: event.startAt,
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedDeleteEventIds.removeAll(deletedIds);
      });
      _showMessage(
        events.length == 1 ? '일정을 삭제했습니다.' : '${events.length}개 일정을 삭제했습니다.',
      );
      context.go(AppRoutes.calendar);
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen delete failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showMessage('삭제하지 못했어요. 로그인 상태 또는 Supabase 설정을 확인해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  Future<void> _refreshHomeWidget(String userId) async {
    try {
      final now = DateTime.now();
      final events = await _repository.listEvents(userId: userId);
      final nextEvents = events.where((event) {
        final startAt = event.startAt;
        return startAt != null && !startAt.isBefore(now);
      }).toList(growable: false)
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

      if (nextEvents.isEmpty) {
        await widget.homeWidgetService.updateNextEventData(
          const HomeWidgetNextEventData(title: '다가올 일정이 없어요'),
        );
        return;
      }

      final nextEvent = nextEvents.first;
      await widget.homeWidgetService.updateNextEvent(
        title: nextEvent.title,
        eventId: nextEvent.id,
        startAt: nextEvent.startAt,
        location: nextEvent.location,
        isCritical: nextEvent.isCritical,
        upcomingEvents: nextEvents
            .take(3)
            .map(
              (event) => HomeWidgetListEventData(
                title: event.title,
                startAt: event.startAt,
                location: event.location,
              ),
            )
            .toList(growable: false),
      );
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen widget refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _resyncExternalPreparationAfterDelete(
    EventModel deletedEvent, {
    required String userId,
  }) async {
    final deletedStartAt = deletedEvent.startAt;
    if (deletedStartAt == null) {
      return;
    }
    try {
      final events = await _repository.listEvents(userId: userId);
      await widget.sideEffectService.resyncExternalPreparationForDay(
        dayEvents: events,
        userId: userId,
        dayReference: deletedStartAt,
      );
    } catch (error, stackTrace) {
      debugPrint(
        'VoiceActionScreen external prep delete resync skipped: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
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
      debugPrint('VoiceActionScreen first external lookup skipped: $error');
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
    final reference = dayReference ?? event.startAt;
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
      );
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen external prep resync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _recordVoiceLog({
    required String action,
    String? targetEventId,
    required String result,
  }) async {
    if (!AppEnv.isSupabaseReady) {
      return;
    }

    final userId = _resolveUserId();
    if (userId == null) {
      return;
    }

    try {
      await Supabase.instance.client
          .from('voice_logs')
          .insert(<String, dynamic>{
        'user_id': userId,
        'event_id': targetEventId,
        'raw_text': _normalizedRawText,
        'parsed_json': <String, dynamic>{
          'action': action,
          'target_event_id': targetEventId,
          'result': result,
        },
      });
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen voice log save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _actionTitle();
    final description = _actionDescription();
    final candidateSnapshot = _candidateLoadSnapshot;
    final visibleEvents =
        candidateSnapshot?.events ?? List<EventModel>.of(_events);
    final visibleDiagnostics =
        candidateSnapshot?.diagnostics ?? _candidateLoadDiagnostics;
    final queryDayGroups = !_isAdd && _isQuery
        ? _buildQueryTimeline(visibleEvents)
        : const <_QueryDayGroup>[];

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _loadCandidates(),
          child: ListView(
            cacheExtent: 1200,
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            children: [
              _CommandCard(
                title: title,
                rawText: _normalizedRawText,
                description: description,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              if (_isChoose || _hasChosenAction) ...[
                _ActionChooserCard(
                  currentAction: _selectedAction,
                  onSelected: _selectAction,
                ),
                const SizedBox(height: 12),
              ],
              if (_isAdd) ...[
                _AddConfirmCard(
                  rawText: _normalizedRawText,
                  onContinue: _openAddConfirm,
                ),
                const SizedBox(height: 12),
              ],
              if (!_isAdd)
                _VoiceCandidateSection(
                  action: _selectedAction,
                  isLoading: _isLoading,
                  events: visibleEvents,
                  diagnostics: visibleDiagnostics,
                  message: _message,
                  rawText: _normalizedRawText,
                  querySummary: _querySummaryText(visibleEvents),
                  queryRangeLabel: _queryRangeLabel(_normalizedRawText),
                  queryDayGroups: queryDayGroups,
                  selectedDeleteCount: _selectedDeleteEventIds.length,
                  selectedDeleteEventIds: _selectedDeleteEventIds,
                  disabled: _isDeleting || _isSaving,
                  actionLabel: _candidateActionLabel(),
                  actionIcon: _candidateActionIcon(),
                  onAdd: _openAddConfirm,
                  onRetryVoice: () => context.go(AppRoutes.voice),
                  onOpenCalendar: () => context.go(AppRoutes.calendar),
                  onRetrySync: _syncAndReloadCandidates,
                  onOpenQueryResult: _openQueryResult,
                  onOpenEdit: _openEdit,
                  onApplyAndSave: _applyAndSave,
                  onDeleteSelected: _confirmSelectedDelete,
                  onToggleDeleteSelection: _toggleDeleteSelection,
                  onDelete: _confirmDelete,
                  buildChangePreviewText: _buildChangePreviewText,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceCandidateSection extends StatelessWidget {
  const _VoiceCandidateSection({
    required this.action,
    required this.isLoading,
    required this.events,
    required this.rawText,
    required this.querySummary,
    required this.queryRangeLabel,
    required this.queryDayGroups,
    required this.selectedDeleteCount,
    required this.selectedDeleteEventIds,
    required this.disabled,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAdd,
    required this.onRetryVoice,
    required this.onOpenCalendar,
    required this.onRetrySync,
    required this.onOpenQueryResult,
    required this.onOpenEdit,
    required this.onApplyAndSave,
    required this.onDeleteSelected,
    required this.onToggleDeleteSelection,
    required this.onDelete,
    required this.buildChangePreviewText,
    this.diagnostics,
    this.message,
  });

  final VoiceScheduleAction action;
  final bool isLoading;
  final List<EventModel> events;
  final _CandidateLoadDiagnostics? diagnostics;
  final String? message;
  final String rawText;
  final String querySummary;
  final String queryRangeLabel;
  final List<_QueryDayGroup> queryDayGroups;
  final int selectedDeleteCount;
  final Set<String> selectedDeleteEventIds;
  final bool disabled;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAdd;
  final VoidCallback onRetryVoice;
  final VoidCallback onOpenCalendar;
  final Future<void> Function() onRetrySync;
  final void Function(EventModel event) onOpenQueryResult;
  final void Function(EventModel event) onOpenEdit;
  final void Function(EventModel event) onApplyAndSave;
  final VoidCallback onDeleteSelected;
  final void Function(EventModel event, bool selected) onToggleDeleteSelection;
  final void Function(EventModel event) onDelete;
  final String? Function(EventModel event) buildChangePreviewText;

  bool get _isQuery => action == VoiceScheduleAction.query;
  bool get _isDelete => action == VoiceScheduleAction.delete;
  bool get _isEdit => action == VoiceScheduleAction.edit;

  String get _title => _isQuery ? '단순 조회 결과' : '대상 일정';

  String? get _candidateCountText {
    final count = events.length;
    final targetQuery = diagnostics?.targetQuery.trim() ?? '';
    if (diagnostics == null && count == 0) {
      return null;
    }
    if (count > 0 && targetQuery.isNotEmpty) {
      return '$count개 후보 · 검색어: $targetQuery';
    }
    return '$count개 후보';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    debugPrint(
      'VoiceActionScreen candidate section build: action=${action.name} '
      'loading=$isLoading events=${events.length} '
      'diagnostics=${diagnostics?.toLogLine() ?? '(none)'}',
    );

    return Column(
      key: const ValueKey('voice-target-events-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: PlanFlowColors.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (_candidateCountText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 18),
            child: Text(
              _candidateCountText!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          )
        else if (_isDelete && events.isNotEmpty)
          const SizedBox(height: 18),
        if (_isDelete && events.isNotEmpty) ...[
          KeyedSubtree(
            key: const ValueKey('voice-delete-candidate-list'),
            child: _DeleteCandidateInlineActions(
              events: events,
              disabled: disabled,
              selectedEventIds: selectedDeleteEventIds,
              selectedCount: selectedDeleteCount,
              onToggleSelection: onToggleDeleteSelection,
              onDeleteSelected: onDeleteSelected,
              onDelete: onDelete,
            ),
          ),
        ],
        if (!_isDelete || events.isEmpty) const SizedBox(height: 8),
        if (isLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          )
        else if (events.isEmpty)
          _EmptyCard(
            message: message ?? '대상 일정을 찾지 못했어요. 캘린더 동기화 상태를 확인하거나 다시 말해 주세요.',
            rawText: rawText,
            showRecoveryActions: true,
            diagnosticsText: diagnostics?.toDisplayText(),
            onAdd: onAdd,
            onRetryVoice: onRetryVoice,
            onOpenCalendar: onOpenCalendar,
            onRetrySync: onRetrySync,
          )
        else if (_isQuery) ...[
          _QueryOverviewCard(
            summary: querySummary,
            rangeLabel: queryRangeLabel,
          ),
          const SizedBox(height: 12),
          ...queryDayGroups.map(
            (dayGroup) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _QueryDayGroupCard(
                dayGroup: dayGroup,
                actionLabel: actionLabel,
                actionIcon: actionIcon,
                isDanger: _isDelete,
                disabled: disabled,
                onTapEvent: onOpenQueryResult,
              ),
            ),
          ),
        ] else if (_isDelete)
          const SizedBox.shrink()
        else
          ...events.map((event) {
            final changePreview =
                _isEdit ? buildChangePreviewText(event) : null;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _EventCandidateCard(
                event: event,
                actionLabel: actionLabel,
                actionIcon: actionIcon,
                isDanger: false,
                disabled: disabled,
                onTap: () =>
                    _isEdit ? onOpenEdit(event) : onOpenQueryResult(event),
                changePreviewText: changePreview,
                onDirectApply: (_isEdit && changePreview != null)
                    ? () => onApplyAndSave(event)
                    : null,
              ),
            );
          }),
      ],
    );
  }
}

class _RankedEvent {
  const _RankedEvent({
    required this.event,
    required this.score,
    required this.matchScore,
  });

  final EventModel event;
  final int score;
  final int matchScore;
}

class _DateRange {
  const _DateRange(this.start, this.end);

  final DateTime start;
  final DateTime end;
}

class _VoiceRequestedTime {
  const _VoiceRequestedTime(this.hour, this.minute);

  final int hour;
  final int minute;
}

class _CommandCard extends StatelessWidget {
  const _CommandCard({
    required this.title,
    required this.rawText,
    required this.description,
  });

  final String title;
  final String rawText;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '말한 내용',
              style: theme.textTheme.labelLarge?.copyWith(
                color: PlanFlowColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              rawText.trim().isEmpty ? '내용이 비어 있어요.' : rawText.trim(),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryDayGroup {
  const _QueryDayGroup({
    required this.label,
    required this.events,
    required this.buckets,
  });

  final String label;
  final List<EventModel> events;
  final List<MapEntry<String, List<EventModel>>> buckets;
}

class _QueryOverviewCard extends StatelessWidget {
  const _QueryOverviewCard({
    required this.summary,
    required this.rangeLabel,
  });

  final String summary;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: const Color(0xFFEAF4FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF92BEE8), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.record_voice_over_outlined,
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$rangeLabel 일정 요약',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    summary,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textPrimary,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryDayGroupCard extends StatelessWidget {
  const _QueryDayGroupCard({
    required this.dayGroup,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTapEvent,
  });

  final _QueryDayGroup dayGroup;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final ValueChanged<EventModel> onTapEvent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    dayGroup.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${dayGroup.events.length}개',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...dayGroup.buckets.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _QueryBucketSection(
                  label: entry.key,
                  events: entry.value,
                  actionLabel: actionLabel,
                  actionIcon: actionIcon,
                  isDanger: isDanger,
                  disabled: disabled,
                  onTapEvent: onTapEvent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueryBucketSection extends StatelessWidget {
  const _QueryBucketSection({
    required this.label,
    required this.events,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTapEvent,
  });

  final String label;
  final List<EventModel> events;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final ValueChanged<EventModel> onTapEvent;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.primaryMid,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ),
        ...events.map(
          (event) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _QueryEventCard(
              event: event,
              actionLabel: actionLabel,
              actionIcon: actionIcon,
              isDanger: isDanger,
              disabled: disabled,
              onTap: () => onTapEvent(event),
            ),
          ),
        ),
      ],
    );
  }
}

class _QueryEventCard extends StatelessWidget {
  const _QueryEventCard({
    required this.event,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTap,
  });

  final EventModel event;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final timeStr = _formatTimeChip(startAt);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    timeStr,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                      height: 1.05,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      startAt == null
                          ? '시간 미정'
                          : '${MaterialLocalizations.of(context).formatFullDate(startAt)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                    if ((event.location ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        event.location!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 104,
                child: FilledButton.tonalIcon(
                  onPressed: disabled ? null : onTap,
                  icon: Icon(actionIcon, size: 18),
                  label: Text(
                    actionLabel,
                    textAlign: TextAlign.center,
                  ),
                  style: FilledButton.styleFrom(
                    foregroundColor:
                        isDanger ? colorScheme.onErrorContainer : null,
                    backgroundColor:
                        isDanger ? colorScheme.errorContainer : null,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTimeChip(DateTime? value) {
    if (value == null) {
      return '미정';
    }
    final hour = value.hour;
    final period = hour < 12
        ? '오전'
        : hour < 18
            ? '오후'
            : '저녁';
    final displayHour = hour % 12 == 0 ? 12 : hour % 12;
    final minute =
        value.minute == 0 ? '' : '\n${value.minute.toString().padLeft(2, '0')}';
    return '$period\n$displayHour시$minute';
  }
}

class _AddConfirmCard extends StatelessWidget {
  const _AddConfirmCard({
    required this.rawText,
    required this.onContinue,
  });

  final String rawText;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '일정 추가 확인',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '음성 원문을 확인한 뒤 일정 확인 화면으로 넘겨드립니다.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onContinue,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('확인 화면으로 이동'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionChooserCard extends StatelessWidget {
  const _ActionChooserCard({
    required this.currentAction,
    required this.onSelected,
  });

  final VoiceScheduleAction currentAction;
  final ValueChanged<VoiceScheduleAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = <(VoiceScheduleAction, String, IconData)>[
      (VoiceScheduleAction.add, '추가', Icons.add_circle_outline),
      (VoiceScheduleAction.edit, '수정', Icons.edit_note),
      (VoiceScheduleAction.delete, '삭제', Icons.delete_outline),
      (VoiceScheduleAction.query, '조회', Icons.search),
    ];

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '무엇을 할까요?',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            ...options.map((option) {
              final selected = currentAction == option.$1;
              final button = selected
                  ? FilledButton.icon(
                      onPressed: () => onSelected(option.$1),
                      icon: Icon(option.$3),
                      label: Text(option.$2),
                    )
                  : OutlinedButton.icon(
                      onPressed: () => onSelected(option.$1),
                      icon: Icon(option.$3),
                      label: Text(option.$2),
                    );
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: button,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.message,
    this.rawText,
    this.showRecoveryActions = false,
    this.diagnosticsText,
    this.onAdd,
    this.onRetryVoice,
    this.onOpenCalendar,
    this.onRetrySync,
  });

  final String message;
  final String? rawText;
  final bool showRecoveryActions;
  final String? diagnosticsText;
  final VoidCallback? onAdd;
  final VoidCallback? onRetryVoice;
  final VoidCallback? onOpenCalendar;
  final Future<void> Function()? onRetrySync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showRecoveryActions) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: PlanFlowColors.primaryFaint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.cloud_off_outlined,
                      color: PlanFlowColors.primaryMid,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '저장된 일정이 앱 DB에서 보이지 않아요',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            if (diagnosticsText != null &&
                diagnosticsText!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '후보 조회 결과',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: PlanFlowColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                diagnosticsText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            if (showRecoveryActions) ...[
              const SizedBox(height: 12),
              if (rawText != null && rawText!.trim().isNotEmpty)
                Text(
                  '말한 내용: ${rawText!.trim()}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('새 일정으로 추가'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onRetryVoice,
                    icon: const Icon(Icons.mic_none),
                    label: const Text('다시 말하기'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpenCalendar,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: const Text('일정 탭 보기'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onRetrySync == null
                        ? null
                        : () {
                            unawaited(onRetrySync!());
                          },
                    icon: const Icon(Icons.sync_outlined),
                    label: const Text('동기화 후 다시 찾기'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CandidateLoadDiagnostics {
  const _CandidateLoadDiagnostics({
    required this.action,
    required this.userIdAvailable,
    required this.totalEventCount,
    required this.filteredCount,
    required this.displayedCount,
    required this.targetQuery,
  });

  final String action;
  final bool userIdAvailable;
  final int totalEventCount;
  final int filteredCount;
  final int displayedCount;
  final String targetQuery;

  String toDisplayText() {
    return [
      'action=$action',
      'userId=${userIdAvailable ? '있음' : '없음'}',
      'totalEventCount=$totalEventCount',
      'filteredCount=$filteredCount',
      'displayedCount=$displayedCount',
      'targetQuery=${targetQuery.isEmpty ? '(비어 있음)' : targetQuery}',
    ].join('\n');
  }

  String toLogLine() => toDisplayText().replaceAll('\n', ' ');
}

class _CandidateLoadSnapshot {
  const _CandidateLoadSnapshot({
    required this.diagnostics,
    required this.events,
  });

  final _CandidateLoadDiagnostics diagnostics;
  final List<EventModel> events;
}

class _DeleteCandidateInlineActions extends StatelessWidget {
  const _DeleteCandidateInlineActions({
    required this.events,
    required this.disabled,
    required this.selectedEventIds,
    required this.selectedCount,
    required this.onToggleSelection,
    required this.onDeleteSelected,
    required this.onDelete,
  });

  final List<EventModel> events;
  final bool disabled;
  final Set<String> selectedEventIds;
  final int selectedCount;
  final void Function(EventModel event, bool selected) onToggleSelection;
  final VoidCallback onDeleteSelected;
  final void Function(EventModel event) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final materialLocalizations = MaterialLocalizations.of(context);

    return Container(
      key: const ValueKey('voice-delete-inline-actions'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: PlanFlowColors.primaryFaint,
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '삭제할 일정을 선택해 주세요.',
            style: theme.textTheme.labelLarge?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '카드를 누르면 삭제 확인이 열리고, 여러 개는 왼쪽 체크로 선택할 수 있어요.',
            key: const ValueKey('voice-delete-inline-instruction'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          if (selectedCount > 0) ...[
            Text(
              '선택된 일정 $selectedCount개',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.error,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('voice-delete-selected-inline-button'),
              onPressed: disabled ? null : onDeleteSelected,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('선택 삭제'),
              style: FilledButton.styleFrom(
                foregroundColor: colorScheme.onErrorContainer,
                backgroundColor: colorScheme.errorContainer,
                minimumSize: const Size.fromHeight(44),
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ] else ...[
            Text(
              '선택된 일정 0개',
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.textSecondary.withValues(alpha: 0.82),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '여러 개를 지우려면 체크박스를 선택해 주세요.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.textSecondary.withValues(alpha: 0.82),
              ),
            ),
            const SizedBox(height: 10),
          ],
          for (var index = 0; index < events.length; index += 1)
            _DeleteCandidateCard(
              key:
                  ValueKey('voice-delete-candidate-$index-${events[index].id}'),
              event: events[index],
              index: index,
              disabled: disabled,
              isSelected: selectedEventIds.contains(events[index].id),
              materialLocalizations: materialLocalizations,
              onToggleSelection: (selected) =>
                  onToggleSelection(events[index], selected),
              onDelete: () => onDelete(events[index]),
            ),
        ],
      ),
    );
  }
}

class _DeleteCandidateCard extends StatelessWidget {
  const _DeleteCandidateCard({
    super.key,
    required this.event,
    required this.index,
    required this.disabled,
    required this.isSelected,
    required this.materialLocalizations,
    required this.onToggleSelection,
    required this.onDelete,
  });

  final EventModel event;
  final int index;
  final bool disabled;
  final bool isSelected;
  final MaterialLocalizations materialLocalizations;
  final ValueChanged<bool> onToggleSelection;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        key: ValueKey('voice-delete-inline-button-$index-${event.id}'),
        color: isSelected
            ? PlanFlowColors.primaryFaint.withValues(alpha: 0.82)
            : PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        elevation: isSelected ? 1 : 0,
        shadowColor: PlanFlowColors.primary.withValues(alpha: 0.12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: disabled ? null : onDelete,
          child: Container(
            constraints: const BoxConstraints(minHeight: 82),
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? PlanFlowColors.primaryMid
                    : PlanFlowColors.primaryFaint,
                width: isSelected ? 1.3 : 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: disabled
                          ? null
                          : (value) => onToggleSelection(value ?? false),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: PlanFlowColors.primary,
                              fontWeight: FontWeight.w800,
                              height: 1.22,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _candidateMetaText(event, materialLocalizations),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton(
                  key: ValueKey('voice-delete-button-$index-${event.id}'),
                  onPressed: disabled ? null : onDelete,
                  style: FilledButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    backgroundColor: colorScheme.errorContainer
                        .withValues(alpha: isSelected ? 0.72 : 0.52),
                    minimumSize: const Size.fromHeight(40),
                    textStyle: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  child: const Text('삭제'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _candidateMetaText(
    EventModel event,
    MaterialLocalizations materialLocalizations,
  ) {
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final timeText = startAt == null
        ? '시간 미정'
        : '${materialLocalizations.formatFullDate(startAt)} · ${materialLocalizations.formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}';
    final location = event.location?.trim();
    if (location == null || location.isEmpty) {
      return timeText;
    }
    return '$timeText · $location';
  }
}

class _EventCandidateCard extends StatelessWidget {
  const _EventCandidateCard({
    required this.event,
    required this.actionLabel,
    required this.actionIcon,
    required this.isDanger,
    required this.disabled,
    required this.onTap,
    this.changePreviewText,
    this.onDirectApply,
  });

  final EventModel event;
  final String actionLabel;
  final IconData actionIcon;
  final bool isDanger;
  final bool disabled;
  final VoidCallback onTap;

  /// 감지된 변경 내용 요약 (예: "1/22(수) 오전 9시"). null이면 표시 안 함.
  final String? changePreviewText;

  /// 변경사항을 바로 저장하는 콜백. null이면 바로저장 버튼 표시 안 함.
  final VoidCallback? onDirectApply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final startAt =
        event.startAt == null ? null : planflowLocal(event.startAt!);
    final hasDirectApply = onDirectApply != null;

    return Card(
      key: isDanger ? ValueKey('voice-delete-candidate-${event.id}') : null,
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: hasDirectApply
              ? PlanFlowColors.primary.withValues(alpha: 0.4)
              : PlanFlowColors.primaryFaint,
          width: hasDirectApply ? 1.0 : 0.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: PlanFlowColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          startAt == null
                              ? '시간 미정'
                              : '${MaterialLocalizations.of(context).formatFullDate(startAt)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(startAt))}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: changePreviewText != null
                                ? PlanFlowColors.textSecondary
                                    .withValues(alpha: 0.6)
                                : PlanFlowColors.textSecondary,
                            decoration: changePreviewText != null
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        if (changePreviewText != null) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              const Icon(
                                Icons.arrow_forward,
                                size: 13,
                                color: PlanFlowColors.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                changePreviewText!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: PlanFlowColors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if ((event.location ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            event.location!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!hasDirectApply) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 104,
                      child: FilledButton.tonalIcon(
                        key: isDanger
                            ? ValueKey('voice-delete-button-${event.id}')
                            : null,
                        onPressed: disabled ? null : onTap,
                        icon: Icon(actionIcon, size: 18),
                        label: Text(
                          actionLabel,
                          textAlign: TextAlign.center,
                        ),
                        style: FilledButton.styleFrom(
                          foregroundColor:
                              isDanger ? colorScheme.onErrorContainer : null,
                          backgroundColor:
                              isDanger ? colorScheme.errorContainer : null,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              // 변경사항이 감지된 경우: 바로저장 + 직접편집 버튼 행
              if (hasDirectApply) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: disabled ? null : onDirectApply,
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('바로 저장'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: disabled ? null : onTap,
                      child: const Text('직접 편집'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
