import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/home_widget_platform.dart';
import 'package:planflow/services/home_widget_service.dart';

void main() {
  test('HomeWidgetService updates next-event widget payload', () async {
    final platform = _FakeHomeWidgetPlatform();
    final service = HomeWidgetService(platform: platform);

    final success = await service.updateNextEvent(
      title: 'Team sync',
      eventId: 'event-1',
      startAt: DateTime.parse('2026-05-01T09:00:00Z'),
      location: 'Seoul Station',
      travelBufferMinutes: 25,
      isCritical: true,
      upcomingEvents: <HomeWidgetListEventData>[
        HomeWidgetListEventData(
          title: 'Team sync',
          eventId: 'event-1',
          startAt: DateTime.parse('2026-05-01T09:00:00Z'),
          location: 'Seoul Station',
          isCritical: true,
        ),
        HomeWidgetListEventData(
          title: 'Design review',
          startAt: DateTime.parse('2026-05-01T11:00:00Z'),
        ),
        HomeWidgetListEventData(
          title: 'Lunch',
          startAt: DateTime.parse('2026-05-01T12:00:00Z'),
        ),
        HomeWidgetListEventData(
          title: 'User interview',
          startAt: DateTime.parse('2026-05-01T14:00:00Z'),
        ),
        HomeWidgetListEventData(
          title: 'Sales call',
          startAt: DateTime.parse('2026-05-01T16:00:00Z'),
        ),
        HomeWidgetListEventData(
          title: 'Wrap up',
          startAt: DateTime.parse('2026-05-01T18:00:00Z'),
        ),
        HomeWidgetListEventData(
          title: 'Hidden overflow',
          startAt: DateTime.parse('2026-05-01T19:00:00Z'),
        ),
      ],
      widgetName: 'next_event_widget',
    );

    expect(success, isTrue);
    expect(platform.savedValues['next_event_title'], 'Team sync');
    expect(platform.savedValues['next_event_id'], 'event-1');
    expect(platform.savedValues['next_event_start_at'],
        '2026-05-01T09:00:00.000Z');
    expect(platform.savedValues['next_event_location'], 'Seoul Station');
    expect(platform.savedValues['next_event_travel_buffer_minutes'], 25);
    expect(platform.savedValues['next_event_is_critical'], isTrue);
    expect(platform.savedValues['event_list_1_title'], 'Team sync');
    expect(platform.savedValues['event_list_1_id'], 'event-1');
    expect(
        platform.savedValues['event_list_1_time'], '2026-05-01T09:00:00.000Z');
    expect(platform.savedValues['event_list_1_location'], 'Seoul Station');
    expect(platform.savedValues['event_list_1_is_critical'], isTrue);
    expect(platform.savedValues['event_list_2_title'], 'Design review');
    expect(platform.savedValues['event_list_2_is_critical'], isFalse);
    expect(platform.savedValues['event_list_6_title'], 'Wrap up');
    expect(platform.savedValues['event_list_7_title'], isNull);
    expect(platform.savedValues['today_event_count'], 6);
    expect(platform.updatedWidgets.single, 'next_event_widget');
  });

  test('HomeWidgetService returns false when the platform is unsupported',
      () async {
    final platform = _FakeHomeWidgetPlatform(supported: false);
    final service = HomeWidgetService(platform: platform);

    final success = await service.updateNextEvent(
      title: 'Team sync',
      widgetName: 'next_event_widget',
    );

    expect(success, isFalse);
    expect(platform.savedValues, isEmpty);
    expect(platform.updatedWidgets, isEmpty);
  });

  test('HomeWidgetService clears optional fields to avoid stale widget data',
      () async {
    final platform = _FakeHomeWidgetPlatform();
    final service = HomeWidgetService(platform: platform);

    await service.updateNextEvent(
      title: 'First event',
      eventId: 'event-1',
      startAt: DateTime.parse('2026-05-01T09:00:00Z'),
      location: 'Seoul Station',
      travelBufferMinutes: 25,
      widgetName: 'next_event_widget',
    );

    final success = await service.updateNextEvent(
      title: 'Second event',
      eventId: '',
      location: '',
      widgetName: 'next_event_widget',
    );

    expect(success, isTrue);
    expect(platform.savedValues['next_event_title'], 'Second event');
    expect(platform.savedValues['next_event_id'], '');
    expect(platform.savedValues['next_event_start_at'], isNull);
    expect(platform.savedValues['next_event_location'], '');
    expect(platform.savedValues['next_event_travel_buffer_minutes'], 15);
  });

  test('HomeWidgetService stores monthly, weekly, and today widget data',
      () async {
    final platform = _FakeHomeWidgetPlatform();
    final service = HomeWidgetService(platform: platform);

    final success = await service.updateScheduleData(
      nextEvent: HomeWidgetNextEventData(
        title: 'Morning sync',
        startAt: DateTime.parse('2026-05-04T01:00:00Z'),
      ),
      todayEvents: List<HomeWidgetListEventData>.generate(
        7,
        (index) => HomeWidgetListEventData(title: 'Today event ${index + 1}'),
      ),
      lastPastEvent: HomeWidgetListEventData(
        title: 'Past event',
        eventId: 'past',
        startAt: DateTime.parse('2026-05-04T00:00:00Z'),
      ),
      todayUpcomingEvents: <HomeWidgetListEventData>[
        HomeWidgetListEventData(
          title: 'Upcoming event',
          eventId: 'upcoming',
          startAt: DateTime.parse('2026-05-04T03:00:00Z'),
        ),
      ],
      tomorrowEvents: <HomeWidgetListEventData>[
        HomeWidgetListEventData(
          title: 'Tomorrow event',
          eventId: 'tomorrow',
          startAt: DateTime.parse('2026-05-05T01:00:00Z'),
        ),
      ],
      month: DateTime(2026, 5),
      monthDays: const <HomeWidgetMonthDayData>[
        HomeWidgetMonthDayData(
          day: 1,
          summary: '2 events',
          eventCount: 2,
          hasCritical: true,
        ),
        HomeWidgetMonthDayData(day: 32, summary: 'ignored'),
      ],
      monthCells: <HomeWidgetMonthCellData>[
        HomeWidgetMonthCellData(
          cellIndex: 1,
          day: 1,
          inMonth: true,
          date: DateTime(2026, 5, 1),
          events: <HomeWidgetListEventData>[
            const HomeWidgetListEventData(
              title: 'Cell event 1',
              eventId: 'cell-1',
              isCritical: true,
            ),
            const HomeWidgetListEventData(title: 'Cell event 2'),
            const HomeWidgetListEventData(title: 'Cell event 3'),
          ],
          overflowCount: 2,
        ),
      ],
      weekDays: <HomeWidgetWeekDayData>[
        HomeWidgetWeekDayData(
          date: DateTime.parse('2026-05-04T00:00:00Z'),
          summary: '2 events',
          eventCount: 2,
          hasCritical: true,
          events: <HomeWidgetListEventData>[
            HomeWidgetListEventData(
              title: 'Week event 1',
              eventId: 'week-1',
              startAt: DateTime.parse('2026-05-04T01:00:00Z'),
              isCritical: true,
            ),
            HomeWidgetListEventData(title: 'Week event 2'),
            HomeWidgetListEventData(title: 'Week event 3'),
          ],
        ),
      ],
    );

    expect(success, isTrue);
    expect(platform.savedValues['next_event_title'], 'Morning sync');
    expect(platform.savedValues['event_list_6_title'], 'Today event 6');
    expect(platform.savedValues['event_list_7_title'], isNull);
    expect(platform.savedValues['last_past_event_title'], 'Past event');
    expect(platform.savedValues['last_past_event_id'], 'past');
    expect(
      platform.savedValues['last_past_event_time'],
      '2026-05-04T00:00:00.000Z',
    );
    expect(platform.savedValues['today_upcoming_count'], 1);
    expect(platform.savedValues['today_upcoming_1_title'], 'Upcoming event');
    expect(platform.savedValues['today_upcoming_1_id'], 'upcoming');
    expect(platform.savedValues['today_upcoming_2_title'], isNull);
    expect(platform.savedValues['tomorrow_event_count'], 1);
    expect(platform.savedValues['tomorrow_event_1_title'], 'Tomorrow event');
    expect(platform.savedValues['tomorrow_event_1_id'], 'tomorrow');
    expect(platform.savedValues['month_day_1_summary'], '2 events');
    expect(platform.savedValues['month_day_1_count'], 2);
    expect(platform.savedValues['month_day_1_has_critical'], isTrue);
    expect(platform.savedValues['month_day_31_summary'], isNull);
    expect(platform.savedValues['month_day_31_has_critical'], isFalse);
    expect(platform.savedValues['month_cell_1_day'], 1);
    expect(platform.savedValues['month_cell_1_date'], '2026-05-01');
    expect(platform.savedValues['month_cell_1_in_month'], isTrue);
    expect(platform.savedValues['month_cell_1_event_1_title'], 'Cell event 1');
    expect(platform.savedValues['month_cell_1_event_1_id'], 'cell-1');
    expect(platform.savedValues['month_cell_1_event_1_is_critical'], isTrue);
    expect(platform.savedValues['month_cell_1_event_3_title'], 'Cell event 3');
    expect(platform.savedValues['month_cell_1_overflow_count'], 2);
    expect(platform.savedValues['month_cell_42_day'], isNull);
    expect(platform.savedValues['month_cell_42_in_month'], isFalse);
    expect(platform.savedValues['week_day_1_date'], '2026-05-04T00:00:00.000Z');
    expect(platform.savedValues['week_day_1_summary'], '2 events');
    expect(platform.savedValues['week_day_1_count'], 2);
    expect(platform.savedValues['week_day_1_has_critical'], isTrue);
    expect(platform.savedValues['week_day_1_overflow_count'], 0);
    expect(platform.savedValues['week_day_1_event_1_title'], 'Week event 1');
    expect(platform.savedValues['week_day_1_event_1_id'], 'week-1');
    expect(platform.savedValues['week_day_1_event_1_time'],
        '2026-05-04T01:00:00.000Z');
    expect(platform.savedValues['week_day_1_event_1_is_critical'], isTrue);
    expect(platform.savedValues['week_day_1_event_2_title'], 'Week event 2');
    expect(platform.savedValues['week_day_1_event_3_title'], isNull);
    expect(
        platform.updatedWidgets, HomeWidgetService.defaultAndroidWidgetNames);
  });

  test('HomeWidgetSchedulePayloadBuilder builds actual calendar payload', () {
    final now = DateTime.parse('2026-05-20T04:00:00Z');
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: now,
      events: <EventModel>[
        EventModel(
          id: 'past',
          userId: 'user-1',
          title: 'Past event',
          startAt: DateTime.parse('2026-05-20T01:00:00Z'),
        ),
        EventModel(
          id: 'next',
          userId: 'user-1',
          title: 'Next event',
          startAt: DateTime.parse('2026-05-20T06:00:00Z'),
          isCritical: true,
        ),
        EventModel(
          id: 'tomorrow',
          userId: 'user-1',
          title: 'Tomorrow event',
          startAt: DateTime.parse('2026-05-21T00:00:00Z'),
        ),
        EventModel(
          id: 'overflow-1',
          userId: 'user-1',
          title: 'Overflow 1',
          startAt: DateTime.parse('2026-05-20T07:00:00Z'),
        ),
        EventModel(
          id: 'overflow-2',
          userId: 'user-1',
          title: 'Overflow 2',
          startAt: DateTime.parse('2026-05-20T08:00:00Z'),
        ),
        EventModel(
          id: 'overflow-3',
          userId: 'user-1',
          title: 'Overflow 3',
          startAt: DateTime.parse('2026-05-20T09:00:00Z'),
        ),
      ],
    );

    expect(payload.nextEvent.title, 'Next event');
    expect(payload.nextEvent.eventId, 'next');
    expect(payload.nextEvent.isCritical, isTrue);
    expect(payload.lastPastEvent?.title, 'Past event');
    expect(payload.lastPastEvent?.eventId, 'past');
    expect(payload.todayUpcomingEvents.map((event) => event.title),
        contains('Next event'));
    expect(payload.tomorrowEvents, isEmpty);
    final may20Cell = payload.monthCells.firstWhere((cell) => cell.day == 20);
    expect(may20Cell.inMonth, isTrue);
    expect(may20Cell.date, DateTime(2026, 5, 20));
    expect(may20Cell.events.length, 3);
    expect(may20Cell.overflowCount, 2);
    final wednesday = payload.weekDays[2];
    expect(wednesday.eventCount, 5);
    expect(wednesday.events.length, 2);
    expect(wednesday.hasCritical, isTrue);
  });

  test('HomeWidgetSchedulePayloadBuilder uses local day for tomorrow fallback',
      () {
    final now = DateTime.parse('2026-05-20T16:30:00Z');
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: now,
      events: <EventModel>[
        EventModel(
          id: 'kst-tomorrow',
          userId: 'user-1',
          title: 'KST tomorrow event',
          startAt: DateTime.parse('2026-05-21T16:00:00Z'),
        ),
      ],
    );

    expect(payload.todayUpcomingEvents, isEmpty);
    expect(payload.tomorrowEvents.single.eventId, 'kst-tomorrow');
    expect(payload.month, DateTime(2026, 5));
  });

  test('HomeWidgetSchedulePayloadBuilder keeps ongoing multi-day event today',
      () {
    final now = DateTime.parse('2026-05-20T04:00:00Z');
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: now,
      events: <EventModel>[
        EventModel(
          id: 'ongoing',
          userId: 'user-1',
          title: 'Ongoing event',
          startAt: DateTime.parse('2026-05-19T15:00:00Z'),
          endAt: DateTime.parse('2026-05-20T05:00:00Z'),
          isMultiDay: true,
        ),
        EventModel(
          id: 'tomorrow',
          userId: 'user-1',
          title: 'Tomorrow preview',
          startAt: DateTime.parse('2026-05-21T00:00:00Z'),
        ),
      ],
    );

    expect(payload.lastPastEvent, isNull);
    expect(payload.todayUpcomingEvents.single.title, 'Ongoing event');
    expect(payload.tomorrowEvents, isEmpty);
  });

  test('HomeWidgetService refreshScheduleFromEvents delegates payload build',
      () async {
    final platform = _FakeHomeWidgetPlatform();
    final service = HomeWidgetService(platform: platform);

    final success = await service.refreshScheduleFromEvents(
      <EventModel>[
        EventModel(
          id: 'past',
          userId: 'user-1',
          title: 'Past event',
          startAt: DateTime.parse('2026-05-20T01:00:00Z'),
        ),
        EventModel(
          id: 'next',
          userId: 'user-1',
          title: 'Next event',
          startAt: DateTime.parse('2026-05-20T06:00:00Z'),
        ),
      ],
      now: DateTime.parse('2026-05-20T04:00:00Z'),
      widgetName: 'schedule_widget',
    );

    expect(success, isTrue);
    expect(platform.savedValues['next_event_title'], 'Next event');
    expect(platform.savedValues['last_past_event_title'], 'Past event');
    expect(platform.updatedWidgets.single, 'schedule_widget');
  });
}

class _FakeHomeWidgetPlatform extends HomeWidgetPlatform {
  _FakeHomeWidgetPlatform({this.supported = true});

  final bool supported;
  final Map<String, Object?> savedValues = <String, Object?>{};
  final List<String> updatedWidgets = <String>[];
  String? appGroupId;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> saveWidgetData(String id, Object? data) async {
    if (!supported) {
      return false;
    }

    savedValues[id] = data;
    return true;
  }

  @override
  Future<bool> setAppGroupId(String groupId) async {
    if (!supported) {
      return false;
    }

    appGroupId = groupId;
    return true;
  }

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    if (!supported) {
      return false;
    }

    updatedWidgets.add(name ?? '');
    return true;
  }
}
