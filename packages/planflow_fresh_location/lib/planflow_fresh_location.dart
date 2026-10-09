import 'package:flutter/services.dart';

/// Auto-registered plugin; permission checks never require an Activity.
class PlanflowFreshLocation {
  static const channel = MethodChannel('planflow/fresh_location');

  /// Cancels only pending requests that explicitly require background access.
  /// Foreground interactive location requests are not affected.
  static Future<int> cancelPendingBackgroundRequests() async {
    try {
      return await channel
              .invokeMethod<int>('cancelPendingBackgroundRequests') ??
          0;
    } catch (_) {
      return 0;
    }
  }

  /// Activity-free capability probe. Does not request permission or read GPS.
  static Future<bool> canUseBackgroundPermission() async {
    try {
      return await channel
              .invokeMethod<bool>('canUseBackgroundPermission')
              .timeout(const Duration(seconds: 3)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<Object?> getCurrentFix({
    bool requireBackgroundPermission = false,
  }) =>
      channel.invokeMethod<Object?>(
        'getFreshCurrentLocation',
        <String, Object?>{
          'requireBackgroundPermission': requireBackgroundPermission,
        },
      ).timeout(const Duration(seconds: 12));
}
