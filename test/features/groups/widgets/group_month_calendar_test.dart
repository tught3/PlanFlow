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
    String? Function(String createdBy)? ownerNameOf,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 실제 화면(GroupEventListScreen._buildCalendarView)에서도 이
          // 위젯은 항상 ListView 안에 들어가 스크롤된다. 테스트도 동일하게
          // 스크롤 가능한 컨테이너로 감싸야, 멤버가 많아 칸이 커질 때
          // 고정 뷰포트에서 거짓 오버플로우가 나지 않는다.
          body: SingleChildScrollView(
            child: GroupMonthCalendar(
              events: events,
              focusedMonth: focusedMonth,
              onMonthChanged: (_) {},
              initialSelectedDay: initialSelectedDay,
              ownerNameOf: ownerNameOf,
            ),
          ),
        ),
      ),
    );
  }

  GroupEventModel eventOn(
    String id,
    DateTime day, {
    String createdBy = 'u1',
  }) =>
      GroupEventModel(
        id: id,
        groupId: 'g1',
        title: '일정 $id',
        startAt: planflowSeoulDateTimeToUtc(
          DateTime(day.year, day.month, day.day, 10),
        ),
        endAt: planflowSeoulDateTimeToUtc(
          DateTime(day.year, day.month, day.day, 11),
        ),
        createdBy: createdBy,
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

  group('날짜 칸 멤버별 집계', () {
    final names = <String, String>{
      'u1': '김철수',
      'u2': '박민지',
      'u3': '이정훈',
      'u4': '최수아',
      'u5': '한도윤',
    };
    String? ownerNameOf(String userId) => names[userId];

    testWidgets(
      '멤버 1명이면 "이름 N건" 한 줄만 뜬다(그냥 총건수만 뜨지 않음)',
      (tester) async {
        final month = DateTime(2026, 7);
        final day = DateTime(2026, 7, 15);
        final events = [
          eventOn('e1', day, createdBy: 'u1'),
          eventOn('e2', day, createdBy: 'u1'),
        ];

        await pumpCalendar(
          tester,
          events: events,
          focusedMonth: month,
          ownerNameOf: ownerNameOf,
        );

        expect(find.text('김철수 2건'), findsOneWidget);
        expect(find.text('2건'), findsNothing);
      },
    );

    testWidgets(
      '멤버가 늘어나면 각자 이름별로 줄이 따로 나뉘어 건수가 집계된다',
      (tester) async {
        final month = DateTime(2026, 7);
        final day = DateTime(2026, 7, 15);
        final events = [
          eventOn('e1', day, createdBy: 'u1'),
          eventOn('e2', day, createdBy: 'u1'),
          eventOn('e3', day, createdBy: 'u2'),
        ];

        await pumpCalendar(
          tester,
          events: events,
          focusedMonth: month,
          ownerNameOf: ownerNameOf,
        );

        expect(find.text('김철수 2건'), findsOneWidget);
        expect(find.text('박민지 1건'), findsOneWidget);
      },
    );

    testWidgets(
      '멤버가 4명을 넘으면(예: 5명) 마지막 줄이 "+N명"으로 요약되고 '
      '건수가 많은 순으로 정렬된다',
      (tester) async {
        final month = DateTime(2026, 7);
        final day = DateTime(2026, 7, 15);
        final events = [
          eventOn('e1', day, createdBy: 'u1'),
          eventOn('e2', day, createdBy: 'u1'),
          eventOn('e3', day, createdBy: 'u2'),
          eventOn('e4', day, createdBy: 'u3'),
          eventOn('e5', day, createdBy: 'u4'),
          eventOn('e6', day, createdBy: 'u5'),
        ];

        await pumpCalendar(
          tester,
          events: events,
          focusedMonth: month,
          ownerNameOf: ownerNameOf,
        );

        expect(find.text('김철수 2건'), findsOneWidget);
        expect(find.text('+2명'), findsOneWidget);
      },
    );
  });
}
