import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:planflow/services/app_permission_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fresh = MethodChannel('planflow/fresh_location');
  const legacy = MethodChannel('planflow/android_permissions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var legacyCalls = 0;
  Map<String, Object?> fix() => {
        'latitude': 37.5,
        'longitude': 127.0,
        'source': 'current_request',
        'isFresh': true,
        'timestampMillis': DateTime.now().millisecondsSinceEpoch,
        'requestAgeMillis': 5,
        'fixAgeMillis': 0,
      };
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(
      {'planflow_background_location_opt_in_v1': true},
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    legacyCalls = 0;
    messenger.setMockMethodCallHandler(legacy, (call) async {
      legacyCalls++;
      throw PlatformException(code: 'activity_unavailable');
    });
  });
  tearDown(() {
    expect(legacyCalls, 0,
        reason: 'No Activity permission check or UI prompt in headless path');
    messenger.setMockMethodCallHandler(fresh, null);
    messenger.setMockMethodCallHandler(legacy, null);
    debugDefaultTargetPlatformOverride = null;
  });
  test('headless caller explicitly requires background authorization',
      () async {
    messenger.setMockMethodCallHandler(fresh, (call) async {
      expect(call.method, 'getFreshCurrentLocation');
      expect(call.arguments, {'requireBackgroundPermission': true});
      return null;
    });
    expect(
      await AppPermissionService().getFreshCurrentLocation(
        requireBackgroundPermission: true,
      ),
      isNull,
    );
  });
  test('foreground caller keeps explicit foreground-only behavior', () async {
    messenger.setMockMethodCallHandler(fresh, (call) async {
      expect(call.arguments, {'requireBackgroundPermission': false});
      return null;
    });
    expect(await AppPermissionService().getFreshCurrentLocation(), isNull);
  });
  test('fresh stationary fixes work without Activity permission channel',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(fresh, (call) async {
      expect(call.method, 'getFreshCurrentLocation');
      calls++;
      return fix();
    });
    final service = AppPermissionService();
    final first = await service.getFreshCurrentLocation();
    final second = await service.getFreshCurrentLocation();
    expect(first?.latitude, 37.5);
    expect(second?.latitude, first?.latitude);
    expect(second?.longitude, first?.longitude);
    expect(calls, 2);
  });
  for (final scenario in [
    'stale',
    'last_known',
    'no_timestamp',
    'no_source',
    'future',
    'request_timeout',
    'invalid_coordinate',
    'nonfinite',
    'fix_before_request'
  ]) {
    test('rejects $scenario', () async {
      messenger.setMockMethodCallHandler(fresh, (_) async {
        final value = fix();
        switch (scenario) {
          case 'stale':
            value['timestampMillis'] =
                DateTime.now().millisecondsSinceEpoch - 30000;
          case 'last_known':
            value['source'] = 'last_known';
          case 'no_timestamp':
            value.remove('timestampMillis');
          case 'no_source':
            value.remove('source');
          case 'future':
            value['timestampMillis'] =
                DateTime.now().millisecondsSinceEpoch + 30000;
          case 'request_timeout':
            value['requestAgeMillis'] = 10001;
          case 'invalid_coordinate':
            value['latitude'] = 91.0;
          case 'nonfinite':
            value['longitude'] = double.nan;
          case 'fix_before_request':
            value['fixAgeMillis'] = 6;
        }
        return value;
      });
      expect(await AppPermissionService().getFreshCurrentLocation(), isNull);
    });
  }
  for (final scenario in ['denied', 'provider_unavailable', 'native_timeout']) {
    test('$scenario returns null without prompt/fallback', () async {
      messenger.setMockMethodCallHandler(fresh, (_) async => null);
      expect(await AppPermissionService().getFreshCurrentLocation(), isNull);
    });
  }
  testWidgets('unresponsive channel has bounded Dart timeout', (tester) async {
    messenger.setMockMethodCallHandler(
        fresh, (_) => Completer<Object?>().future);
    final pending = AppPermissionService().getFreshCurrentLocation();
    await tester.pump(const Duration(seconds: 13));
    expect(await pending, isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  test('unsupported platform fails closed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await AppPermissionService().getFreshCurrentLocation(), isNull);
  });
}
