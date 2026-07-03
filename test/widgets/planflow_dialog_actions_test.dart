import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/planflow_action_buttons.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size? surface,
  }) async {
    if (surface != null) {
      await tester.binding.setSurfaceSize(surface);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: child),
        ),
      ),
    );
  }

  testWidgets('넓은 화면에서는 Row로 가로 배치된다', (tester) async {
    await pump(
      tester,
      const PlanflowDialogActions(
        actions: [
          PlanflowDialogAction(label: '취소'),
          PlanflowDialogAction(label: '확인', isDefault: true),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Row), findsOneWidget);
    expect(find.byType(Wrap), findsNothing);
    expect(find.text('취소'), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);
  });

  testWidgets('좁은 화면(compactBreakpoint 이하)에서는 Wrap으로 전환된다',
      (tester) async {
    await pump(
      tester,
      const PlanflowDialogActions(
        actions: [
          PlanflowDialogAction(label: '나중에 다시 할게요'),
          PlanflowDialogAction(label: '지금 바로 저장하기', isDefault: true),
        ],
      ),
      surface: const Size(320, 640),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // LayoutBuilder 기반 전환: 좁은 화면에서는 Wrap.
    expect(find.byType(Wrap), findsOneWidget);
    expect(find.byType(Row), findsNothing);
  });

  testWidgets('모든 버튼이 테두리 있는 OutlinedButton으로 렌더링된다',
      (tester) async {
    await pump(
      tester,
      const PlanflowDialogActions(
        actions: [
          PlanflowDialogAction(label: '보조'),
          PlanflowDialogAction(label: '주요', isDefault: true),
          PlanflowDialogAction(label: '위험', isDestructive: true),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final outlinedButtons = find.byType(OutlinedButton);
    expect(outlinedButtons, findsNWidgets(3));
    // FilledButton은 단 한 개도 없어야 한다(규칙: 모두 테두리 OutlinedButton).
    expect(find.byType(FilledButton), findsNothing);

    // 각 OutlinedButton의 side(테두리)가 null이 아니어야 한다.
    for (final element in tester.widgetList<OutlinedButton>(outlinedButtons)) {
      final side = element.style?.side?.resolve(<WidgetState>{});
      expect(side, isNotNull, reason: '버튼에 테두리가 있어야 한다');
      expect(side!.width, greaterThan(0));
    }
  });

  testWidgets('onPressed 콜백이 정상 동작한다', (tester) async {
    var tapped = 0;
    await pump(
      tester,
      PlanflowDialogActions(
        actions: [
          PlanflowDialogAction(label: '확인', onPressed: () => tapped += 1),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('확인'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('onPressed가 null이면 비활성 버튼으로 렌더링된다', (tester) async {
    await pump(
      tester,
      const PlanflowDialogActions(
        actions: [
          PlanflowDialogAction(label: '확인'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.enabled, isFalse);
  });
}
