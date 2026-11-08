import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';

void main() {
  testWidgets('real target gets taps through hole and outside tap is blocked',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    var hits = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Center(
          child: GuidedAnchor(
              id: 'target',
              registry: registry,
              child: ElevatedButton(
                  onPressed: () => hits++, child: const Text('Target')))),
      GuidedCoachmarkOverlay(
          registry: registry,
          targetId: 'target',
          bubble: const Text('Details'),
          progressLabel: 'Step 1 of 2',
          onSkip: () {})
    ]))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Target'));
    expect(hits, 1);
    await tester.tapAt(const Offset(5, 5));
    expect(hits, 1);
  });
  testWidgets('bubble and skip are visible and callback works', (tester) async {
    final registry = GuidedAnchorRegistry();
    var skipped = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Center(
          child: GuidedAnchor(
              id: 'x',
              registry: registry,
              child: const SizedBox(width: 80, height: 50))),
      GuidedCoachmarkOverlay(
          registry: registry,
          targetId: 'x',
          bubble: const Text('Coach content'),
          progressLabel: 'Step 2 of 3',
          onSkip: () => skipped++)
    ]))));
    await tester.pumpAndSettle();
    expect(find.text('Coach content'), findsOneWidget);
    expect(find.text('Step 2 of 3'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    expect(skipped, 1);
  });
  testWidgets(
      'replacement owner stays registered and missing target is graceful',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    final old = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      GuidedAnchor(
          key: old,
          id: 'x',
          registry: registry,
          child: const SizedBox(width: 40, height: 40)),
      GuidedCoachmarkOverlay(
          registry: registry,
          targetId: 'missing',
          bubble: const Text('Waiting'),
          progressLabel: 'Step 1',
          onSkip: () {})
    ]))));
    final oldBinding = registry.keyFor('x');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      GuidedAnchor(
          id: 'x',
          registry: registry,
          child: const SizedBox(width: 40, height: 40)),
      GuidedCoachmarkOverlay(
          registry: registry,
          targetId: 'missing',
          bubble: const Text('Waiting'),
          progressLabel: 'Step 1',
          onSkip: () {})
    ]))));
    expect(registry.keyFor('x'), isNot(oldBinding));
    expect(find.text('Waiting'), findsOneWidget);
  });
  testWidgets(
      'multiple openings keep transcript and actual mic controls interactive',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    var transcriptHits = 0;
    var micStarts = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Align(
            alignment: const Alignment(0, -0.55),
            child: GuidedAnchor(
              id: 'voice.review',
              registry: registry,
              child: ElevatedButton(
                key: const ValueKey('review'),
                onPressed: () => transcriptHits++,
                child: const Text('Transcript'),
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
                child: const Text('Voice start'),
              ),
            ),
          ),
          GuidedCoachmarkOverlay(
            registry: registry,
            targetId: 'voice.review',
            additionalTargetIds: const ['voice.start'],
            bubble: const Text('Practice'),
            progressLabel: '1/7',
            onSkip: () {},
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review')));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    expect(transcriptHits, 1);
    expect(micStarts, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('small viewport lays out without overflow', (tester) async {
    final registry = GuidedAnchorRegistry();
    tester.view.physicalSize = const Size(240, 320);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Align(
          alignment: Alignment.topCenter,
          child: GuidedAnchor(
              id: 'x',
              registry: registry,
              child: const SizedBox(width: 80, height: 40))),
      GuidedCoachmarkOverlay(
          registry: registry,
          targetId: 'x',
          bubble: const Text('A small viewport coachmark'),
          progressLabel: 'Step 1',
          onSkip: () {})
    ]))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
