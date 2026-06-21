import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/home_widget_platform.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

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
      rawEvents: const <Map<String, Object?>>[
        <String, Object?>{
          'id': 'past',
          'user_id': 'user-1',
          'title': 'Past event',
          'start_at': '2026-05-04T00:00:00.000Z',
        },
        <String, Object?>{
          'id': 'upcoming',
          'user_id': 'user-1',
          'title': 'Upcoming event',
          'start_at': '2026-05-04T03:00:00.000Z',
        },
        <String, Object?>{
          'id': 'tomorrow',
          'user_id': 'user-1',
          'title': 'Tomorrow event',
          'start_at': '2026-05-05T01:00:00.000Z',
        },
        <String, Object?>{
          'id': 'cell-1',
          'user_id': 'user-1',
          'title': 'Cell event 1',
          'start_at': '2026-05-01T09:00:00.000Z',
          'is_critical': true,
        },
        <String, Object?>{
          'id': 'prev-month',
          'user_id': 'user-1',
          'title': 'Previous month event',
          'start_at': '2026-04-30T00:00:00.000Z',
        },
        <String, Object?>{
          'id': 'next-month',
          'user_id': 'user-1',
          'title': 'Next month event',
          'start_at': '2026-06-01T00:00:00.000Z',
        },
      ],
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
            const HomeWidgetListEventData(title: 'Cell event 4'),
          ],
          overflowCount: 2,
        ),
      ],
      previousMonthCells: <HomeWidgetMonthCellData>[
        HomeWidgetMonthCellData(
          cellIndex: 6,
          day: 30,
          inMonth: true,
          date: DateTime(2026, 4, 30),
          events: const <HomeWidgetListEventData>[
            HomeWidgetListEventData(title: 'Previous month event'),
          ],
        ),
      ],
      nextMonthCells: <HomeWidgetMonthCellData>[
        HomeWidgetMonthCellData(
          cellIndex: 2,
          day: 1,
          inMonth: true,
          date: DateTime(2026, 6, 1),
          events: const <HomeWidgetListEventData>[
            HomeWidgetListEventData(title: 'Next month event'),
          ],
        ),
      ],
      weekDays: <HomeWidgetWeekDayData>[
        HomeWidgetWeekDayData(
          date: DateTime.parse('2026-05-04T00:00:00Z'),
          summary: '3 events',
          eventCount: 3,
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
    expect(platform.savedValues['month_cell_1_event_4_title'], 'Cell event 4');
    expect(platform.savedValues['month_cell_1_overflow_count'], 2);
    expect(platform.savedValues['month_cell_42_day'], isNull);
    expect(platform.savedValues['month_cell_42_in_month'], isFalse);
    expect(platform.savedValues['month_title_offset_-1'], '2026.04');
    expect(platform.savedValues['month_title_offset_1'], '2026.06');
    expect(platform.savedValues['schedule_events_json'], isA<String>());
    final rawEvents = jsonDecode(
      platform.savedValues['schedule_events_json'] as String,
    ) as List<dynamic>;
    expect(rawEvents.length, 6);
    expect(rawEvents.first['title'], 'Past event');
    expect(platform.savedValues['month_offset_-1_cell_6_day'], 30);
    expect(
      platform.savedValues['month_offset_-1_cell_6_event_1_title'],
      'Previous month event',
    );
    expect(platform.savedValues['month_offset_1_cell_2_day'], 1);
    expect(
      platform.savedValues['month_offset_1_cell_2_event_1_title'],
      'Next month event',
    );
    expect(platform.savedValues['week_day_1_date'], '2026-05-04T00:00:00.000Z');
    expect(platform.savedValues['week_day_1_summary'], '3 events');
    expect(platform.savedValues['week_day_1_count'], 3);
    expect(platform.savedValues['week_day_1_has_critical'], isTrue);
    expect(platform.savedValues['week_day_1_overflow_count'], 0);
    expect(platform.savedValues['week_day_1_event_1_title'], 'Week event 1');
    expect(platform.savedValues['week_day_1_event_1_id'], 'week-1');
    expect(platform.savedValues['week_day_1_event_1_time'],
        '2026-05-04T01:00:00.000Z');
    expect(platform.savedValues['week_day_1_event_1_is_critical'], isTrue);
    expect(platform.savedValues['week_day_1_event_2_title'], 'Week event 2');
    expect(platform.savedValues['week_day_1_event_3_title'], 'Week event 3');
    expect(platform.savedValues['week_day_1_event_4_title'], isNull);
    expect(
        platform.updatedWidgets, HomeWidgetService.defaultAndroidWidgetNames);
  });

  test('weekly widget payload saves four real event rows before overflow',
      () async {
    final platform = _FakeHomeWidgetPlatform();
    final service = HomeWidgetService(platform: platform);

    final success = await service.updateScheduleData(
      nextEvent: const HomeWidgetNextEventData(title: 'Next'),
      weekDays: <HomeWidgetWeekDayData>[
        HomeWidgetWeekDayData(
          date: DateTime.parse('2026-05-04T00:00:00Z'),
          eventCount: 5,
          events: List<HomeWidgetListEventData>.generate(
            5,
            (index) => HomeWidgetListEventData(
              title: 'Week event ${index + 1}',
              eventId: 'week-${index + 1}',
              startAt: DateTime.parse('2026-05-04T01:00:00Z')
                  .add(Duration(hours: index)),
            ),
          ),
          overflowPreviewTitle: 'Week event 5',
        ),
      ],
      widgetName: 'schedule_widget',
    );

    expect(success, isTrue);
    expect(platform.savedValues['week_day_1_event_1_title'], 'Week event 1');
    expect(platform.savedValues['week_day_1_event_2_title'], 'Week event 2');
    expect(platform.savedValues['week_day_1_event_3_title'], 'Week event 3');
    expect(platform.savedValues['week_day_1_event_4_title'], 'Week event 4');
    expect(platform.savedValues['week_day_1_overflow_count'], 1);
    expect(
      platform.savedValues['week_day_1_overflow_preview_title'],
      'Week event 5',
    );
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
    expect(payload.rawEvents.length, 6);
    expect(payload.rawEvents.first['title'], 'Past event');
    expect(payload.lastPastEvent?.title, 'Past event');
    expect(payload.lastPastEvent?.eventId, 'past');
    expect(payload.todayUpcomingEvents.map((event) => event.title),
        contains('Next event'));
    expect(payload.tomorrowEvents.single.eventId, 'tomorrow');
    final may20Cell = payload.monthCells.firstWhere((cell) => cell.day == 20);
    expect(may20Cell.inMonth, isTrue);
    expect(may20Cell.date, DateTime(2026, 5, 20));
    expect(may20Cell.events.length, 3);
    expect(may20Cell.overflowCount, 2);
    final wednesday = payload.weekDays[2];
    expect(wednesday.eventCount, 5);
    expect(wednesday.events.length, 4);
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

  test('HomeWidgetSchedulePayloadBuilder can hide weekend events', () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.parse('2026-05-22T00:00:00Z'),
      includeWeekends: false,
      events: <EventModel>[
        EventModel(
          id: 'fri',
          userId: 'user-1',
          title: 'Friday work',
          startAt: DateTime.parse('2026-05-22T01:00:00Z'),
        ),
        EventModel(
          id: 'sat',
          userId: 'user-1',
          title: 'Saturday work',
          startAt: DateTime.parse('2026-05-23T01:00:00Z'),
        ),
        EventModel(
          id: 'mon',
          userId: 'user-1',
          title: 'Monday work',
          startAt: DateTime.parse('2026-05-25T01:00:00Z'),
        ),
      ],
    );

    expect(payload.nextEvent.title, 'Friday work');
    expect(
      payload.weekDays.expand((day) => day.events).map((event) => event.title),
      isNot(contains('Saturday work')),
    );
    expect(
      payload.monthCells
          .expand((cell) => cell.events)
          .map((event) => event.title),
      isNot(contains('Saturday work')),
    );
  });

  test('HomeWidgetSchedulePayloadBuilder moves last monthly slot into overflow',
      () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime(2026, 6, 9, 9),
      events: <EventModel>[
        EventModel(
          id: 'multi-day',
          userId: 'user-1',
          title: '멀티데이',
          startAt: DateTime(2026, 6, 8, 9),
          endAt: DateTime(2026, 6, 10, 18),
          isMultiDay: true,
        ),
        for (var index = 0; index < 5; index += 1)
          EventModel(
            id: 'single-$index',
            userId: 'user-1',
            title: '단일 ${index + 1}',
            startAt: DateTime(2026, 6, 9, 10 + index),
          ),
      ],
    );

    final june9Cell = payload.monthCells.firstWhere(
      (cell) => cell.inMonth && cell.day == 9,
    );

    expect(june9Cell.events.length, 3);
    expect(june9Cell.overflowCount, 3);
  });

  test('HomeWidgetSchedulePayloadBuilder fills tomorrow only in empty space',
      () {
    final now = DateTime.parse('2026-05-20T04:00:00Z');

    HomeWidgetSchedulePayload build(int todayCount) {
      return HomeWidgetSchedulePayloadBuilder.fromEvents(
        now: now,
        events: <EventModel>[
          ...List<EventModel>.generate(
            todayCount,
            (index) => EventModel(
              id: 'today-${index + 1}',
              userId: 'user-1',
              title: 'Today ${index + 1}',
              startAt: DateTime.parse('2026-05-20T05:00:00Z')
                  .add(Duration(hours: index)),
            ),
          ),
          EventModel(
            id: 'tomorrow-1',
            userId: 'user-1',
            title: 'Tomorrow 1',
            startAt: DateTime.parse('2026-05-21T00:00:00Z'),
          ),
          EventModel(
            id: 'tomorrow-2',
            userId: 'user-1',
            title: 'Tomorrow 2',
            startAt: DateTime.parse('2026-05-21T01:00:00Z'),
          ),
        ],
      );
    }

    final noToday = build(0);
    expect(noToday.todayUpcomingEvents, isEmpty);
    expect(noToday.tomorrowEvents.map((event) => event.eventId), [
      'tomorrow-1',
      'tomorrow-2',
    ]);

    final oneToday = build(1);
    expect(oneToday.todayUpcomingEvents.map((event) => event.eventId), [
      'today-1',
    ]);
    expect(oneToday.tomorrowEvents.map((event) => event.eventId), [
      'tomorrow-1',
      'tomorrow-2',
    ]);

    final fourToday = build(4);
    expect(fourToday.todayUpcomingEvents.length, 4);
    expect(fourToday.tomorrowEvents.length, 2);

    final fiveToday = build(5);
    expect(fiveToday.todayUpcomingEvents.length, 5);
    expect(fiveToday.tomorrowEvents.single.eventId, 'tomorrow-1');

    final sixToday = build(6);
    expect(sixToday.todayUpcomingEvents.length, 6);
    expect(sixToday.tomorrowEvents, isEmpty);

    final eightToday = build(8);
    expect(eightToday.todayUpcomingEvents.length, 6);
    expect(eightToday.todayUpcomingEvents.last.title, '오늘 일정 3개 더');
    expect(eightToday.tomorrowEvents, isEmpty);
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
    expect(payload.tomorrowEvents.single.title, 'Tomorrow preview');
  });

  test('HomeWidgetSchedulePayloadBuilder expands date-range events in month',
      () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.parse('2026-05-01T00:00:00Z'),
      events: <EventModel>[
        EventModel(
          id: 'wonju-home',
          userId: 'user-1',
          title: '원주집방문',
          startAt: DateTime.utc(2026, 4, 30, 15),
          endAt: DateTime.utc(2026, 5, 10, 15),
          isMultiDay: false,
        ),
      ],
    );

    for (var day = 1; day <= 10; day += 1) {
      final cell = payload.monthCells.firstWhere(
        (cell) => cell.inMonth && cell.day == day,
      );
      expect(cell.events.map((event) => event.title), contains('원주집방문'));
    }
    final may11Cell = payload.monthCells.firstWhere(
      (cell) => cell.inMonth && cell.day == 11,
    );
    expect(
        may11Cell.events.map((event) => event.title), isNot(contains('원주집방문')));
  });

  test('HomeWidgetSchedulePayloadBuilder clips midnight-ended ranges', () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.parse('2026-05-19T00:00:00Z'),
      events: <EventModel>[
        EventModel(
          id: 'range',
          userId: 'user-1',
          title: '테스트',
          startAt: DateTime.utc(2026, 5, 18, 15),
          endAt: DateTime.utc(2026, 5, 22, 15),
          isMultiDay: true,
        ),
      ],
    );

    for (var day = 19; day <= 22; day += 1) {
      final cell = payload.monthCells.firstWhere(
        (cell) => cell.inMonth && cell.day == day,
      );
      expect(cell.events.map((event) => event.title), contains('테스트'));
    }
    final may23Cell = payload.monthCells.firstWhere(
      (cell) => cell.inMonth && cell.day == 23,
    );
    expect(
        may23Cell.events.map((event) => event.title), isNot(contains('테스트')));
  });

  test(
      'HomeWidgetSchedulePayloadBuilder keeps cross-month range in muted cells',
      () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.parse('2026-05-27T00:00:00Z'),
      events: <EventModel>[
        EventModel(
          id: 'wonju-home',
          userId: 'user-1',
          title: '원주집방문',
          startAt: DateTime.utc(2026, 5, 25, 15),
          endAt: DateTime.utc(2026, 6, 1, 14, 59, 59),
          isAllDay: true,
          isMultiDay: true,
        ),
      ],
    );

    for (var day = 26; day <= 31; day += 1) {
      final cell = payload.monthCells.firstWhere(
        (cell) => cell.inMonth && cell.day == day,
      );
      expect(cell.events.map((event) => event.title), contains('원주집방문'));
    }

    final june1Cell = payload.monthCells.firstWhere(
      (cell) => !cell.inMonth && cell.date == DateTime(2026, 6),
    );
    expect(june1Cell.events.map((event) => event.title), contains('원주집방문'));
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
