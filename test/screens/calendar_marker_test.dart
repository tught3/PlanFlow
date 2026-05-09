import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';

void main() {
  test('calendar marker is red when the day has a critical event', () {
    final markerColors = buildCalendarEventMarkerColorsByDay(
      focusedMonth: DateTime(2026, 5),
      events: <EventModel>[
        EventModel(
          id: 'normal',
          userId: 'user',
          title: '일반 일정',
          startAt: DateTime(2026, 5, 7, 9),
        ),
        EventModel(
          id: 'critical',
          userId: 'user',
          title: '중요 일정',
          startAt: DateTime(2026, 5, 7, 10),
          isCritical: true,
        ),
      ],
    );

    expect(markerColors[7], calendarCriticalEventMarkerColor);
  });

  test('calendar marker is blue when the day only has normal events', () {
    final markerColors = buildCalendarEventMarkerColorsByDay(
      focusedMonth: DateTime(2026, 5),
      events: <EventModel>[
        EventModel(
          id: 'normal',
          userId: 'user',
          title: '일반 일정',
          startAt: DateTime(2026, 5, 8, 9),
        ),
      ],
    );

    expect(markerColors[8], PlanFlowColors.active);
  });

  test('calendar marker spans every day of a multi-day event', () {
    final markerColors = buildCalendarEventMarkerColorsByDay(
      focusedMonth: DateTime(2026, 5),
      events: <EventModel>[
        EventModel(
          id: 'multi-day',
          userId: 'user',
          title: '연속 일정',
          startAt: DateTime(2026, 4, 30, 9),
          endAt: DateTime(2026, 5, 2, 18),
          isMultiDay: true,
        ),
      ],
    );

    expect(markerColors[1], PlanFlowColors.active);
    expect(markerColors[2], PlanFlowColors.active);
  });

  test('calendar marker groups UTC instants by local Korean day', () {
    final markerColors = buildCalendarEventMarkerColorsByDay(
      focusedMonth: DateTime(2026, 5),
      events: <EventModel>[
        EventModel(
          id: 'naver-midnight',
          userId: 'user',
          title: '네이버 새벽 일정',
          startAt: DateTime.utc(2026, 5, 4, 15, 30),
          isCritical: true,
        ),
      ],
    );

    expect(markerColors[5], calendarCriticalEventMarkerColor);
    expect(markerColors[4], isNull);
  });
}
