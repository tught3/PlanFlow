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
import '../../features/groups/models/group_event_model.dart';
import '../../features/groups/repositories/group_event_repository.dart';
import '../../features/groups/repositories/group_repository.dart';
import '../../features/groups/services/group_event_share_service.dart';
import '../../services/app_feedback_service.dart';
import '../../services/app_permission_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/background_task_service.dart';
import '../../services/calendar_auto_sync_service.dart';
import '../../services/event_preparation_service.dart';
import '../../services/gpt_service.dart';
import '../../services/home_widget_service.dart';
import '../../services/location_lookup_service.dart';
import '../../services/manual_event_side_effect_service.dart';
import '../../services/departure_alarm_service.dart';
import '../../services/smart_preparation_alarm_service.dart';
import '../../services/recurrence_edit_scope.dart';
import '../../services/voice_command_router.dart';
import '../../services/voice_date_range_parser.dart';
import '../../services/voice_text_cleanup_service.dart';
import '../../widgets/planflow_action_buttons.dart';
import '../calendar/calendar_screen.dart'
    show
        calendarCriticalEventTextColor,
        calendarGroupEventColor,
        calendarMultiDayEventTextColor,
        calendarRecurringEventColor;
part 'voice_action_widgets.dart';

enum VoiceScheduleAction { add, edit, delete, query, choose }

class VoiceActionScreen extends StatefulWidget {
  VoiceActionScreen({
    super.key,
    required this.rawText,
    required this.action,
    this.eventRepository,
    this.groupRepository,
    this.groupEventRepository,
    this.gptService,
    ManualEventSideEffectService? sideEffectService,
    HomeWidgetService? homeWidgetService,
    LocationLookupService? locationLookupService,
    AppPermissionService? permissionService,
    this.forceSyncCalendars,
    this.userIdOverride,
  })  : sideEffectService =
            sideEffectService ?? const ManualEventSideEffectService(),
        homeWidgetService = homeWidgetService ?? HomeWidgetService(),
        locationLookupService =
            locationLookupService ?? LocationLookupService(),
        permissionService = permissionService ?? AppPermissionService();

