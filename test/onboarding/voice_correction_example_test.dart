import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/voice_correction_example.dart';

void main() {
  testWidgets('practice copy is exact, ordered, and has no duplicate/demo UI',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(child: VoiceCorrectionExample())),
    ));
    final heading = tester.widget<Text>(find.text('말하기 교정 연습'));
    final instruction = tester.widget<Text>(
        find.byKey(const ValueKey('voice-correction-practice-sequence')));
    final explanation = tester.widget<Text>(
        find.byKey(const ValueKey('voice-correction-practice-explanation')));
    expect(
        instruction.data,
        '음성으로 일정 입력하기 버튼을 누르고\n'
        '“내일 오후 1시에”\n'
        '→ “아니”\n'
        '→ “오후 2시에 강남역에서 일정”\n'
        '순서로 말해보세요.');
    final explanationSpan = explanation.textSpan! as TextSpan;
    final boldSpan = explanationSpan.children!.first as TextSpan;
    expect(boldSpan.text, '“오후 1시에”가 입력됐다가 “아니”라고 말하면 지워집니다.');
    expect(boldSpan.style!.fontWeight, FontWeight.w700);
    expect(explanationSpan.toPlainText(),
        '“오후 1시에”가 입력됐다가 “아니”라고 말하면 지워집니다. 이어서 “오후 2시에 강남역에서 일정”이라고 말하면 “내일 오후 2시에 강남역에서 일정”으로 입력됩니다. (“아니” 대신 “다시”라고 말하면 전체 삭제)');
    expect(heading.style!.fontSize, greaterThan(instruction.style!.fontSize!));
    expect(instruction.style!.fontSize,
        greaterThan(explanation.style?.fontSize ?? 0));
    expect(find.textContaining('말하면서 고치기'), findsNothing);
    expect(find.textContaining('완료누르기'), findsNothing);
    expect(find.textContaining('완료 버튼'), findsNothing);
    expect(find.byKey(const ValueKey('voice-correction-example-toggle')),
        findsNothing);
    expect(find.byKey(const ValueKey('voice-correction-final-goal')),
        findsNothing);
    expect(find.textContaining('예시 보기'), findsNothing);
    expect(find.textContaining('처음부터 보기'), findsNothing);
  });

  testWidgets(
      'practice remains scrollable without overflow on narrow large text',
      (tester) async {
    tester.view.physicalSize = const Size(240, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: const Scaffold(
        body: SingleChildScrollView(child: VoiceCorrectionExample()),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('말하기 교정 연습'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-correction-practice-sequence')),
        findsOneWidget);
  });
}
