import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/recurrence_expansion.dart';
import 'package:planflow/data/models/event_model.dart';

EventModel _event({
  String id = 'evt-1',
  DateTime? startAt,
  DateTime? endAt,
  String? recurrenceRule,
  String? parentEventId,
  DateTime? overriddenOccurrenceDate,
  String title = '테스트 일정',
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt,
    endAt: endAt,
    recurrenceRule: recurrenceRule,
    parentEventId: parentEventId,
    overriddenOccurrenceDate: overriddenOccurrenceDate,
  );
}

/// 테스트 전용 날짜 헬퍼 — 절대 날짜 리터럴 대신 항상 현재 시점 기준
/// 미래로 계산해 시한폭탄(클램프/만료 로직에 걸려 나중에 깨짐)을 막는다.
///
/// [daysFromNow]만큼 떨어진 자정 시각(시/분/초 없음)을 반환한다. 기본값
/// 400일은 프로덕션 코드의 어떤 "과거로 취급" 판정에도 걸리지 않을 만큼
/// 충분히 먼 미래다.
DateTime _futureDate({int daysFromNow = 400}) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day)
      .add(Duration(days: daysFromNow));
}

/// [from] 이후(포함) 가장 가까운 [weekday](`DateTime.monday` 등) 날짜를
/// day-offset 연산만으로 계산한다. 연/월/일을 직접 하드코딩해 요일을
/// 맞추면 연도가 바뀔 때마다 요일이 어긋나므로(달력 드리프트), BYDAY 기반
/// 기대값은 반드시 이 방식으로 구해야 한다.
DateTime _onOrAfterWeekday(DateTime from, int weekday) {
  final diff = (weekday - from.weekday) % 7;
  return from.add(Duration(days: diff));
}

/// 날짜(연/월/일)는 유지하고 시(hour)만 붙인다.
DateTime _withHour(DateTime date, int hour) {
  return DateTime(date.year, date.month, date.day, hour);
}

/// RRULE의 `UNTIL=YYYYMMDDT000000Z` 값을 [date] 기준으로 생성한다.
String _untilRuleValue(DateTime date) {
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(date.year, 4)}${pad(date.month, 2)}${pad(date.day, 2)}T000000Z';
}

