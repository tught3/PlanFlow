import '../data/models/event_model.dart';
import 'local_time.dart';

/// 반복 일정(recurrence_rule) 확장 + override 숨김 공유 유틸.
///
/// `calendar_screen.dart`에 있던 `_expandRecurringEvent` /
/// `_hideOverriddenRecurringOccurrences` 로직을 그대로(안전 카운터·경계
/// 계산 포함) 이식한 것이다. 다만 원본에 있던 "범위 안에 회차가 0개면
/// 원본 anchor 이벤트를 그대로 돌려주는" 폴백은 이 유틸에서는 제거했다
/// (그 fallback을 유지하면 "범위 안에 회차가 있는지" 판정하려는 호출자가
/// 항상 true를 받는 반대 방향 버그가 생긴다). 범위 밖이면 빈 리스트를
/// 반환한다.
///
/// 캘린더 화면 전용 술어([_calendarDisplayEndDay] 기반의
/// `_eventIntersectsRange`)는 이 유틸로 옮기지 않았다 — 대신
/// [includeOccurrence] 콜백으로 주입받는다. 호출자가 주입하지 않으면
/// 기본 판정([_defaultIncludeOccurrence])을 사용한다.

/// 반복 규칙(FREQ/INTERVAL/UNTIL/BYDAY)에 따라 [rangeStart] ~ [rangeEnd]
/// 범위 안에 실제로 존재하는 회차들을 생성해 반환한다.
///
/// - [event]에 반복 규칙이 없으면(`recurrenceRule`이 비어있거나 `startAt`이
///   없으면) 원본 이벤트를 그대로 담은 `[event]`를 반환한다(반복이 아닌
///   이벤트는 "확장"할 것이 없으므로 anchor를 그대로 돌려주는 것이 맞다 —
///   범위 필터링은 이 함수의 책임이 아니다, 원본 `calendar_screen.dart`의
///   동작과 동일).
/// - 반복 규칙이 있는데 범위 안에 생성된 회차가 없으면 **빈 리스트**를
///   반환한다(anchor 폴백 없음).
/// - [includeOccurrence]는 각 후보 회차가 범위에 포함되는지 판정하는
///   술어다. 지정하지 않으면 [_defaultIncludeOccurrence](단순 시작/종료
///   구간 겹침 판정)를 사용한다.
List<EventModel> expandRecurringEvent({
  required EventModel event,
  required DateTime rangeStart,
  required DateTime rangeEnd,
  bool Function(EventModel occurrence, DateTime rangeStart, DateTime rangeEnd)?
      includeOccurrence,
}) {
  final include = includeOccurrence ?? _defaultIncludeOccurrence;

  final rule = event.recurrenceRule?.toUpperCase();
  final startAt = event.startAt;
  if (rule == null || rule.isEmpty || startAt == null) {
    return <EventModel>[event];
  }

  final freq = RegExp(r'FREQ=([A-Z]+)').firstMatch(rule)?.group(1);
  if (freq == null) {
    return <EventModel>[event];
  }

  final intervalText = RegExp(r'INTERVAL=(\d+)').firstMatch(rule)?.group(1);
  final interval = int.tryParse(intervalText ?? '1')?.clamp(1, 365) ?? 1;
  final until = _parseRRuleUntil(
    RegExp(r'UNTIL=([0-9TzZ]+)').firstMatch(rule)?.group(1),
  );
  final hardEnd = until?.isBefore(rangeEnd) == true ? until! : rangeEnd;
  final localStartAt = planflowLocal(startAt);
  final duration = event.endAt?.difference(startAt);
  final occurrences = <EventModel>[];

  if (freq == 'WEEKLY') {
    final byDays = _parseRRuleByDays(rule);
    if (byDays.isNotEmpty) {
      var weekStart = DateTime(
        localStartAt.year,
        localStartAt.month,
        localStartAt.day,
        localStartAt.hour,
        localStartAt.minute,
        localStartAt.second,
      ).subtract(Duration(days: localStartAt.weekday - DateTime.monday));
      var safety = 0;
      while (weekStart.isBefore(hardEnd) && safety < 120) {
        safety += 1;
        for (final weekday in byDays) {
          final day = weekStart.add(Duration(days: weekday - DateTime.monday));
          final current = DateTime(
            day.year,
            day.month,
            day.day,
            localStartAt.hour,
            localStartAt.minute,
            localStartAt.second,
          );
          if (current.isBefore(localStartAt) || !current.isBefore(hardEnd)) {
            continue;
          }
          final occurrenceEnd = duration == null ? null : current.add(duration);
          final candidate = _copyEventWithTime(
            event,
            startAt: current,
            endAt: occurrenceEnd,
          );
          if (include(candidate, rangeStart, rangeEnd)) {
            occurrences.add(candidate);
          }
        }
        weekStart = weekStart.add(Duration(days: 7 * interval));
      }
      return occurrences;
    }
  }

  var current = localStartAt;
  var safety = 0;
  while (current.isBefore(hardEnd) && safety < 420) {
    safety += 1;
    final occurrenceEnd = duration == null ? null : current.add(duration);
    final candidate = _copyEventWithTime(
      event,
      startAt: current,
      endAt: occurrenceEnd,
    );
    if (include(candidate, rangeStart, rangeEnd)) {
      occurrences.add(candidate);
    }
    current = switch (freq) {
      'DAILY' => current.add(Duration(days: interval)),
      'WEEKLY' => current.add(Duration(days: 7 * interval)),
      'MONTHLY' => DateTime(
          current.year,
          current.month + interval,
          current.day,
          current.hour,
          current.minute,
          current.second,
        ),
      'YEARLY' => DateTime(
          current.year + interval,
          current.month,
          current.day,
          current.hour,
          current.minute,
          current.second,
        ),
      _ => hardEnd,
    };
  }
  return occurrences;
}