  final String rawText;
  final VoiceScheduleAction action;
  final EventRepository? eventRepository;
  final GroupRepository? groupRepository;
  final GroupEventRepository? groupEventRepository;
  final GptService? gptService;
  final ManualEventSideEffectService sideEffectService;
  final HomeWidgetService homeWidgetService;
  final LocationLookupService locationLookupService;
  final AppPermissionService permissionService;
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
  // 그룹 일정을 개인 EventModel로 변환해 후보 목록에 병합할 때, id로 원본
  // GroupEventModel을 역참조하기 위한 레지스트리. 저장/삭제/전환 라우팅 분기에서
  // "이 id가 그룹 일정인가"를 판정하는 데 쓴다.
  Map<String, GroupEventModel> _groupEventById = <String, GroupEventModel>{};
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
  GroupRepository get _groupRepository =>
      widget.groupRepository ?? GroupRepository.supabase();
  GroupEventRepository get _groupEventRepository =>
      widget.groupEventRepository ?? GroupEventRepository.supabase();

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
  bool get _isLocationFieldAddition =>
      _isEdit && _requestedChanges.contains('location');
  // 그룹 일정을 개인 일정으로 전환하는 발화인지. 같은 발화에 날짜/장소 등 다른
  // 필드 변경 신호가 함께 잡혀도(예: "이 팀 일정 개인 일정으로 바꿔줘 이번 주
  // 금요일"), 전환 의도가 다른 필드 추론보다 항상 우선한다.
  bool get _isConvertToPersonalRequested =>
      _requestedChanges.contains('convert_to_personal');

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
    if (_isEdit && _isLocationFieldAddition) {
      return '장소 입력';
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
        _groupEventById = <String, GroupEventModel>{};
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

      final personalEvents = await _repository.listEvents(userId: userId);
      final groupCandidates = await _loadGroupEventCandidates();
      final events = <EventModel>[
        ...personalEvents,
        ...groupCandidates.events,
      ];
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
      final requiresDateMatchForTarget =
          _requiresDateMatchForTarget(routeResult);
      final rankedCandidates = _candidateEventsForDisplay(
        rankedItems,
        filteredEvents,
        queryText: routeResult.targetQuery,
        candidateDateRange: candidateDateRange,
        hasTargetMatchTokens: _hasTargetMatchTokens(routeResult.targetQuery),
        requiresDateMatchForTarget: requiresDateMatchForTarget,
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
        _groupEventById = groupCandidates.byId;
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

  /// 사용자가 속한 모든 그룹의 그룹 일정을 조회해 개인 EventModel 형태로
  /// 변환한다. 그룹 기능을 쓰지 않는 사용자이거나 조회가 실패해도(권한 없음,
  /// 네트워크 오류 등) 개인 일정 음성 흐름 자체는 깨지지 않도록 여기서
  /// 예외를 흡수하고 빈 결과를 반환한다.
  Future<
      ({
        List<EventModel> events,
        Map<String, GroupEventModel> byId,
      })> _loadGroupEventCandidates() async {
    try {
      final groups = await _groupRepository.listGroups();
      if (groups.isEmpty) {
        return (
          events: const <EventModel>[],
          byId: const <String, GroupEventModel>{},
        );
      }
      final from = DateTime.utc(2000);
      final to = DateTime.utc(2100);
      final converted = <EventModel>[];
      final byId = <String, GroupEventModel>{};
      for (final group in groups) {
        final groupEvents = await _groupEventRepository.getEventsForGroup(
          group.id,
          from,
          to,
        );
        for (final groupEvent in groupEvents) {
          if (!groupEvent.isActive) {
            continue;
          }
          final eventModel = _eventModelFromGroupEvent(groupEvent);
          converted.add(eventModel);
          byId[eventModel.id] = groupEvent;
        }
      }
      return (events: converted, byId: byId);
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen group events load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return (
        events: const <EventModel>[],
        byId: const <String, GroupEventModel>{},
      );
    }
  }

  /// 그룹 일정(GroupEventModel)을 이 화면의 후보 목록/랭킹 로직이 다루는 개인
  /// EventModel 형태로 변환한다. 원본과 동일한 id를 유지해야 [_groupEventById]
  /// 레지스트리로 역참조할 수 있다. GroupEventModel엔 좌표(location_lat/lng)·
  /// 참석자 등 개인 일정 전용 필드가 없으므로 해당 필드는 비워둔다.
  EventModel _eventModelFromGroupEvent(GroupEventModel groupEvent) {
    return EventModel(
      id: groupEvent.id,
      userId: groupEvent.createdBy,
      title: groupEvent.title,
      startAt: groupEvent.startAt,
      endAt: groupEvent.endAt,
      location: groupEvent.location,
      memo: groupEvent.description,
      isAllDay: groupEvent.allDay,
      recurrenceRule: _recurrenceRuleFromGroupRecurrenceType(
        groupEvent.recurrenceType,
      ),
      category: '기타',
      source: 'group',
      createdAt: groupEvent.createdAt,
      updatedAt: groupEvent.updatedAt,
    );
  }

  /// 그룹 일정의 recurrenceType(none/daily/weekly/monthly)을 개인 EventModel이
  /// 쓰는 RRULE 근사치로 변환한다. 요일(BYDAY) 지정은 그룹 스키마가 지원하지
  /// 않으므로 FREQ 단위까지만 표현한다.
  String? _recurrenceRuleFromGroupRecurrenceType(String recurrenceType) {
    switch (recurrenceType) {
      case 'daily':
        return 'FREQ=DAILY';
      case 'weekly':
        return 'FREQ=WEEKLY';
      case 'monthly':
        return 'FREQ=MONTHLY';
      default:
        return null;
    }
  }

  List<_RankedEvent> _candidateEventsForDisplay(
    List<_RankedEvent> rankedItems,
    List<EventModel> filteredEvents, {
    required String queryText,
    _DateRange? candidateDateRange,
    required bool hasTargetMatchTokens,
    required bool requiresDateMatchForTarget,
  }) {
    if (_isQuery) {
      final queryCandidates = _filterQueryCandidates(
        rankedItems,
        queryText,
      );
      if (queryCandidates.isNotEmpty) {
        return queryCandidates;
      }
      if (_hasQueryDateCue(queryText) || candidateDateRange != null) {
        return rankedItems;
      }
      return const <_RankedEvent>[];
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
        if (hasTargetMatchTokens && requiresDateMatchForTarget) {
          return const <_RankedEvent>[];
        }
      }
      return scoredItems.take(5).toList(growable: false);
    }

    if (candidateDateRange != null) {
      if (hasTargetMatchTokens && requiresDateMatchForTarget) {
        return const <_RankedEvent>[];
      }
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

  List<_RankedEvent> _filterQueryCandidates(
    List<_RankedEvent> rankedItems,
    String queryText,
  ) {
    final normalizedQuery =
        _voiceCommandRouter.normalizeManagementText(queryText).trim();
    final focusTokens = _queryFocusTokens(normalizedQuery);
    if (focusTokens.isEmpty) {
      return rankedItems;
    }

    final exactMatches = rankedItems
        .where(
          (item) => _isExactQueryCandidate(
            item,
            normalizedQuery,
            focusTokens,
          ),
        )
        .toList(growable: false);
    if (exactMatches.isNotEmpty) {
      return exactMatches;
    }

    final threshold =
        focusTokens.length <= 1 ? 1 : (focusTokens.length * 0.6).ceil();
    final fuzzyMatches = rankedItems
        .where(
          (item) => _isMeaningfulQueryCandidate(
            item,
            focusTokens,
            threshold: threshold,
          ),
        )
        .toList(growable: false);
    if (fuzzyMatches.isEmpty) {
      return const <_RankedEvent>[];
    }
    return fuzzyMatches.take(5).toList(growable: false);
  }

  bool _isExactQueryCandidate(
    _RankedEvent item,
    String normalizedQuery,
    List<String> focusTokens,
  ) {
    final searchable = _normalizedSearchableText(item.event);
    final searchableTokens = _voiceCommandRouter.searchTokens(searchable);
    if (searchable.contains(normalizedQuery)) {
      return true;
    }
    return focusTokens.every(searchableTokens.contains);
  }

  bool _isMeaningfulQueryCandidate(
    _RankedEvent item,
    List<String> focusTokens, {
    required int threshold,
  }) {
    if (focusTokens.isEmpty) {
      return false;
    }
    final searchableTokens = _voiceCommandRouter.searchTokens(
      _normalizedSearchableText(item.event),
    );
    final matchedTokens = focusTokens
        .where(
          (token) =>
              searchableTokens.contains(token) ||
              (!_containsDigit(token) &&
                  (_voiceCommandRouter.hasFuzzyTokenMatch(
                        token,
                        searchableTokens,
                      ) ||
                      _voiceCommandRouter.hasPrefixMatch(
                        token,
                        searchableTokens,
                      ))),
        )
        .length;
    if (matchedTokens < threshold) {
      return false;
    }
    final ratio = matchedTokens / focusTokens.length;
    return ratio >= 0.6;
  }

  List<String> _queryFocusTokens(String normalizedQuery) {
    final tokens = _voiceCommandRouter
        .searchTokens(normalizedQuery)
        .where(_isMeaningfulQueryToken)
        .map((token) {
      if (token.length >= 3 && token.endsWith('라')) {
        return token.substring(0, token.length - 1);
      }
      return token;
    }).toList(growable: false);
    final seen = <String>{};
    return tokens.where(seen.add).toList(growable: false);
  }

  bool _isMeaningfulQueryToken(String token) {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      return false;
    }
    if (!_isTargetMatchToken(normalized)) {
      return false;
    }
    return !RegExp(
      r'^(?:일정|스케줄|약속|조회|검색|찾아|찾아봐|찾아줘|보여|보여줘|알려|알려줘|확인|확인해|확인해줘|오늘|내일|모레|글피|이번|다음|이번주|다음주|이번\s*주|다음\s*주|있어|있나|있나요|있어요|몇\s*시|몇시|언제|어디|무엇|뭐|무슨)$',
    ).hasMatch(normalized);
  }

  bool _hasQueryDateCue(String queryText) {
    final normalized = _voiceCommandRouter.normalizeManagementText(queryText);
    return RegExp(
      r'(오늘|내일|모레|글피|이번\s*주|다음\s*주|이번주|다음주|이번\s*달|다음\s*달|이번달|다음달|'
      r'[월화수목금토일]요일|\d+\s*월|\d+\s*일|\d+\s*시|오전|오후|아침|점심|저녁|밤|새벽)',
    ).hasMatch(normalized);
  }

  String _normalizedSearchableText(EventModel event) {
    return _voiceCommandRouter.normalizeManagementText([
      event.title,
      event.location ?? '',
      event.memo ?? '',
      event.supplies.join(' '),
    ].join(' '));
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

    final absoluteTargetRange = _absoluteDateRangeInText(
      routeResult.targetQuery,
    );
    if (absoluteTargetRange != null) {
      return absoluteTargetRange;
    }

    final absoluteCleanedRange = _absoluteDateRangeInText(
      routeResult.targetText,
    );
    if (absoluteCleanedRange != null) {
      return absoluteCleanedRange;
    }

    final targetRange = _queryDateRange(routeResult.targetQuery);
    if (targetRange != null) {
      return targetRange;
    }

    final normalized = routeResult.targetText.replaceAll(RegExp(r'\s+'), ' ');
    final firstDateRange = _firstDateRangeInText(normalized);
    if (firstDateRange != null) {
      return firstDateRange;
    }

    return _queryDateRange(normalized);
  }

  bool _requiresDateMatchForTarget(VoiceCommandRouteResult routeResult) {
    return _absoluteDateRangeInText(routeResult.targetQuery) != null ||
        _absoluteDateRangeInText(routeResult.targetText) != null;
  }

  _DateRange? _absoluteDateRangeInText(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ');
    final match = RegExp(
      r'(?:(\d{4})\s*년\s*)?(\d{1,2})\s*월\s*(\d{1,2})\s*일',
    ).firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final now = planflowLocal(planflowNow());
    final year = int.tryParse(match.group(1) ?? '') ?? now.year;
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (month == null || day == null) {
      return null;
    }
    final start = DateTime(year, month, day);
    if (start.year != year || start.month != month || start.day != day) {
      return null;
    }
    return _DateRange(start, start.add(const Duration(days: 1)));
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
    final parsed = VoiceDateRangeParser.parse(rawText);
    if (parsed == null) {
      return null;
    }
    return _DateRange(parsed.start, parsed.end);
  }

  String _queryRangeLabel(String rawText) {
    return VoiceDateRangeParser.parse(rawText)?.label ?? '다가오는';
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
    final tokens = _voiceCommandRouter
        .searchTokens(rawText)
        .where(_isTargetMatchToken)
        .toList(growable: false);
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
        if (!_containsDigit(token) &&
            _voiceCommandRouter.hasFuzzyTokenMatch(token, searchableTokens)) {
          matchScore += 2;
          continue;
        }
        if (!_containsDigit(token) &&
            _voiceCommandRouter.hasPrefixMatch(token, searchableTokens)) {
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

  bool _isTargetMatchToken(String token) {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      return false;
    }
    if (RegExp(r'^\d{1,2}(?:월|일|시|분)$').hasMatch(normalized)) {
      return false;
    }
    if (RegExp(r'^\d{4}년$').hasMatch(normalized)) {
      return false;
    }
    if (RegExp(r'^\d{1,2}:\d{2}$').hasMatch(normalized)) {
      return false;
    }
    return true;
  }

  bool _hasTargetMatchTokens(String rawText) {
    return _voiceCommandRouter.searchTokens(rawText).any(_isTargetMatchToken);
  }

  bool _containsDigit(String value) => RegExp(r'\d').hasMatch(value);

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
    final groupEvent = _groupEventById[event.id];
    if (groupEvent != null) {
      if (_isConvertToPersonalRequested) {
        await _convertGroupEventToPersonal(groupEvent);
      } else {
        await _applyGroupEventVoiceUpdate(event, groupEvent);
      }
      return;
    }
    var editedEvent = _eventWithRequestedVoiceChanges(event);
    if (_isLocationFieldAddition) {
      editedEvent = (await _eventWithResolvedVoiceLocation(editedEvent)).event;
    }

    RecurrenceEditScope? recurrenceScope;
    if ((event.recurrenceRule ?? '').trim().isNotEmpty) {
      if (!mounted) return;
      recurrenceScope = await chooseRecurrenceEditScope(context);
      if (recurrenceScope == null) {
        // 사용자가 범위 선택을 취소함: 저장하지 않는다.
        return;
      }
    }

    final previousStartAt = event.startAt;
    setState(() => _isSaving = true);
    try {
      final savedEvent = await _saveWithRecurrenceScope(
        event: event,
        editedEvent: editedEvent,
        scope: recurrenceScope,
      );
      final userId = _resolveUserId();
      unawaited(
        _runDirectSaveFollowUps(
          userId: userId,
          savedEvent: savedEvent,
          previousStartAt: previousStartAt,
        ),
      );
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_direct_apply',
        eventId: savedEvent.id,
        startAt: savedEvent.startAt,
      );
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장했어요. 알림과 위젯은 백그라운드에서 정리 중입니다.')),
      );
      context.go(AppRoutes.calendar);
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

  /// [scope]가 null(비반복 일정)이면 그냥 덮어써 저장한다. 반복 일정이면
  /// 선택한 범위에 맞춰 원본 계열을 자르고 새 계열을 분리하거나(single/future),
  /// 계열 전체를 그대로 수정한다(all). [event_edit_screen.dart]의
  /// `_saveEvent` 반복 범위 분기와 동일한 규칙을 따른다.
  Future<EventModel> _saveWithRecurrenceScope({
    required EventModel event,
    required EventModel editedEvent,
    required RecurrenceEditScope? scope,
  }) async {
    if (scope == RecurrenceEditScope.single) {
      return _repository.createEvent(
        detachedRecurringVoiceEvent(
          editedEvent,
          parentEventId: event.id,
          keepRecurrence: false,
        ),
      );
    }
    if (scope == RecurrenceEditScope.future) {
      final originalStart = event.startAt;
      final targetDate = editedEvent.startAt ?? originalStart;
      final isAnchorOccurrence = originalStart == null ||
          (targetDate != null &&
              planflowIsSameLocalDay(originalStart, targetDate));
      if (isAnchorOccurrence) {
        return _repository.updateEvent(editedEvent);
      }
      final truncatedRule = truncateRRuleBefore(
        event.recurrenceRule,
        targetDate!,
      );
      await _repository.updateEvent(
        event.copyWith(
          recurrenceRule: truncatedRule,
          clearRecurrenceRule: truncatedRule == null,
        ),
      );
      return _repository.createEvent(
        detachedRecurringVoiceEvent(
          editedEvent,
          parentEventId: event.id,
          keepRecurrence: true,
        ),
      );
    }
    return _repository.updateEvent(editedEvent);
  }

  /// 그룹 일정 대상 음성 수정. 개인 [_repository.updateEvent] 대신
  /// [GroupEventRepository.updateGroupEvent]로 저장한다. 그룹 일정 편집
  /// 화면이 따로 없고 개인 전용 event_edit_screen을 재사용할 수 없으므로,
  /// 편집 화면 이동 없이 이 함수에서 바로 저장까지 마친다.
  /// 지원 범위: 제목·장소·시간을 반영한다.
  Future<void> _applyGroupEventVoiceUpdate(
    EventModel event,
    GroupEventModel groupEvent,
  ) async {
    var updated = groupEvent;
    var changed = false;

    final requestedLocation = _inferRequestedLocation();
    if (requestedLocation != null && requestedLocation.trim().isNotEmpty) {
      updated = updated.copyWith(location: requestedLocation.trim());
      changed = true;
    }

    final newTitle = _extractGroupTitleChange(_normalizedRawText);
    if (newTitle != null && newTitle.isNotEmpty && newTitle != updated.title) {
      updated = updated.copyWith(title: newTitle);
      changed = true;
    }

    final requestedStartLocal = _inferRequestedStartLocal(event);
    if (requestedStartLocal != null) {
      final newStart = planflowLocalDateTimeToUtc(requestedStartLocal);
      final originalDuration = updated.endAt.difference(updated.startAt);
      final newEnd = newStart.add(
        originalDuration.isNegative || originalDuration == Duration.zero
            ? const Duration(hours: 1)
            : originalDuration,
      );
      updated = updated.copyWith(startAt: newStart, endAt: newEnd);
      changed = true;
    }

    if (!changed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('그룹 일정에는 아직 지원하지 않는 변경이에요. 제목·장소·시간만 바꿀 수 있어요.'),
          ),
        );
      }
      return;
    }

