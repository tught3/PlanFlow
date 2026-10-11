import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/home_widget_route_coordinator.dart';

const _voice = '/voice?autoStart=1';
const _other = '/calendar?date=2026-10-11';

// Actual app helper, binding callbacks and coordinator; only push is a spy.
// No copied guard, native intents, auth or STT services.
class _Harness {
  final pushes = <String>[];
  final consumed = <String>[];
  int seeds = 0;
  bool mounted = true;
  Uri location = Uri.parse('/home');
  void Function()? onSeed;
  late HomeWidgetRouteCoordinator coordinator = makeCoordinator();

  /// When true (default), the `seedHome` callback mirrors the legacy shared
  /// HOME seed path and schedules a frame itself. When false, `seedHome` is a
  /// no-op for frame scheduling so a regression test can prove that the
  /// helper itself requests the visual update via `ensureVisualUpdate()`
  /// instead of relying on the seed to do it.
  final bool seedHomeSchedulesFrame;

  _Harness({this.seedHomeSchedulesFrame = true});

  HomeWidgetRouteCoordinator makeCoordinator() => HomeWidgetRouteCoordinator(
        readinessResolver: () => HomeWidgetRouteReadiness.ready,
        navigate: (route) => seedHomeAndDeferHomeWidgetPush(
          route: route,
          currentCoordinator: () => coordinator,
          isMounted: () => mounted,
          seedHome: () {
            seeds++;
            if (seedHomeSchedulesFrame) {
              WidgetsBinding.instance.scheduleFrame();
            }
            onSeed?.call();
          },
          push: (target) {
            pushes.add(target);
            location = Uri.parse(target);
          },
        ),
        currentUri: () => location,
        consume: (route) async => consumed.add(route),
        arrivalCheckInterval: const Duration(milliseconds: 20),
      );
}

