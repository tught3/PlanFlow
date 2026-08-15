import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'shell onboarding opens feature tour before permissions and defers startup work',
      () {
    final shellSource =
        File('lib/screens/shell_screen.dart').readAsStringSync();
    final featureTourIndex = shellSource.indexOf('_maybeOpenFeatureTour()');
    final permissionIndex =
        shellSource.indexOf('_maybeOpenPermissionOnboarding()');
    final externalGuideIndex =
        shellSource.indexOf('_maybeShowExternalCalendarSyncGuide()');

    expect(featureTourIndex, greaterThan(-1));
    expect(permissionIndex, greaterThan(featureTourIndex));
    expect(externalGuideIndex, greaterThan(permissionIndex));
    expect(
        shellSource, contains('startupRouteGate.beginStartupWorkDeferral()'));
    expect(shellSource,
        contains('startupRouteGate.completeStartupWorkDeferral()'));

    final appSource = File('lib/app.dart').readAsStringSync();
    expect(appSource, contains('startupRouteGate.startupWorkDeferred'));
    expect(appSource, contains('_scheduleDeferredSessionSync'));
    expect(appSource, contains('_runDeferredSessionSync'));
    expect(appSource, contains('_isOnboardingRoute'));
  });
}
