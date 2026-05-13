import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';

void main() {
  testWidgets('EventEditScreen uses inline calendar style editor',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(2026, 5, 13, 0),
            endAt: DateTime.utc(2026, 5, 13, 1),
            category: '업무',
          ),
        ),
      ),
    );

    expect(find.text('하루'), findsNothing);
    expect(find.text('연속'), findsNothing);
    expect(find.text('서울 (GMT+9:00)'), findsNothing);
    expect(find.text('기본 정보'), findsOneWidget);
    expect(find.text('날짜 · 시간'), findsOneWidget);
    expect(find.text('시작 시간 조정'), findsNothing);

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(find.text('시작 시간 조정'), findsOneWidget);
  });
}