void main() {
  testWidgets(
      'A B A before frame pushes only latest A, confirms before consume',
      (tester) async {
    final h = _Harness();
    addTearDown(() => h.coordinator.dispose());
    final first = h.coordinator.submitRoute(_voice);
    final middle = h.coordinator.submitRoute(_other);
    final latest = h.coordinator.submitRoute(_voice);
    expect(h.seeds, 3);
    expect(h.pushes, isEmpty);
    expect(h.consumed, isEmpty);
    await tester.pump();
    expect(h.pushes, [_voice]);
    expect(h.consumed, isEmpty);
    await tester.pump(const Duration(milliseconds: 20));
    expect(await first, HomeWidgetRouteOutcome.cancelled);
    expect(await middle, HomeWidgetRouteOutcome.cancelled);
    expect(await latest, HomeWidgetRouteOutcome.confirmed);
    expect(h.consumed, [_voice]);
    expect(h.coordinator.pendingRoute, isNull);
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.pushes, [_voice]);
    h.coordinator.dispose();
  });

  testWidgets('same-route new generation suppresses earlier queued push',
      (tester) async {
    final h = _Harness();
    addTearDown(() => h.coordinator.dispose());
    h.coordinator.submitRoute(_voice);
    final firstGeneration = h.coordinator.generation;
    h.coordinator.submitRoute(_voice);
    expect(h.coordinator.generation, greaterThan(firstGeneration));
    await tester.pump();
    expect(h.pushes, [_voice]);
    expect(h.consumed, isEmpty);
    h.coordinator.dispose();
  });

  for (final dispose in [false, true]) {
    testWidgets('${dispose ? 'dispose' : 'cancel'} before frame skips push',
        (tester) async {
      final h = _Harness();
      addTearDown(() => h.coordinator.dispose());
      final outcome = h.coordinator.submitRoute(_voice);
      if (dispose) {
        h.coordinator.dispose();
      } else {
        h.coordinator.cancel();
      }
      await tester.pump();
      expect(h.pushes, isEmpty);
      expect(h.consumed, isEmpty);
      expect(await outcome, HomeWidgetRouteOutcome.cancelled);
    });
  }

  testWidgets('replacement with same generation and route rejects old identity',
      (tester) async {
    final h = _Harness();
    addTearDown(() => h.coordinator.dispose());
    h.coordinator.submitRoute(_voice);
    final old = h.coordinator;
    addTearDown(old.dispose);
    final generation = old.generation;
    h.coordinator = h.makeCoordinator();
    h.coordinator.submitRoute(_voice);
    expect(h.coordinator.generation, generation);
    expect(old.pendingRoute, h.coordinator.pendingRoute);
    await tester.pump();
    expect(h.pushes, [_voice]);
    expect(h.consumed, isEmpty);
    old.dispose();
    h.coordinator.dispose();
  });

  testWidgets('unmounted owner skips queued push', (tester) async {
    final h = _Harness();
    addTearDown(() => h.coordinator.dispose());
    h.coordinator.submitRoute(_voice);
    h.mounted = false;
    await tester.pump();
    expect(h.pushes, isEmpty);
    expect(h.consumed, isEmpty);
    h.coordinator.dispose();
  });

  testWidgets('capture precedes synchronous HOME seed supersession',
      (tester) async {
    final h = _Harness();
    addTearDown(() => h.coordinator.dispose());
    h.onSeed = () {
      h.onSeed = null;
      h.coordinator.submitRoute(_voice);
    };
    h.coordinator.submitRoute(_voice);
    expect(h.seeds, 2);
    await tester.pump();
    expect(h.pushes, [_voice]);
    expect(h.consumed, isEmpty);
    h.coordinator.dispose();
  });

  testWidgets(
      'helper requests frame when binding is idle and pushes selected-date URI exactly once',
      (tester) async {
    final h = _Harness(seedHomeSchedulesFrame: false);
    addTearDown(() => h.coordinator.dispose());

    // Drain any leftover frame work from the binding so the helper's
    // own request becomes observable as a fresh false -> true transition.
    var safety = 5;
    while (WidgetsBinding.instance.hasScheduledFrame && safety-- > 0) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(WidgetsBinding.instance.hasScheduledFrame, isFalse,
        reason: 'binding must be idle before submission to make the '
            'helper-owned frame request observable');

    // Submit the selected-date URI: `_other` carries date=2026-10-11 so the
    // helper must push exactly that, with no extras.
    final outcome = h.coordinator.submitRoute(_other);

    // Without `ensureVisualUpdate()` after the postframe registration, no
    // visual update is requested by the helper (addPostFrameCallback itself
    // does not schedule a frame, and seedHome is intentionally a no-op here),
    // so the postframe may never fire in production. With the fix, the
    // helper requests the frame itself.
    expect(WidgetsBinding.instance.hasScheduledFrame, isTrue,
        reason: 'helper must request a visual update to drive the '
            'postframe callback when the binding is idle');

    expect(h.seeds, 1);
    expect(h.pushes, isEmpty,
        reason: 'push is deferred to the postframe callback');
    expect(h.consumed, isEmpty,
        reason: 'no consume before arrival confirmation');

    await tester.pump();
    expect(h.pushes, [_other],
        reason: 'exactly one push and the URI must carry date=2026-10-11');
    expect(h.consumed, isEmpty,
        reason: 'consume only after arrival, never pre-arrival');

    await tester.pump(const Duration(milliseconds: 20));
    expect(await outcome, HomeWidgetRouteOutcome.confirmed,
        reason: 'outcome confirmed only after arrival');
    expect(h.consumed, [_other],
        reason: 'exactly one consume after arrival, no premature consume');
    expect(h.coordinator.pendingRoute, isNull,
        reason: 'queue cleared after confirmed consume');

    await tester.pump(const Duration(milliseconds: 100));
    expect(h.pushes, [_other],
        reason: 'no additional pushes after consume');
    h.coordinator.dispose();
  });
}
