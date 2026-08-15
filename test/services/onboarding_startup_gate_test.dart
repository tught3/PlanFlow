import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:planflow/services/onboarding_startup_gate.dart';

void main() {
  testWidgets('coalesces startup work until the next frame', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final gate = OnboardingStartupGate();
    var runs = 0;
    final first = gate.runAfterFirstHomeFrame(() async {
      runs++;
    });
    final second = gate.runAfterFirstHomeFrame(() async {
      runs += 100;
    });

    expect(identical(first, second), isTrue);
    expect(runs, 0);
  });
}
