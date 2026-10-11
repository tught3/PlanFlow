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

  HomeWidgetRouteCoordinator makeCoordinator() => HomeWidgetRouteCoordinator(
        readinessResolver: () => HomeWidgetRouteReadiness.ready,
        navigate: (route) => seedHomeAndDeferHomeWidgetPush(
          route: route,
          currentCoordinator: () => coordinator,
          isMounted: () => mounted,
          seedHome: () {
            seeds++;
            WidgetsBinding.instance.scheduleFrame();
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
}
