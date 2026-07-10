import '../core/local_time.dart';
import '../data/models/event_model.dart';
import 'gpt_service.dart';
import 'voice_command_router.dart';
import 'voice_date_range_parser.dart';

typedef VoiceConversationNow = DateTime Function();

enum VoiceConversationAction {
  none,
  showEvents,
  openEditScreen,
  confirmedEdit,
  confirmDelete,
  deleteConfirmed,
  deleteCanceled,
  createEvent,
  confirmConvertToPersonal,
  convertToPersonalConfirmed,
}

class VoiceConversationDeleteAction {
  const VoiceConversationDeleteAction({
    required this.event,
    required this.requestText,
  });

  final EventModel event;
  final String requestText;
}

class VoiceConversationSession {
  const VoiceConversationSession({
    this.visibleEvents = const <EventModel>[],
    this.selectedEvents = const <EventModel>[],
    this.focusedEvent,
    this.pendingDelete,
    this.pendingConvert,
    this.pendingTitleSearchText,
  });

  final List<EventModel> visibleEvents;
  final List<EventModel> selectedEvents;
  final EventModel? focusedEvent;
  final VoiceConversationDeleteAction? pendingDelete;
  final EventModel? pendingConvert;
  final String? pendingTitleSearchText;

  VoiceConversationSession copyWith({
    List<EventModel>? visibleEvents,
    List<EventModel>? selectedEvents,
    EventModel? focusedEvent,
    VoiceConversationDeleteAction? pendingDelete,
    EventModel? pendingConvert,
    String? pendingTitleSearchText,
    bool clearPendingAction = false,
    bool clearFocusedEvent = false,
    bool clearPendingTitleSearch = false,
    bool clearPendingConvert = false,
  }) {
    return VoiceConversationSession(
      visibleEvents: visibleEvents ?? this.visibleEvents,
      selectedEvents: selectedEvents ?? this.selectedEvents,
      focusedEvent:
          clearFocusedEvent ? null : focusedEvent ?? this.focusedEvent,
      pendingDelete:
          clearPendingAction ? null : pendingDelete ?? this.pendingDelete,
      pendingConvert: clearPendingConvert || clearPendingAction
          ? null
          : pendingConvert ?? this.pendingConvert,
      pendingTitleSearchText: clearPendingTitleSearch
          ? null
          : pendingTitleSearchText ?? this.pendingTitleSearchText,
    );
  }
}

class VoiceConversationResult {
  const VoiceConversationResult({
    required this.action,
    required this.inputText,
    this.queryRange,
    this.visibleEvents = const <EventModel>[],
    this.selectedEvents = const <EventModel>[],
    this.targetEvent,
    this.draftEvent,
    this.locationText,
    this.criticalValue,
    this.pendingDelete,
    this.deleteConfirmed = false,
    this.deleteCanceled = false,
    this.isAvailabilityCheck = false,
    this.requiresEditScreenNavigation = false,
    this.requiresDeleteConfirmation = false,
    this.session = const VoiceConversationSession(),
    String? assistantMessage,
  }) : _assistantMessage = assistantMessage;

  final VoiceConversationAction action;
  final String inputText;
  final VoiceConversationDateRange? queryRange;
  final List<EventModel> visibleEvents;
  final List<EventModel> selectedEvents;
  final EventModel? targetEvent;
  final EventModel? draftEvent;
  final String? locationText;
  final bool? criticalValue;
  final VoiceConversationDeleteAction? pendingDelete;
  final bool deleteConfirmed;
  final bool deleteCanceled;
  final bool isAvailabilityCheck;
  final bool requiresEditScreenNavigation;
  final bool requiresDeleteConfirmation;
  final VoiceConversationSession session;
  final String? _assistantMessage;

  bool get isEmptyAvailability => isAvailabilityCheck && visibleEvents.isEmpty;
  bool get hasMultipleSelectedEvents => selectedEvents.length > 1;
  bool get shouldOpenEdit =>
      action == VoiceConversationAction.openEditScreen &&
      requiresEditScreenNavigation;
  bool get confirmedDelete => deleteConfirmed;
  String get assistantMessage => _assistantMessage ?? _defaultMessage();

  String _defaultMessage() {
    if (action == VoiceConversationAction.none && selectedEvents.length > 1) {
      return '${selectedEvents.length}개의 일정을 선택했어요. 무엇을 바꿀지 이어서 말해 주세요.';
    }
    return switch (action) {
      VoiceConversationAction.showEvents => visibleEvents.isEmpty
          ? (isAvailabilityCheck ? '해당 날짜는 비어 있어요.' : '해당 날짜에 표시할 일정이 없어요.')
          : '${visibleEvents.length}개의 일정을 찾았어요.',
      VoiceConversationAction.openEditScreen =>
        '장소를 수정 화면에 넣어둘게요. 확인 후 저장해 주세요.',
      VoiceConversationAction.confirmedEdit =>
        targetEvent == null ? '변경할 일정을 찾지 못했어요.' : '일정을 변경했어요.',
      VoiceConversationAction.confirmDelete => targetEvent == null
          ? '삭제할 일정을 찾지 못했어요.'
          : '"${targetEvent!.title}" 일정을 삭제할까요? 삭제 확인이 필요해요.',
      VoiceConversationAction.deleteConfirmed => targetEvent == null
          ? '삭제를 진행할게요.'
          : '"${targetEvent!.title}" 일정을 삭제할게요.',
      VoiceConversationAction.deleteCanceled => '삭제를 취소했어요.',
      VoiceConversationAction.createEvent => draftEvent == null
          ? '일정 정보를 파악하지 못했어요.'
          : '일정을 만들어 드릴까요? 확인 후 저장해 주세요.',
      VoiceConversationAction.confirmConvertToPersonal => targetEvent == null
          ? '옮길 일정을 찾지 못했어요.'
          : '"${targetEvent!.title}" 일정을 개인 일정으로 옮길까요? 팀원들 화면에서도 사라져요.',
      VoiceConversationAction.convertToPersonalConfirmed => targetEvent == null
          ? '개인 일정으로 옮길게요.'
          : '"${targetEvent!.title}" 일정을 개인 일정으로 옮길게요.',
      VoiceConversationAction.none =>
        targetEvent == null ? '이해한 일정을 찾지 못했어요.' : '해당 일정을 선택했어요.',
    };
  }
}

class VoiceConversationDateRange {
  const VoiceConversationDateRange({
    required this.start,
    required this.end,
  });

  final DateTime start;
  final DateTime end;

  bool get isSingleDay => end.difference(start).inDays == 1;
}

class VoiceConversationController {
  const VoiceConversationController({
    Iterable<EventModel> events = const <EventModel>[],
    VoiceConversationNow? now,
    VoiceCommandRouter? router,
  })  : _initialEvents = events,
        _now = now,
        _router = router ?? const VoiceCommandRouter();

  static final Expando<_VoiceConversationState> _states =
      Expando<_VoiceConversationState>('VoiceConversationController');

  final Iterable<EventModel> _initialEvents;
  final VoiceConversationNow? _now;
  final VoiceCommandRouter _router;

