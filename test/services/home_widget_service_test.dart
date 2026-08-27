import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/home_widget_platform.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/screens/calendar/calendar_style_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('calendar style contract contains the app calendar source-of-truth', () {
    final payload = calendarStyleContractPayload();
    expect(payload['calendar_style_contract_version'],
        calendarStyleContractVersion);
    expect(payload['calendar_style_critical_text'],
        calendarCriticalEventTextColor.toARGB32());
    expect(payload['calendar_style_critical_marker'],
        calendarCriticalEventMarkerColor.toARGB32());
    expect(payload['calendar_style_critical_background'],
        calendarCriticalEventBackgroundColor.toARGB32());
    expect(payload['calendar_style_normal_background'],
        calendarNormalEventBackgroundColor.toARGB32());
    expect(payload['calendar_style_multiday_background'],
        calendarMultiDayEventBackgroundColor.toARGB32());
    expect(payload['calendar_style_multiday_border'],
        calendarMultiDayEventBorderColor.toARGB32());
    expect(payload['calendar_style_normal_text'],
        calendarNormalEventTextColor.toARGB32());
    expect(payload['calendar_style_team_text'],
        calendarGroupEventColor.toARGB32());
    expect(payload['calendar_style_team_background'],
        calendarGroupEventBackgroundColor.toARGB32());
    expect(payload['calendar_style_recurring_text'],
        calendarRecurringEventColor.toARGB32());
    expect(payload['calendar_style_recurring_background'],
        calendarRecurringEventBackgroundColor.toARGB32());
    expect(payload['calendar_style_holiday_text'],
        calendarHolidayColor.toARGB32());
    expect(payload['calendar_style_saturday_text'],
        calendarSaturdayColor.toARGB32());
    expect(payload['calendar_style_event_font_sp10'], 83);
    expect(payload['calendar_style_date_font_sp10'], 130);
    expect(payload['calendar_style_holiday_font_sp10'], 88);
    expect(payload['calendar_style_group_member_font_sp10'], 100);
    expect(payload['calendar_style_recurring_marker_sp10'], 78);
    expect(payload['calendar_style_strong_alarm_marker_sp10'], 58);
  });

  test(
      'marker styling keeps only strong-alarm marker and critical title emphasis',
      () {
    final calendarSource =
        File('lib/screens/calendar/calendar_widgets.dart').readAsStringSync();
    expect(calendarSource, contains('_calendarEventTitleSpan'));
    expect(calendarSource, contains('FontWeight.w900'));
    expect(calendarSource,
        contains('markerFontSize: calendarRecurringMarkerFontSize'));
    expect(calendarSource, contains('markerFontSize: 14'));
    expect(calendarSource, contains('calendarStrongAlarmMarkerFontSize'));
    expect(calendarSource, contains('strongAlarmMarkerFontSize: 12'));
    expect(calendarSource, contains('fontSize: calendarEventFontSize'));
    expect(calendarSource, contains("text: '🔔\\u200A'"));
    expect(calendarSource, isNot(contains("text: '↻\\u200A'")));
    expect(calendarSource, contains('fontWeight: FontWeight.w700'));
    expect(calendarSource, contains('semanticColor'));
    expect(calendarSource, contains('final recurringBackground'));
    expect(calendarSource, contains('color: recurringBackground'));
    expect(calendarSource, contains('left: segment.\$1'));
    expect(calendarSource, contains('right: segment.\$2'));
    final homeSource =
        File('lib/services/home_widget_service.dart').readAsStringSync();
    expect(homeSource, contains('_event_\${eventSlot}_use_strong_alarm'));

    final widgetSource = File(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/PlanFlowHomeWidgetProvider.kt',
    ).readAsStringSync();
    final monthLayoutSource = File(
      'android/app/src/main/res/layout/planflow_monthly_widget.xml',
    ).readAsStringSync();
    expect(
        monthLayoutSource, contains('android:id="@+id/widget_month_dow_sun"'));
    expect(
        monthLayoutSource, contains('android:id="@+id/widget_month_dow_sat"'));
    expect(widgetSource, contains('bindMonthWeekdayHeader(views)'));
    expect(widgetSource, contains('widgetStyle.holidayTextColor'));
    expect(widgetSource, contains('widgetStyle.saturdayTextColor'));
    // Canonical resources retain their rounded/multi-day shape. RemoteViews
    // must not flatten a LayerDrawable when a future token differs; the
    // provider deliberately keeps the resource and waits for a matching XML
    // drawable instead.
    final applyBackgroundStart =
        widgetSource.indexOf('protected fun applyMonthEventBackground(');
    final applyBackgroundEnd = widgetSource.indexOf(
      '\n    protected fun bindMonthWeekdayHeader',
      applyBackgroundStart,
    );
    expect(applyBackgroundStart, isNonNegative);
    expect(applyBackgroundEnd, greaterThan(applyBackgroundStart));
    final applyBackground =
        widgetSource.substring(applyBackgroundStart, applyBackgroundEnd);
    expect(applyBackground, contains('setBackgroundResource'));
    expect(applyBackground, contains('setBackgroundTintList'));
    expect(applyBackground, contains('borderColor'));
    expect(applyBackground, isNot(contains('setBackgroundColor')));
    expect(widgetSource, contains('displayWidgetTitleSpanned'));
    expect(widgetSource, contains('StyleSpan(Typeface.BOLD)'));
    expect(widgetSource, contains('ForegroundColorSpan'));
    expect(widgetSource, contains("builder.append(marker).append('\\u200A')"));
    expect(widgetSource, contains('strongAlarmMarkerFontSizeSp.roundToInt()'));
    expect(widgetSource,
        isNot(contains('recurringMarkerFontSizeSp.roundToInt()')));
    expect(widgetSource, contains('calendar_style_event_font_sp10'));
    expect(widgetSource, contains('StyleSpan(Typeface.BOLD)'));

    final widgetStylesSource =
        File('android/app/src/main/res/values/styles.xml').readAsStringSync();
    final monthEventStyleStart = widgetStylesSource.indexOf(
      '<style name="PlanFlowWidgetMonthCellEvent">',
    );
    final monthEventStyleEnd = widgetStylesSource.indexOf(
      '</style>',
      monthEventStyleStart,
    );
    expect(monthEventStyleStart, isNonNegative);
    expect(monthEventStyleEnd, greaterThan(monthEventStyleStart));
    final monthEventStyle = widgetStylesSource.substring(
      monthEventStyleStart,
      monthEventStyleEnd,
    );
    expect(
      monthEventStyle,
      contains('<item name="android:textSize">8.3sp</item>'),
    );
    expect(
      monthEventStyle,
      contains('<item name="android:textStyle">normal</item>'),
    );
    final groupWidgetSource = File(
      'android/app/src/main/res/layout/planflow_group_calendar_widget.xml',
    ).readAsStringSync();
    expect(groupWidgetSource, isNot(contains('android:textSize="8.5sp"')));
    expect(groupWidgetSource, contains('android:textSize="10.5sp"'));
    expect(
      File(
        'android/app/src/main/res/drawable/widget_month_event_recurring_single.xml',
      ).readAsStringSync(),
      contains('#D2ECE8'),
    );
    expect(
      File(
        'android/app/src/main/res/drawable/widget_month_event_recurring_critical_single.xml',
      ).readAsStringSync(),
      contains('#E2D2F3'),
    );
    final listStyleStart = widgetStylesSource.indexOf(
      '<style name="PlanFlowWidgetListText">',
    );
    final listStyleEnd = widgetStylesSource.indexOf(
      '</style>',
      listStyleStart,
    );
    expect(listStyleStart, isNonNegative);
    expect(listStyleEnd, greaterThan(listStyleStart));
    final listStyle =
        widgetStylesSource.substring(listStyleStart, listStyleEnd);
    expect(listStyle, contains('<item name="android:textStyle">bold</item>'));

    final homeLayoutSource =
        File('android/app/src/main/res/layout/planflow_home_widget.xml')
            .readAsStringSync();
    final timeStart = homeLayoutSource.indexOf('android:id="@+id/widget_time"');
    final timeEnd = homeLayoutSource.indexOf('/>', timeStart);
    expect(timeStart, isNonNegative);
    expect(timeEnd, greaterThan(timeStart));
    final timeView = homeLayoutSource.substring(timeStart, timeEnd);
    expect(timeView, contains('android:textStyle="bold"'));

    for (final drawableName in <String>[
      'widget_month_event_single.xml',
      'widget_month_event_start.xml',
      'widget_month_event_middle.xml',
      'widget_month_event_end.xml',
      'widget_month_event_critical_single.xml',
      'widget_month_event_team_single.xml',
      'widget_month_event_team_start.xml',
      'widget_month_event_team_middle.xml',
      'widget_month_event_team_end.xml',
      'widget_month_event_holiday.xml',
    ]) {
      final drawableSource = File(
        'android/app/src/main/res/drawable/$drawableName',
      ).readAsStringSync();
      expect(drawableSource, contains('transparent'));
    }
    for (final drawableName in <String>[
      'widget_month_event_critical_start.xml',
      'widget_month_event_critical_middle.xml',
      'widget_month_event_critical_end.xml',
    ]) {
      final drawableSource = File(
        'android/app/src/main/res/drawable/$drawableName',
      ).readAsStringSync();
      expect(drawableSource, contains('#E2D2F3'));
    }
    for (final drawableName in <String>[
      'widget_month_event_recurring_single.xml',
      'widget_month_event_recurring_start.xml',
      'widget_month_event_recurring_middle.xml',
      'widget_month_event_recurring_end.xml',
      'widget_month_event_recurring_critical_single.xml',
      'widget_month_event_recurring_critical_start.xml',
      'widget_month_event_recurring_critical_middle.xml',
      'widget_month_event_recurring_critical_end.xml',
    ]) {
      final drawableSource = File(
        'android/app/src/main/res/drawable/$drawableName',
      ).readAsStringSync();
      expect(drawableSource, isNot(contains('transparent')));
    }
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
              useStrongAlarm: true,
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
    expect(
        platform.savedValues['month_cell_1_event_1_use_strong_alarm'], isTrue);
    expect(platform.savedValues['month_cell_1_event_3_title'], 'Cell event 3');
    expect(platform.savedValues['month_cell_1_event_4_title'], 'Cell event 4');
    expect(platform.savedValues['month_cell_1_overflow_count'], 2);
    expect(platform.savedValues['month_cell_42_day'], isNull);
    expect(platform.savedValues['month_cell_42_in_month'], isFalse);
    expect(platform.savedValues['widget_payload_generation_pending'],
        isA<String>());
    expect(
      platform.savedValues['widget_payload_generation_complete'],
      platform.savedValues['widget_payload_generation_pending'],
    );
    expect(platform.savedValues['month_cell_row_count'], 1);
    expect(platform.savedValues['month_cell_holiday_calendar_json'],
        isA<String>());
    final holidayPayload = jsonDecode(
      platform.savedValues['month_cell_holiday_calendar_json'] as String,
    ) as Map<String, dynamic>;
    expect(holidayPayload, isA<Map<String, dynamic>>());
    expect(
      holidayPayload.values.every((value) => value is Map<String, dynamic>),
      isTrue,
    );
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
    expect(may20Cell.events.length, 4);
    expect(may20Cell.overflowCount, 1);
    final wednesday = payload.weekDays[2];
    expect(wednesday.eventCount, 5);
    expect(wednesday.events.length, 4);
    expect(wednesday.hasCritical, isTrue);
  });

  test(
      'HomeWidget payload omits synced canonical holidays but keeps manual events',
      () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.utc(2026, 8, 15, 0),
      events: <EventModel>[
        EventModel(
          id: 'synced-holiday',
          userId: 'user-1',
          title: '광복절',
          startAt: DateTime.utc(2026, 8, 15, 0),
          externalId: 'provider-holiday-1',
          externalCalendarId: 'google:holidays',
        ),
        EventModel(
          id: 'manual-holiday-event',
          userId: 'user-1',
          title: '광복절 행사',
          startAt: DateTime.utc(2026, 8, 15, 1),
        ),
        EventModel(
          id: 'personal-event',
          userId: 'user-1',
          title: '개인 일정',
          startAt: DateTime.utc(2026, 8, 15, 2),
        ),
      ],
    );

    expect(payload.rawEvents.map((event) => event['id']), <String>[
      'manual-holiday-event',
      'personal-event',
    ]);
    final august15 = payload.monthCells.firstWhere((cell) => cell.day == 15);
    expect(august15.holidayName, '광복절');
    expect(august15.events.map((event) => event.eventId), <String>[
      'manual-holiday-event',
      'personal-event',
    ]);
  });

  test('HomeWidget same-start monthly ordering matches calendar semantics', () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.utc(2026, 9, 1),
      events: <EventModel>[
        EventModel(
          id: 'normal',
          userId: 'user-1',
          title: '가장 먼저일 제목',
          startAt: DateTime.utc(2026, 9, 2, 9),
        ),
        EventModel(
          id: 'critical',
          userId: 'user-1',
          title: '중요 일정',
          startAt: DateTime.utc(2026, 9, 2, 9),
          isCritical: true,
        ),
      ],
    );

    final cell = payload.monthCells.firstWhere((item) => item.day == 2);
    expect(cell.events.map((event) => event.eventId), <String>[
      'critical',
      'normal',
    ]);
  });

  test('HomeWidget keeps the app five-row shape for September 2026', () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.utc(2026, 9, 1),
      events: const <EventModel>[],
    );
    final lastInMonth = payload.monthCells.lastWhere((cell) => cell.inMonth);
    expect(lastInMonth.cellIndex, 32);
    expect(payload.monthCells.skip(32).every((cell) => !cell.inMonth), isTrue);
  });

  test('HomeWidget reserves the holiday row before four user events', () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.utc(2026, 8, 15),
      events: [
        for (var index = 1; index <= 4; index += 1)
          EventModel(
            id: 'holiday-event-$index',
            userId: 'user-1',
            title: '일정 $index',
            startAt: DateTime.utc(2026, 8, 15, 8 + index),
          ),
      ],
    );

    final august15 = payload.monthCells.firstWhere((cell) => cell.day == 15);
    expect(august15.holidayName, '광복절');
    expect(august15.events.length, 3);
    expect(august15.overflowCount, 1);
  });

  test('HomeWidget keeps a multi-day event below the holiday row', () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.utc(2026, 9, 23),
      events: <EventModel>[
        EventModel(
          id: 'birthday-range',
          userId: 'user-1',
          title: '생일 축하합니다',
          startAt: DateTime.utc(2026, 9, 23),
          endAt: DateTime.utc(2026, 9, 27),
          isAllDay: true,
          isMultiDay: true,
        ),
      ],
    );

    for (final day in <int>[23, 24, 25, 26]) {
      final cell = payload.monthCells.firstWhere((item) => item.day == day);
      expect(cell.events.map((event) => event.eventId),
          contains('birthday-range'));
    }
    // The span crosses Chuseok on the 24th. The app calendar reserves the
    // holiday row for the entire band, so the widget payload must retain the
    // same leading blank row on the non-holiday days too.
    expect(
      payload.monthCells
          .firstWhere((item) => item.day == 23)
          .leadingEventRowCount,
      1,
    );
    expect(
      payload.monthCells
          .firstWhere((item) => item.day == 24)
          .leadingEventRowCount,
      1,
    );
    final holidayCell = payload.monthCells.firstWhere(
      (item) => item.holidayName != null,
    );
    expect(holidayCell.holidayName, isNotNull);
  });

  test('HomeWidget raw payload preserves team and recurring semantic flags',
      () {
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.utc(2026, 8, 15),
      events: <EventModel>[
        EventModel(
          id: 'team-event',
          userId: 'user-1',
          title: '팀 일정',
          startAt: DateTime.utc(2026, 8, 15, 9),
          groupEventId: 'group-1',
        ),
        EventModel(
          id: 'recurring-event',
          userId: 'user-1',
          title: '반복 일정',
          startAt: DateTime.utc(2026, 8, 15, 10),
          recurrenceRule: 'FREQ=WEEKLY',
        ),
      ],
    );

    final byId = <String, Map<String, Object?>>{
      for (final event in payload.rawEvents) event['id']! as String: event,
    };
    expect(byId['team-event']?['is_team'], isTrue);
    expect(byId['recurring-event']?['is_recurring'], isTrue);
  });

  test(
      'HomeWidgetSchedulePayloadBuilder hides a recurring occurrence that was '
      'moved to a different date (single-occurrence override)', () {
    // 원래 버그: 반복 회차를 "이 일정만" 수정해 날짜를 옮기면, 위젯이 옮긴
    // 날짜(override.startAt)로 원본 회차를 찾으려 해서 원래 날짜(19일)에
    // 그대로 남아 보였다(2026-07-27). overriddenOccurrenceDate로 원래
    // 날짜를 명시해야 정확히 숨겨진다.
    final year = DateTime.now().year + 1;
    final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime(year, 5, 20, 4),
      events: <EventModel>[
        EventModel(
          id: 'series',
          userId: 'user-1',
          title: 'Weekly sync',
          startAt: DateTime(year, 5, 5, 9),
          recurrenceRule: 'FREQ=WEEKLY',
        ),
        EventModel(
          id: 'override-1',
          userId: 'user-1',
          title: 'Weekly sync',
          startAt: DateTime(year, 5, 21, 9),
          parentEventId: 'series',
          overriddenOccurrenceDate: DateTime(year, 5, 19, 9),
        ),
      ],
    );

    final originalDayCell =
        payload.monthCells.firstWhere((cell) => cell.day == 19);
    expect(
      originalDayCell.events.any((event) => event.title == 'Weekly sync'),
      isFalse,
      reason: '원본 회차(19일)는 다른 날로 옮겨졌으니 더 이상 보이면 안 된다',
    );
    final movedDayCell =
        payload.monthCells.firstWhere((cell) => cell.day == 21);
    expect(
      movedDayCell.events.any((event) => event.title == 'Weekly sync'),
      isTrue,
      reason: '옮긴 날(21일)에는 그대로 보여야 한다',
    );
  });

  test(
      'HomeWidgetSchedulePayloadBuilder fills holidayName/isDayOff for month cells',
      () {
    final octoberPayload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.parse('2026-10-05T04:00:00Z'),
      events: const <EventModel>[],
    );
    final gaecheonjeolCell =
        octoberPayload.monthCells.firstWhere((cell) => cell.day == 3);
    expect(gaecheonjeolCell.holidayName, '개천절');
    expect(gaecheonjeolCell.isDayOff, isTrue);

    final julyPayload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.parse('2026-07-05T04:00:00Z'),
      events: const <EventModel>[],
    );
    final jeheonjeolCell =
        julyPayload.monthCells.firstWhere((cell) => cell.day == 17);
    expect(jeheonjeolCell.holidayName, '제헌절');
    expect(jeheonjeolCell.isDayOff, isTrue);

    final priorJulyPayload = HomeWidgetSchedulePayloadBuilder.fromEvents(
      now: DateTime.parse('2025-07-05T04:00:00Z'),
      events: const <EventModel>[],
    );
    final priorJeheonjeolCell =
        priorJulyPayload.monthCells.firstWhere((cell) => cell.day == 17);
    expect(priorJeheonjeolCell.holidayName, '제헌절');
    expect(priorJeheonjeolCell.isDayOff, isFalse);
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
