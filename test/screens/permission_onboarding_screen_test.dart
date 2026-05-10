import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/screens/onboarding/permission_onboarding_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets(
    'PermissionOnboardingScreen keeps the main request button visible on compact height',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            permissionService: _FakePermissionService(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find
            .byKey(
              const ValueKey('permission-onboarding-request-all-button'),
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Android 앱 설정 열기'), findsNothing);
      expect(find.text('마이크').hitTestable(), findsOneWidget);
    },
  );
}

class _FakePermissionService extends AppPermissionService {
  _FakePermissionService()
      : super(notificationService: _FakeNotificationService());

  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return const AppPermissionSnapshot(
      microphoneGranted: false,
      locationGranted: false,
      calendarGranted: false,
      notificationStatus: NotificationPermissionStatus(
        notificationsEnabled: false,
        exactAlarmsEnabled: false,
        fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
      ),
    );
  }

  @override
  Future<bool> requestMicrophonePermission() async => false;

  @override
  Future<bool> requestLocationPermission() async => false;

  @override
  Future<bool> requestCalendarPermission() async => false;

  @override
  Future<NotificationPermissionStatus> requestNotificationPermissions() async {
    return const NotificationPermissionStatus(
      notificationsEnabled: false,
      exactAlarmsEnabled: false,
      fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
    );
  }

  @override
  Future<bool> openAppSettings() async => false;
}

class _FakeNotificationService extends NotificationService {
  _FakeNotificationService();

  @override
  Future<NotificationPermissionStatus> checkPermissionStatus() async {
    return const NotificationPermissionStatus(
      notificationsEnabled: false,
      exactAlarmsEnabled: false,
      fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
    );
  }

  @override
  Future<NotificationPermissionStatus> requestAndCheckPermissions() async {
    return checkPermissionStatus();
  }
}

