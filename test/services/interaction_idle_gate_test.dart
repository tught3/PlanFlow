import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/interaction_idle_gate.dart';

void main() {
  test(
      'interaction advances the shared generation and leaves a short idle window',
      () async {
    final gate = InteractionIdleGate.instance;
    final before = gate.generation;
    gate.notifyInteraction();
    expect(gate.generation, before + 1);
    expect(gate.isIdle, isFalse);
    await gate.waitForIdle();
    expect(gate.isIdle, isTrue);
  });
}
