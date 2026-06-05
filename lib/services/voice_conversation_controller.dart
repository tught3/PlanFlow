import '../core/local_time.dart';
import '../data/models/event_model.dart';
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
  });

  final List<EventModel> visibleEvents;
  final List<EventModel> selectedEvents;
  final EventModel? focusedEvent;
  final VoiceConversationDeleteAction? pendingDelete;

  VoiceConversationSession copyWith({
    List<EventModel>? visibleEvents,
    List<EventModel>? selectedEvents,
    EventModel? focusedEvent,
    VoiceConversationDeleteAction? pendingDelete,
    bool clearPendingAction = false,
    bool clearFocusedEvent = false,
  }) {
    return VoiceConversationSession(
      visibleEvents: visibleEvents ?? this.visibleEvents,
      selectedEvents: selectedEvents ?? this.selectedEvents,
      focusedEvent:
          clearFocusedEvent ? null : focusedEvent ?? this.focusedEvent,
      pendingDelete:
          clearPendingAction ? null : pendingDelete ?? this.pendingDelete,
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

  void replaceEvents(Iterable<EventModel> events) {
    _state.replaceEvents(events);
  }

  void clearSession() {
    _state
      ..visibleEvents = const <EventModel>[]
      ..selectedEvents = const <EventModel>[]
      ..focusedEvent = null
      ..pendingDelete = null;
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

    if (state.pendingDelete != null && _isDeleteConfirmation(text)) {
      final confirmed = state.pendingDelete!;
      state
        ..pendingDelete = null
        ..focusedEvent = confirmed.event
        ..selectedEvents = const <EventModel>[];
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
      state.pendingDelete = null;
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

    final multiTargets = _resolveExplicitFollowUpTargets(text, state);
    if (_isModificationIntent(text, route: route) && multiTargets.length > 1) {
      state
        ..visibleEvents = multiTargets
        ..selectedEvents = multiTargets
        ..focusedEvent = null
        ..pendingDelete = null;
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
    if (criticalValue != null) {
      final target = _resolveFollowUpTarget(text, state);
      if (target == null) {
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
        ..pendingDelete = null;
      return _finish(
        state,
        session,
        VoiceConversationResult(
          action: VoiceConversationAction.confirmedEdit,
          inputText: input,
          targetEvent: target,
          criticalValue: criticalValue,
          assistantMessage: criticalValue
              ? '"${target.title}" 일정을 중요 알림으로 변경할게요.'
              : '"${target.title}" 일정을 일반 알림으로 변경할게요.',
        ),
      );
    }

    if (_isLocationIntent(text, route: route)) {
      final ambiguous = _resolveAmbiguousTimeTargets(text, state);
      if (ambiguous.length > 1) {
        state
          ..visibleEvents = ambiguous
          ..focusedEvent = null
          ..pendingDelete = null;
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
      final target = _resolveFollowUpTarget(text, state);
      final locationText = _extractLocationText(text);
      if (target != null && locationText != null) {
        state
          ..focusedEvent = target
          ..selectedEvents = const <EventModel>[];
        return _finish(
          state,
          session,
          VoiceConversationResult(
            action: VoiceConversationAction.confirmedEdit,
            inputText: input,
            targetEvent: target,
            locationText: locationText,
            assistantMessage:
                '"${target.title}" 일정의 장소를 "$locationText"(으)로 변경할게요.',
          ),
        );
      }
      if (target == null) {
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
          ..pendingDelete = null;
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
      final target = _resolveFollowUpTarget(text, state);
      if (target != null) {
        final pending = VoiceConversationDeleteAction(
          event: target,
          requestText: text,
        );
        state
          ..focusedEvent = target
          ..pendingDelete = pending
          ..selectedEvents = const <EventModel>[];
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
        ..pendingDelete = null;
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

    final followUp = _resolveFollowUpTarget(text, state);
    if (followUp != null) {
      state
        ..focusedEvent = followUp
        ..selectedEvents = const <EventModel>[];
      // 수정 의도(날짜/시간 이동 등 location·critical·delete 외)가 있으면
      // 편집 화면으로 넘겨 GPT 파이프라인이 처리하게 한다.
      if (_isModificationIntent(text, route: route)) {
        final draftEvent = _draftEventForRelativeShift(
          followUp,
          text,
          route: route,
        );
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
    if (RegExp(r'(중요|긴급|급한|critical|중요한)\s*(알람|알림|경보)').hasMatch(text)) {
      return true;
    }
    if (RegExp(r'(보통|일반|normal)\s*(알람|알림)').hasMatch(text)) {
      return false;
    }
    return null;
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

  EventModel? _resolveFollowUpTarget(
    String text,
    _VoiceConversationState state,
  ) {
    if (state.selectedEvents.length > 1) {
      final selectedOrdinal = _parseOrdinalIndex(text);
      if (selectedOrdinal != null &&
          selectedOrdinal >= 0 &&
          selectedOrdinal < state.selectedEvents.length) {
        return state.selectedEvents[selectedOrdinal];
      }
      if (_isFocusedEventReference(text)) {
        return state.selectedEvents.first;
      }
    }

    final ordinalIndex = _parseOrdinalIndex(text);
    if (ordinalIndex != null &&
        ordinalIndex >= 0 &&
        ordinalIndex < state.visibleEvents.length) {
      return state.visibleEvents[ordinalIndex];
    }

    final time = _parseTimeReference(text);
    if (time != null) {
      final matches = _matchVisibleEventsByTime(time, state.visibleEvents);
      if (matches.length == 1) {
        return matches.single;
      }
    }

    if (_isFocusedEventReference(text)) {
      return state.focusedEvent ??
          (state.visibleEvents.isEmpty ? null : state.visibleEvents.first);
    }

    final titleMatched = _matchVisibleEventByTitle(text, state.visibleEvents);
    if (titleMatched != null) {
      return titleMatched;
    }

    return null;
  }

  EventModel? _matchVisibleEventByTitle(
    String text,
    List<EventModel> visibleEvents,
  ) {
    if (visibleEvents.isEmpty) {
      return null;
    }
    final queryTokens = text
        .replaceAll(RegExp(r'\d+\s*(?:번째|번\s*째|번)'), ' ')
        .replaceAll(
          RegExp(
            r'(일정|중요|긴급|급한|critical|중요한|보통|일반|normal|알람|알림|경보|장소|위치|추가|변경|수정|바꿔|고쳐|설정|넣어|으로|로|에|을|를|은|는|해줘|줘)',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .map(_compact)
        .where((token) => !_isDateReferenceToken(token))
        .where((token) => token.length >= 2)
        .toList(growable: false);
    if (queryTokens.isEmpty) {
      return null;
    }

    final matches = <EventModel>[];
    for (final event in visibleEvents) {
      final compactTitle = _compact(event.title);
      if (queryTokens.any(compactTitle.contains)) {
        matches.add(event);
      }
    }
    return matches.length == 1 ? matches.single : null;
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

  EventModel? _draftEventForRelativeShift(
    EventModel event,
    String text, {
    VoiceCommandRouteResult? route,
  }) {
    final resolvedRoute = route ?? _router.route(text);
    if (!resolvedRoute.requestedChanges.contains('start_at') &&
        !_hasRelativeDateShiftCue(text)) {
      return null;
    }

    final shiftDays = _relativeDateShiftDays(text);
    if (shiftDays == null || event.startAt == null) {
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

  int? _relativeDateShiftDays(String text) {
    final normalized = _compact(text);
    if (normalized.isEmpty) {
      return null;
    }

    final explicitForward = RegExp(r'(\d+)일(?:뒤|후)(?:로|에|으로)?').firstMatch(normalized);
    if (explicitForward != null) {
      return int.tryParse(explicitForward.group(1) ?? '');
    }

    final explicitBackward = RegExp(r'(\d+)일(?:전|앞)(?:으로|로|에)?').firstMatch(normalized);
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

    final directionOnlyDays = RegExp(r'(?:하루|이틀|삼일|\d+일)(?:뒤|후)').firstMatch(normalized);
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
        text.contains('방금 일정') ||
        text.contains('그거') ||
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
}

class _VoiceConversationState {
  _VoiceConversationState({
    required Iterable<EventModel> events,
    this.visibleEvents = const <EventModel>[],
    this.selectedEvents = const <EventModel>[],
    this.focusedEvent,
    this.pendingDelete,
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
    );
  }

  final List<EventModel> events;
  List<EventModel> visibleEvents;
  List<EventModel> selectedEvents;
  EventModel? focusedEvent;
  VoiceConversationDeleteAction? pendingDelete;

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
