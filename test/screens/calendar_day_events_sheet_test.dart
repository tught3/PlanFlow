import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';

void main() {
  testWidgets('DayEventsSheet keeps actions visible and scrolls many events',
      (tester) async {
    final events = List<EventModel>.generate(
      14,
      (index) => EventModel(
        id: 'event-$index',
        userId: 'user-1',
        title: '테스트 일정 ${index + 1}',
        startAt: DateTime(2026, 5, 12, 9 + index),
      ),
    );

    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 360,
            child: DayEventsSheet(
              day: DateTime(2026, 5, 12),
              personalEvents: events,
              groupEvents: const [],
              onAdd: () {},
              onVoice: () {},
              onEventTap: (_) {},
              onGroupEventTap: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('5월 12일 화요일'), findsOneWidget);
    expect(find.text('직접 추가'), findsOneWidget);
    expect(find.text('음성 추가'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('calendar-day-events-list')), findsOneWidget);
    expect(find.text('테스트 일정 1'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('테스트 일정 14'),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('직접 추가'), findsOneWidget);
    expect(find.text('음성 추가'), findsOneWidget);
    expect(find.text('테스트 일정 14'), findsOneWidget);
  });
}
