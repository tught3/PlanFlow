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

  testWidgets('취소/확인 버튼이 오류 없이 Row로 렌더된다', (tester) async {
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
    expect(find.byType(Row), findsOneWidget);
  });

  testWidgets('버튼 1개도 크래시 없이 렌더된다', (tester) async {
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
    expect(find.text('닫기'), findsOneWidget);
  });

  testWidgets('좁은 화면에서 라벨 길이가 다른 3버튼도 텍스트가 전부 보인다(축소가림 회귀)',
      (tester) async {
    // 실증 버그: 반복일정 수정 다이얼로그에서 flex 1:1:2로 좁게 눌려
    // "이 일정만"/"이후 모든 일정" 글자가 안 보였다. 이제는 라벨 실측
    // 너비로 배치하므로 좁은 화면에서도 세 라벨이 모두 텍스트로 보여야 한다.
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pump(
      tester,
      PlanFlowActionButtons(
        buttons: [
          PlanFlowActionButton(
            label: '이 일정만',
            onPressed: () {},
          ),
          PlanFlowActionButton(
            label: '이후 모든 일정',
            onPressed: () {},
          ),
          PlanFlowActionButton(
            label: '전체 반복 일정',
            onPressed: () {},
            type: ActionButtonType.primary,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('이 일정만'), findsOneWidget);
    expect(find.text('이후 모든 일정'), findsOneWidget);
    expect(find.text('전체 반복 일정'), findsOneWidget);
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

  testWidgets('borderWidth/fontSize로 선택된 버튼을 더 두껍고 크게 강조할 수 있다',
      (tester) async {
    // 오전/오후 선택처럼 여러 버튼 중 하나가 "현재 선택됨" 상태일 때,
    // 테두리 두께와 글자 크기로 눈에 띄게 강조할 수 있어야 한다.
    await pump(
      tester,
      PlanFlowActionButtons(
        buttons: [
          PlanFlowActionButton(
            label: '오전 8:00',
            onPressed: () {},
            borderWidth: 1.0,
            fontSize: 13,
          ),
          PlanFlowActionButton(
            label: '오후 8:00',
            onPressed: () {},
            type: ActionButtonType.primary,
            borderWidth: 2.5,
            fontSize: 16,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final unselectedButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '오전 8:00'),
    );
    final unselectedSide = unselectedButton.style?.side?.resolve(<WidgetState>{});
    expect(unselectedSide?.width, 1.0);

    final selectedButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '오후 8:00'),
    );
    final selectedShape =
        selectedButton.style?.shape?.resolve(<WidgetState>{})
            as RoundedRectangleBorder?;
    expect(selectedShape?.side.width, 2.5);

    final selectedTextStyle =
        selectedButton.style?.textStyle?.resolve(<WidgetState>{});
    expect(selectedTextStyle?.fontSize, 16);
  });
}
