// Voice-first practice tour: in-memory controller + SIMULATED-input parser.
//
// This file owns all tutorial state the new FeatureTourScreen will bind to:
//   - `TourEvent`: saved practice event with example-derived departure /
//     preparation times (travel 20 + buffer 10 => departure = t-30,
//     prep 15 on top => preparation = t-45). Clearly EXAMPLE values, not a
//     real route ETA.
//   - `VoiceCommandParser`: turns one final transcript into add / query /
//     edit-time / unsupported, reusing the production deterministic parsers
//     READ-ONLY (`VoiceDateRangeParser.parse`, `VoiceScheduleStructureService`,
//     `VoiceCommandPipeline`). No cloud / LLM parser is involved.
//   - `VoiceFirstTourController`: in-memory event list with explicit
//     two-step save. A recognized preview NEVER mutates saved state; only
//     `savePending()` commits, exactly once per staged preview.
//
// No persistence here: the tour completion marker belongs to the screen.
// The relative-date reference is frozen once per tour session, so a
// "tomorrow" utterance stays stable across midnight.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;

import '../../services/voice_command_pipeline.dart';
import '../../services/voice_date_range_parser.dart';
import '../../services/voice_schedule_structure_service.dart';

/// EXAMPLE travel assumption for the practice departure preview.
const Duration kTourExampleTravel = Duration(minutes: 20);

/// EXAMPLE buffer assumption for the practice departure preview.
const Duration kTourExampleBuffer = Duration(minutes: 10);

/// EXAMPLE preparation offset (applied before departure) for the practice
/// preparation reminder.
const Duration kTourExamplePrep = Duration(minutes: 15);

/// One saved practice event. Fully immutable: updates replace the instance
/// via [copyWith], so a staged preview can never mutate a saved record.
class TourEvent {
  TourEvent({
    required this.id,
    required this.title,
    required this.eventTime,
    this.location,
  }) {
    _recomputeDerived();
  }

  /// Stable identity for the rendered list / detail binding. Never reused,
  /// even across [VoiceFirstTourController.restart].
  final int id;

  /// Title committed from the parser output (production normalization).
  final String title;

  /// Calendar date + wall-clock time committed at save/update.
  final DateTime eventTime;

  /// Optional free-text location (example-only).
  final String? location;

  /// Departure = eventTime - (travel + buffer). Derived on save/update.
  late final DateTime departure;

  /// Preparation = eventTime - (travel + buffer + prep). Derived on
  /// save/update.
  late final DateTime preparation;

  void _recomputeDerived() {
    final departureTime =
        eventTime.subtract(kTourExampleTravel).subtract(kTourExampleBuffer);
    departure = DateTime(
      departureTime.year,
      departureTime.month,
      departureTime.day,
      departureTime.hour,
      departureTime.minute,
    );
    final preparationTime = departureTime.subtract(kTourExamplePrep);
    preparation = DateTime(
      preparationTime.year,
      preparationTime.month,
      preparationTime.day,
      preparationTime.hour,
      preparationTime.minute,
    );
  }

  TourEvent copyWith({
    String? title,
    DateTime? eventTime,
    String? location,
  }) {
    return TourEvent(
      id: id,
      title: title ?? this.title,
      eventTime: eventTime ?? this.eventTime,
      location: location ?? this.location,
    );
  }
}

/// Structured result of parsing one transcript. Exactly one public field is
/// set; `unsupported` carries a safe user-facing reason otherwise.
@immutable
class VoiceCommandOutcome {
  const VoiceCommandOutcome._({
    this.addDraft,
    this.queryRange,
    this.editTarget,
    this.unsupported,
  });

  factory VoiceCommandOutcome.add(VoiceAddDraft draft) =>
      VoiceCommandOutcome._(addDraft: draft);

  factory VoiceCommandOutcome.query(VoiceQueryRange range) =>
      VoiceCommandOutcome._(queryRange: range);

  factory VoiceCommandOutcome.edit(VoiceEditTarget target) =>
      VoiceCommandOutcome._(editTarget: target);

  factory VoiceCommandOutcome.unsupported(String reason) =>
      VoiceCommandOutcome._(unsupported: reason);

  final VoiceAddDraft? addDraft;
  final VoiceQueryRange? queryRange;
  final VoiceEditTarget? editTarget;
  final String? unsupported;
}

/// Create preview: a brand-new event, staged until the user saves.
@immutable
class VoiceAddDraft {
  const VoiceAddDraft({
    required this.title,
    required this.date,
    required this.time,
    this.location,
  });

  final String title;

