import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';

void main() {
  testWidgets('dimmed passthrough target is tappable but outside stays blocked',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    var micTaps = 0;
    var submitTaps = 0;
    var unrelatedTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Align(
            alignment: const Alignment(-0.8, 0),
            child: GuidedAnchor(
              id: 'mic',
              registry: registry,
              child: FilledButton(
                key: const ValueKey('mic'),
                onPressed: () => micTaps++,
                child: const Text('Mic'),
              ),
            ),
          ),
          Align(
            alignment: const Alignment(0.8, 0),
            child: GuidedAnchor(
              id: 'submit',
              registry: registry,
              child: FilledButton(
                key: const ValueKey('submit'),
                onPressed: () => submitTaps++,
                child: const Text('Submit'),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FilledButton(
              key: const ValueKey('unrelated'),
              onPressed: () => unrelatedTaps++,
              child: const Text('Unrelated'),
            ),
          ),
          GuidedCoachmarkOverlay(
            registry: registry,
            targetId: 'mic',
            passThroughTargetIds: const ['submit'],
            showBubble: false,
            bubble: const SizedBox.shrink(),
            progressLabel: '1/7',
            onSkip: () {},
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    final overlay = find.byType(GuidedCoachmarkOverlay);
    final clips = tester
        .widgetList<ClipPath>(find.descendant(of: overlay, matching: find.byType(ClipPath)))
        .toList();
    expect(clips, hasLength(2));
    final size = tester.getSize(overlay);
    final micCenter = tester.getCenter(find.byKey(const ValueKey('mic')));
    final submitCenter = tester.getCenter(find.byKey(const ValueKey('submit')));
    final visualMask = clips.first.clipper!.getClip(size);
    final inputMask = clips.last.clipper!.getClip(size);
    expect(visualMask.contains(micCenter), isFalse);
    expect(visualMask.contains(submitCenter), isTrue);
    expect(inputMask.contains(submitCenter), isFalse);
    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.tap(find.byKey(const ValueKey('submit')));
    await tester.tap(find.byKey(const ValueKey('unrelated')), warnIfMissed: false);
    expect((micTaps, submitTaps, unrelatedTaps), (1, 1, 0));
  });

  testWidgets(
      'a bottom FAB keeps the above bubble and Skip inside the viewport',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    bool skipped = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GuidedAnchor(
                  id: 'target',
                  registry: registry,
                  child: ElevatedButton(
                      key: const ValueKey('target'),
                      onPressed: () {},
                      child: const Text('Target'))))),
      GuidedCoachmarkOverlay(
          registry: registry,
          targetId: 'target',
          bubble:
              const Text('Read the real event, then use its actual controls.'),
          progressLabel: '1/7',
          onSkip: () => skipped = true),
    ]))));
    await tester.pumpAndSettle();
    final skip = tester.getRect(find.text('Skip'));
    final target = tester.getRect(find.byKey(const ValueKey('target')));
    expect(skip.top, greaterThanOrEqualTo(0));
    expect(tester.getRect(find.text('1/7')).top, greaterThanOrEqualTo(0));
    expect(
        tester
            .getRect(
                find.text('Read the real event, then use its actual controls.'))
            .top,
        greaterThanOrEqualTo(0));
    expect(skip.bottom, lessThan(target.top));
    await tester.tap(find.text('Skip'));
    expect(skipped, isTrue);
  });

  testWidgets(
      'review mode allows actual outside controls while preserving Skip',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    int edits = 0;
    int saves = 0;
    bool skipped = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      Align(
          // Keep this real outside control below the top-positioned coachmark
          // bubble so the test exercises tap-through rather than overlap.
          alignment: const Alignment(0, 0.35),
          child: ElevatedButton(
              key: const ValueKey('edit'),
              onPressed: () => edits++,
              child: const Text('Edit real field'))),
      Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GuidedAnchor(
                  id: 'save',
                  registry: registry,
                  child: ElevatedButton(
                      key: const ValueKey('save'),
                      onPressed: () => saves++,
                      child: const Text('Save real event'))))),
      GuidedCoachmarkOverlay(
          registry: registry,
          targetId: 'save',
          blockOutsideTaps: false,
          skipLabel: 'Leave guide',
          bubble: const Text('Correct only if needed, then save.'),
          progressLabel: '2/7',
          onSkip: () => skipped = true),
    ]))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit')));
    expect(edits, 1);
    await tester.tap(find.byKey(const ValueKey('save')));
    expect(saves, 1);
    await tester.tap(find.text('Leave guide'));
    expect(skipped, isTrue);
  });
  testWidgets(
      'important, strong notification, then save stay spotlighted after scroll',
      (tester) async {
    final registry = GuidedAnchorRegistry();
    var stage = 0;
    var importantTaps = 0;
    var strongTaps = 0;
    var saveTaps = 0;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, rebuild) {
        final target = ['important', 'strong', 'save'][stage];
        return Scaffold(
          body: Stack(children: [
            SingleChildScrollView(
                child: Column(children: [
              const SizedBox(height: 900),
              for (final id in ['important', 'strong', 'save'])
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: GuidedAnchor(
                    id: id,
                    registry: registry,
                    child: ElevatedButton(
                      key: ValueKey(id),
                      onPressed: () {
                        if (id == 'important') importantTaps++;
                        if (id == 'strong') strongTaps++;
                        if (id == 'save') saveTaps++;
                        if (stage < 2) rebuild(() => stage++);
                      },
                      child: Text(id),
                    ),
                  ),
                ),
            ])),
            GuidedCoachmarkOverlay(
              registry: registry,
              targetId: target,
              bubble: Text('bubble-$target'),
              progressLabel: '$stage/3',
              onSkip: () {},
            ),
          ]),
        );
      }),
    ));
    for (final id in ['important', 'strong', 'save']) {
      await tester.ensureVisible(find.byKey(ValueKey(id)));
      await tester.pumpAndSettle();
      final targetRect = tester.getRect(find.byKey(ValueKey(id)));
      final bubbleRect = tester.getRect(find.text('bubble-$id'));
      expect(targetRect.overlaps(bubbleRect), isFalse, reason: id);
      await tester.tap(find.byKey(ValueKey(id)));
      await tester.pumpAndSettle();
    }
    expect(importantTaps, 1);
    expect(strongTaps, 1);
    expect(saveTaps, 1);
    expect(tester.takeException(), isNull);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}
