import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/startup_route_gate.dart';

void main() {
  test('calendar hold starts closed before async load and is UID scoped', () {
    final gate = StartupRouteGate();
    expect(gate.calendarSyncHeldFor('a'), isTrue);
    expect(gate.startupWorkDeferred, isFalse);
    gate.beginGuideChoice('a');
    expect(gate.calendarSyncHeldFor('a'), isTrue);
    gate.closeGuideChoice('b');
    expect(gate.calendarSyncHeldFor('a'), isTrue);
    gate.closeGuideChoice('a');
    expect(gate.calendarSyncHeldFor('a'), isFalse);
    expect(gate.calendarSyncHeldFor('b'), isTrue);
    gate.beginGuideChoice('b');
    gate.closeGuideChoice('a');
    expect(gate.calendarSyncHeldFor('b'), isTrue);
    gate.dispose();
  });
}