  /// Resolved calendar date (relative days resolved against the frozen
  /// session reference).
  final DateTime date;
  final TimeOfDay time;
  final String? location;
}

/// Query range [start, end) used to filter the in-memory list.
@immutable
class VoiceQueryRange {
  const VoiceQueryRange({required this.start, required this.end});

  final DateTime start;

  /// Exclusive.
  final DateTime end;
}

/// Edit intent: the ordinal-th event of the RENDERED query list, with a new
/// wall-clock time. Date / title / location of the target stay untouched.
@immutable
class VoiceEditTarget {
  const VoiceEditTarget({required this.ordinalIndex, required this.newTime});

  /// 1-based ordinal within the last rendered query list.
  final int ordinalIndex;
  final TimeOfDay newTime;
}

/// Staged edit preview resolved by the controller: binds the spoken ordinal
/// to a concrete saved event id plus an immutable snapshot for previewing.
@immutable
class VoicePendingTimeEdit {
  const VoicePendingTimeEdit({
    required this.eventId,
    required this.ordinalIndex,
    required this.newTime,
    required this.originalEvent,
  });

  final int eventId;
  final int ordinalIndex;
  final TimeOfDay newTime;

  /// Snapshot of the record BEFORE the edit; preview shows this plus
  /// [newTime]. Saving replaces the stored instance, never mutates it.
  final TourEvent originalEvent;
}

/// Stateless SIMULATED-transcript parser for the three supported tutorial
/// intents. Reuses production deterministic parsers read-only:
///  - date: `VoiceDateRangeParser.parse` (private ctor never instantiated),
///  - title: `VoiceScheduleStructureService.normalizeLocalVoiceTitle`,
///  - location: `VoiceScheduleStructureService.normalizeScheduleLocation`,
///  - query intent: `VoiceCommandPipeline.resolveIntent`.
/// Wall-clock time has no public production parser, so a small deterministic
/// Korean time regex lives here.
class VoiceCommandParser {
  const VoiceCommandParser({
    this.structureService = const VoiceScheduleStructureService(),
    this.pipeline = const VoiceCommandPipeline(),
  });

  final VoiceScheduleStructureService structureService;
  final VoiceCommandPipeline pipeline;

  /// Parses [rawText] with [now] as the (already frozen) session reference.
  VoiceCommandOutcome parse(String rawText, {required DateTime now}) {
    final text = rawText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) {
      return VoiceCommandOutcome.unsupported('입력이 비어 있어요.');
    }
    final edit = _parseEdit(text);
    if (edit != null) {
      return edit;
    }
    final query = _parseQuery(text, now);
    if (query != null) {
      return query;
    }
    final add = _parseAdd(text, now);
    if (add != null) {
      return add;
    }
    return VoiceCommandOutcome.unsupported(
      '지금은 날짜와 시간이 모두 담긴 일정 등록, 조회, 시간 변경만 연습할 수 있어요.',
    );
  }

  VoiceCommandOutcome? _parseEdit(String text) {
    final ordinal = _extractOrdinal(text);
    if (ordinal == null || !_hasEditCue(text)) {
      return null;
    }
    final time = extractTourTimeOfDay(text);
    if (time == null) {
      return null;
    }
    return VoiceCommandOutcome.edit(
      VoiceEditTarget(ordinalIndex: ordinal, newTime: time),
    );
  }

  VoiceCommandOutcome? _parseQuery(String text, DateTime now) {
    if (pipeline.resolveIntent(text) != VoiceCommandPipelineIntent.query) {
      return null;
    }
    final range = VoiceDateRangeParser.parse(text, now: now);
    if (range == null) {
      // "일정 보여줘" without a spoken date: default to the frozen today.
      final today = DateTime(now.year, now.month, now.day);
      return VoiceCommandOutcome.query(
        VoiceQueryRange(
          start: today,
          end: today.add(const Duration(days: 1)),
        ),
      );
    }
    return VoiceCommandOutcome.query(
      VoiceQueryRange(start: range.start, end: range.end),
    );
  }

  VoiceCommandOutcome? _parseAdd(String text, DateTime now) {
    // The tour practices complete inputs only: an explicit date AND an
    // explicit wall-clock time are required; anything less is rejected so
    // saved state is never built from guesses.
    final dateRange = VoiceDateRangeParser.parse(text, now: now);
    if (dateRange == null) {
      return null;
    }
    final time = extractTourTimeOfDay(text);
    if (time == null) {
      return null;
    }
    final title = structureService.normalizeLocalVoiceTitle(
      text,
      referenceText: text,
    );
    if (title.trim().isEmpty) {
      return null;
    }
    final location = structureService.normalizeScheduleLocation(
      rawText: text,
      title: title,
    );
    return VoiceCommandOutcome.add(
      VoiceAddDraft(
        title: title,
        date: DateTime(
          dateRange.start.year,
          dateRange.start.month,
          dateRange.start.day,
        ),
        time: time,
        location: location,
      ),
    );
  }

  bool _hasEditCue(String text) {
    return RegExp(
      r'(수정|변경|바꿔|미뤄|밀어|앞당겨|옮겨|이동|고쳐|편집|연기|늦춰|당겨)',
    ).hasMatch(text);
  }

  /// 1..4 ordinals with spacing / Korean-numeral / digit variants.
  int? _extractOrdinal(String text) {
    final match = RegExp(
      r'(첫\s*번째|1\s*번째|첫\s*째)'
      r'|(두\s*번째|2\s*번째|둘\s*째)'
      r'|(세\s*번째|3\s*번째|셋\s*째)'
      r'|(네\s*번째|4\s*번째|넷\s*째)',
    ).firstMatch(text);
    if (match == null) {
      return null;
    }
    final groups = match.groups(<int>[1, 2, 3, 4]);
    for (var i = 0; i < groups.length; i += 1) {
      if (groups[i] != null) {
        return i + 1;
      }
    }
    return null;
  }
}

