import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/recurrence_expansion.dart';
import 'package:planflow/data/models/event_model.dart';

/// [eventHasOccurrenceInRange] / [occurrenceLocalDaysInRange] 테스트.
/// 절대 날짜 리터럴 금지 규칙에 따라 항상 현재 시점 기준 상대 날짜를 쓴다.
void main() {
  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// [from] 이후(포함) 가장 가까운 [weekday] 날짜.
  DateTime onOrAfterWeekday(DateTime from, int weekday) {
    final diff = (weekday - from.weekday) % 7;
    return from.add(Duration(days: diff));
  }

  DateTime dayAt(DateTime date, int hour) =>
      DateTime(date.year, date.month, date.day, hour);

  EventModel singleEvent(DateTime startAt, {DateTime? endAt}) {
    return EventModel(
      id: 'evt-single',
      userId: 'user-1',
      title: '단발',
      startAt: startAt,
      endAt: endAt,
    );
  }

  /// [firstStart]에 시작해 매주 같은 요일 반복되는 WEEKLY 일정.
  EventModel weeklyEvent(DateTime firstStart, {List<DateTime>? deleted}) {
    return EventModel(
      id: 'evt-weekly',
      userId: 'user-1',
      title: '반복 회의',
      startAt: firstStart,
      recurrenceRule: 'FREQ=WEEKLY;BYDAY='
          '${['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'][firstStart.weekday - 1]}',
      deletedOccurrenceDates: deleted,
    );
  }

  group('eventHasOccurrenceInRange', () {
    test('단발 일정은 anchor startAt이 범위 안에 들면 true', () {
      final day = today().add(const Duration(days: 5));
      final event = singleEvent(dayAt(day, 10));
      expect(
        eventHasOccurrenceInRange(event, day, day.add(const Duration(days: 1))),
        isTrue,
      );
    });

    test('단발 일정이 범위 밖이면 false', () {
      final day = today().add(const Duration(days: 5));
      final event = singleEvent(dayAt(day, 10));
      final other = today().add(const Duration(days: 20));
      expect(
        eventHasOccurrenceInRange(
          event,
          other,
          other.add(const Duration(days: 1)),
        ),
        isFalse,
      );
    });

    test('반복 일정은 앵커가 범위 밖이어도 범위 안의 회차가 있으면 true', () {
      // 매주 수요일 반복. 앵커는 3일 뒤 이후 첫 수요일, 매칭 범위는
      // 앵커 다음 주(앵커 제외) 하루 — 회차 확정성을 위해 앵커+7일 하루로.
      final first = onOrAfterWeekday(
        today().add(const Duration(days: 3)),
        DateTime.wednesday,
      );
      final anchorStart = dayAt(first, 9);
      final secondOccurrence = first.add(const Duration(days: 7));
      final event = weeklyEvent(anchorStart);
      expect(
        eventHasOccurrenceInRange(
          event,
          secondOccurrence,
          secondOccurrence.add(const Duration(days: 1)),
        ),
        isTrue,
      );
    });

    test('삭제된 회차(deletedOccurrenceDates)는 매칭하지 않는다', () {
      final first = onOrAfterWeekday(
        today().add(const Duration(days: 3)),
        DateTime.wednesday,
      );
      final targetWeek = today().add(const Duration(days: 10));
      // targetWeek와 first 사이의 회차들을 계산해 모두 삭제 처리.
      final deleted = <DateTime>[];
      var cursor = first;
      final limit = targetWeek.add(const Duration(days: 1));
      while (cursor.isBefore(limit)) {
        deleted.add(DateTime(cursor.year, cursor.month, cursor.day));
        cursor = cursor.add(const Duration(days: 7));
      }
      final event = weeklyEvent(dayAt(first, 9), deleted: deleted);
      expect(
        eventHasOccurrenceInRange(
          event,
          targetWeek,
          targetWeek.add(const Duration(days: 1)),
        ),
        isFalse,
      );
    });

    test('반복 일정이어도 범위 안에 회차가 없으면 false', () {
      final first = onOrAfterWeekday(
        today().add(const Duration(days: 3)),
        DateTime.wednesday,
      );
      // 회차 확정성을 위해 두 번째 회차의 '다음 날' 하루로 검사한다.
      final afterSecond = first.add(const Duration(days: 8));
      final event = weeklyEvent(dayAt(first, 9));
      expect(
        eventHasOccurrenceInRange(
          event,
          afterSecond,
          afterSecond.add(const Duration(days: 1)),
        ),
        isFalse,
      );
    });
  });

  group('occurrenceLocalDaysInRange', () {
    test('범위 안 회차들의 local-day 날짜를 오름차순으로 반환한다', () {
      final first = onOrAfterWeekday(
        today().add(const Duration(days: 3)),
        DateTime.wednesday,
      );
      final event = weeklyEvent(dayAt(first, 9));
      final rangeStart = first;
      final rangeEnd = first.add(const Duration(days: 15));
      final days = occurrenceLocalDaysInRange(
        event: event,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      );
      // 15일 범위의 매주 반복이므로 2~3개 회차.
      expect(days.length, inInclusiveRange(2, 3));
      expect(days, equals(days.toList()..sort()));
      for (final day in days) {
        expect(day.hour, 0);
        expect(day.minute, 0);
        expect(day.weekday, DateTime.wednesday);
      }
      expect(days.first, DateTime(first.year, first.month, first.day));
    });

    test('단발 일정은 anchor 날짜 하나만 반환한다', () {
      final day = today().add(const Duration(days: 5));
      final days = occurrenceLocalDaysInRange(
        event: singleEvent(dayAt(day, 10)),
        rangeStart: day,
        rangeEnd: day.add(const Duration(days: 1)),
      );
      expect(days, [DateTime(day.year, day.month, day.day)]);
    });

    test('범위 밖이면 빈 리스트', () {
      final first = onOrAfterWeekday(
        today().add(const Duration(days: 3)),
        DateTime.wednesday,
      );
      final far = today().add(const Duration(days: 40));
      expect(
        occurrenceLocalDaysInRange(
          event: weeklyEvent(dayAt(first, 9)),
          rangeStart: far,
          rangeEnd: far.add(const Duration(days: 1)),
        ),
        isEmpty,
      );
    });
  });
}
