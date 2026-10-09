import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android headless plugin fails closed without required background grant',
      () {
    final source = File(
      'packages/planflow_fresh_location/android/src/main/java/com/fluxstudio/planflow/freshlocation/PlanflowFreshLocationPlugin.java',
    ).readAsStringSync();
    expect(source, contains('PROCESS_PENDING'));
    expect(source, contains('PENDING_LOCK'));
    expect(source, contains('CriticalAlarmOwnershipChannel ownershipChannel'));
    expect(source, contains('new CriticalAlarmOwnershipChannel('));
    expect(source, contains('ownershipChannel.dispose()'));
    expect(source, contains('canUseBackgroundPermission'));
    expect(source, contains('cancelPendingBackgroundRequests'));
    expect(source, contains('request.requireBackgroundPermission'));
    expect(source, contains('request.finish(null)'));
    expect(source, contains('hasBackgroundLocationPermission'));
    expect(source, contains('requireBackgroundPermission'));
    expect(source, contains('Build.VERSION.SDK_INT < 29'));
    expect(
      source,
      contains('requireBackground && !hasBackgroundLocationPermission(app)'),
    );
    expect(source, contains('Manifest.permission.ACCESS_BACKGROUND_LOCATION'));
    expect(source, contains('result.success(null);'));
    expect(source, contains('manager.requestLocationUpdates'));
    expect(source, isNot(contains('getLastKnownLocation')));
  });
}