/// Wall-clock time extraction for the tour. Supports 오전/오후/아침/낮/점심/
/// 저녁/밤/새벽 markers (spacing-insensitive), `N시`, optional `M분` or `반`.
/// A bare hour without a marker keeps its literal value, matching the local
/// deterministic behavior of the production voice conversation controller.
TimeOfDay? extractTourTimeOfDay(String text) {
  final match = RegExp(
    r'(오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*(\d{1,2})\s*시(?:\s*(\d{1,2})\s*분?|\s*반)?',
  ).firstMatch(text);
  if (match == null) {
    return null;
  }
  final meridiem = match.group(1);
  final hour = int.tryParse(match.group(2) ?? '');
  if (hour == null || hour < 0 || hour > 23) {
    return null;
  }
  final minuteGroup = match.group(3);
  final minute = minuteGroup != null ? int.tryParse(minuteGroup) : null;
  final half = (match.group(0) ?? '').contains('반');
  var resolvedHour = hour;
  if (meridiem == '오후' && hour < 12) {
    resolvedHour = hour + 12;
  } else if ((meridiem == '오전' || meridiem == '아침' || meridiem == '새벽') &&
      hour == 12) {
    resolvedHour = 0;
  } else if ((meridiem == '저녁' || meridiem == '밤') && hour < 12) {
    resolvedHour = hour + 12;
  } else if (meridiem == '점심' && hour <= 1) {
    resolvedHour = hour + 12;
  }
  final resolvedMinute = half ? 30 : (minute ?? 0);
  if (resolvedMinute < 0 || resolvedMinute > 59) {
    return null;
  }
  return TimeOfDay(hour: resolvedHour, minute: resolvedMinute);
}

/// Controller-style facade the tutorial screen owns. Keeps the in-memory
/// list, the rendered query list (spoken ordinals bind to it), and staged
/// previews. Commit is always explicit via [savePending].
class VoiceFirstTourController extends ChangeNotifier {
  VoiceFirstTourController({
    DateTime Function()? nowProvider,
    VoiceCommandParser? parser,
  })  : _nowProvider = nowProvider ?? DateTime.now,
        _parser = parser ?? const VoiceCommandParser() {
    // Frozen once per tour session: "tomorrow" stays stable even if the
    // wall clock crosses midnight mid-tour.
    _sessionNow = _nowProvider();
  }

  final DateTime Function() _nowProvider;
  final VoiceCommandParser _parser;
  late final DateTime _sessionNow;

  final List<TourEvent> _events = <TourEvent>[];
  int _nextId = 1;
  List<TourEvent> _lastQueryEvents = const <TourEvent>[];
  VoiceAddDraft? _pendingAdd;
  VoicePendingTimeEdit? _pendingEdit;

  /// Frozen relative-date reference for this tour session.
  DateTime get sessionNow => _sessionNow;

  /// Saved events, unmodifiable, in insertion order.
  List<TourEvent> get events => List<TourEvent>.unmodifiable(_events);

  /// Events rendered by the most recent query, sorted by event time
  /// (ties broken by id). Spoken ordinals bind to THIS list.
  List<TourEvent> get lastQueryEvents =>
      List<TourEvent>.unmodifiable(_lastQueryEvents);