/// [includeOccurrence]가 주어지지 않았을 때 쓰는 기본 범위 판정.
///
/// `calendar_screen.dart`의 `_eventIntersectsRange`처럼
/// `_calendarDisplayEndDay`(화면 표시용 종료일 보정)에 의존하지 않는,
/// 단순한 시작/종료 구간 겹침 판정이다: 회차의 시작이 [rangeEnd] 이전이고
/// 종료(없으면 시작과 동일)가 [rangeStart] 이후(또는 같음)면 포함한다.
bool _defaultIncludeOccurrence(
  EventModel occurrence,
  DateTime rangeStart,
  DateTime rangeEnd,
) {
  final startAt = occurrence.startAt;
  if (startAt == null) {
    return false;
  }
  final endAt = occurrence.endAt ?? startAt;
  return startAt.isBefore(rangeEnd) && !endAt.isBefore(rangeStart);
}

/// override(단일 회차 예외)된 원본 회차를 [events] 목록에서 숨긴다.
///
/// 예외 이벤트(`parentEventId` + `overriddenOccurrenceDate`가 있는 이벤트)가
/// 대체하는 원본 회차 날짜로 매칭한다. 예외 이벤트의 현재 `startAt`(=새로
/// 옮긴 날짜)이 아니라 `overriddenOccurrenceDate`로 매칭해야, 회차 날짜
/// 자체를 바꾼 예외도 원본 회차를 정확히 숨길 수 있다.
List<EventModel> hideOverriddenRecurringOccurrences(
  List<EventModel> events,
) {
  final overrides = events
      .where((event) =>
          event.parentEventId != null &&
          event.parentEventId!.trim().isNotEmpty &&
          event.overriddenOccurrenceDate != null)
      .toList(growable: false);
  if (overrides.isEmpty) {
    return events;
  }
  return events.where((event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return true;
    }
    final isOverridden = overrides.any((override) {
      if (override.parentEventId != event.id) {
        return false;
      }
      final overriddenDate = override.overriddenOccurrenceDate;
      return overriddenDate != null &&
          planflowIsSameLocalDay(overriddenDate, startAt);
    });
    return !isOverridden;
  }).toList(growable: false);
}

DateTime? _parseRRuleUntil(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  final normalized = value.replaceAll('Z', '');
  if (normalized.length < 8) {
    return null;
  }
  final year = int.tryParse(normalized.substring(0, 4));
  final month = int.tryParse(normalized.substring(4, 6));
  final day = int.tryParse(normalized.substring(6, 8));
  if (year == null || month == null || day == null) {
    return null;
  }
  return DateTime(year, month, day).add(const Duration(days: 1));
}

List<int> _parseRRuleByDays(String rule) {
  final raw = RegExp(r'BYDAY=([A-Z0-9,\-]+)').firstMatch(rule)?.group(1);
  if (raw == null || raw.isEmpty) {
    return const <int>[];
  }
  return raw
      .split(',')
      .map((item) => item.replaceAll(RegExp(r'[-0-9]'), ''))
      .map((item) => switch (item) {
            'MO' => DateTime.monday,
            'TU' => DateTime.tuesday,
            'WE' => DateTime.wednesday,
            'TH' => DateTime.thursday,
            'FR' => DateTime.friday,
            'SA' => DateTime.saturday,
            'SU' => DateTime.sunday,
            _ => null,
          })
      .whereType<int>()
      .toList(growable: false);
}

EventModel _copyEventWithTime(
  EventModel event, {
  required DateTime startAt,
  DateTime? endAt,
}) {
  return EventModel(
    id: event.id,
    userId: event.userId,
    title: event.title,
    startAt: startAt,
    endAt: endAt,
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