void main() {
  group('expandRecurringEvent', () {
    test('WEEKLY + BYDAY 반복이 범위 안에서 올바른 요일에 회차 생성', () {
      // 매주 월/수요일 반복. 요일 계산이 연도가 바뀌어도 항상 올바르도록
      // "미래의 가장 가까운 월요일"을 anchor로 잡고, 기대 회차는 그 anchor에
      // day-offset만 더해 구한다(달력 월/일을 직접 하드코딩하지 않는다).
      final monday = _onOrAfterWeekday(_futureDate(), DateTime.monday);
      final event = _event(
        startAt: _withHour(monday, 9),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,WE',
      );

      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: monday.subtract(const Duration(days: 2)),
        rangeEnd: monday.add(const Duration(days: 12)),
      );

      final days = occurrences
          .map((e) => e.startAt!)
          .map((d) => DateTime(d.year, d.month, d.day))
          .toList()
        ..sort((a, b) => a.compareTo(b));

      expect(days, <DateTime>[
        monday, // 월
        monday.add(const Duration(days: 2)), // 수
        monday.add(const Duration(days: 7)), // 월
        monday.add(const Duration(days: 9)), // 수
      ]);
      for (final occurrence in occurrences) {
        expect(occurrence.startAt!.hour, 9);
        expect(occurrence.recurrenceRule, event.recurrenceRule);
      }
    });

    test('DAILY 반복이 범위 안 매일 회차를 생성한다', () {
      final anchor = _futureDate();
      final event = _event(
        startAt: _withHour(anchor, 8),
        recurrenceRule: 'FREQ=DAILY',
      );

      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: anchor,
        rangeEnd: anchor.add(const Duration(days: 5)),
      );

      final days = occurrences
          .map((e) => DateTime(e.startAt!.year, e.startAt!.month, e.startAt!.day))
          .toList()
        ..sort((a, b) => a.compareTo(b));

      expect(
        days,
        List<DateTime>.generate(5, (i) => anchor.add(Duration(days: i))),
      );
    });

    test('MONTHLY 반복이 같은 날짜(일)에 회차를 생성한다', () {
      // MONTHLY는 요일과 무관하므로(같은 일(day)만 유지) 연도만 미래로
      // 고정한다.
      final baseYear = DateTime.now().year + 2;
      final event = _event(
        startAt: DateTime(baseYear, 1, 15, 10),
        recurrenceRule: 'FREQ=MONTHLY',
      );

      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: DateTime(baseYear, 3, 1),
        rangeEnd: DateTime(baseYear, 6, 1),
      );

      final days = occurrences
          .map((e) => DateTime(e.startAt!.year, e.startAt!.month, e.startAt!.day))
          .toList()
        ..sort((a, b) => a.compareTo(b));

      expect(days, <DateTime>[
        DateTime(baseYear, 3, 15),
        DateTime(baseYear, 4, 15),
        DateTime(baseYear, 5, 15),
      ]);
    });

    test('YEARLY 반복이 같은 월/일에 회차를 생성한다', () {
      // YEARLY도 요일과 무관하므로 연도만 미래로 고정한다.
      final baseYear = DateTime.now().year + 2;
      final event = _event(
        startAt: DateTime(baseYear - 2, 8, 3, 10),
        recurrenceRule: 'FREQ=YEARLY',
      );

      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: DateTime(baseYear, 1, 1),
        rangeEnd: DateTime(baseYear + 2, 12, 31),
      );

      final days = occurrences
          .map((e) => DateTime(e.startAt!.year, e.startAt!.month, e.startAt!.day))
          .toList()
        ..sort((a, b) => a.compareTo(b));

      expect(days, <DateTime>[
        DateTime(baseYear, 8, 3),
        DateTime(baseYear + 1, 8, 3),
        DateTime(baseYear + 2, 8, 3),
      ]);
    });

    test('INTERVAL > 1 (2주마다) 반복이 격주로 회차를 생성한다', () {
      // BYDAY 없는 WEEKLY는 요일과 무관(7*interval일 간격)하므로 day-offset만
      // 맞으면 된다.
      final anchor = _futureDate();
      final event = _event(
        startAt: _withHour(anchor, 9),
        recurrenceRule: 'FREQ=WEEKLY;INTERVAL=2',
      );

      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: anchor.subtract(const Duration(days: 2)),
        rangeEnd: anchor.add(const Duration(days: 43)),
      );

      final days = occurrences
          .map((e) => DateTime(e.startAt!.year, e.startAt!.month, e.startAt!.day))
          .toList()
        ..sort((a, b) => a.compareTo(b));

      expect(days, <DateTime>[
        anchor,
        anchor.add(const Duration(days: 14)),
        anchor.add(const Duration(days: 28)),
        anchor.add(const Duration(days: 42)),
      ]);
    });

    test('UNTIL 경계 이후에는 회차가 생성되지 않는다', () {
      final anchor = _futureDate();
      // UNTIL=anchor+7일 -> anchor+7일 포함, 그 다음날부터 제외(hardEnd는
      // UNTIL+1일이므로 anchor+8일 자정 미만까지만 포함).
      final untilDate = anchor.add(const Duration(days: 7));
      final event = _event(
        startAt: _withHour(anchor, 9),
        recurrenceRule: 'FREQ=DAILY;UNTIL=${_untilRuleValue(untilDate)}',
      );

      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: anchor.subtract(const Duration(days: 2)),
        rangeEnd: anchor.add(const Duration(days: 28)),
      );

      final lastDay = occurrences
          .map((e) => DateTime(e.startAt!.year, e.startAt!.month, e.startAt!.day))
          .reduce((a, b) => a.isAfter(b) ? a : b);

      expect(lastDay, untilDate);
      expect(
        occurrences.any((e) => e.startAt!.isAfter(
              untilDate.add(
                const Duration(hours: 23, minutes: 59, seconds: 59),
              ),
            )),
        isFalse,
      );
    });

    test('범위 밖이면 빈 리스트를 반환한다(anchor 폴백 없음)', () {
      // 매주 월요일 반복이지만 조회 범위가 반복 시작(anchor)보다 훨씬 이전
      // (400~370일 전 구간)이라 범위 안에 회차가 전혀 없다. 실제 달력상
      // "과거"인지는 중요하지 않다 — anchor보다 앞선 구간이라는 상대적
      // 관계만 유지하면 된다.
      final anchor = _futureDate();
      final farPastRangeStart = anchor.subtract(const Duration(days: 400));
      final farPastRangeEnd = anchor.subtract(const Duration(days: 370));

      final event = _event(
        startAt: _withHour(anchor, 9),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO',
      );

      final occurrencesByDay = expandRecurringEvent(
        event: event,
        rangeStart: farPastRangeStart,
        rangeEnd: farPastRangeEnd,
      );
      expect(occurrencesByDay, isEmpty);

      // BYDAY 없는 일반 루프 경로(DAILY)도 동일하게 빈 리스트여야 한다.
      final dailyEvent = _event(
        startAt: _withHour(anchor, 9),
        recurrenceRule: 'FREQ=DAILY',
      );
      final occurrencesDaily = expandRecurringEvent(
        event: dailyEvent,
        rangeStart: farPastRangeStart,
        rangeEnd: farPastRangeEnd,
      );
      expect(occurrencesDaily, isEmpty);
    });

    test('비반복 일정(recurrence_rule 없음)은 원본 이벤트를 그대로 반환한다', () {
      final anchor = _futureDate();
      final rangeStart = anchor.subtract(const Duration(days: 2));
      final rangeEnd = anchor.add(const Duration(days: 28));

      final event = _event(
        startAt: _withHour(anchor, 9),
        recurrenceRule: null,
      );

      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      );

      expect(occurrences, <EventModel>[event]);

      // 빈 문자열 recurrenceRule도 "반복 없음"과 동일하게 취급된다.
      final emptyRuleEvent = _event(
        startAt: _withHour(anchor, 9),
        recurrenceRule: '',
      );
      final emptyRuleOccurrences = expandRecurringEvent(
        event: emptyRuleEvent,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      );
      expect(emptyRuleOccurrences, <EventModel>[emptyRuleEvent]);

      // startAt이 없으면 반복 규칙이 있어도 원본 그대로 반환한다.
      final noStartEvent = _event(
        startAt: null,
        recurrenceRule: 'FREQ=DAILY',
      );
      final noStartOccurrences = expandRecurringEvent(
        event: noStartEvent,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      );
      expect(noStartOccurrences, <EventModel>[noStartEvent]);
    });

    test('includeOccurrence 콜백을 주입하면 그 판정을 그대로 사용한다', () {
      final anchor = _futureDate();
      final event = _event(
        startAt: _withHour(anchor, 9),
        recurrenceRule: 'FREQ=DAILY',
      );

      // 항상 false를 반환하는 콜백을 주입하면 회차가 전부 걸러져야 한다.
      final occurrences = expandRecurringEvent(
        event: event,
        rangeStart: anchor.subtract(const Duration(days: 2)),
        rangeEnd: anchor.add(const Duration(days: 7)),
        includeOccurrence: (occurrence, rangeStart, rangeEnd) => false,
      );

      expect(occurrences, isEmpty);
    });
  });

  group('hideOverriddenRecurringOccurrences', () {
    test('override된 원본 회차(overriddenOccurrenceDate)를 목록에서 숨긴다', () {
      final anchor = _futureDate();
      final originalOccurrence = _event(
        id: 'occ-1',
        startAt: _withHour(anchor, 9),
      );
      final unrelatedOccurrence = _event(
        id: 'occ-2',
        startAt: _withHour(anchor.add(const Duration(days: 7)), 9),
      );
      // 예외 이벤트: 원래 회차를 대체하되, 실제 시각은 다른 날(anchor+1일)로
      // 옮겨졌다. overriddenOccurrenceDate로 매칭해야 원본이 숨겨진다.
      final overrideEvent = _event(
        id: 'override-1',
        startAt: _withHour(anchor.add(const Duration(days: 1)), 15),
        parentEventId: originalOccurrence.id,
        overriddenOccurrenceDate: _withHour(anchor, 9),
      );

      final result = hideOverriddenRecurringOccurrences(<EventModel>[
        originalOccurrence,
        unrelatedOccurrence,
        overrideEvent,
      ]);

      expect(result, contains(overrideEvent));
      expect(result, contains(unrelatedOccurrence));
      expect(result, isNot(contains(originalOccurrence)));
    });

    test('override가 없으면 원본 목록을 그대로 반환한다', () {
      final anchor = _futureDate();
      final events = <EventModel>[
        _event(id: 'a', startAt: _withHour(anchor, 9)),
        _event(
          id: 'b',
          startAt: _withHour(anchor.add(const Duration(days: 1)), 9),
        ),
      ];

      final result = hideOverriddenRecurringOccurrences(events);

      expect(result, events);
    });
  });
}
