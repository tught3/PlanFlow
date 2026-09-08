import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS-only bridge for the bounded native startup diagnostic ledger.
/// Android and other platforms intentionally do nothing.
class NativeStartupDiagnostics {
  static const MethodChannel _channel =
      MethodChannel('planflow/native_startup_diagnostics');

  static void dartMainEnter() => _report('DART_MAIN_ENTER');

  static void runAppReached() => _report('RUNAPP_REACHED');

  static void firstFrame() => _report('FIRST_FRAME');

  static void _report(String stage) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    unawaited(_send(stage));
  }

  static Future<void> _send(String stage) async {
    try {
      await _channel.invokeMethod<void>('mark', <String, Object>{
        'stage': stage,
      });
    } on MissingPluginException {
      // The bridge is best-effort during the earliest engine transition.
    } on PlatformException {
      // Diagnostics must never change startup behavior.
    } catch (_) {
      // Unexpected channel failures must also never change startup behavior.
    }
  }
}
