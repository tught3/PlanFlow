import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_event_recurrence.dart';

GroupEventModel _event({
  required DateTime startAt,
  required DateTime endAt,
  String recurrenceType = 'none',
  DateTime? recurrenceUntil,
}) {
  return GroupEventModel(
    id: 'event-1',
    groupId: 'group-1',
    title: '팀 회의',
    startAt: startAt,
    endAt: endAt,
    recurrenceType: recurrenceType,
    recurrenceUntil: recurrenceUntil,
    createdBy: 'user-1',
  );
}

void main() {
  // KST(UTC+9) 기준 2026-06-02 10:00 시작 일정.
  final start = DateTime.utc(2026, 6, 2, 1);
  final end = DateTime.utc(2026, 6, 2, 2);
  // KST 2026-06-01 00:00 ~ 2026-07-01 00:00 (한 달)
  final monthStartUtc = DateTime.utc(2026, 5, 31, 15);
  final monthEndUtc = DateTime.utc(2026, 6, 30, 15);

  group('groupEventOccursOnLocalDay', () {
    test('non-recurring only on its own local day', () {
      final event = _event(startAt: start, endAt: end);
      expect(
        groupEventOccursOnLocalDay(event, DateTime(2026, 6, 2)),
        isTrue,
      );
      expect(
        groupEventOccursOnLocalDay(event, DateTime(2026, 6, 9)),
        isFalse,
      );
    });

    test('weekly matches the same weekday only', () {
      final event = _event(
        startAt: start,
        endAt: end,
        recurrenceType: 'weekly',
      );
      final startWeekday = planflowLocalDay(start).weekday;
      // 같은 요일(다음 주) → true
      expect(
        groupEventOccursOnLocalDay(event, DateTime(2026, 6, 9)),
        isTrue,
      );
      expect(DateTime(2026, 6, 9).weekday, startWeekday);
      // 다른 요일 → false
      expect(
        groupEventOccursOnLocalDay(event, DateTime(2026, 6, 10)),
        isFalse,
      );
      // 시작 전 → false
      expect(
        groupEventOccursOnLocalDay(event, DateTime(2026, 5, 26)),
        isFalse,
      );
    });

    test('respects recurrence_until', () {
      final event = _event(
        startAt: start,
        endAt: end,
        recurrenceType: 'weekly',
        recurrenceUntil: DateTime.utc(2026, 6, 16, 2),
      );
      expect(groupEventOccursOnLocalDay(event, DateTime(2026, 6, 16)), isTrue);
      expect(groupEventOccursOnLocalDay(event, DateTime(2026, 6, 23)), isFalse);
    });
  });

  group('expandGroupEventOccurrences', () {
    test('non-recurring returns self when intersecting range', () {
      final event = _event(startAt: start, endAt: end);
      expect(
        expandGroupEventOccurrences(event, monthStartUtc, monthEndUtc),
        hasLength(1),
      );
      // 구간 밖
      expect(
        expandGroupEventOccurrences(
          event,
          DateTime.utc(2026, 7, 1),
          DateTime.utc(2026, 7, 31),
        ),
        isEmpty,
      );
    });

    test('weekly expands to every matching weekday in range', () {
      final event = _event(
        startAt: start,
        endAt: end,
        recurrenceType: 'weekly',
      );
      final occurrences =
          expandGroupEventOccurrences(event, monthStartUtc, monthEndUtc);
      // 6/2, 6/9, 6/16, 6/23, 6/30 → 5회
      expect(occurrences, hasLength(5));
      final startWeekday = planflowLocalDay(start).weekday;
      for (final occ in occurrences) {
        expect(planflowLocalDay(occ.startAt).weekday, startWeekday);
        // 길이(1시간) 유지
        expect(occ.endAt.difference(occ.startAt), const Duration(hours: 1));
      }
    });

    test('daily expands to each day in range', () {
      final event = _event(
        startAt: start,
        endAt: end,
        recurrenceType: 'daily',
      );
      // 6/2 ~ 6/8 (KST) 범위
      final occurrences = expandGroupEventOccurrences(
        event,
        DateTime.utc(2026, 6, 1, 15),
        DateTime.utc(2026, 6, 8, 15),
      );
      expect(occurrences, hasLength(7));
    });

    test('monthly skips months without the start day', () {
      final janStart = DateTime.utc(2026, 1, 31, 1);
      final event = _event(
        startAt: janStart,
        endAt: DateTime.utc(2026, 1, 31, 2),
        recurrenceType: 'monthly',
      );
      // 1월~4월 KST 범위: 1/31, 3/31 발생, 2월은 31일 없음 → 제외
      final occurrences = expandGroupEventOccurrences(
        event,
        DateTime.utc(2025, 12, 31, 15),
        DateTime.utc(2026, 4, 30, 15),
      );
      final days = occurrences
          .map((occ) => planflowLocalDay(occ.startAt))
          .toList(growable: false);
      expect(days.any((d) => d.month == 2), isFalse);
      expect(days.any((d) => d.month == 1 && d.day == 31), isTrue);
      expect(days.any((d) => d.month == 3 && d.day == 31), isTrue);
    });

    test('weekly stops at recurrence_until', () {
      final event = _event(
        startAt: start,
        endAt: end,
        recurrenceType: 'weekly',
        recurrenceUntil: DateTime.utc(2026, 6, 16, 2),
      );
      final occurrences =
          expandGroupEventOccurrences(event, monthStartUtc, monthEndUtc);
      // 6/2, 6/9, 6/16 → 3회
      expect(occurrences, hasLength(3));
    });
  });
}
