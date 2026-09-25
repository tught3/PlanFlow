import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/startup_route_gate.dart';

void main() {
  test('redirect refresh is isolated from startup-work deferral changes', () {
    final gate = StartupRouteGate();
    addTearDown(gate.dispose);
    var appChanges = 0;
    var redirectChanges = 0;
    gate.addListener(() => appChanges++);
    gate.redirectRefreshListenable.addListener(() => redirectChanges++);

    gate.beginStartupWorkDeferral();
    expect(gate.startupWorkDeferred, isTrue);
    expect(appChanges, 1);
    expect(redirectChanges, 0);

    gate.completeStartupWorkDeferral();
    expect(gate.startupWorkDeferred, isFalse);
    expect(appChanges, 2);
    expect(redirectChanges, 0);

    gate.beginWidgetLaunch();
    expect(gate.suppressLoginRedirects, isTrue);
    expect(appChanges, 3);
    expect(redirectChanges, 1);

    gate.completeWidgetLaunch();
    expect(gate.suppressLoginRedirects, isFalse);
    expect(appChanges, 4);
    expect(redirectChanges, 2);
  });
}