  List<EventModel> get visibleEvents =>
      List<EventModel>.unmodifiable(_state.visibleEvents);
  EventModel? get focusedEvent => _state.focusedEvent;
  VoiceConversationDeleteAction? get pendingDelete => _state.pendingDelete;
  EventModel? get pendingConvert => _state.pendingConvert;

  void replaceEvents(Iterable<EventModel> events) {
    _state.replaceEvents(events);
  }

  void clearSession() {
    _state
      ..visibleEvents = const <EventModel>[]
      ..selectedEvents = const <EventModel>[]
      ..focusedEvent = null
      ..pendingDelete = null
      ..pendingConvert = null
      ..pendingTitleSearchText = null;
  }

  VoiceConversationResult handle(
    String input, {
    VoiceConversationSession? session,
    Iterable<EventModel>? events,
  }) {
    final state = session == null
        ? _state
        : _VoiceConversationState.fromSession(session, events ?? _state.events);
    if (events != null && session == null) {
      state.replaceEvents(events);
    }

    final text = input.trim();
    final route = _router.route(text);
    if (text.isEmpty) {
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.none,
          inputText: input,
        ),
      );
    }

    final pendingTitleSearchText = state.pendingTitleSearchText;
    if (pendingTitleSearchText != null) {
      final expansion = _parseTitleSearchExpansion(text);
      if (expansion != null) {
        final expanded = _searchEventsByTitleOrPeople(
          pendingTitleSearchText,
          state,
          windowStart: expansion.includePast
              ? _addMonthsClamped(
                  planflowLocal((_now ?? planflowNow)()),
                  -expansion.months,
                )
              : planflowLocal((_now ?? planflowNow)()),
          windowEnd: expansion.includeFuture
              ? _addMonthsClamped(
                  planflowLocal((_now ?? planflowNow)()),
                  expansion.months,
                ).add(const Duration(days: 1))
              : planflowLocal((_now ?? planflowNow)()).add(
                  const Duration(days: 1),
                ),
        );
        if (expanded.inRangeMatches.isNotEmpty) {
          final matched = expanded.inRangeMatches;
          state
            ..visibleEvents = matched
            ..focusedEvent = matched.length == 1 ? matched.first : null
            ..selectedEvents = const <EventModel>[]
            ..pendingDelete = null
            ..pendingConvert = null
            ..pendingTitleSearchText = null;
          return _finish(
            state,
            session,
            VoiceConversationResult(
              action: VoiceConversationAction.showEvents,
              inputText: input,
              visibleEvents: matched,
              selectedEvents: const <EventModel>[],
              targetEvent: state.focusedEvent,
              assistantMessage: '확장한 기간에서 ${matched.length}개의 일정을 찾았어요.',
            ),
          );
        }
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.none,
            inputText: input,
            assistantMessage: '그 범위에서는 아직 찾지 못했어요. 더 넓혀볼까요?',
          ),
        );
      }
      if (_isTitleSearchExpansionFollowUp(text)) {
        final hasDirection = _hasExpansionDirection(text);
        final hasMonths = _extractExpansionMonths(text) != null;
        if (!hasDirection) {
          return _finish(
            state,
            session,
            VoiceConversationResult(
              action: VoiceConversationAction.none,
              inputText: input,
              assistantMessage: '과거, 미래, 또는 양쪽 중 어디로 확장할지 말해 주세요.',
            ),
          );
        }
        if (!hasMonths) {
          return _finish(
            state,
            session,
            VoiceConversationResult(
              action: VoiceConversationAction.none,
              inputText: input,
              assistantMessage: '몇 개월까지 넓혀 찾을까요?',
            ),
          );
        }
      }
    }

    if (state.pendingDelete != null && _isDeleteConfirmation(text)) {
      final confirmed = state.pendingDelete!;
      state
        ..pendingDelete = null
        ..pendingConvert = null
        ..focusedEvent = confirmed.event
        ..selectedEvents = const <EventModel>[]
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.deleteConfirmed,
          inputText: input,
          targetEvent: confirmed.event,
          pendingDelete: confirmed,
          deleteConfirmed: true,
        ),
      );
    }

    if (state.pendingDelete != null && _isDeleteRejection(text)) {
      final canceled = state.pendingDelete!;
      state
        ..pendingDelete = null
        ..pendingConvert = null
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.deleteCanceled,
          inputText: input,
          targetEvent: canceled.event,
          pendingDelete: canceled,
          deleteCanceled: true,
        ),
      );
    }

    if (state.pendingConvert != null && _isConvertConfirmation(text)) {
      final confirmed = state.pendingConvert!;
      state
        ..pendingConvert = null
        ..focusedEvent = confirmed
        ..selectedEvents = const <EventModel>[]
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.convertToPersonalConfirmed,
          inputText: input,
          targetEvent: confirmed,
        ),
      );
    }

    if (state.pendingConvert != null && _isDeleteRejection(text)) {
      state
        ..pendingConvert = null
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.none,
          inputText: input,
          assistantMessage: '개인 일정으로 옮기지 않을게요.',
        ),
      );
    }

    if (state.pendingConvert == null &&
        _isConvertToPersonalIntent(text, route: route)) {
      final target = _resolveFollowUpTarget(text, state, route: route);
      if (target == null) {
        state.pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.none,
            inputText: input,
            assistantMessage: state.visibleEvents.isEmpty
                ? '먼저 일정을 조회해 주세요.'
                : '옮길 일정을 찾지 못했어요. 몇 번째 일정인지 다시 말해 주세요.',
          ),
        );
      }
      state
        ..pendingConvert = target
        ..pendingDelete = null
        ..focusedEvent = target
        ..selectedEvents = const <EventModel>[]
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.confirmConvertToPersonal,
          inputText: input,
          targetEvent: target,
        ),
      );
    }

    final multiTargets = _resolveExplicitFollowUpTargets(text, state);
    if (_isModificationIntent(text, route: route) && multiTargets.length > 1) {
      state
        ..visibleEvents = multiTargets
        ..selectedEvents = multiTargets
        ..focusedEvent = null
        ..pendingDelete = null
        ..pendingConvert = null
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.none,
          inputText: input,
          visibleEvents: multiTargets,
          selectedEvents: multiTargets,
          assistantMessage:
              '${multiTargets.length}개의 일정을 선택했어요. 무엇을 바꿀지 이어서 말해 주세요.',
        ),
      );
    }

    final criticalValue = _criticalValueFromText(text);
    if (criticalValue != null && !_isLocationIntent(text, route: route)) {
      // 이미 '중요 표시' 의도가 확정됐으므로 route.intent(add 오분류 가능성,
      // 예: '표시'의 '시'가 시간 표현으로 오매칭)와 무관하게 대상을 찾는다.
      final target = _resolveFollowUpTarget(text, state);
      if (target == null) {
        state.pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.none,
            inputText: input,
            assistantMessage: state.visibleEvents.isEmpty
                ? '먼저 일정을 조회해 주세요.'
                : '변경할 일정을 찾지 못했어요. 몇 번째 일정인지 다시 말해 주세요.',
          ),
        );
      }
      state
        ..focusedEvent = target
        ..selectedEvents = const <EventModel>[]
        ..pendingDelete = null
        ..pendingConvert = null;
      state.pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.confirmedEdit,
          inputText: input,
          targetEvent: target,
          criticalValue: criticalValue,
          assistantMessage: criticalValue
              ? '"${target.title}" 일정을 중요한 일정으로 표시할게요.'
              : '"${target.title}" 일정을 중요한 일정으로 표시하지 않을게요.',
        ),
      );
    }

    if (_isLocationIntent(text, route: route)) {
      final ambiguous = _resolveAmbiguousTimeTargets(text, state);
      if (ambiguous.length > 1) {
        state
          ..visibleEvents = ambiguous
          ..focusedEvent = null
          ..pendingDelete = null
          ..pendingConvert = null
          ..pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.showEvents,
            inputText: input,
            visibleEvents: ambiguous,
            selectedEvents: const <EventModel>[],
            assistantMessage: '같은 시간대 일정이 여러 개예요. 몇 번째 일정인지 골라서 다시 말해 주세요.',
          ),
        );
      }
      // 이미 '장소 변경' 의도가 확정됐으므로 route.intent와 무관하게 대상을 찾는다.
      final target = _resolveFollowUpTarget(text, state);
      final locationText =
          _locationTextFromRoute(route) ?? _extractLocationText(text);
      if (target != null && locationText != null) {
        state
          ..focusedEvent = target
          ..selectedEvents = const <EventModel>[];
        state.pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            // 장소가 포함된 수정은 지도 선택 화면으로 바로 보내지 않는다.
            // 시간/중요도 같은 동시 변경도 함께 채운 편집 초안에서 확인한다.
            action: VoiceConversationAction.openEditScreen,
            inputText: input,
            targetEvent: target,
            draftEvent: _draftEventForRequestedStart(
              target,
              text,
              route: route,
            ),
            locationText: locationText,
            criticalValue: criticalValue,
            requiresEditScreenNavigation: true,
            assistantMessage: '"${target.title}" 일정의 변경 내용을 편집 화면에서 확인해 주세요.',
          ),
        );
      }
      if (target == null) {
        state.pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.none,
            inputText: input,
            assistantMessage: state.visibleEvents.isEmpty
                ? '먼저 일정을 조회해 주세요.'
                : '변경할 일정을 찾지 못했어요. 몇 번째 일정인지 다시 말해 주세요.',
          ),
        );
      }
    }

    if (_isDeleteIntent(text, route: route)) {
      final ambiguous = _resolveAmbiguousTimeTargets(text, state);
      if (ambiguous.length > 1) {
        state
          ..visibleEvents = ambiguous
          ..focusedEvent = null
          ..pendingDelete = null
          ..pendingConvert = null
          ..pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.showEvents,
            inputText: input,
            visibleEvents: ambiguous,
            selectedEvents: const <EventModel>[],
            assistantMessage: '같은 시간대 일정이 여러 개예요. 삭제할 일정을 번호로 다시 말해 주세요.',
          ),
        );
      }
      // 이미 '삭제' 의도가 확정됐으므로 route.intent와 무관하게 대상을 찾는다.
      final target = _resolveFollowUpTarget(text, state);
      if (target != null) {
        final pending = VoiceConversationDeleteAction(
          event: target,
          requestText: text,
        );
        state
          ..focusedEvent = target
          ..pendingDelete = pending
          ..pendingConvert = null
          ..selectedEvents = const <EventModel>[]
          ..pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.confirmDelete,
            inputText: input,
            targetEvent: target,
            pendingDelete: pending,
            requiresDeleteConfirmation: true,
          ),
        );
      }
      state.pendingTitleSearchText = null;
    }

    final range = _parseDateRange(text);
    if (range != null && _isQueryIntent(text, route: route)) {
      final matched = state.events
          .where((event) => _eventIntersectsRange(event, range))
          .toList(growable: false);
      _sortEvents(matched);
      state
        ..visibleEvents = matched
        ..focusedEvent = matched.length == 1 ? matched.first : null
        ..selectedEvents = const <EventModel>[]
        ..pendingDelete = null
        ..pendingConvert = null
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.showEvents,
          inputText: input,
          queryRange: range,
          visibleEvents: matched,
          selectedEvents: const <EventModel>[],
          targetEvent: state.focusedEvent,
          isAvailabilityCheck: _isAvailabilityIntent(text),
        ),
      );
    }

    final followUp = _resolveFollowUpTarget(text, state, route: route);
    if (followUp != null) {
      state
        ..focusedEvent = followUp
        ..selectedEvents = const <EventModel>[];
      // 수정 의도(날짜/시간 이동 등 location·critical·delete 외)가 있으면
      // 편집 화면으로 넘겨 GPT 파이프라인이 처리하게 한다.
      if (_isModificationIntent(text, route: route)) {
        final draftEvent = _draftEventForRequestedStart(
          followUp,
          text,
          route: route,
        );
        state.pendingTitleSearchText = null;
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.openEditScreen,
            inputText: input,
            targetEvent: followUp,
            draftEvent: draftEvent,
            selectedEvents: <EventModel>[followUp],
            requiresEditScreenNavigation: true,
            assistantMessage: '"${followUp.title}" 일정을 편집 화면에서 바꿔 드릴게요.',
          ),
        );
      }
      state.pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.none,
          inputText: input,
          targetEvent: followUp,
          selectedEvents: <EventModel>[followUp],
        ),
      );
    }

    if (_isModificationIntent(text, route: route) &&
        _isFocusedEventReference(text) &&
        state.focusedEvent == null &&
        state.visibleEvents.length > 1) {
      state.pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.none,
          inputText: input,
          visibleEvents: state.visibleEvents,
          selectedEvents: const <EventModel>[],
          assistantMessage: '여러 일정이 보여요. 몇 번째 일정인지 말해 주세요.',
        ),
      );
    }

    final titleSearch = _searchEventsByTitleOrPeople(text, state);
    if (titleSearch.inRangeMatches.isNotEmpty) {
      final matched = titleSearch.inRangeMatches;
      state
        ..visibleEvents = matched
        ..focusedEvent = matched.length == 1 ? matched.first : null
        ..selectedEvents = const <EventModel>[]
        ..pendingDelete = null
        ..pendingConvert = null
        ..pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.showEvents,
          inputText: input,
          visibleEvents: matched,
          selectedEvents: const <EventModel>[],
          targetEvent: state.focusedEvent,
        ),
      );
    }

    if (titleSearch.hasOutOfRangeMatches) {
      state.pendingTitleSearchText = text;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.none,
          inputText: input,
          assistantMessage: '기본 검색 기간에는 없어요. 기간을 넓혀 찾아볼까요?',
        ),
      );
    }

    if (route.intent == VoiceCommandRouteIntent.add ||
        _hasCreateEventKeywords(text)) {
      final draftTitle = route.targetText.trim().isNotEmpty
          ? route.targetText.trim()
          : route.cleanedText.trim();
      final range = _parseDateRange(text);
      final now = planflowLocal((_now ?? planflowNow)());
      final startAt = range?.start ?? now;
      final endAt = range?.end ?? startAt.add(const Duration(hours: 1));
      final draft = EventModel(
        id: '',
        userId: '',
        title: draftTitle.isEmpty ? input : draftTitle,
        startAt: startAt,
        endAt: endAt,
        createdAt: now,
      );
      state.pendingTitleSearchText = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.createEvent,
          inputText: input,
          draftEvent: draft,
          assistantMessage: '일정을 만들어 드릴까요? 편집 화면에서 확인 후 저장하세요.',
        ),
      );
    }

    return _finish(
      state,
      session,
      VoiceConversationResult(
        action: VoiceConversationAction.none,
        inputText: input,
        selectedEvents: state.selectedEvents.length > 1
            ? state.selectedEvents
            : const <EventModel>[],
      ),
    );
  }

  static const _createEventKeywords = [
    '만들어',
    '만들어줘',
    '추가해',
    '추가해줘',
    '등록해',
    '등록해줘',
    '새 일정',
    '일정 만들어',
    '일정 추가',
    '일정 등록',
    '일정 만들',
    '일정 새로',
  ];

  bool _hasCreateEventKeywords(String text) {
    final lower = text.replaceAll(' ', '');
    return _createEventKeywords.any(
      (kw) => lower.contains(kw.replaceAll(' ', '')),
    );
  }

  _VoiceConversationState get _state {
    final existing = _states[this];
    if (existing != null) {
      return existing;
    }
    final created = _VoiceConversationState.fromEvents(_initialEvents);
    _states[this] = created;
    return created;
  }

  VoiceConversationResult _finish(
    _VoiceConversationState state,
    VoiceConversationSession? externalSession,
    VoiceConversationResult result,
  ) {
    final nextSession = state.toSession();
    if (externalSession == null) {
      _states[this] = state;
    }
    return VoiceConversationResult(
      action: result.action,
      inputText: result.inputText,
      queryRange: result.queryRange,
      visibleEvents: result.visibleEvents,
      selectedEvents: result.selectedEvents,
      targetEvent: result.targetEvent,
      draftEvent: result.draftEvent,
      locationText: result.locationText,
      criticalValue: result.criticalValue,
      pendingDelete: result.pendingDelete,
      deleteConfirmed: result.deleteConfirmed,
      deleteCanceled: result.deleteCanceled,
      isAvailabilityCheck: result.isAvailabilityCheck,
      requiresEditScreenNavigation: result.requiresEditScreenNavigation,
      requiresDeleteConfirmation: result.requiresDeleteConfirmation,
      session: nextSession,
      assistantMessage: result._assistantMessage,
    );
  }

  VoiceConversationDateRange? _parseDateRange(String text) {
    final parsed = VoiceDateRangeParser.parse(
      text,
      now: (_now ?? planflowNow)(),
    );
    if (parsed == null) {
      return null;
    }
    return VoiceConversationDateRange(start: parsed.start, end: parsed.end);
  }

  bool _eventIntersectsRange(
    EventModel event,
    VoiceConversationDateRange range,
  ) {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }
    final localStart = planflowLocal(startAt);
    final localEnd =
        event.endAt == null ? localStart : planflowLocal(event.endAt!);
    if (localEnd.isAtSameMomentAs(localStart)) {
      return !localStart.isBefore(range.start) &&
          localStart.isBefore(range.end);
    }
    return localStart.isBefore(range.end) && localEnd.isAfter(range.start);
  }

  bool _isQueryIntent(String text, {VoiceCommandRouteResult? route}) {
    final resolvedRoute = route ?? _router.route(text);
    return resolvedRoute.intent == VoiceCommandRouteIntent.query ||
        _isAvailabilityIntent(text) ||
        (text.contains('일정') &&
            (text.contains('보여') ||
                text.contains('알려') ||
                text.contains('확인') ||
                text.contains('조회') ||
                text.contains('찾아')));
  }

  bool _isAvailabilityIntent(String text) {
    return text.contains('비어') ||
        text.contains('비었') ||
        text.contains('없어') ||
        text.contains('있어?');
  }

  bool _isConvertToPersonalIntent(String text,
      {VoiceCommandRouteResult? route}) {
    final resolvedRoute = route ?? _router.route(text);
    if (resolvedRoute.requestedChanges.contains('convert_to_personal')) {
      return true;
    }
    return RegExp(r'(개인\s*일정|내\s*일정)\s*(?:으로|로)\s*(?:바꿔|변경|옮겨|전환|돌려|이동)')
        .hasMatch(text);
  }

  bool _isLocationIntent(String text, {VoiceCommandRouteResult? route}) {
    final resolvedRoute = route ?? _router.route(text);
    return resolvedRoute.requestedChanges.contains('location') ||
        (text.contains('장소') || text.contains('위치')) &&
            (text.contains('추가') ||
                text.contains('변경') ||
                text.contains('수정') ||
                text.contains('바꿔') ||
                text.contains('고쳐') ||
                text.contains('설정') ||
                text.contains('넣어'));
  }

  bool? _criticalValueFromText(String text) {
    if (_isCriticalFalseCommand(text)) {
      return false;
    }
    if (_isCriticalTrueCommand(text)) {
      return true;
    }
    return null;
  }

  bool _isCriticalFalseCommand(String text) {
    return RegExp(
      r'(일반\s*(알람|알림|일정|경보)|보통\s*(알람|알림|일정|경보)|'
      r'중요(?:한)?\s*(일정|알림|알람|경보|표시)?\s*'
      r'(해제|꺼\s*줘|꺼줘|꺼|끄\s*어|끄고|끄기|풀어|풀\s*어))',
    ).hasMatch(text);
  }

  bool _isCriticalTrueCommand(String text) {
    return RegExp(
      r'(중요하게\s*표시|강한\s*알림|강한알림|강한\s*알람|강한알람|'
      r'중요한\s*일정|중요\s*일정|중요\s*표시|'
      r'중요한\s*알림|중요\s*알림|중요한\s*알람|중요\s*알람|긴급|급한|critical)',
    ).hasMatch(text);
  }

  bool _isDeleteIntent(String text, {VoiceCommandRouteResult? route}) {
    final resolvedRoute = route ?? _router.route(text);
    return resolvedRoute.intent == VoiceCommandRouteIntent.delete ||
        text.contains('삭제') ||
        text.contains('지워') ||
        text.contains('취소') ||
        text.contains('없애');
  }

  bool _isDeleteConfirmation(String text) {
    final normalized = _compact(text);
    final hasPositive = normalized.contains('응') ||
        normalized.contains('그래') ||
        normalized.contains('맞아') ||
        normalized.contains('확인') ||
        normalized.contains('해줘') ||
        normalized.contains('삭제해') ||
        normalized.contains('지워');
    final hasDelete = normalized.contains('삭제') ||
        normalized.contains('지워') ||
        normalized.contains('없애');
    return hasPositive && hasDelete && !normalized.contains('아니');
  }

  bool _isDeleteRejection(String text) {
    final normalized = _compact(text);
    return normalized.contains('아니') ||
        normalized.contains('취소') ||
        normalized.contains('하지마') ||
        normalized.contains('보류');
  }

  // 삭제 확인(_isDeleteConfirmation)과 달리 '삭제/지워/없애' 키워드를 요구하지
  // 않는 일반 긍정 확인. "개인 일정으로 옮길까요?" 같은 확인 질문에 단순히
  // "응"/"네"로만 답해도 확정되어야 한다.
  bool _isConvertConfirmation(String text) {
    final normalized = _compact(text);
    if (normalized.contains('아니')) {
      return false;
    }
    return normalized.contains('응') ||
        normalized.contains('네') ||
        normalized.contains('어') ||
        normalized.contains('그래') ||
        normalized.contains('맞아') ||
        normalized.contains('확인') ||
        normalized.contains('좋아') ||
        normalized.contains('옮겨') ||
        normalized.contains('바꿔') ||
        normalized.contains('해줘');
  }

  EventModel? _resolveFollowUpTarget(
    String text,
    _VoiceConversationState state, {
    VoiceCommandRouteResult? route,
  }) {
    if (state.selectedEvents.length > 1) {
      final selectedOrdinal = _parseOrdinalIndex(text);
      if (selectedOrdinal != null &&
          selectedOrdinal >= 0 &&
          selectedOrdinal < state.selectedEvents.length) {
        return state.selectedEvents[selectedOrdinal];
      }
      if (_isFocusedEventReference(text)) {
        return state.focusedEvent;
      }
    }

    final ordinalIndex = _parseOrdinalIndex(text);
    if (ordinalIndex != null) {
      final pool = state.visibleEvents.isNotEmpty
          ? state.visibleEvents
          : (List<EventModel>.from(state.events)
            ..sort((a, b) => (a.startAt ?? DateTime.now())
                .compareTo(b.startAt ?? DateTime.now())));
      if (ordinalIndex >= 0 && ordinalIndex < pool.length) {
        return pool[ordinalIndex];
      }
    }

    if (_isFocusedEventReference(text)) {
      if (state.focusedEvent != null) {
        return state.focusedEvent;
      }
      return state.visibleEvents.length == 1 ? state.visibleEvents.first : null;
    }

    // 새 일정 생성 의도가 명확하면(route.intent == add) 시간 매칭조차
    // 기존 일정 오인 편집으로 이어질 수 있다(예: "오늘 오후2시에 ~ 일정
    // 생성해줘"가 우연히 같은 시각의 기존 일정과 매칭). 명확한 생성 의도에서는
    // 이 추론을 건너뛴다.
    if (route?.intent == VoiceCommandRouteIntent.add) {
      return null;
    }

    if (_isModificationIntent(text, route: route)) {
      final exactTitleTarget = _resolveExactTitleTarget(text, state.events);
      if (exactTitleTarget != null) {
        return exactTitleTarget;
      }
    }

    // 제목 부분일치 추론은 쓰지 않는다. 기존 일정 변경은 사용자가 명시적으로
    // "몇 시 일정을 이걸로 바꿔줘"처럼 시간을 짚어 말하거나(아래 시간 매칭),
    // 조회 후 "몇 번째 일정"처럼 순번으로 지정하는 방식으로만 이뤄져야 한다.
    // 실증: "모란역으로 가기 일정생성해줘"의 "가기"가 과거 조회 결과에 남아있던
    // 제목 "가기" 일정과 부분일치해, 관련 없는 그 일정을 임의로 편집해버렸다.
    final time = _parseTimeReference(text);
    if (time != null) {
      final matches = _matchVisibleEventsByTime(time, state.visibleEvents);
      if (matches.length == 1) {
        return matches.single;
      }
    }

    return null;
  }

  EventModel? _resolveExactTitleTarget(
    String text,
    Iterable<EventModel> events,
  ) {
    final normalizedInput = _compact(text);
    final matches = events.where((event) {
      final normalizedTitle = _compact(event.title);
      return normalizedTitle.length >= 3 &&
          normalizedInput.contains(normalizedTitle);
    }).toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  _VoiceConversationTitleSearch _searchEventsByTitleOrPeople(
    String text,
    _VoiceConversationState state, {
    DateTime? windowStart,
    DateTime? windowEnd,
  }) {
    if (!_isQueryIntent(text)) {
      return const _VoiceConversationTitleSearch();
    }
    final queryTokens = _queryTokensForTitleSearch(text);
    if (queryTokens.isEmpty) {
      return const _VoiceConversationTitleSearch();
    }

    final localNow = planflowLocal((_now ?? planflowNow)());
    final resolvedWindowStart = windowStart ?? _addMonthsClamped(localNow, -1);
    final resolvedWindowEnd = windowEnd ??
        _addMonthsClamped(localNow, 1).add(const Duration(days: 1));

    final allMatches = state.events
        .where((event) => _eventMatchesTitleOrPeople(event, queryTokens))
        .toList(growable: false);
    final inRange = allMatches.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      final localStart = planflowLocal(startAt);
      return !localStart.isBefore(resolvedWindowStart) &&
          localStart.isBefore(resolvedWindowEnd);
    }).toList(growable: false);
    _sortEvents(inRange);
    return _VoiceConversationTitleSearch(
      inRangeMatches: inRange,
      hasOutOfRangeMatches: allMatches.length > inRange.length,
    );
  }

  List<String> _queryTokensForTitleSearch(String text) {
    return text
        .replaceAll(RegExp(r'\d+\s*(?:번째|번\s*째|번)'), ' ')
        .replaceAll(
          RegExp(
            r'(일정|스케줄|찾아|검색|보여|보여줘|알려|확인|조회|해줘|줘|있어|있나|있니|전체|전부|다|모두)',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .map(_normalizeTitleSearchToken)
        .where((token) => !_isDateReferenceToken(token))
        .where((token) => token.length >= 2)
        .toList(growable: false);
  }

  String _normalizeTitleSearchToken(String token) {
    var value = _compact(token);
    value = value.replaceAll(RegExp(r'(이라고|라고|이라는|라는|이란|란)$'), '');
    value = value.replaceAll(RegExp(r'라$'), '');
    return value;
  }

  bool _isTitleSearchExpansionFollowUp(String text) {
    final normalized = _compact(text);
    return normalized.contains('과거') ||
        normalized.contains('미래') ||
        normalized.contains('이전') ||
        normalized.contains('다음') ||
        normalized.contains('앞으로') ||
        normalized.contains('뒤로') ||
        normalized.contains('양쪽') ||
        normalized.contains('둘다') ||
        normalized.contains('둘다') ||
        normalized.contains('개월') ||
        normalized.contains('달') ||
        normalized.contains('넓혀') ||
        normalized.contains('확장');
  }

  bool _hasExpansionDirection(String text) {
    final normalized = _compact(text);
    return normalized.contains('과거') ||
        normalized.contains('미래') ||
        normalized.contains('이전') ||
        normalized.contains('다음') ||
        normalized.contains('앞으로') ||
        normalized.contains('뒤로') ||
        normalized.contains('양쪽') ||
        normalized.contains('둘다');
  }

  int? _extractExpansionMonths(String text) {
    final normalized = _compact(text);
    final match = RegExp(r'(\d{1,2})\s*(?:개월|달)').firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final months = int.tryParse(match.group(1)!);
    if (months == null || months <= 0) {
      return null;
    }
    return months;
  }

  _VoiceConversationTitleSearchExpansion? _parseTitleSearchExpansion(
    String text,
  ) {
    final normalized = _compact(text);
    final months = _extractExpansionMonths(normalized);
    if (months == null) {
      return null;
    }
    var includePast = false;
    var includeFuture = false;
    if (normalized.contains('과거') ||
        normalized.contains('이전') ||
        normalized.contains('뒤로')) {
      includePast = true;
    }
    if (normalized.contains('미래') ||
        normalized.contains('다음') ||
        normalized.contains('앞으로')) {
      includeFuture = true;
    }
    if (normalized.contains('양쪽') ||
        normalized.contains('둘다') ||
        normalized.contains('둘다') ||
        normalized.contains('전후')) {
      includePast = true;
      includeFuture = true;
    }
    if (!includePast && !includeFuture) {
      return null;
    }
    return _VoiceConversationTitleSearchExpansion(
      includePast: includePast,
      includeFuture: includeFuture,
      months: months,
    );
  }

  bool _eventMatchesTitleOrPeople(EventModel event, List<String> queryTokens) {
    final haystack = <String>[
      event.title,
      ...event.participants,
      ...event.targets,
    ].map(_compact).join(' ');
    return queryTokens.every(haystack.contains);
  }

  bool _isDateReferenceToken(String token) {
    return token == '오늘' ||
        token == '내일' ||
        token == '모레' ||
        token == '어제' ||
        RegExp(r'^\d{1,2}월\d{1,2}일$').hasMatch(token) ||
        RegExp(r'^\d{1,2}일$').hasMatch(token);
  }

  List<EventModel> _resolveExplicitFollowUpTargets(
    String text,
    _VoiceConversationState state,
  ) {
    final ordinalIndices = _parseExplicitOrdinalIndices(text);
    if (ordinalIndices.length <= 1) {
      return const <EventModel>[];
    }
    final selected = <EventModel>[];
    final seen = <String>{};
    for (final ordinalIndex in ordinalIndices) {
      if (ordinalIndex < 0 || ordinalIndex >= state.visibleEvents.length) {
        continue;
      }
      final event = state.visibleEvents[ordinalIndex];
      if (seen.add(event.id)) {
        selected.add(event);
      }
    }
    return selected.length > 1 ? selected : const <EventModel>[];
  }

  bool _isModificationIntent(String text, {VoiceCommandRouteResult? route}) {
    final resolvedRoute = route ?? _router.route(text);
    return resolvedRoute.intent == VoiceCommandRouteIntent.edit ||
        resolvedRoute.requestedChanges.isNotEmpty ||
        text.contains('바꿔') ||
        text.contains('변경') ||
        text.contains('수정') ||
        text.contains('고쳐') ||
        text.contains('맞춰') ||
        text.contains('조정') ||
        text.contains('옮겨');
  }

  EventModel? _draftEventForRequestedStart(
    EventModel event,
    String text, {
    VoiceCommandRouteResult? route,
  }) {
    final resolvedRoute = route ?? _router.route(text);
    // "매주 금요일마다 반복으로 바꿔줘"처럼 반복설정 변경 의도가 감지되면,
    // 신규 생성 경로(GptService().parseSchedule)와 동일한 결정적 로컬 파서로
    // RRULE을 계산해둔다. 시간 변경이 없어도(반복만 바뀌는 경우) 이 draft가
    // 만들어져야 하므로 아래 게이트/분기 각각에 반영한다.
    final requestsRecurrenceChange =
        resolvedRoute.requestedChanges.contains('recurrence_rule');
    final requestedRecurrenceRule = requestsRecurrenceChange
        ? GptService().localRecurrenceRuleFromRawText(text)
        : null;

    if (!resolvedRoute.requestedChanges.contains('start_at') &&
        !_hasRelativeDateShiftCue(text) &&
        !_hasExplicitDateOrTimeCue(text) &&
        requestedRecurrenceRule == null) {
      return null;
    }

    final requestedStartLocal = _inferRequestedStartLocal(
      event,
      text,
      route: resolvedRoute,
    );
    if (requestedStartLocal != null) {
      final originalStartLocal =
          event.startAt == null ? null : planflowLocal(event.startAt!);
      final originalEndLocal =
          event.endAt == null ? null : planflowLocal(event.endAt!);
      final duration = originalStartLocal == null || originalEndLocal == null
          ? null
          : originalEndLocal.difference(originalStartLocal);

      return EventModel(
        id: event.id,
        userId: event.userId,
        title: event.title,
        startAt: planflowLocalDateTimeToUtc(requestedStartLocal),
        endAt:
            duration == null || duration.isNegative || duration == Duration.zero
                ? event.endAt
                : planflowLocalDateTimeToUtc(requestedStartLocal.add(duration)),
        location: event.location,
        locationLat: event.locationLat,
        locationLng: event.locationLng,
        memo: event.memo,
        supplies: event.supplies,
        suppliesChecked: event.suppliesChecked,
        participants: event.participants,
        targets: event.targets,
        isCritical: event.isCritical,
        recurrenceRule: requestedRecurrenceRule ?? event.recurrenceRule,
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

    final shiftDays = _relativeDateShiftDays(text);
    if (shiftDays == null || event.startAt == null) {
      // 시간 이동 없이 반복설정만 바뀌는 경우("매주 금요일마다 반복으로
      // 바꿔줘"): 시작 시각은 그대로 두고 recurrenceRule만 교체한 draft를
      // 만든다.
      if (requestedRecurrenceRule != null) {
        return event.copyWith(recurrenceRule: requestedRecurrenceRule);
      }
      return null;
    }

    final shiftedStart = planflowLocal(event.startAt!).add(
      Duration(days: shiftDays),
    );
    final shiftedEnd = event.endAt == null
        ? null
        : planflowLocal(event.endAt!).add(Duration(days: shiftDays));

    return EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: planflowLocalDateTimeToUtc(shiftedStart),
      endAt: shiftedEnd == null ? null : planflowLocalDateTimeToUtc(shiftedEnd),
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      participants: event.participants,
      targets: event.targets,
      isCritical: event.isCritical,
      recurrenceRule: requestedRecurrenceRule ?? event.recurrenceRule,
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

  DateTime? _inferRequestedStartLocal(
    EventModel event,
    String text, {
    VoiceCommandRouteResult? route,
  }) {
    if (_isLocationIntent(text, route: route) &&
        !(route?.requestedChanges.contains('start_at') ?? false)) {
      return null;
    }
    final changeText = route?.changeText.trim();
    final sourceText =
        changeText == null || changeText.isEmpty ? text : changeText;
    final originalStartLocal =
        event.startAt == null ? planflowNow() : planflowLocal(event.startAt!);
    final currentLocalNow = planflowLocal((_now ?? planflowNow)());
    final parsingReferenceLocal = _hasExplicitCalendarDateCue(sourceText)
        ? currentLocalNow
        : originalStartLocal;
    final dateCandidate =
        _inferLastDateCandidate(sourceText, parsingReferenceLocal);
    final timeCandidate = _inferLastTimeCandidate(sourceText);
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

  bool _hasExplicitCalendarDateCue(String text) {
    final normalized = _compact(text);
    return RegExp(r'(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일')
            .hasMatch(normalized) ||
        RegExp(r'(?<!\d)\d{1,2}\s*일(?:로|에|부터|까지)?').hasMatch(normalized);
  }

  DateTime? _inferLastDateCandidate(String text, DateTime referenceLocal) {
    final dateMatches = RegExp(
      r'((?:그\s*)?다음\s*날(?:로|에|으로)?|(?:하루|이틀|삼일|\d+\s*일)\s*(?:뒤|후)(?:로|에|으로)?|(?:하루|이틀|삼일|\d+\s*일)\s*(?:전|앞)(?:으로|로|에)?|(?:이번|다음)\s*주\s*)?[월화수목금토일]요일|오늘|내일|모레|글피|(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일|(?<!\d)\d{1,2}\s*일(?:로|에|부터|까지)?|매월\s*(?:첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*[월화수목금토일]\s*요일|매월\s*\d{1,2}\s*일',
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
    final valueText = match.group(0) ?? '';
    final minute = match.group(4) != null || valueText.contains('반')
        ? 30
        : (_koreanNumber(match.group(3)) ?? 0);
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

  bool _hasRelativeDateShiftCue(String text) {
    final normalized = _compact(text);
    return RegExp(r'(?:그)?다음날(?:로|에|으로)?').hasMatch(normalized) ||
        RegExp(r'(?:하루|이틀|삼일|\d+일)(?:뒤|후)(?:로|에|으로)?').hasMatch(normalized) ||
        RegExp(r'(?:하루|이틀|삼일|\d+일)(?:전|앞)(?:으로|로|에)?').hasMatch(normalized) ||
        normalized.contains('미뤄') ||
        normalized.contains('밀어') ||
        normalized.contains('연기') ||
        normalized.contains('앞당겨') ||
        normalized.contains('당겨');
  }

  bool _hasExplicitDateOrTimeCue(String text) {
    return RegExp(r'(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일')
            .hasMatch(text) ||
        RegExp(r'(?<!\d)\d{1,2}\s*일(?:로|에|부터|까지)?').hasMatch(text) ||
        RegExp(
          r'(오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*([0-9]{1,2}|[가-힣]{1,8})\s*시',
        ).hasMatch(text);
  }

  int? _relativeDateShiftDays(String text) {
    final normalized = _compact(text);
    if (normalized.isEmpty) {
      return null;
    }

    final explicitForward =
        RegExp(r'(\d+)일(?:뒤|후)(?:로|에|으로)?').firstMatch(normalized);
    if (explicitForward != null) {
      return int.tryParse(explicitForward.group(1) ?? '');
    }

    final explicitBackward =
        RegExp(r'(\d+)일(?:전|앞)(?:으로|로|에)?').firstMatch(normalized);
    if (explicitBackward != null) {
      final parsed = int.tryParse(explicitBackward.group(1) ?? '');
      return parsed == null ? null : -parsed;
    }

    if (RegExp(r'(?:그)?다음날(?:로|에|으로)?').hasMatch(normalized) ||
        RegExp(r'하루(?:뒤|후)(?:로|에|으로)?').hasMatch(normalized) ||
        normalized.contains('미뤄') ||
        normalized.contains('밀어') ||
        normalized.contains('연기')) {
      return 1;
    }

    if (RegExp(r'(?:하루|이틀|삼일)(?:전|앞)(?:으로|로|에)?').hasMatch(normalized) ||
        normalized.contains('앞당겨') ||
        normalized.contains('당겨')) {
      return -1;
    }

    final directionOnlyDays =
        RegExp(r'(?:하루|이틀|삼일|\d+일)(?:뒤|후)').firstMatch(normalized);
    if (directionOnlyDays != null) {
      final textValue = directionOnlyDays.group(0) ?? '';
      if (textValue.contains('이틀')) {
        return 2;
      }
      if (textValue.contains('삼일')) {
        return 3;
      }
      final numberMatch = RegExp(r'(\d+)일').firstMatch(textValue);
      if (numberMatch != null) {
        return int.tryParse(numberMatch.group(1) ?? '');
      }
      return 1;
    }

    return null;
  }

  List<int> _parseExplicitOrdinalIndices(String text) {
    final matches = <_OrdinalTokenMatch>[];
    final numericPattern = RegExp(r'(\d+)\s*(?:번째|번\s*째|번)');
    for (final match in numericPattern.allMatches(text)) {
      final value = int.tryParse(match.group(1) ?? '');
      if (value == null) {
        continue;
      }
      matches.add(_OrdinalTokenMatch(match.start, value - 1));
    }

    const words = <String, int>{
      '첫': 1,
      '첫째': 1,
      '두': 2,
      '둘': 2,
      '둘째': 2,
      '세': 3,
      '셋': 3,
      '셋째': 3,
      '네': 4,
      '넷': 4,
      '넷째': 4,
      '다섯': 5,
      '여섯': 6,
      '일곱': 7,
      '여덟': 8,
      '아홉': 9,
      '열': 10,
    };
    for (final entry in words.entries) {
      final pattern = RegExp('${entry.key}\\s*(?:번째|째|번)');
      for (final match in pattern.allMatches(text)) {
        matches.add(_OrdinalTokenMatch(match.start, entry.value - 1));
      }
    }

    matches.sort((left, right) => left.position.compareTo(right.position));
    final indices = <int>[];
    final seen = <int>{};
    for (final match in matches) {
      if (seen.add(match.ordinalIndex)) {
        indices.add(match.ordinalIndex);
      }
    }
    return indices;
  }

  List<EventModel> _resolveAmbiguousTimeTargets(
    String text,
    _VoiceConversationState state,
  ) {
    if (_parseOrdinalIndex(text) != null || _isFocusedEventReference(text)) {
      return const <EventModel>[];
    }
    final time = _parseTimeReference(text);
    if (time == null) {
      return const <EventModel>[];
    }
    final matches = _matchVisibleEventsByTime(time, state.visibleEvents);
    return matches.length > 1 ? matches : const <EventModel>[];
  }

  int? _parseOrdinalIndex(String text) {
    final numeric = RegExp(r'(\d+)\s*(?:번째|번\s*째|번)').firstMatch(text);
    if (numeric != null) {
      final value = int.tryParse(numeric.group(1)!);
      return value == null ? null : value - 1;
    }

    const words = <String, int>{
      '첫': 1,
      '첫째': 1,
      '두': 2,
      '둘': 2,
      '둘째': 2,
      '세': 3,
      '셋': 3,
      '셋째': 3,
      '네': 4,
      '넷': 4,
      '넷째': 4,
      '다섯': 5,
      '여섯': 6,
      '일곱': 7,
      '여덟': 8,
      '아홉': 9,
      '열': 10,
    };
    for (final entry in words.entries) {
      final pattern = RegExp('${entry.key}\\s*(?:번째|째|번)');
      if (pattern.hasMatch(text)) {
        return entry.value - 1;
      }
    }
    return null;
  }

  _TimeReference? _parseTimeReference(String text) {
    final match = RegExp(
      r'(오전|오후|아침|저녁|밤)?\s*(\d{1,2})\s*시',
    ).firstMatch(text);
    if (match == null) {
      return null;
    }
    final hour = int.tryParse(match.group(2)!);
    if (hour == null || hour < 0 || hour > 23) {
      return null;
    }
    final period = match.group(1);
    if (period == '오후' || period == '저녁' || period == '밤') {
      return _TimeReference(hour == 12 ? 12 : hour + 12, hasPeriod: true);
    }
    if (period == '오전' || period == '아침') {
      return _TimeReference(hour == 12 ? 0 : hour, hasPeriod: true);
    }
    return _TimeReference(hour, hasPeriod: false);
  }

  List<EventModel> _matchVisibleEventsByTime(
    _TimeReference time,
    List<EventModel> visibleEvents,
  ) {
    final matches = <EventModel>[];
    for (final event in visibleEvents) {
      final startAt = event.startAt;
      if (startAt == null) {
        continue;
      }
      final local = planflowLocal(startAt);
      if (local.hour == time.hour) {
        matches.add(event);
        continue;
      }
      if (!time.hasPeriod &&
          time.hour >= 1 &&
          time.hour <= 11 &&
          local.hour == time.hour + 12) {
        matches.add(event);
      }
    }
    return matches;
  }

  bool _isFocusedEventReference(String text) {
    return text.contains('그 일정') ||
        text.contains('이 일정') ||
        text.contains('방금 일정') ||
        text.contains('그거') ||
        text.contains('이거') ||
        text.contains('방금 거') ||
        text.contains('방금거');
  }

  String? _extractLocationText(String text) {
    var cleaned = text;
    cleaned = cleaned.replaceFirst(
      RegExp(r'^\s*\d+\s*(?:번째|번\s*째|번)\s*(?:일정)?(?:에|으로|을|를)?\s*'),
      ' ',
    );
    cleaned = cleaned.replaceFirst(
      RegExp(
        r'^\s*(첫|두|둘|세|셋|네|넷|다섯|여섯|일곱|여덟|아홉|열)\s*(?:번째|째|번)\s*(?:일정)?(?:에|으로|을|를)?\s*',
      ),
      ' ',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\d+\s*(?:번째|번\s*째|번)\s*일정(?:에|으로|을|를)?'),
      ' ',
    );
    cleaned = cleaned.replaceAll(
      RegExp(
        r'(첫|두|둘|세|셋|네|넷|다섯|여섯|일곱|여덟|아홉|열)\s*(?:번째|째|번)\s*일정(?:에|으로|을|를)?',
      ),
      ' ',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'(그|방금)\s*일정(?:에|으로|을|를)?'),
      ' ',
    );
    cleaned = cleaned.replaceAll(
      RegExp(
        r'(오전|오후|아침|저녁|밤)?\s*\d{1,2}\s*시\s*일정(?:에|으로|을|를)?',
      ),
      ' ',
    );
    final fieldFirst = RegExp(
      r'^\s*(?:장소|위치)(?:를|을|는)?\s*(.+?)\s*(?:으로|로)?\s*(?:추가|변경|바꿔|넣어)',
    ).firstMatch(cleaned);
    if (fieldFirst != null) {
      cleaned = fieldFirst.group(1) ?? cleaned;
    }
    cleaned = cleaned.replaceAll(
      RegExp(r'(장소|위치)(를|을|에|로|으로)?\s*(추가|변경|바꿔|넣어).*'),
      ' ',
    );
    cleaned = cleaned.replaceAll(RegExp(r'(장소|위치)(를|을|에)?'), ' ');
    cleaned = cleaned.replaceAll(
      RegExp(r'(추가|변경|바꿔|넣어)(해줘|줘|해)?'),
      ' ',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    cleaned = cleaned.replaceFirst(RegExp(r'^(을|를|은|는)\s*'), '');
    cleaned = cleaned.replaceFirst(RegExp(r'^(으로|로|에)\s*'), '');
    cleaned = cleaned.replaceFirst(RegExp(r'\s*(으로|로)$'), '');
    return cleaned.isEmpty ? null : cleaned;
  }

  String? _locationTextFromRoute(VoiceCommandRouteResult route) {
    final location = route.requestedFieldValues['location']?.trim();
    return location == null || location.isEmpty ? null : location;
  }

  String _compact(String text) => text.replaceAll(RegExp(r'\s+'), '');

  static void _sortEvents(List<EventModel> events) {
    events.sort((left, right) {
      final leftStart = left.startAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final rightStart =
          right.startAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final byStart = leftStart.compareTo(rightStart);
      if (byStart != 0) {
        return byStart;
      }
      return left.id.compareTo(right.id);
    });
  }

  DateTime _addMonthsClamped(DateTime value, int months) {
    final targetMonthIndex = value.month + months;
    final targetYear = value.year + ((targetMonthIndex - 1) ~/ 12);
    final targetMonth = ((targetMonthIndex - 1) % 12) + 1;
    final day = value.day.clamp(1, _lastDayOfMonth(targetYear, targetMonth));
    return DateTime(
      targetYear,
      targetMonth,
      day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }

  int _lastDayOfMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }
}

class _VoiceRequestedTime {
  const _VoiceRequestedTime(this.hour, this.minute);

  final int hour;
  final int minute;
}

class _VoiceConversationTitleSearch {
  const _VoiceConversationTitleSearch({
    this.inRangeMatches = const <EventModel>[],
    this.hasOutOfRangeMatches = false,
  });

  final List<EventModel> inRangeMatches;
  final bool hasOutOfRangeMatches;
}

class _VoiceConversationTitleSearchExpansion {
  const _VoiceConversationTitleSearchExpansion({
    required this.includePast,
    required this.includeFuture,
    required this.months,
  });

  final bool includePast;
  final bool includeFuture;
  final int months;
}

class _VoiceConversationState {
  _VoiceConversationState({
    required Iterable<EventModel> events,
    this.visibleEvents = const <EventModel>[],
    this.selectedEvents = const <EventModel>[],
    this.focusedEvent,
    this.pendingDelete,
    this.pendingConvert,
    this.pendingTitleSearchText,
  }) : events = List<EventModel>.of(events) {
    VoiceConversationController._sortEvents(this.events);
  }

  factory _VoiceConversationState.fromEvents(Iterable<EventModel> events) {
    return _VoiceConversationState(events: events);
  }

  factory _VoiceConversationState.fromSession(
    VoiceConversationSession session,
    Iterable<EventModel> events,
  ) {
    return _VoiceConversationState(
      events: events,
      visibleEvents: session.visibleEvents,
      selectedEvents: session.selectedEvents,
      focusedEvent: session.focusedEvent,
      pendingDelete: session.pendingDelete,
      pendingConvert: session.pendingConvert,
      pendingTitleSearchText: session.pendingTitleSearchText,
    );
  }

  final List<EventModel> events;
  List<EventModel> visibleEvents;
  List<EventModel> selectedEvents;
  EventModel? focusedEvent;
  VoiceConversationDeleteAction? pendingDelete;
  EventModel? pendingConvert;
  String? pendingTitleSearchText;

  void replaceEvents(Iterable<EventModel> nextEvents) {
    events
      ..clear()
      ..addAll(nextEvents);
    VoiceConversationController._sortEvents(events);
  }

  VoiceConversationSession toSession() {
    return VoiceConversationSession(
      visibleEvents: List<EventModel>.unmodifiable(visibleEvents),
      selectedEvents: List<EventModel>.unmodifiable(selectedEvents),
      focusedEvent: focusedEvent,
      pendingDelete: pendingDelete,
      pendingConvert: pendingConvert,
      pendingTitleSearchText: pendingTitleSearchText,
    );
  }
}

class _OrdinalTokenMatch {
  const _OrdinalTokenMatch(this.position, this.ordinalIndex);

  final int position;
  final int ordinalIndex;
}

class _TimeReference {
  const _TimeReference(this.hour, {required this.hasPeriod});

  final int hour;
  final bool hasPeriod;
}
