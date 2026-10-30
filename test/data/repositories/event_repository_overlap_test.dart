import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/recurrence_expansion.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';

void main() {
  group('monthly overlap expansion', () {
    EventModel monthlyEvent(DateTime start, String rule) {
      final startUtc = planflowLocalDateTimeToUtc(start);
      return EventModel(
        id: 'monthly-seed',
        userId: 'user-1',
        title: '월간 회의',
        startAt: startUtc,
        endAt: startUtc.add(const Duration(hours: 1)),
        recurrenceRule: rule,
      );
    }

    DateTime localStart(EventModel occurrence) {
      final start = occurrence.startAt!;
      return start.isUtc ? planflowLocal(start) : start;
    }

    List<DateTime> localStarts(
      EventModel event,
      DateTime start,
      DateTime end,
    ) => expandEventOccurrencesForOverlap(
      event,
      rangeStart: start,
      rangeEnd: end,
    ).map(localStart).toList();

    test('O1 last Friday occurs on November 27', () {
      final event = monthlyEvent(
        DateTime(2026, 10, 30, 10), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY;BYDAY=-1FR',
      );
      final start = DateTime(2026, 11, 27); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final end = DateTime(2026, 11, 28); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final expected = DateTime(2026, 11, 27, 10); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      expect(
        localStarts(event, start, end).where((date) => date == expected),
        hasLength(1),
      );
    });

    test('O2 last Friday does not occur on November 30', () {
      final event = monthlyEvent(
        DateTime(2026, 10, 30, 10), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY;BYDAY=-1FR',
      );
      final start = DateTime(2026, 11, 30); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final end = DateTime(2026, 12, 1); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      expect(
        localStarts(event, start, end).where(
          (date) =>
              date.year == start.year &&
              date.month == start.month &&
              date.day == start.day,
        ),
        isEmpty,
      );
    });

    test('O3 last Fridays in January and February', () {
      final event = monthlyEvent(
        DateTime(2026, 10, 30, 10), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY;BYDAY=-1FR',
      );
      final dates = <DateTime>[
        DateTime(2027, 1, 29, 10), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        DateTime(2027, 2, 26, 10), // banned-ok: Fixed calendar regression fixture; independent of current clock.
      ];
      for (final expected in dates) {
        final start = DateTime(expected.year, expected.month, expected.day);
        final end = start.add(const Duration(days: 1));
        expect(
          localStarts(event, start, end).where((date) => date == expected),
          hasLength(1),
        );
      }
    });

    test('O4 skips February when the monthly anchor is the 31st', () {
      final event = monthlyEvent(
        DateTime(2026, 1, 31, 9), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY',
      );
      final start = DateTime(2026, 2, 28); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final end = DateTime(2026, 3, 1); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      expect(
        localStarts(
          event,
          start,
          end,
        ).where((date) => !date.isBefore(start) && date.isBefore(end)),
        isEmpty,
      );
    });

    test('O5 returns March 31 for a monthly 31st anchor', () {
      final event = monthlyEvent(
        DateTime(2026, 1, 31, 9), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY',
      );
      final start = DateTime(2026, 3, 31); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final end = DateTime(2026, 4, 1); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final expected = DateTime(2026, 3, 31, 9); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      expect(
        localStarts(event, start, end).where((date) => date == expected),
        hasLength(1),
      );
    });

    test('O6 does not drift from the 31st to April 3', () {
      final event = monthlyEvent(
        DateTime(2026, 1, 31, 9), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY',
      );
      final start = DateTime(2026, 4, 3); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final end = DateTime(2026, 4, 4); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      expect(
        localStarts(event, start, end).where(
          (date) =>
              date.year == start.year &&
              date.month == start.month &&
              date.day == start.day,
        ),
        isEmpty,
      );
    });

    test('O7 invalid BYMONTHDAY keeps the monthly fallback', () {
      final event = monthlyEvent(
        DateTime(2026, 1, 20, 10), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY;BYMONTHDAY=32',
      );
      final start = DateTime(2026, 3, 20); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final end = DateTime(2026, 3, 21); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final expected = DateTime(2026, 3, 20, 10); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      expect(
        localStarts(event, start, end).where((date) => date == expected),
        hasLength(1),
      );
    });

    test('O8 agrees with the app recurrence expander', () {
      final event = monthlyEvent(
        DateTime(2026, 10, 30, 10), // banned-ok: Fixed calendar regression fixture; independent of current clock.
        'FREQ=MONTHLY;BYDAY=-1FR',
      );
      final start = DateTime(2026, 11, 1); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final end = DateTime(2027, 3, 1); // banned-ok: Fixed calendar regression fixture; independent of current clock.
      final appStarts = expandRecurringEvent(
        event: event,
        rangeStart: start,
        rangeEnd: end,
        includeOccurrence: (occurrence, rangeStart, rangeEnd) =>
            eventRangesOverlap(
              rangeStart: rangeStart,
              rangeEnd: rangeEnd,
              eventStart: occurrence.startAt!,
              eventEnd: occurrence.endAt!,
            ),
      ).map(localStart).toList();
      expect(localStarts(event, start, end), appStarts);
    });
  });

  test('eventRangesOverlap keeps adjacent ranges separate', () {
    final rangeStart = DateTime.utc(2026, 5, 5, 1);
    final rangeEnd = DateTime.utc(2026, 5, 5, 2);
    final eventStart = DateTime.utc(2026, 5, 5, 0);
    final eventEnd = DateTime.utc(2026, 5, 5, 1);

    expect(
      eventRangesOverlap(
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        eventStart: eventStart,
        eventEnd: eventEnd,
      ),
      isFalse,
    );
  });

  test('expandEventOccurrencesForOverlap includes weekly recurrence hits', () {
    final seedStart = DateTime.utc(2026, 5, 5, 0);
    final seedEvent = EventModel(
      id: 'seed',
      userId: 'user-1',
      title: '반복 회의',
      startAt: seedStart,
      endAt: seedStart.add(const Duration(hours: 1)),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU',
    );
    final rangeStart = DateTime.utc(2026, 5, 19, 0);
    final rangeEnd = DateTime.utc(2026, 5, 20, 23, 59, 59);

    final occurrences = expandEventOccurrencesForOverlap(
      seedEvent,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );

    expect(occurrences, isNotEmpty);
    expect(
      occurrences.any(
        (candidate) =>
            candidate.startAt != null &&
            planflowLocal(candidate.startAt!) ==
                planflowLocal(DateTime.utc(2026, 5, 19, 0)),
      ),
      isTrue,
    );
  });

  test(
      'expandEventOccurrencesForOverlap keeps strong alarm and override metadata',
      () {
    final now = DateTime.now();
    final anchor = DateTime(now.year, now.month, now.day + 1, 9);
    final overrideDate = DateTime(now.year, now.month, now.day - 30, 9);
    final deletedDate = DateTime(now.year, now.month, now.day + 15, 9);
    final seedEvent = EventModel(
      id: 'seed-meta',
      userId: 'user-1',
      title: '강도알람 반복 회의',
      startAt: planflowLocalDateTimeToUtc(anchor),
      endAt: planflowLocalDateTimeToUtc(anchor.add(const Duration(hours: 1))),
      recurrenceRule: 'FREQ=WEEKLY',
      overriddenOccurrenceDate: planflowLocalDateTimeToUtc(overrideDate),
      deletedOccurrenceDates: <DateTime>[
        planflowLocalDateTimeToUtc(deletedDate),
      ],
      useStrongAlarm: true,
      groupEventId: 'group-1',
    );

    final occurrences = expandEventOccurrencesForOverlap(
      seedEvent,
      rangeStart: planflowLocalDateTimeToUtc(
        DateTime(now.year, now.month, now.day),
      ),
      rangeEnd: planflowLocalDateTimeToUtc(
        DateTime(now.year, now.month, now.day + 22),
      ),
    );

    expect(occurrences, isNotEmpty);
    final occurrence = occurrences.first;
    expect(occurrence.id, 'seed-meta');
    expect(occurrence.useStrongAlarm, isTrue);
    expect(occurrence.groupEventId, 'group-1');
    expect(
      occurrence.overriddenOccurrenceDate,
      planflowLocalDateTimeToUtc(overrideDate),
    );
    expect(
      occurrence.deletedOccurrenceDates,
      <DateTime>[planflowLocalDateTimeToUtc(deletedDate)],
    );
    expect(occurrence.recurrenceRule, 'FREQ=WEEKLY');
    // 회차 시각은 seed와 동일한 로컬 벽시각(09:00, 1시간 길이)으로 전개된다.
    expect(planflowLocal(occurrence.startAt!), anchor);
    expect(
      planflowLocal(occurrence.endAt!),
      anchor.add(const Duration(hours: 1)),
    );
  });

  test('filterDuplicateWarningEvents ignores unrelated overlapping events', () {
    final draft = EventModel(
      id: '',
      userId: 'user-1',
      title: '원주집방문',
      startAt: DateTime.utc(2026, 5, 26, 0),
      endAt: DateTime.utc(2026, 5, 26, 1),
    );
    final unrelated = EventModel(
      id: 'other',
      userId: 'user-1',
      title: '거래처 전화',
      startAt: DateTime.utc(2026, 5, 26, 0, 30),
      endAt: DateTime.utc(2026, 5, 26, 1, 30),
    );

    expect(
      filterDuplicateWarningEvents(
        draft: draft,
        candidates: <EventModel>[unrelated],
      ),
      isEmpty,
    );
  });

  test('filterDuplicateWarningEvents keeps same start or similar content', () {
    final draft = EventModel(
      id: '',
      userId: 'user-1',
      title: '원주집방문',
      startAt: DateTime.utc(2026, 5, 26, 0),
      endAt: DateTime.utc(2026, 5, 26, 1),
    );
    final sameStart = EventModel(
      id: 'same-start',
      userId: 'user-1',
      title: '다른 제목',
      startAt: DateTime.utc(2026, 5, 26, 0),
      endAt: DateTime.utc(2026, 5, 26, 1),
    );
    final similarTitle = EventModel(
      id: 'similar',
      userId: 'user-1',
      title: '원주집 방문',
      startAt: DateTime.utc(2026, 5, 26, 0, 30),
      endAt: DateTime.utc(2026, 5, 26, 1, 30),
    );

    final filtered = filterDuplicateWarningEvents(
      draft: draft,
      candidates: <EventModel>[sameStart, similarTitle],
    );

    expect(filtered.map((event) => event.id),
        containsAll(['same-start', 'similar']));
  });
}
