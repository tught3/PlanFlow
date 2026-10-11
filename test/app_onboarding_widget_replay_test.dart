import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/core/home_widget_route_coordinator.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/shell_screen.dart';

void main() {
  for (final target in ['/calendar?date=2026-10-14', '/voice?autoStart=1']) {
    testWidgets('actual setup at HOME replays capped $target once', (tester) async {
      final auth = AuthProvider()..start()..setUser('a');
      final gate = StartupRouteGate()..beginRequiredSetup('a')..completeRequiredSetup('a');
      var current = Uri.parse('/home');
      var arrives = false;
      final navigations = <String>[];
      final consumed = <String>[];
      final coordinator = HomeWidgetRouteCoordinator(
        readinessResolver: () => resolveAppHomeWidgetReadiness(auth: auth, gate: gate, supabaseReady: true),
        wakeSignal: Listenable.merge([auth, gate]),
        currentUri: () => current,
        navigate: (route) { navigations.add(route); if (arrives) current = Uri.parse(route); },
        consume: (route) async { consumed.add(route); },
        arrivalMaxAttempts: 1,
        arrivalCheckInterval: const Duration(milliseconds: 1),
        retainedRetryDelay: const Duration(milliseconds: 1),
        maxNavigationCycles: 3,
      );
      coordinator.submitRoute(target);
      for (var i = 0; i < 8; i++) { await tester.pump(const Duration(milliseconds: 2)); }
      expect(navigations.length, 3);
      expect(consumed, isEmpty);
      gate..resetRequiredSetup()..beginRequiredSetup('a');
      gate.beginWidgetLaunch();
      gate.completeWidgetLaunch();
      coordinator.notifyLocationChanged();
      expect(resolveAppHomeWidgetReadiness(auth: auth, gate: gate, supabaseReady: true), HomeWidgetRouteReadiness.notReady);
      expect(completeShellRequiredSetup(flowCompleted: false, flowUserId: 'a', auth: auth, gate: gate), false);
      expect(navigations.length, 3);
      arrives = true;
      final completed = await runOnboardingStageChain(
        stages: [OnboardingStage('required setup', () async {})],
        shouldContinue: () => true,
        releaseGate: gate.completeStartupWorkDeferral,
        presentationTimeout: const Duration(seconds: 1), log: (_) {},
      );
      expect(current.path, '/home');
      expect(completeShellRequiredSetup(flowCompleted: completed, flowUserId: 'a', auth: auth, gate: gate), true);
      await tester.pump(const Duration(milliseconds: 2));
      expect(navigations, [target, target, target, target]);
      expect(current, Uri.parse(target));
      expect(consumed, [target]);
      for (var i = 0; i < 30; i++) { gate.completeRequiredSetup('a'); coordinator.notifyLocationChanged(); coordinator.kickPendingRoute(); }
      expect(consumed, [target]);
      expect(navigations.length, 4);
      coordinator.dispose(); gate.dispose(); auth.dispose();
    });
  }
  test('real provider waits for login and rejects stale or cancelled completion', () {
    final auth = AuthProvider()..start();
    final gate = StartupRouteGate()..beginRequiredSetup('a');
    expect(resolveAppHomeWidgetReadiness(auth: auth, gate: gate, supabaseReady: true), HomeWidgetRouteReadiness.needsAuth);
    expect(completeShellRequiredSetup(flowCompleted: true, flowUserId: 'a', auth: auth, gate: gate), false);
    auth.setUser('a');
    expect(resolveAppHomeWidgetReadiness(auth: auth, gate: gate, supabaseReady: true), HomeWidgetRouteReadiness.notReady);
    expect(completeShellRequiredSetup(flowCompleted: true, flowUserId: 'b', auth: auth, gate: gate), false);
    expect(completeShellRequiredSetup(flowCompleted: false, flowUserId: 'a', auth: auth, gate: gate), false);
    gate.dispose(); auth.dispose();
  });
}
