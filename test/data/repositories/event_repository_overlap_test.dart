import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';

void main() {
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
