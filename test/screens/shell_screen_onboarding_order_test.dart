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
    expect(shellSource, contains('_sessionOnboardingUserId'));
    expect(shellSource, contains('_sessionDeferredWorkUserId'));
    expect(shellSource, contains('_sessionOnboardingFlow'));
    expect(shellSource, contains('Only an actual auth identity transition'));
    expect(shellSource, contains('_startupWorkGeneration'));
    expect(shellSource, contains('_interactionIdleGate.waitForIdle()'));
    expect(shellSource,
        contains('deferred startup cancelled before gate release'));
    final tabHandlerStart = shellSource.indexOf('void _goToTab');
    final tabHandlerEnd = shellSource.indexOf('void _handleTabSwipe');
    final tabHandler = shellSource.substring(tabHandlerStart, tabHandlerEnd);
    expect(tabHandler, isNot(contains('context.go')));
    expect(tabHandler, contains('_tabChildren[index]'));
    expect(shellSource, contains('const SizedBox.shrink()'));

    final appSource = File('lib/app.dart').readAsStringSync();
    expect(appSource, contains('startupRouteGate.startupWorkDeferred'));
    expect(appSource, contains('_scheduleDeferredSessionSync'));
    expect(appSource, contains('_runDeferredSessionSync'));
    expect(appSource, contains('_isOnboardingRoute'));
    expect(appSource,
        contains('await _calendarAutoSyncService.syncConnectedCalendars'));
    expect(
        appSource,
        isNot(contains(
            'unawaited(() async {\n      try {\n        await _calendarAutoSyncService')));
    final gateSource =
        File('lib/core/startup_route_gate.dart').readAsStringSync();
    expect(gateSource, contains('startupWorkAllowedWhenIdle'));
    expect(gateSource, contains('waitForStableIdle'));
    final prefetchSource =
        File('lib/services/event_prefetch_service.dart').readAsStringSync();
    expect(
      prefetchSource,
      isNot(contains('await startupRouteGate.startupWorkAllowedWhenIdle')),
    );
    expect(prefetchSource, contains('_warmingUserIds.add(resolvedUserId)'));
    expect(appSource, contains('waitForStableIdle().then'));
    final mainSource = File('lib/main.dart').readAsStringSync();
    final platformServicesStart =
        mainSource.indexOf('Future<void> _initializePlatformServices() async');
    final platformServicesEnd =
        mainSource.indexOf('Future<void> _reconcileStaleGroupAlarms() async');
    final platformServices =
        mainSource.substring(platformServicesStart, platformServicesEnd);
    expect(platformServices,
        contains('final supabaseReady = _initializeSupabase();'));
    expect(
      platformServices,
      isNot(contains('await _initializeSupabase();')),
    );
    expect(platformServices, contains('await Future.wait(['));
    expect(platformServices, contains('supabaseReady,'));
    expect(platformServices, contains('_primingAdService(firebaseReady)'));
    expect(mainSource, contains('_scheduleStaleGroupAlarmReconcile()'));
    expect(mainSource, contains('startupRouteGate.startupWorkAllowedWhenIdle'));
    expect(mainSource, contains('_staleGroupAlarmReconcile ??='));
    expect(mainSource, contains('_scheduleDailyCalendarSyncAfterStartup'));
    expect(mainSource,
        contains('await startupRouteGate.startupWorkAllowedWhenIdle'));
    expect(shellSource, contains('Always release the route gate'));
    expect(appSource, contains('_deferStartupLifecycleWork'));
    expect(appSource, contains('startupRouteGate.startupWorkAllowedWhenIdle'));
    expect(appSource, contains('_startupLifecycleJobs'));
    expect(appSource, contains("_deferStartupLifecycleWork('resume'"));
    expect(shellSource, contains('_runAlarmRecovery'));
    expect(shellSource, contains('_alarmRecoveryFuture'));
    expect(mainSource, contains('_dailyCalendarSyncSchedule = null'));
  });
}
