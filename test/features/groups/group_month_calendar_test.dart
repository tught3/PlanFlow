import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/widgets/group_month_calendar.dart';

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
            body: GroupMonthCalendar(
              events: [event],
              focusedMonth: DateTime(now.year, now.month),
              onMonthChanged: (_) {},
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
}
