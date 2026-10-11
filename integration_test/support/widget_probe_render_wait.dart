import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Waits for an observable native-route render using the test binding clock.
/// [onPump] is called initially and after every bounded pump.
Future<void> waitForNativeRouteRender(
  WidgetTester tester, {
  required bool Function() isRendered,
  void Function()? onPump,
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 50),
}) async {
  if (timeout <= Duration.zero || step <= Duration.zero || step > timeout) {
    throw ArgumentError(
        'timeout and step must be positive and step <= timeout');
  }
  final clock = tester.binding.clock;
  final deadline = clock.fromNowBy(timeout);
  onPump?.call();
  while (!isRendered()) {
    final remaining = deadline.difference(clock.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException(
          'Native route did not render before timeout', timeout);
    }
    await tester.pump(remaining < step ? remaining : step);
    onPump?.call();
  }
  onPump?.call();
}
