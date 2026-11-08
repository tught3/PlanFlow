import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/widgets/guided_anchor.dart';

class _Guide implements GuideCoordinator {
  _Guide({GuideStep step = GuideStep.homeMic})
      : state = ValueNotifier(GuideSnapshot(
            uid: 'u',
            version: 'real_ui_v1',
            revision: 1,
            serverRevision: 1,
            sessionId: 's',
            step: step,
            run: GuideRun.active));
  @override
  final ValueNotifier<GuideSnapshot> state;
  int dispatches = 0;
  int terminations = 0;
  @override
  Future<GuideSnapshot> start({required String uid}) async => state.value;
  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async {
    dispatches++;
    return state.value;
  }

  @override
  void suspend(GuidePauseReason reason) {}
  @override
  Future<void> terminate(GuideExit exit) async {
    terminations++;
  }

  @override
  Future<GuideAccess> authorize(
          {required GuideChargeContext context,
          required String operationId}) async =>
      const GuideAccess(
          status: GuideAccessStatus.denied, reasonCode: 'test-only');
}

void main() {
  testWidgets('offscreen mounted target stays unmasked and scroll activates it',
      (tester) async {
    final guide = _Guide();
    final registry = realUiGuideAnchorRegistry;
    var realControlTaps = 0;
    var skips = 0;
    await tester.pumpWidget(MaterialApp(
        // Native navigation padding must not close the target's tap opening.
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(padding: const EdgeInsets.only(bottom: 48)),
            child: child!),
        home: Scaffold(
            body: Stack(children: [
          Column(children: [
            TextButton(
                key: const ValueKey('visible-real-control'),
                onPressed: () => realControlTaps++,
                child: const Text('Unrelated real control')),
            Expanded(
                child: SingleChildScrollView(
                    child: SizedBox(
                        height: 1200,
                        child: Align(
                            alignment: Alignment.bottomCenter,
                            child: GuidedAnchor(
                                id: 'home.mic',
                                registry: registry,
                                child: ElevatedButton(
                                    key: const ValueKey('target'),
                                    onPressed: () => realControlTaps++,
                                    child: const Text('Real target'))))))),
          ]),
          Positioned.fill(
              child: RealUiGuideCoachmark(
                  coordinator: guide, onSkip: () => skips++)),
        ]))));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('1/7'), findsNothing);
    expect(find.text('안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 안내를 건너뛸 수 있어요.'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('visible-real-control')));
    expect(realControlTaps, 1);
    expect(guide.dispatches, 0);
    expect(skips, 0);

    await tester.ensureVisible(find.byKey(const ValueKey('target')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final visibleTarget = tester.getRect(find.byKey(const ValueKey('target')));
    expect(visibleTarget.top, greaterThanOrEqualTo(0));
    expect(
        visibleTarget.bottom,
        lessThanOrEqualTo(
            tester.view.physicalSize.height / tester.view.devicePixelRatio));
    expect(find.textContaining('1/7'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('target')));
    expect(realControlTaps, 2);
    expect(guide.dispatches, 0);
    await tester.tap(find.text('안내 건너뛰기'));
    expect(skips, 1);
    expect(guide.dispatches, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });

  testWidgets('covered route has neither coachmark nor passive fallback',
      (tester) async {
    final guide = _Guide();
    final registry = realUiGuideAnchorRegistry;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      GuidedAnchor(
          id: 'home.mic',
          registry: registry,
          child: ElevatedButton(
              key: const ValueKey('covered-target'),
              onPressed: () {},
              child: const Text('Covered target'))),
      Positioned.fill(child: RealUiGuideCoachmark(coordinator: guide)),
    ]))));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('1/7'), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const ValueKey('covered-target'))))
        .push(MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covering route'))));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('1/7'), findsNothing);
    expect(find.text('안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 안내를 건너뛸 수 있어요.'),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });

  testWidgets('nested viewport clip defeats on-window target coordinates',
      (tester) async {
    final guide = _Guide();
    final registry = realUiGuideAnchorRegistry;
    var skips = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
              height: 72,
              child: SingleChildScrollView(
                  child: SizedBox(
                      height: 240,
                      child: Column(children: [
                        const SizedBox(height: 180),
                        GuidedAnchor(
                            id: 'home.mic',
                            registry: registry,
                            child: ElevatedButton(
                                key: const ValueKey('nested-target'),
                                onPressed: () {},
                                child: const Text('Nested real target'))),
                      ]))))),
      Positioned.fill(
          child:
              RealUiGuideCoachmark(coordinator: guide, onSkip: () => skips++)),
    ]))));
    await tester.pump(const Duration(milliseconds: 120));
    final targetRect =
        tester.getRect(find.byKey(const ValueKey('nested-target')));
    expect(
        targetRect.top,
        lessThan(
            tester.view.physicalSize.height / tester.view.devicePixelRatio));
    expect(find.textContaining('1/7'), findsNothing);
    expect(find.text('안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 안내를 건너뛸 수 있어요.'),
        findsOneWidget);
    await tester.tap(find.text('안내 건너뛰기'));
    expect(skips, 1);
    expect(guide.dispatches, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });

  testWidgets(
      'createSpeech shows exact practice copy and leaves both real controls tappable',
      (tester) async {
    final guide = _Guide(step: GuideStep.createSpeech);
    final registry = realUiGuideAnchorRegistry;
    var transcriptTaps = 0;
    var micStarts = 0;
    var skips = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Align(
            alignment: const Alignment(0, -0.55),
            child: GuidedAnchor(
              id: 'voice.review',
              registry: registry,
              child: ElevatedButton(
                key: const ValueKey('review-field'),
                onPressed: () => transcriptTaps++,
                child: const Text('인식 결과'),
              ),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.15),
            child: GuidedAnchor(
              id: 'voice.start',
              registry: registry,
              child: FilledButton(
                key: const ValueKey('voice-primary-button'),
                onPressed: () => micStarts++,
                child: const Text('음성으로 일정 입력하기'),
              ),
            ),
          ),
          Positioned.fill(
            child:
                RealUiGuideCoachmark(coordinator: guide, onSkip: () => skips++),
          ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(find.text('1/7'), findsOneWidget);
    expect(find.text('말하기 교정 연습'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-correction-practice-sequence')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('voice-correction-practice-explanation')),
        findsOneWidget);
    expect(find.textContaining('말하면서 고치기'), findsNothing);
    expect(find.textContaining('완료누르기'), findsNothing);
    expect(find.text('예시 보기'), findsNothing);
    // Only the microphone button is lit now: it is the control that starts
    // recognition. The transcript card stays dimmed by the guide overlay, so
    // a tap there must not reach it.
    await tester.tap(find.byKey(const ValueKey('review-field')),
        warnIfMissed: false);
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    expect(transcriptTaps, 0);
    expect(micStarts, 1);
    expect(guide.dispatches, 0);
    await tester.tap(find.text('안내 건너뛰기'));
    expect(skips, 1);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });
}