  VoiceAddDraft? get pendingAdd => _pendingAdd;
  VoicePendingTimeEdit? get pendingEdit => _pendingEdit;
  bool get hasPending => _pendingAdd != null || _pendingEdit != null;

  /// Applies one final transcript. A preview stages state for the screen;
  /// saved events are untouched until [savePending].
  VoiceCommandOutcome applyTranscript(String transcript) {
    // Any new utterance supersedes the previous preview.
    _clearPending(notify: false);
    final outcome = _parser.parse(transcript, now: _sessionNow);
    final add = outcome.addDraft;
    if (add != null) {
      _pendingAdd = add;
      notifyListeners();
      return outcome;
    }
    final range = outcome.queryRange;
    if (range != null) {
      final filtered = _events
          .where(
            (event) =>
                !event.eventTime.isBefore(range.start) &&
                event.eventTime.isBefore(range.end),
          )
          .toList()
        ..sort((a, b) {
          final byTime = a.eventTime.compareTo(b.eventTime);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
      _lastQueryEvents = List<TourEvent>.unmodifiable(filtered);
      notifyListeners();
      return outcome;
    }
    final target = outcome.editTarget;
    if (target != null) {
      final event = resolveOrdinal(target.ordinalIndex);
      if (event == null) {
        // No rendered list (or out-of-range ordinal): reject without
        // touching saved state. The user must query first.
        return VoiceCommandOutcome.unsupported(
          '먼저 "일정 보여줘"로 조회한 뒤 몇 번째 일정인지 말씀해 주세요.',
        );
      }
      _pendingEdit = VoicePendingTimeEdit(
        eventId: event.id,
        ordinalIndex: target.ordinalIndex,
        newTime: target.newTime,
        originalEvent: event,
      );
      notifyListeners();
      return outcome;
    }
    return outcome;
  }

  /// Resolves a 1-based spoken ordinal against the rendered query list.
  /// Returns null when nothing was rendered or the ordinal is out of range.
  TourEvent? resolveOrdinal(int ordinalIndex) {
    if (ordinalIndex < 1 || ordinalIndex > _lastQueryEvents.length) {
      return null;
    }
    return _lastQueryEvents[ordinalIndex - 1];
  }

  /// Commits the staged preview exactly once and returns the event id.
  /// Returns null when nothing is staged (covers double-tap / duplicate
  /// finals): saved state is never duplicated by a second call.
  int? savePending() {
    final add = _pendingAdd;
    if (add != null) {
      _pendingAdd = null;
      final id = _nextId;
      _nextId += 1;
      _events.add(
        TourEvent(
          id: id,
          title: add.title,
          eventTime: DateTime(
            add.date.year,
            add.date.month,
            add.date.day,
            add.time.hour,
            add.time.minute,
          ),
          location: add.location,
        ),
      );
      notifyListeners();
      return id;
    }
    final edit = _pendingEdit;
    if (edit != null) {
      _pendingEdit = null;
      final index = _events.indexWhere((event) => event.id == edit.eventId);
      if (index < 0) {
        return null;
      }
      final original = _events[index];
      // Time-only edit: the ORIGINAL date, title and location stay as saved;
      // derived departure/preparation are recomputed on the new instance.
      _events[index] = original.copyWith(
        eventTime: DateTime(
          original.eventTime.year,
          original.eventTime.month,
          original.eventTime.day,
          edit.newTime.hour,
          edit.newTime.minute,
        ),
      );
      // Rendered ordinals are stale after an edit; force a fresh query
      // before the next ordinal-based edit.
      _lastQueryEvents = const <TourEvent>[];
      notifyListeners();
      return edit.eventId;
    }
    return null;
  }

  /// Discards the staged preview (reject path). Saved state is untouched.
  void discardPending() {
    _clearPending();
  }

  /// Clears ALL in-memory practice state: events, staged previews and the
  /// rendered query list. No persistence is touched; ids stay monotonic.
  void restart() {
    _events.clear();
    _lastQueryEvents = const <TourEvent>[];
    _pendingAdd = null;
    _pendingEdit = null;
    notifyListeners();
  }

  TourEvent? findById(int id) {
    for (final event in _events) {
      if (event.id == id) {
        return event;
      }
    }
    return null;
  }

  void _clearPending({bool notify = true}) {
    final hadPending = _pendingAdd != null || _pendingEdit != null;
    _pendingAdd = null;
    _pendingEdit = null;
    if (hadPending && notify) {
      notifyListeners();
    }
  }
}
