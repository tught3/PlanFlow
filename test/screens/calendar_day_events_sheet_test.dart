import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/korean_holidays.dart';

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

  testWidgets('DayEventsSheet shows holiday name when day is a holiday',
      (tester) async {
    // banned-ok: 광복절(8/15)은 매년 고정 공휴일이라 연도 무관 결정적, 클램프/만료 로직 미사용
    final holidayDate = DateTime(2026, 8, 15);
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 360,
            child: DayEventsSheet(
              day: holidayDate,
              personalEvents: const [],
              groupEvents: const [],
              onAdd: () {},
              onVoice: () {},
              onEventTap: (_) {},
              onGroupEventTap: (_) {},
              holidayName: KoreanHolidays.holidayName(holidayDate),
            ),
          ),
        ),
      ),
    );

    expect(find.text('광복절'), findsOneWidget);
  });

  testWidgets(
      'DayEventsSheet omits holiday text on non-holiday days (no regression)',
      (tester) async {
    // banned-ok: 기존 테스트와 동일 기준일로 요일 라벨('수요일') 검증, 클램프/만료 로직 미사용
    final weekday = DateTime(2026, 5, 13);
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 360,
            child: DayEventsSheet(
              day: weekday,
              personalEvents: const [],
              groupEvents: const [],
              onAdd: () {},
              onVoice: () {},
              onEventTap: (_) {},
              onGroupEventTap: (_) {},
              holidayName: KoreanHolidays.holidayName(weekday),
            ),
          ),
        ),
      ),
    );

    expect(KoreanHolidays.holidayName(weekday), isNull);
    expect(find.text('5월 13일 수요일'), findsOneWidget);
    expect(find.text('직접 추가'), findsOneWidget);
    expect(find.text('음성 추가'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('calendar-day-events-empty-scroll')),
        findsOneWidget);
  });
}