    setState(() => _isSaving = true);
    try {
      final saved = await _groupEventRepository.updateGroupEvent(updated);
      _groupEventById[saved.id] = saved;
      final savedAsEvent = _eventModelFromGroupEvent(saved);
      final index = _events.indexWhere((candidate) => candidate.id == saved.id);
      if (index != -1) {
        _events[index] = savedAsEvent;
      }
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_group_direct_apply',
        eventId: saved.id,
        startAt: saved.startAt,
      );
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('팀 일정을 저장했어요.')),
      );
      context.go(AppRoutes.calendar);
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen group direct save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹 일정을 저장하지 못했어요. 다시 시도해 주세요.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 그룹 일정을 개인 일정으로 옮긴다(취소-우선 + 보상 롤백). 먼저 그룹
  /// 일정을 취소(cancelGroupEvent)하고, 그 다음 개인 일정을 생성한다.
  /// 개인 일정 생성이 실패하면 방금 취소한 그룹 일정을 다시 active로
  /// 되돌려(보상 롤백) 데이터가 양쪽 모두에서 사라지지 않게 한다.
  Future<void> _convertGroupEventToPersonal(GroupEventModel g) async {
    setState(() => _isSaving = true);
    GroupEventModel cancelled;
    try {
      cancelled = await _groupEventRepository.cancelGroupEvent(g.id);
    } catch (error, stackTrace) {
      debugPrint(
        'VoiceActionScreen group cancel for convert failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('이 팀 일정은 만든 사람이나 팀 리더만 개인 일정으로 옮길 수 있어요.'),
          ),
        );
      }
      return;
    }

    try {
      final userId = _resolveUserId() ?? '';
      final draft = _personalEventFromGroupEvent(g, userId);
      await _repository.createEvent(draft);
    } catch (error, stackTrace) {
      debugPrint(
        'VoiceActionScreen personal create for convert failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      try {
        await _groupEventRepository.updateGroupEvent(
          cancelled.copyWith(
            status: 'active',
            clearCancelledAt: true,
            clearCancelledBy: true,
          ),
        );
      } catch (_) {
        // 복구 실패는 조용히 무시(그룹 일정은 취소 상태로 남되, 개인 일정도
        // 안 생겼으므로 데이터 유실은 아님 — 사용자가 그룹 화면에서 직접
        // 복구해야 함).
      }
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('개인 일정으로 옮기지 못했어요. 팀 일정은 그대로 두었어요.')),
        );
      }
      return;
    }

    _groupEventById.remove(g.id);
    setState(() {
      _events.removeWhere((event) => event.id == g.id);
      _selectedDeleteEventIds.remove(g.id);
      _isSaving = false;
    });
    EventRefreshBus.instance.notifyChanged(
      reason: 'voice_group_to_personal',
      eventId: g.id,
      startAt: g.startAt,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_convertSuccessMessage(g))),
    );
    context.go(AppRoutes.calendar);
  }

  /// 그룹 일정을 개인 일정으로 옮길 때 만들 개인 EventModel 초안.
  /// id는 빈 문자열로 두어 [EventRepository.createEvent]가 신규 생성으로
  /// 처리하게 한다.
  EventModel _personalEventFromGroupEvent(GroupEventModel g, String userId) {
    return EventModel(
      id: '',
      userId: userId,
      title: g.title,
      startAt: g.startAt,
      endAt: g.endAt,
      location: g.location,
      memo: g.description,
      isAllDay: g.allDay,
      recurrenceRule: recurrenceRuleFromGroupRecurrence(
        g.recurrenceType,
        g.startAt,
        g.recurrenceUntil,
      ),
      category: '기타',
      source: 'manual',
      createdAt: DateTime.now().toUtc(),
    );
  }

  String _convertSuccessMessage(GroupEventModel g) {
    const base = '팀 일정을 개인 일정으로 옮겼어요.';
    if (g.recurrenceType == 'weekly') {
      return '$base 매주 반복은 시작 요일 기준으로 옮겼어요. 여러 요일이었다면 다시 확인해 주세요.';
    }
    return base;
  }

  Future<void> _runDirectSaveFollowUps({
    required String? userId,
    required EventModel savedEvent,
    DateTime? previousStartAt,
  }) {
    return BackgroundTaskService.run(
      () async {
        var departureSafetyMargin = Duration(
          minutes: DepartureAlarmService.safetyMargin.inMinutes,
        );
        UserSettingsModel? settings;
        if (userId != null && AppEnv.isSupabaseReady) {
          settings = await _fetchSettingsOrNull(userId);
          departureSafetyMargin = Duration(
            minutes: settings?.departureSafetyMarginMin ??
                DepartureAlarmService.safetyMargin.inMinutes,
          );
          await _runFollowUpStep(
            'sync_after_save',
            () async {
              await widget.sideEffectService.syncAfterSave(
                event: savedEvent,
                userId: userId,
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
            },
          );
          await _runFollowUpStep(
            'resync_external_preparation',
            () => _resyncExternalPreparationForDay(
              userId: userId,
              event: savedEvent,
              settings: settings,
            ),
          );
          if (previousStartAt != null &&
              savedEvent.startAt != null &&
              !planflowIsSameLocalDay(previousStartAt, savedEvent.startAt!)) {
            await _runFollowUpStep(
              'resync_previous_day_external_preparation',
              () => _resyncExternalPreparationForDay(
                userId: userId,
                event: savedEvent,
                settings: settings,
                dayReference: previousStartAt,
              ),
            );
          }
          await _runFollowUpStep('refresh_home_widget', () {
            return _refreshHomeWidget(userId);
          });
        }
        unawaited(
          BackgroundTaskService.run(
            () => CalendarAutoSyncService().syncAfterEventSave(savedEvent),
            owner: 'VoiceActionScreen',
            label: 'calendar_auto_sync_after_direct_save',
            failureMessage:
                '저장은 완료됐지만 캘린더 동기화 중 문제가 생겼어요. 문제 신고에 이 문구를 함께 보내 주세요.',
          ),
        );
        unawaited(
          BackgroundTaskService.run(
            () => EventPreparationService(
              eventRepository: _repository,
            ).prepareAfterSave(
              savedEvent,
              departureSafetyMargin: departureSafetyMargin,
            ),
            owner: 'VoiceActionScreen',
            label: 'event_preparation_after_direct_save',
            failureMessage:
                '저장은 완료됐지만 준비사항 계산 중 문제가 생겼어요. 문제 신고에 이 문구를 함께 보내 주세요.',
          ),
        );
        await _runFollowUpStep(
          'voice_log_direct_save',
          () => _recordVoiceLog(
            action: 'edit',
            targetEventId: savedEvent.id,
            result: 'applied_directly',
          ),
        );
      },
      owner: 'VoiceActionScreen',
      label: 'direct_save_follow_ups',
      failureMessage: '저장은 완료됐지만 알림/위젯 정리 중 문제가 생겼어요. 문제 신고에 이 문구를 함께 보내 주세요.',
    );
  }

  Future<void> _runFollowUpStep(
    String label,
    Future<void> Function() task,
  ) async {
    try {
      await task();
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen follow-up failed ($label): $error');
      debugPrintStack(stackTrace: stackTrace);
      AppFeedbackService.showSnackBar(_followUpFailureMessage(label));
    }
  }

  String _followUpFailureMessage(String label) {
    final taskName = switch (label) {
      'sync_after_save' => '알림/스마트준비알람 정리',
      'resync_external_preparation' => '스마트준비알람 다시 계산',
      'resync_previous_day_external_preparation' => '이전 날짜 준비알람 정리',
      'refresh_home_widget' || 'refresh_home_widget_after_delete' => '홈 위젯 갱신',
      'voice_log_direct_save' || 'voice_log_delete' => '음성 처리 기록 저장',
      'cleanup_after_delete' => '삭제된 일정의 알림 정리',
      'resync_external_preparation_after_delete' => '삭제 후 준비알람 다시 계산',
      _ => '후속 작업',
    };
    return '일정 저장/삭제는 완료됐지만 $taskName 중 문제가 생겼어요. 문제 신고에 이 문구를 함께 보내 주세요.';
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

    if (edited.isCritical != original.isCritical) {
      parts.add(edited.isCritical ? '중요 일정' : '중요 표시 해제');
    }

    if (edited.isMultiDay &&
        !original.isMultiDay &&
        edited.endAt != null) {
      final newEnd = planflowLocal(edited.endAt!);
      const weekdays = ['', '월', '화', '수', '목', '금', '토', '일'];
      parts.add(
        '연속 일정(~${newEnd.month}/${newEnd.day}(${weekdays[newEnd.weekday]}))',
      );
    }

    return parts.isEmpty ? null : parts.join(', ');
  }

  Future<void> _openEdit(EventModel event) async {
    if (_groupEventById[event.id] != null) {
      // 그룹 일정 전용 편집 화면이 없어 개인 일정 편집 화면(event_edit_screen)을
      // 재사용할 수 없다. 카드 버튼이 이미 비활성화돼 있어야 하지만, 방어적으로
      // 여기서도 다시 한 번 막는다.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('팀 일정은 "바로 저장"으로만 바꿀 수 있어요.')),
        );
      }
      return;
    }
    final requestedLocation = _inferRequestedLocation();
    if (_isLocationFieldAddition &&
        requestedLocation != null &&
        _hasExistingLocation(event) &&
        !_isSameLocationText(event.location, requestedLocation)) {
      final shouldReplace = await _confirmReplaceExistingLocation(
        currentLocation: event.location?.trim().isNotEmpty == true
            ? event.location!.trim()
            : '지도 위치',
        nextLocation: requestedLocation,
      );
      if (shouldReplace != true) {
        return;
      }
    }
    final editedEvent = _eventWithRequestedVoiceChanges(event);
    final locationResolution =
        await _eventWithResolvedVoiceLocation(editedEvent);
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
    final locationSnackBarMessage =
        _isLocationFieldAddition && appliedVoiceChange
            ? locationResolution.message
            : null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          appliedVoiceChange
              ? _isLocationFieldAddition
                  ? '장소를 입력해 두었어요. 확인 후 저장해 주세요.'
                  : '말한 변경값을 반영해 열었어요. 확인 후 저장해 주세요.'
              : '수정할 일정을 열었어요. 확인 후 저장해 주세요.',
        ),
      ),
    );
    if (locationSnackBarMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(locationSnackBarMessage)),
      );
    }
    await context.push(
      '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}',
      extra: locationResolution.event,
    );
  }

  bool _hasExistingLocation(EventModel event) {
    return (event.location?.trim().isNotEmpty ?? false) ||
        (event.locationLat != null && event.locationLng != null);
  }

  bool _isSameLocationText(String? left, String right) {
    final normalizedLeft =
        (left ?? '').replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final normalizedRight = right.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return normalizedLeft.isNotEmpty && normalizedLeft == normalizedRight;
  }

  Future<bool?> _confirmReplaceExistingLocation({
    required String currentLocation,
    required String nextLocation,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('장소를 바꿀까요?'),
          content: Text(
            '현재 장소가 "$currentLocation"로 등록되어 있어요.\n'
            '"$nextLocation"로 교체할까요?',
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          actions: [
            PlanFlowActionButtons(
              buttons: [
                PlanFlowActionButton(
                  label: '그대로 둘게요',
                  onPressed: () => Navigator.of(context).pop(false),
                  type: ActionButtonType.secondary,
                  flex: 1,
                ),
                PlanFlowActionButton(
                  label: '교체하기',
                  onPressed: () => Navigator.of(context).pop(true),
                  type: ActionButtonType.primary,
                  flex: 1,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<_VoiceLocationResolution> _eventWithResolvedVoiceLocation(
    EventModel event,
  ) async {
    if (!_isLocationFieldAddition ||
        event.location == null ||
        event.location!.trim().isEmpty ||
        (event.locationLat != null && event.locationLng != null)) {
      return _VoiceLocationResolution(
        event: event,
        message: '장소를 입력해 두었어요. 확인 후 저장해 주세요.',
      );
    }

    try {
      final origin =
          await widget.permissionService.getCurrentLocationWithPermission(
        requestIfMissing: false,
      );
      final results = await widget.locationLookupService.search(
        event.location!.trim(),
        origin: origin,
      );
      if (results.isEmpty) {
        return _VoiceLocationResolution(
          event: event,
          message: '장소명을 입력해 두었어요. 지도에서 정확한 위치를 확인한 뒤 저장해 주세요.',
        );
      }
      return _VoiceLocationResolution(
        event: _eventWithResolvedLocation(event, results.first),
        message: '장소 위치를 지도에서 찾았어요. 확인 후 저장해 주세요.',
      );
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen location lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return _VoiceLocationResolution(
        event: event,
        message: '장소명을 입력해 두었어요. 지도에서 정확한 위치를 확인한 뒤 저장해 주세요.',
      );
    }
  }

  EventModel _eventWithResolvedLocation(
    EventModel event,
    LocationLookupResult result,
  ) {
    final resolvedName = result.name.trim().isNotEmpty
        ? result.name.trim()
        : event.location?.trim();
    return EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: resolvedName ?? event.location,
      locationLat: result.latitude,
      locationLng: result.longitude,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      participants: event.participants,
      targets: event.targets,
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

  EventModel _eventWithRequestedVoiceChanges(EventModel event) {
    // 그룹 일정을 개인 일정으로 전환하는 발화라면, 같은 발화에 날짜 등 다른
    // 필드 변경 신호가 함께 잡혔더라도(예: "이 팀 일정 개인 일정으로 바꿔줘
    // 이번 주 금요일") 전환 의도가 항상 우선한다. 다른 필드 추론을 건너뛰지
    // 않으면 날짜 변경 카드로 잘못 라우팅되어 전환 의도가 무시된다.
    if (_isConvertToPersonalRequested && _groupEventById[event.id] != null) {
      return event;
    }
    final requestedStartLocal = _inferRequestedStartLocal(event);
    final requestedLocation = _inferRequestedLocation();
    final requestedCritical = _inferRequestedCriticalFlag();
    final requestedMultiDayEndLocal = _inferRequestedMultiDayEndLocal(event);
    if (requestedStartLocal == null &&
        requestedLocation == null &&
        requestedCritical == null &&
        requestedMultiDayEndLocal == null) {
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

    DateTime? nextEndUtc;
    var nextIsMultiDay = event.isMultiDay;
    if (requestedMultiDayEndLocal != null) {
      // "연속 일정으로 바꿔줘"류: 종료일을 명시된 날짜로 바꾸고, 시작일과
      // 다른 날이면 연속(멀티데이) 일정으로 표시한다.
      nextEndUtc = planflowLocalDateTimeToUtc(requestedMultiDayEndLocal);
      nextIsMultiDay = nextStartUtc != null &&
          !planflowIsSameLocalDay(nextStartUtc, nextEndUtc);
    } else if (requestedStartLocal != null) {
      nextEndUtc =
          duration == null || duration.isNegative || duration == Duration.zero
              ? event.endAt
              : planflowLocalDateTimeToUtc(requestedStartLocal.add(duration));
    } else {
      nextEndUtc = event.endAt;
    }

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
      participants: event.participants,
      targets: event.targets,
      isCritical: requestedCritical ?? event.isCritical,
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: nextIsMultiDay,
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

  bool? _inferRequestedCriticalFlag() {
    if (_requestedChanges.isEmpty) {
      return null;
    }
    final requestedValue = _routeResult?.requestedFieldValues['is_critical'];
    if (requestedValue == 'true') {
      return true;
    }
    if (requestedValue == 'false') {
      return false;
    }
    if (_requestedChanges.contains('is_critical_true')) {
      return true;
    }
    if (_requestedChanges.contains('is_critical_false')) {
      return false;
    }
    return null;
  }

  DateTime? _inferRequestedStartLocal(EventModel event) {
    if (_isLocationFieldAddition) {
      return null;
    }
    if (_requestedChanges.isNotEmpty &&
        !_requestedChanges.contains('start_at')) {
      return null;
    }
    final changeText = _routeResult?.changeText.trim();
    final text = changeText == null || changeText.isEmpty
        ? _normalizedRawText
        : changeText;
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

  /// "연속 일정으로 바꿔줘"류 발화에서 종료일을 추론한다. 파이프라인이
  /// `multi_day` 변경 신호를 감지했을 때만 동작해 오탐(관련 없는 "N일" 언급)을
  /// 막는다. 지원 표현:
  /// - "N일간/N일 동안/N일 연속": 종료일 = 시작일 + (N-1)일
  /// - "N박(M일)?": 2박3일이면 3일짜리, 숫자만(2박)이면 N+1일짜리로 계산
  /// - "…까지": 명시된 날짜를 그대로 종료일로 사용
  DateTime? _inferRequestedMultiDayEndLocal(EventModel event) {
    if (!_requestedChanges.contains('multi_day')) {
      return null;
    }
    if (event.startAt == null) {
      return null;
    }
    final originalStartLocal = planflowLocal(event.startAt!);
    // start_at 변경 신호와 함께 잡히면 파이프라인이 날짜 구간을 targetText로
    // 분리해버릴 수 있어(changeText에서 "…까지" 부분이 빠짐), 여기서는 항상
    // 정제된 원문 전체를 본다.
    final text = _normalizedRawText;

    DateTime endLocalFromDayCount(int totalDays) {
      final endDate = originalStartLocal.add(Duration(days: totalDays - 1));
      return DateTime(
        endDate.year,
        endDate.month,
        endDate.day,
        originalStartLocal.hour,
        originalStartLocal.minute,
      );
    }

    final nightsAndDays =
        RegExp(r'(\d{1,2})\s*박\s*(?:(\d{1,2})\s*일)?').firstMatch(text);
    if (nightsAndDays != null) {
      final nights = int.tryParse(nightsAndDays.group(1) ?? '');
      final explicitDays = int.tryParse(nightsAndDays.group(2) ?? '');
      final totalDays = explicitDays ?? (nights == null ? null : nights + 1);
      if (totalDays != null && totalDays > 1) {
        return endLocalFromDayCount(totalDays);
      }
    }

    final durationMatch = RegExp(
      r'(\d{1,2}|[일이삼사오육칠팔구십]{1,2})\s*일\s*(?:간|동안|연속)',
    ).firstMatch(text);
    if (durationMatch != null) {
      final totalDays = _koreanNumber(durationMatch.group(1));
      if (totalDays != null && totalDays > 1) {
        return endLocalFromDayCount(totalDays);
      }
    }

    final dateMatches = RegExp(
      r'((?:이번|다음)\s*주\s*)?[월화수목금토일]요일|오늘|내일|모레|글피|(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일',
    ).allMatches(text).toList(growable: false);
    for (final match in dateMatches.reversed) {
      if (!text.substring(match.end).trimLeft().startsWith('까지')) {
        continue;
      }
      final snippet = text.substring(match.start, match.end);
      final parsed = GptService(now: () => originalStartLocal)
          .inferStartAtFromRawText(snippet);
      if (parsed != null) {
        return DateTime(
          parsed.year,
          parsed.month,
          parsed.day,
          originalStartLocal.hour,
          originalStartLocal.minute,
        );
      }
    }
    return null;
  }

  DateTime? _inferLastDateCandidate(String text, DateTime referenceLocal) {
    final allMatches = RegExp(
      r'((?:이번|다음)\s*주\s*)?[월화수목금토일]요일|오늘|내일|모레|글피|(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일',
    ).allMatches(text).toList(growable: false);
    // "…까지"로 끝나는 날짜는 연속 일정의 종료일 지정이지 시작일 변경이
    // 아니므로 시작일 후보에서 제외한다.
    final dateMatches = allMatches
        .where(
          (match) => !text.substring(match.end).trimLeft().startsWith('까지'),
        )
        .toList(growable: false);
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
    final plannedLocation = _routeResult?.requestedFieldValues['location'];
    if (plannedLocation != null && plannedLocation.trim().isNotEmpty) {
      return plannedLocation.trim();
    }
    if (_requestedChanges.isNotEmpty &&
        !_requestedChanges.contains('location')) {
      return null;
    }
    final source = _routeResult?.changeText.trim().isNotEmpty == true
        ? _routeResult!.changeText
        : _normalizedRawText;
    final match = RegExp(
      r'(?:장소|위치|주소)\s*(?:를|을)?\s*(.+?)(?:로|으로)\s*(?:변경|바꿔|수정)|(.+?)(?:로|으로)?\s*(?:장소|위치|주소)\s*(?:추가|넣어|입력|설정|등록)',
    ).firstMatch(source);
    final prefixLocation = match?.group(1)?.trim();
    final suffixLocation = match?.group(2)?.trim();
    var location = prefixLocation == null || prefixLocation.isEmpty
        ? suffixLocation
        : prefixLocation;
    if (location != null &&
        suffixLocation != null &&
        suffixLocation.isNotEmpty) {
      final targetBoundaries =
          RegExp(r'(?:일정|스케줄|약속)에\s+').allMatches(location).toList();
      if (targetBoundaries.isNotEmpty) {
        location = location.substring(targetBoundaries.last.end).trim();
      }
    }
    return location == null || location.isEmpty ? null : location;
  }

  Future<void> _confirmDelete(EventModel event) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('음성으로 일정 삭제'),
          content: Text('"${event.title}" 일정을 삭제할까요? 이 작업은 되돌릴 수 없습니다.'),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actions: [
            PlanFlowActionButtons(
              buttons: [
                PlanFlowActionButton(
                  label: '취소',
                  onPressed: () => Navigator.of(context).pop(false),
                  type: ActionButtonType.secondary,
                  flex: 1,
                ),
                PlanFlowActionButton(
                  buttonKey: ValueKey('voice-confirm-delete-${event.id}'),
                  label: '삭제',
                  onPressed: () => Navigator.of(context).pop(true),
                  type: ActionButtonType.destructive,
                  flex: 1,
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
        return AlertDialog(
          title: const Text('선택한 일정 삭제'),
          content: Text(
            '${selectedEvents.length}개 일정을 삭제할까요? 이 작업은 되돌릴 수 없습니다.',
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actions: [
            PlanFlowActionButtons(
              buttons: [
                PlanFlowActionButton(
                  label: '취소',
                  onPressed: () => Navigator.of(context).pop(false),
                  type: ActionButtonType.secondary,
                  flex: 1,
                ),
                PlanFlowActionButton(
                  buttonKey: const ValueKey('voice-confirm-selected-delete'),
                  label: '선택 삭제',
                  onPressed: () => Navigator.of(context).pop(true),
                  type: ActionButtonType.destructive,
                  flex: 1,
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
      // 선택 목록에 개인 일정과 그룹 일정이 섞여 있을 수 있으므로(다중 선택
      // 삭제) 이벤트별로 저장소를 분기한다. 개인 일정은 하드 삭제, 그룹
      // 일정은 소프트 취소(cancelGroupEvent)로 처리한다.
      final personalEventsDeleted = <EventModel>[];
      for (final event in events) {
        final groupEvent = _groupEventById[event.id];
        if (groupEvent != null) {
          await _groupEventRepository.cancelGroupEvent(groupEvent.id);
          _groupEventById.remove(event.id);
        } else {
          await _repository.deleteEvent(event.id, userId: userId);
          personalEventsDeleted.add(event);
        }
      }
      if (personalEventsDeleted.isNotEmpty) {
        unawaited(
          _runDeleteFollowUps(
            userId: userId,
            events: List.of(personalEventsDeleted),
          ),
        );
      }
      if (!mounted) {
        return;
      }
      final deletedIds = events.map((event) => event.id).toSet();
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
        _isDeleting = false;
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

  Future<void> _runDeleteFollowUps({
    required String userId,
    required List<EventModel> events,
  }) {
    return BackgroundTaskService.run(
      () async {
        final settings = await _fetchSettingsOrNull(userId);
        for (final event in events) {
          await _runFollowUpStep(
            'cleanup_after_delete',
            () => widget.sideEffectService.cleanupAfterDelete(
              event.id,
              userId: userId,
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
            ),
          );
          await _runFollowUpStep(
            'resync_external_preparation_after_delete',
            () => _resyncExternalPreparationAfterDelete(event, userId: userId),
          );
        }
        await _runFollowUpStep(
          'refresh_home_widget_after_delete',
          () => _refreshHomeWidget(userId),
        );
        await _runFollowUpStep(
          'voice_log_delete',
          () => _recordVoiceLog(
            action: 'delete',
            targetEventId: events.length == 1 ? events.single.id : null,
            result: events.length == 1 ? 'deleted' : 'selected_deleted',
          ),
        );
      },
      owner: 'VoiceActionScreen',
      label: 'delete_follow_ups',
      failureMessage: '삭제는 완료됐지만 알림/위젯 정리 중 문제가 생겼어요. 문제 신고에 이 문구를 함께 보내 주세요.',
    );
  }

  Future<void> _refreshHomeWidget(String userId) async {
    try {
      final now = DateTime.now();
      final events = await _repository.listEvents(userId: userId);
      await widget.homeWidgetService.updateSchedulePayload(
        HomeWidgetSchedulePayloadBuilder.fromEvents(
          events: events,
          now: now,
          emptyTitle: '다가올 일정이 없어요',
        ),
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
      final settings = await _fetchSettingsOrNull(userId);
      final events = await _repository.listEvents(userId: userId);
      await widget.sideEffectService.resyncExternalPreparationForDay(
        dayEvents: events,
        userId: userId,
        dayReference: deletedStartAt,
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

  Future<UserSettingsModel?> _fetchSettingsOrNull(String userId) async {
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    try {
      return await SettingsRepository.supabase().fetchSettings(userId);
    } catch (error, stackTrace) {
      debugPrint('VoiceActionScreen settings lookup skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
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
        departureSafetyMargin: Duration(
          minutes: settings?.departureSafetyMarginMin ??
              DepartureAlarmService.safetyMargin.inMinutes,
        ),
        travelMode: settings?.travelMode ?? 'car',
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
                  forceManualEdit: _isLocationFieldAddition,
                  allowDirectApply: _routeResult?.safeDirectApply ?? false,
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
                  groupEventIds: _groupEventById.keys.toSet(),
                  isConvertToPersonalRequested: _isConvertToPersonalRequested,
                  onConvertToPersonal: (event) {
                    final groupEvent = _groupEventById[event.id];
                    if (groupEvent != null) {
                      unawaited(_convertGroupEventToPersonal(groupEvent));
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

