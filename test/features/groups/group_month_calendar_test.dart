import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/widgets/group_month_calendar.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/screens/calendar/calendar_style_contract.dart';

void main() {
  testWidgets(
    'GroupMonthCalendar shows the selected day events list below the grid',
    (tester) async {
      // 자정 경계 flakiness를 피하려고 KST 정오로 오늘 일정을 만든다.
      final now = planflowNow();
      final todayNoonUtc = DateTime.utc(now.year, now.month, now.day, 3);
      final event = GroupEventModel(
        id: 'group-event-today',
        groupId: 'group-1',
        title: '팀 스탠드업',
        startAt: todayNoonUtc,
        endAt: todayNoonUtc.add(const Duration(hours: 1)),
        createdBy: 'user-1',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // 실제 화면(GroupEventListScreen._buildCalendarView)에서 이
            // 위젯은 항상 ListView 안에서 스크롤된다. 고정 뷰포트인
            // Scaffold.body에 바로 넣으면 콘텐츠가 조금만 커져도 거짓
            // 오버플로우가 난다.
            body: SingleChildScrollView(
              child: GroupMonthCalendar(
                events: [event],
                focusedMonth: DateTime(now.year, now.month),
                onMonthChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 기본 선택 날짜는 오늘이므로, 탭 없이도 오늘 일정 목록이 그리드 아래
      // 바로 보여야 한다 (사용자가 지적한 "선택 날짜 일정이 안 보임" 회귀 방지).
      expect(find.text('팀 스탠드업'), findsOneWidget);
      expect(find.text('이 날에 등록된 일정이 없어요.'), findsNothing);
    },
  );

  testWidgets(
    'GroupMonthCalendar keeps today circle on selected today and outline-only on other selected days',
    (tester) async {
      final now = planflowNow();
      final focusedMonth = DateTime(now.year, now.month);
      final today = DateTime(now.year, now.month, now.day);
      final otherDay = _findSelectableWeekday(focusedMonth, today);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GroupMonthCalendar(
                events: const [],
                focusedMonth: focusedMonth,
                onMonthChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final todayCellKey = ValueKey(
        'group-calendar-day-cell-${today.year}-${today.month}-${today.day}',
      );
      final todayCircleKey = ValueKey(
        'group-calendar-day-circle-${today.year}-${today.month}-${today.day}',
      );
      final todayText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(todayCellKey),
          matching: find.byType(Text),
        ),
      );
      final todayCircle = tester.widget<AnimatedContainer>(
        find.byKey(todayCircleKey),
      );
      final todayCell = tester.widget<Container>(find.byKey(todayCellKey));

      expect(todayText.style?.color, Colors.white);
      expect(
        (todayCircle.decoration! as BoxDecoration).color,
        PlanFlowColors.calendarTodayCircle,
      );
      expect(
        (todayCell.decoration! as BoxDecoration).border,
        isA<Border>().having(
          (border) => border.top.color,
          'top color',
          PlanFlowColors.primary,
        ),
      );

      final otherCellKey = ValueKey(
        'group-calendar-day-cell-${otherDay.year}-${otherDay.month}-${otherDay.day}',
      );
      final otherCircleKey = ValueKey(
        'group-calendar-day-circle-${otherDay.year}-${otherDay.month}-${otherDay.day}',
      );
      await tester.tap(find.byKey(otherCellKey));
      await tester.pumpAndSettle();

      final otherText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(otherCellKey),
          matching: find.byType(Text),
        ),
      );
      final otherCircle = tester.widget<AnimatedContainer>(
        find.byKey(otherCircleKey),
      );
      final otherCell = tester.widget<Container>(find.byKey(otherCellKey));

      expect(otherText.style?.color, calendarNormalEventTextColor);
      expect(
        (otherCircle.decoration! as BoxDecoration).color,
        Colors.transparent,
      );
      expect(
        (otherCell.decoration! as BoxDecoration).border,
        isA<Border>().having(
          (border) => border.top.color,
          'top color',
          PlanFlowColors.primary,
        ),
      );
    },
  );
}

DateTime _findSelectableWeekday(DateTime focusedMonth, DateTime today) {
  for (var day = 1; day <= 31; day++) {
    final candidate = DateTime(focusedMonth.year, focusedMonth.month, day);
    if (candidate.month != focusedMonth.month) {
      break;
    }
    if (candidate.year == today.year &&
        candidate.month == today.month &&
        candidate.day == today.day) {
      continue;
    }
    if (candidate.weekday != DateTime.saturday &&
        candidate.weekday != DateTime.sunday) {
      return candidate;
    }
  }
  throw StateError('No selectable weekday found in the focused month');
}
