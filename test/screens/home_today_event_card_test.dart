import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/home/widgets/today_event_card.dart';

void main() {
  testWidgets('TodayEventCard shows v3 smart prep wording', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TodayEventCard(
            title: '회의',
            timeRange: '10:00',
            hasPreActions: true,
          ),
        ),
      ),
    );

    expect(find.text('스마트 준비'), findsOneWidget);
    expect(find.text('사전 액션'), findsNothing);
  });

  testWidgets('TodayEventCard marks done status as past schedule',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TodayEventCard(
            title: '끝난 일정',
            timeRange: '09:00',
            status: TodayEventStatus.done,
          ),
        ),
      ),
    );

    expect(find.text('지난 일정'), findsOneWidget);
    expect(find.text('완료'), findsNothing);
  });
}
