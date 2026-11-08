import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/voice_correction_example.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';

void main() {
  testWidgets(
      'practice copy has one hierarchy and no simulated example controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(child: VoiceCorrectionExample())),
    ));
    expect(find.text('말하기 교정 연습'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-correction-practice-sequence')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-correction-practice-explanation')),
        findsOneWidget);
    expect(find.textContaining('완료'), findsNothing);
    expect(find.textContaining('말하면서 고치기'), findsNothing);
    expect(find.textContaining('예시 보기'), findsNothing);
    expect(find.textContaining('처음부터 보기'), findsNothing);
  });

  testWidgets(
      'both real controls remain tappable through bright coachmark holes',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    var transcriptHits = 0;
    var sttStarts = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Align(
            alignment: Alignment.topCenter,
            child: GuidedAnchor(
              id: 'voice.review',
              registry: registry,
              child: ElevatedButton(
                onPressed: () => transcriptHits++,
                child: const Text('Transcript'),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: GuidedAnchor(
              id: 'voice.start',
              registry: registry,
              child: FilledButton(
                key: const ValueKey('voice-primary-button'),
                onPressed: () => sttStarts++,
                child: const Text('음성으로 일정 입력하기'),
              ),
            ),
          ),
          GuidedCoachmarkOverlay(
            registry: registry,
            targetId: 'voice.review',
            additionalTargetIds: const ['voice.start'],
            bubble: const Text('말하기 교정 연습'),
            progressLabel: '1/7',
            onSkip: () {},
          ),
        ]),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Transcript'));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    expect(transcriptHits, 1);
    expect(sttStarts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('practice copy fits a narrow viewport at large text scale',
      (tester) async {
    tester.view.physicalSize = const Size(240, 320);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: VoiceCorrectionExample()),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('말하기 교정 연습'), findsOneWidget);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
