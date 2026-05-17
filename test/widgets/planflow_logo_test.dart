import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/widgets/planflow_logo.dart';

void main() {
  testWidgets('PlanFlowLogo colors Plan and Flow separately', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlanFlowLogo(),
        ),
      ),
    );

    expect(find.bySemanticsLabel('PlanFlow'), findsOneWidget);

    final richText = tester.widget<RichText>(find.byType(RichText));
    final rootSpan = richText.text as TextSpan;
    final spans = rootSpan.children!.cast<TextSpan>();

    expect(spans[0].text, 'Plan');
    expect(spans[0].style?.color, PlanFlowColors.primaryMid);
    expect(spans[1].text, 'Flow');
    expect(spans[1].style?.color, const Color(0xFF111827));
    expect(rootSpan.style?.fontWeight, FontWeight.w900);
    expect(rootSpan.style?.letterSpacing, 0);
  });
}
