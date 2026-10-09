import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow_fresh_location/planflow_fresh_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('planflow/android_permissions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('headless fresh fix is unavailable until app-level opt-in', () async {
    const fresh = MethodChannel('planflow/fresh_location');
    var invoked = false;
    messenger.setMockMethodCallHandler(fresh, (_) async {
      invoked = true;
      return null;
    });
    expect(
      await AppPermissionService().getFreshCurrentLocation(
        requireBackgroundPermission: true,
      ),
      isNull,
    );
    expect(invoked, isFalse);
    messenger.setMockMethodCallHandler(fresh, null);
  });

  test('capability requires saved opt-in and application-context OS grant',
      () async {
    const fresh = MethodChannel('planflow/fresh_location');
    var calls = 0;
    messenger.setMockMethodCallHandler(fresh, (call) async {
      calls++;
      expect(call.method, 'canUseBackgroundPermission');
      return true;
    });
    final service = AppPermissionService();
    expect(await service.canUseBackgroundFreshLocation(), isFalse);
    expect(calls, 0, reason: 'No native permission query without app opt-in');
    await service.setBackgroundLocationOptIn(true);
    expect(await service.canUseBackgroundFreshLocation(), isTrue);
    expect(calls, 1);
    messenger.setMockMethodCallHandler(fresh, null);
  });

  test('capability is false when OS background permission is denied', () async {
    const fresh = MethodChannel('planflow/fresh_location');
    messenger.setMockMethodCallHandler(fresh, (call) async {
      expect(call.method, 'canUseBackgroundPermission');
      return false;
    });
    final service = AppPermissionService();
    await service.setBackgroundLocationOptIn(true);
    expect(await service.canUseBackgroundFreshLocation(), isFalse);
    messenger.setMockMethodCallHandler(fresh, null);
  });

  test('cancellation uses plugin channel and returns cancelled request count',
      () async {
    const fresh = MethodChannel('planflow/fresh_location');
    messenger.setMockMethodCallHandler(fresh, (call) async {
      expect(call.method, 'cancelPendingBackgroundRequests');
      return 2;
    });
    expect(await PlanflowFreshLocation.cancelPendingBackgroundRequests(), 2);
    messenger.setMockMethodCallHandler(fresh, null);
  });

  test('status facade returns native background status', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'checkBackgroundLocationPermission');
      return 'granted';
    });
    expect(
      await AppPermissionService().checkBackgroundLocationPermissionStatus(),
      AppPermissionStatus.granted,
    );
  });

  test('does not request background permission without foreground grant',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.method, 'checkLocationPermission');
      return false;
    });
    expect(
      await AppPermissionService().requestBackgroundLocationPermission(),
      AppPermissionStatus.denied,
    );
    expect(calls, ['checkLocationPermission']);
  });

  test('foreground grant allows explicit background settings request',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'checkLocationPermission') return true;
      if (call.method == 'requestBackgroundLocationPermission') {
        return 'settingsRequired';
      }
      fail('Unexpected method: ${call.method}');
    });
    expect(
      await AppPermissionService().requestBackgroundLocationPermission(),
      AppPermissionStatus.settingsRequired,
    );
    expect(calls, [
      'checkLocationPermission',
      'requestBackgroundLocationPermission',
    ]);
  });

  test('non-Android platforms report background support unavailable', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(
      await AppPermissionService().checkBackgroundLocationPermissionStatus(),
      AppPermissionStatus.unavailable,
    );
    expect(
      await AppPermissionService().requestBackgroundLocationPermission(),
      AppPermissionStatus.unavailable,
    );
  });
}
