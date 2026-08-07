import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/widgets/planflow_voice_fab.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: child),
        ),
      ),
    );
  }

  testWidgets("'AI일정대화' 라벨이 정확히 1개 렌더된다", (tester) async {
    await pump(
      tester,
      PlanFlowAiConversationFab(onPressed: () {}),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('AI일정대화'), findsOneWidget);
  });

  testWidgets('backgroundColor가 PlanFlowColors.active와 같다', (tester) async {
    await pump(
      tester,
      PlanFlowAiConversationFab(onPressed: () {}),
    );
    await tester.pumpAndSettle();

    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.backgroundColor, PlanFlowColors.active);
  });

  testWidgets('Icons.chat_bubble_outline 아이콘이 존재한다', (tester) async {
    await pump(
      tester,
      PlanFlowAiConversationFab(onPressed: () {}),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
  });

  testWidgets('탭하면 onPressed 콜백이 정확히 1회 호출된다', (tester) async {
    var tapCount = 0;
    await pump(
      tester,
      PlanFlowAiConversationFab(
        onPressed: () {
          tapCount += 1;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlanFlowAiConversationFab));
    await tester.pumpAndSettle();

    expect(tapCount, 1);
  });
}
