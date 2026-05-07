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
}
