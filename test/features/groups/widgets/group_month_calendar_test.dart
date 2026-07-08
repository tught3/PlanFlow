import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/widgets/group_month_calendar.dart';

void main() {
  Future<void> pumpCalendar(
    WidgetTester tester, {
    required List<GroupEventModel> events,
    required DateTime focusedMonth,
    DateTime? initialSelectedDay,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupMonthCalendar(
            events: events,
            focusedMonth: focusedMonth,
            onMonthChanged: (_) {},
            initialSelectedDay: initialSelectedDay,
          ),
        ),
      ),
    );
  }

  GroupEventModel eventOn(String id, DateTime day) => GroupEventModel(
        id: id,
        groupId: 'g1',
        title: '일정 $id',
        startAt: planflowSeoulDateTimeToUtc(
          DateTime(day.year, day.month, day.day, 10),
        ),
        endAt: planflowSeoulDateTimeToUtc(
          DateTime(day.year, day.month, day.day, 11),
        ),
        createdBy: 'u1',
      );

  testWidgets(
    'initialSelectedDay가 없으면 오늘이 선택된 채로 뜬다(기존 기본 동작 유지)',
    (tester) async {
      final now = planflowNow();
      final today = DateTime(now.year, now.month, now.day);
      final month = DateTime(today.year, today.month);
      await pumpCalendar(tester, events: const [], focusedMonth: month);

      expect(find.text('${today.month}월 ${today.day}일 일정'), findsOneWidget);
    },
  );

  testWidgets(
    'initialSelectedDay가 주어지면 홈 위젯 날짜 클릭처럼 그 날짜가 처음부터 선택돼 '
    '해당 날짜의 그룹일정이 바로 보인다(오늘로 고정되지 않음)',
    (tester) async {
      final month = DateTime(2026, 7);
      final targetDay = DateTime(2026, 7, 15);
      final events = [eventOn('e1', targetDay)];

      await pumpCalendar(
        tester,
        events: events,
        focusedMonth: month,
        initialSelectedDay: targetDay,
      );

      expect(find.text('7월 15일 일정'), findsOneWidget);
      expect(find.text('일정 e1'), findsOneWidget);
    },
  );

  testWidgets(
    'initialSelectedDay로 지정한 날짜에 일정이 없으면 "등록된 일정이 없어요"가 뜬다'
    '(다른 날짜의 일정으로 잘못 새지 않음을 확인)',
    (tester) async {
      final month = DateTime(2026, 7);
      final targetDay = DateTime(2026, 7, 20);
      final events = [eventOn('e1', DateTime(2026, 7, 15))];

      await pumpCalendar(
        tester,
        events: events,
        focusedMonth: month,
        initialSelectedDay: targetDay,
      );

      expect(find.text('7월 20일 일정'), findsOneWidget);
      expect(find.text('이 날에 등록된 일정이 없어요.'), findsOneWidget);
      expect(find.text('일정 e1'), findsNothing);
    },
  );
}
