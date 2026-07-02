import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/planflow_action_buttons.dart';

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

  testWidgets('flex 버튼(취소/확인 반반)이 ParentData 오류 없이 렌더된다',
      (tester) async {
    // 회귀: 이전엔 Wrap 안에 Expanded를 넣어 "Incorrect use of ParentDataWidget"로
    // 크래시했음. flex 버튼은 Row로 배치돼 Expanded가 정상 동작해야 한다.
    await pump(
      tester,
      planflowCancelConfirmButtons(
        onCancel: () {},
        onConfirm: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('취소'), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);
    expect(find.byType(Expanded), findsNWidgets(2));
  });

  testWidgets('flex 없는 버튼은 Wrap으로 배치되고 크래시하지 않는다', (tester) async {
    await pump(
      tester,
      const PlanFlowActionButtons(
        buttons: [
          PlanFlowActionButton(
            label: '닫기',
            onPressed: null,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Wrap), findsOneWidget);
    expect(find.text('닫기'), findsOneWidget);
  });

  testWidgets('좁은 화면에서도 flex 버튼이 오버플로우 없이 렌더된다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pump(
      tester,
      planflowCancelConfirmButtons(
        onCancel: () {},
        onConfirm: () {},
        cancelLabel: '나중에 다시 할게요',
        confirmLabel: '지금 바로 저장하기',
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
