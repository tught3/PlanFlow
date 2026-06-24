import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/home_widget_service.dart';

void main() {
  group('HomeWidgetSchedulePayloadBuilder recurrence expansion', () {
    test('caps monthly occurrences to the target month last day', () {
      final payload = _payload(
        now: DateTime(2026, 3, 15, 9),
        events: <EventModel>[
          _event(
            id: 'monthly-31',
            title: '월말 정산',
            startAt: DateTime(2026, 1, 31, 9),
            recurrenceRule: 'FREQ=MONTHLY',
          ),
        ],
      );

      expect(_titlesOn(payload.previousMonthCells, DateTime(2026, 2, 28)),
          contains('월말 정산'));
      expect(_titlesOn(payload.monthCells, DateTime(2026, 3, 31)),
          contains('월말 정산'));
      expect(_titlesOn(payload.nextMonthCells, DateTime(2026, 4, 30)),
          contains('월말 정산'));
      expect(_titlesOn(payload.monthCells, DateTime(2026, 3, 3)),
          isNot(contains('월말 정산')));
    });

    test('keeps monthly interval anchored to the original start date', () {
      final payload = _payload(
        now: DateTime(2026, 4, 15, 9),
        events: <EventModel>[
          _event(
            id: 'monthly-interval',
            title: '격월 보고',
            startAt: DateTime(2026, 1, 30, 9),
            recurrenceRule: 'FREQ=MONTHLY;INTERVAL=2',
          ),
        ],
      );

      expect(_titlesOn(payload.previousMonthCells, DateTime(2026, 3, 30)),
          contains('격월 보고'));
      expect(_titlesOn(payload.nextMonthCells, DateTime(2026, 5, 30)),
          contains('격월 보고'));
      expect(_titlesOn(payload.previousMonthCells, DateTime(2026, 2, 28)),
          isNot(contains('격월 보고')));
    });

    test('caps yearly leap-day occurrences without losing leap years', () {
      final commonYearPayload = _payload(
        now: DateTime(2025, 2, 1, 9),
        events: <EventModel>[
          _event(
            id: 'yearly-leap',
            title: '윤년 점검',
            startAt: DateTime(2024, 2, 29, 9),
            recurrenceRule: 'FREQ=YEARLY',
          ),
        ],
      );
      final leapYearPayload = _payload(
        now: DateTime(2028, 2, 1, 9),
        events: <EventModel>[
          _event(
            id: 'yearly-leap',
            title: '윤년 점검',
            startAt: DateTime(2024, 2, 29, 9),
            recurrenceRule: 'FREQ=YEARLY',
          ),
        ],
      );

      expect(_titlesOn(commonYearPayload.monthCells, DateTime(2025, 2, 28)),
          contains('윤년 점검'));
      expect(_titlesOn(leapYearPayload.monthCells, DateTime(2028, 2, 29)),
          contains('윤년 점검'));
    });

    test('treats UTC UNTIL as an inclusive instant boundary', () {
      final payload = _payload(
        now: DateTime(2026, 2, 1, 9),
        events: <EventModel>[
          _event(
            id: 'daily-until',
            title: '마감 전 확인',
            startAt: DateTime.utc(2026, 2, 27, 23, 30),
            recurrenceRule: 'FREQ=DAILY;UNTIL=20260228T000000Z',
          ),
        ],
      );

      final starts = payload.rawEvents
          .where((event) => event['id'] == 'daily-until')
          .map((event) => event['start_at']);

      expect(starts, contains('2026-02-27T23:30:00.000Z'));
      expect(starts, isNot(contains('2026-02-28T23:30:00.000Z')));
    });

    test('treats local timestamp UNTIL as an inclusive wall-time boundary', () {
      final payload = _payload(
        now: DateTime(2026, 2, 1, 9),
        events: <EventModel>[
          _event(
            id: 'daily-local-until',
            title: '로컬 마감 확인',
            startAt: DateTime(2026, 2, 27, 9),
            recurrenceRule: 'FREQ=DAILY;UNTIL=20260228T090000',
          ),
        ],
      );

      expect(_titlesOn(payload.monthCells, DateTime(2026, 2, 27)),
          contains('로컬 마감 확인'));
      expect(_titlesOn(payload.monthCells, DateTime(2026, 2, 28)),
          contains('로컬 마감 확인'));
      expect(_titlesOn(payload.monthCells, DateTime(2026, 3, 1)),
          isNot(contains('로컬 마감 확인')));
    });

    test('does not create BYDAY occurrences before the recurrence start', () {
      final payload = _payload(
        now: DateTime(2026, 1, 7, 9),
        events: <EventModel>[
          _event(
            id: 'weekly-byday',
            title: '주간 체크',
            startAt: DateTime(2026, 1, 7, 9),
            recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,FR',
          ),
        ],
      );

      expect(_titlesOn(payload.monthCells, DateTime(2026, 1, 5)),
          isNot(contains('주간 체크')));
      expect(_titlesOn(payload.monthCells, DateTime(2026, 1, 9)),
          contains('주간 체크'));
    });

    test('keeps daily, weekly, non-recurring, and multi-day events visible',
        () {
      final payload = _payload(
        now: DateTime(2026, 5, 5, 9),
        events: <EventModel>[
          _event(
            id: 'daily',
            title: '매일 루틴',
            startAt: DateTime(2026, 5, 4, 9),
            recurrenceRule: 'FREQ=DAILY;UNTIL=20260506',
          ),
          _event(
            id: 'weekly',
            title: '주간 루틴',
            startAt: DateTime(2026, 4, 28, 10),
            recurrenceRule: 'FREQ=WEEKLY',
          ),
          _event(
            id: 'multi',
            title: '연속 일정',
            startAt: DateTime(2026, 5, 5, 12),
            endAt: DateTime(2026, 5, 7, 12),
            isMultiDay: true,
          ),
        ],
      );

      expect(_titlesOn(payload.monthCells, DateTime(2026, 5, 5)),
          containsAll(<String>['매일 루틴', '주간 루틴', '연속 일정']));
      expect(_titlesOn(payload.monthCells, DateTime(2026, 5, 6)),
          containsAll(<String>['매일 루틴', '연속 일정']));
      expect(_titlesOn(payload.monthCells, DateTime(2026, 5, 7)),
          contains('연속 일정'));
    });
  });
}

HomeWidgetSchedulePayload _payload({
  required DateTime now,
  required List<EventModel> events,
}) {
  return HomeWidgetSchedulePayloadBuilder.fromEvents(
    now: now,
    events: events,
  );
}

EventModel _event({
  required String id,
  required String title,
  required DateTime startAt,
  DateTime? endAt,
  String? recurrenceRule,
  bool isMultiDay = false,
}) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt,
    endAt: endAt,
    recurrenceRule: recurrenceRule,
    isMultiDay: isMultiDay,
  );
}

Iterable<String> _titlesOn(
  List<HomeWidgetMonthCellData> cells,
  DateTime date,
) {
  return cells
      .where((cell) => cell.date == DateTime(date.year, date.month, date.day))
      .expand((cell) => cell.events)
      .map((event) => event.title);
}
