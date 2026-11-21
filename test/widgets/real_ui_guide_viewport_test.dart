import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/screens/onboarding/legacy_intro_screen.dart';
import 'package:planflow/services/feature_tour_service.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';

class _Guide implements GuideCoordinator {
  _Guide({GuideStep step = GuideStep.homeMic, DateTime? savedLocalDate})
      : state = ValueNotifier(GuideSnapshot(
            uid: 'u',
            version: 'real_ui_v1',
            revision: 1,
            serverRevision: 1,
            sessionId: 's',
            step: step,
            run: GuideRun.active,
            savedLocalDate: savedLocalDate));
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

class _FeatureTourStore extends FeatureTourStore {
  int completions = 0;

  @override
  Future<void> markCompleted() async {
    completions++;
  }

  @override
  Future<bool> shouldShow() async => completions == 0;

  @override
  Future<void> markTipShown(String tipId) async {}

  @override
  Future<bool> shouldShowTip(String tipId) async => false;
}

void main() {
  testWidgets('legacy intro stays tappable before the 1/7 target mounts',
      (tester) async {
    final guide = _Guide();
    final initial = guide.state.value;
    final tourStore = _FeatureTourStore();
    final navigator = GlobalKey<NavigatorState>();
    final showMic = ValueNotifier(false);
    final missingTarget = find.textContaining('안내할 실제 화면을 기다리고 있어요');
    final next = find.byKey(const ValueKey('legacy-intro-next-button'));
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      builder: (context, child) => Stack(fit: StackFit.expand, children: [
        child!,
        RealUiGuideCoachmark(coordinator: guide),
      ]),
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: showMic,
            builder: (_, visible, __) => visible
                ? GuidedAnchor(
                    id: 'home.mic',
                    registry: realUiGuideAnchorRegistry,
                    child: FilledButton(
                      onPressed: () {},
                      child: const Text('마이크'),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(missingTarget, findsOneWidget);

    navigator.currentState!.push<void>(MaterialPageRoute<void>(
      builder: (_) => LegacyIntroScreen(store: tourStore),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(realUiGuideAnchorRegistry.keyFor('home.mic'), isNull);
    expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);
    expect(find.textContaining('안내할 실제 화면을 기다리고 있어요'), findsNothing);
    expect(find.text('안내 건너뛰기'), findsNothing);

    expect(find.text('다음'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('AI 대화로 일정도 고쳐요'), findsOneWidget);
    expect(missingTarget, findsNothing);
    expect(find.text('다음'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('출발과 브리핑을 챙겨드려요'), findsOneWidget);
    expect(missingTarget, findsNothing);
    expect(find.text('시작하기'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tourStore.completions, 1);
    expect(find.byType(LegacyIntroScreen), findsNothing);
    // The route change alone restores the usual fallback until home is ready.
    expect(missingTarget, findsOneWidget);

    showMic.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('1/7 · 음성으로 입력 시작'), findsOneWidget);
    expect(missingTarget, findsNothing);
    expect(guide.state.value, same(initial));
    expect(guide.dispatches, 0);
    expect(guide.terminations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    showMic.dispose();
    guide.state.dispose();
  });

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
    expect(find.text('안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 뒤로가기로 안내를 닫을 수 있어요.'),
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
    expect(find.text('안내 건너뛰기'), findsNothing);
    expect(skips, 0);
    expect(guide.dispatches, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });

  for (final step in [GuideStep.savedDetail, GuideStep.editPreview]) {
    testWidgets('guide card leaves a gap above its bottom action at $step',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 760);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final guide = _Guide(step: step);
      final isDetail = step == GuideStep.savedDetail;
      final summaryId = isDetail ? 'saved.summary' : 'edit.location';
      final actionId = isDetail ? 'saved.confirm' : 'edit.save.footer';
      const summaryKey = ValueKey('guide-visible-summary');
      const actionKey = ValueKey('guide-bottom-action');
      var actionTaps = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            if (!isDetail)
              Positioned(
                right: 16,
                top: 16,
                child: GuidedAnchor(
                  id: 'edit.save',
                  registry: realUiGuideAnchorRegistry,
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('저장'),
                  ),
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              top: 140,
              height: 100,
              child: GuidedAnchor(
                id: summaryId,
                registry: realUiGuideAnchorRegistry,
                child: const SizedBox(key: summaryKey),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              height: 56,
              child: GuidedAnchor(
                id: actionId,
                registry: realUiGuideAnchorRegistry,
                child: FilledButton(
                  key: actionKey,
                  onPressed: () => actionTaps++,
                  child: Text(isDetail ? '준비·출발 안내 확인' : '변경 저장'),
                ),
              ),
            ),
            Positioned.fill(child: RealUiGuideCoachmark(coordinator: guide)),
          ]),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      final heading =
          find.text(isDetail ? '3/7 · 저장된 일정 확인' : '6/7 · 변경 내용 확인·저장');
      expect(heading, findsOneWidget);
      final card = find.ancestor(of: heading, matching: find.byType(Material));
      final cardRect = tester.getRect(card.first);
      final buttonRect = tester.getRect(find.byKey(actionKey));
      expect(cardRect.top,
          greaterThan(tester.getRect(find.byKey(summaryKey)).bottom));
      expect(buttonRect.top - cardRect.bottom, closeTo(20, 1));
      expect(tester.getTopLeft(heading).dy - cardRect.top,
          greaterThanOrEqualTo(15));

      await tester.tap(find.byKey(actionKey));
      expect(actionTaps, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      guide.state.dispose();
    });
  }

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
    expect(find.text('안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 뒤로가기로 안내를 닫을 수 있어요.'),
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
    expect(find.text('안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 뒤로가기로 안내를 닫을 수 있어요.'),
        findsOneWidget);
    expect(find.text('안내 건너뛰기'), findsNothing);
    expect(skips, 0);
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
    var submits = 0;
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
          Align(
            alignment: const Alignment(0.85, 0.6),
            child: GuidedAnchor(
              id: 'voice.submit',
              registry: registry,
              child: FilledButton(
                key: const ValueKey('submit-current'),
                onPressed: () => submits++,
                child: const Text('현재 내용으로 입력'),
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
    // The microphone is lit, the dimmed submit remains tappable, and other
    // controls stay blocked.
    await tester.tap(find.byKey(const ValueKey('review-field')),
        warnIfMissed: false);
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.tap(find.byKey(const ValueKey('submit-current')));
    expect(transcriptTaps, 0);
    expect(micStarts, 1);
    expect(submits, 1);
    expect(guide.dispatches, 0);
    expect(find.text('안내 건너뛰기'), findsNothing);
    expect(skips, 0);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });

  testWidgets('query input highlights microphone as well as transcript',
      (tester) async {
    final guide = _Guide(step: GuideStep.querySpeech);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Align(
            alignment: const Alignment(0, 0.15),
            child: GuidedAnchor(
              id: 'voice.review',
              registry: realUiGuideAnchorRegistry,
              child: const SizedBox(width: 240, height: 80),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.55),
            child: GuidedAnchor(
              id: 'voice.start',
              registry: realUiGuideAnchorRegistry,
              child: const SizedBox(width: 200, height: 60),
            ),
          ),
          Positioned.fill(child: RealUiGuideCoachmark(coordinator: guide)),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    final overlay = tester
        .widget<GuidedCoachmarkOverlay>(find.byType(GuidedCoachmarkOverlay));
    expect(overlay.targetId, 'voice.review');
    expect(overlay.additionalTargetIds, contains('voice.start'));
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });

  testWidgets('query retry shows saved local date and remains at 4/7',
      (tester) async {
    var micTaps = 0;
    var sendTaps = 0;
    var unrelatedTaps = 0;
    final guide = _Guide(
        step: GuideStep.querySpeech,
        savedLocalDate: DateTime.utc(2026, 11, 12, 16));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Align(
            alignment: const Alignment(0, -0.3),
            child: GuidedAnchor(
              id: 'query.retry',
              registry: realUiGuideAnchorRegistry,
              child: const SizedBox(
                width: 300,
                height: 60,
                child: Center(child: Text('해당 날짜의 일정은 없어요.')),
              ),
            ),
          ),
          Align(
            alignment: const Alignment(-0.8, 0.75),
            child: GuidedAnchor(
              id: 'query.retryMic',
              registry: realUiGuideAnchorRegistry,
              child: FilledButton(
                key: const ValueKey('retry-mic'),
                onPressed: () => micTaps++,
                child: const Text('마이크'),
              ),
            ),
          ),
          Align(
            alignment: const Alignment(0.8, 0.75),
            child: FilledButton(
              key: const ValueKey('retry-unrelated'),
              onPressed: () => unrelatedTaps++,
              child: const Text('다른 버튼'),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.98),
            child: GuidedAnchor(
              id: 'query.composer',
              registry: realUiGuideAnchorRegistry,
              child: SizedBox(
                width: 300,
                child: Row(children: [
                  const Expanded(child: TextField()),
                  FilledButton(
                    onPressed: () => sendTaps++,
                    child: const Text('전송'),
                  ),
                ]),
              ),
            ),
          ),
          Positioned.fill(child: RealUiGuideCoachmark(coordinator: guide)),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('4/7 · 음성으로 조회'), findsOneWidget);
    expect(find.textContaining('11월 13일 일정 보여줘'), findsOneWidget);
    expect(find.textContaining('2026년 11월 13일'), findsNothing);
    expect(find.textContaining('안내할 실제 화면을 기다리고 있어요'), findsNothing);
    final overlay = tester
        .widget<GuidedCoachmarkOverlay>(find.byType(GuidedCoachmarkOverlay));
    expect(overlay.targetId, 'query.composer');
    expect(overlay.additionalTargetIds, ['query.retryMic']);
    final rich = tester.widget<Text>(find.textContaining('말을 다 했다면'));
    final emphasis = (rich.textSpan! as TextSpan).children!.last as TextSpan;
    expect(emphasis.style!.fontWeight, FontWeight.bold);
    expect(overlay.blockOutsideTaps, isTrue);
    final overlayFinder = find.byType(GuidedCoachmarkOverlay);
    final clips = tester
        .widgetList<ClipPath>(
            find.descendant(of: overlayFinder, matching: find.byType(ClipPath)))
        .toList();
    final mask = clips.first.clipper!.getClip(tester.getSize(overlayFinder));
    expect(
        mask.contains(
            tester.getCenter(find.byKey(const ValueKey('retry-mic')))),
        isFalse);
    expect(mask.contains(tester.getCenter(find.byType(TextField))), isFalse);
    expect(mask.contains(tester.getCenter(find.text('전송'))), isFalse);
    expect(
        mask.contains(tester.getCenter(find.text('해당 날짜의 일정은 없어요.'))), isTrue);
    await tester.tap(find.byKey(const ValueKey('retry-mic')));
    await tester.tap(find.text('전송'));
    expect(sendTaps, 1);
    await tester.tap(find.byKey(const ValueKey('retry-unrelated')),
        warnIfMissed: false);
    expect(micTaps, 1);
    expect(unrelatedTaps, 0);
    guide.state.value =
        guide.state.value.copyWith(savedLocalDate: DateTime(2025, 12, 31)); // banned-ok: explicit savedLocalDate fixture verifies date text rendering, not clock-based behavior.
    await tester.pump();
    expect(find.textContaining('12월 31일 일정 보여줘'), findsOneWidget);
    expect(guide.state.value.step, GuideStep.querySpeech);
    expect(guide.dispatches, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    guide.state.dispose();
  });
}
