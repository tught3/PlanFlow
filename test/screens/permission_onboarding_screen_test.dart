import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/onboarding/permission_onboarding_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  tearDown(() {
    authProvider.setUser(null);
  });

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

  testWidgets(
    'PermissionOnboardingScreen does not request OS permissions on entry',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

      final permissionService = _FakePermissionService();

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            permissionService: permissionService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(permissionService.microphoneRequests, isZero);
      expect(permissionService.locationRequests, isZero);
      expect(permissionService.calendarRequests, isZero);
      expect(permissionService.notificationRequests, isZero);
      expect(permissionService.exactAlarmRequests, isZero);
      expect(permissionService.fullScreenIntentRequests, isZero);
      expect(
        find.byKey(const ValueKey('permission-onboarding-skip-button')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'PermissionOnboardingScreen skip completes onboarding without OS permission requests',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
      authProvider.setUser('user-1');

      final permissionService = _FakePermissionService();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: AppRoutes.root,
            builder: (context, state) => PermissionOnboardingScreen(
              permissionService: permissionService,
            ),
          ),
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) =>
                const Scaffold(body: Text('home reached')),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('permission-onboarding-skip-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('home reached'), findsOneWidget);
      expect(permissionService.completedUserId, 'user-1');
      expect(permissionService.totalRequests, isZero);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen request-all flow only asks microphone and app notifications',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final permissionService = _FakePermissionService();

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            permissionService: permissionService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('permission-onboarding-request-all-button')),
      );
      await tester.pumpAndSettle();

      expect(permissionService.microphoneRequests, 1);
      expect(permissionService.notificationRequests, 1);
      expect(permissionService.exactAlarmRequests, 0);
      expect(permissionService.fullScreenIntentRequests, 0);
      expect(permissionService.exactAlarmGranted, isFalse);
      expect(permissionService.fullScreenIntentGranted, isFalse);
      expect(
        find.byKey(const ValueKey('permission-onboarding-request-all-button')),
        findsOneWidget,
      );

      final exactAlarmTile = find.byKey(
        const ValueKey('permission-onboarding-exact-alarm-tile'),
      );
      await tester.scrollUntilVisible(
        exactAlarmTile,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(exactAlarmTile, findsOneWidget);

      final fullScreenIntentTile = find.byKey(
        const ValueKey('permission-onboarding-full-screen-intent-tile'),
      );
      await tester.scrollUntilVisible(
        fullScreenIntentTile,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(fullScreenIntentTile, findsOneWidget);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen opens notification settings when app notifications stay denied',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

      final permissionService = _FakePermissionService()
        ..notificationRequestGranted = false;

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            permissionService: permissionService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final requestButton = find.descendant(
        of: find.byKey(
          const ValueKey('permission-onboarding-notification-tile'),
        ),
        matching: find.byType(TextButton),
      );
      await tester.ensureVisible(requestButton);
      await tester.tap(requestButton);
      await tester.pumpAndSettle();

      expect(permissionService.notificationSettingsOpened, isTrue);
      expect(permissionService.notificationGranted, isFalse);

      permissionService.notificationGranted = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('permission-onboarding-notification-tile'),
          ),
          matching: find.byIcon(Icons.check_circle_outline),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'PermissionOnboardingScreen opens app settings when exact alarm stays denied',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

      final permissionService = _FakePermissionService()
        ..exactAlarmRequestGranted = false;

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            permissionService: permissionService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final requestButton = find.descendant(
        of: find.byKey(
          const ValueKey('permission-onboarding-exact-alarm-tile'),
        ),
        matching: find.byType(TextButton),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('permission-onboarding-exact-alarm-tile')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final buttonWidget = tester.widget<TextButton>(requestButton);
      expect(buttonWidget.onPressed, isNotNull);
      buttonWidget.onPressed!();
      await tester.pumpAndSettle();

      expect(permissionService.appSettingsOpened, isTrue);
      expect(permissionService.exactAlarmGranted, isFalse);

      permissionService.exactAlarmGranted = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('permission-onboarding-exact-alarm-tile'),
          ),
          matching: find.byIcon(Icons.check_circle_outline),
        ),
        findsOneWidget,
      );
    },
  );
}

class _FakePermissionService extends AppPermissionService {
  _FakePermissionService()
      : super(notificationService: _FakeNotificationService());

  bool exactAlarmGranted = false;
  bool fullScreenIntentGranted = false;
  bool notificationGranted = false;
  bool notificationRequestGranted = true;
  bool exactAlarmRequestGranted = true;
  bool notificationSettingsOpened = false;
  bool appSettingsOpened = false;
  int microphoneRequests = 0;
  int locationRequests = 0;
  int calendarRequests = 0;
  int notificationRequests = 0;
  int exactAlarmRequests = 0;
  int fullScreenIntentRequests = 0;
  String? completedUserId;

  int get totalRequests =>
      microphoneRequests +
      locationRequests +
      calendarRequests +
      notificationRequests +
      exactAlarmRequests +
      fullScreenIntentRequests;

  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return AppPermissionSnapshot(
      microphoneGranted: false,
      locationGranted: false,
      calendarGranted: false,
      notificationStatus: NotificationPermissionStatus(
        notificationsEnabled: notificationGranted,
        exactAlarmsEnabled: exactAlarmGranted,
        fullScreenIntentStatus: fullScreenIntentGranted
            ? PermissionCheckState.granted
            : PermissionCheckState.denied,
      ),
    );
  }

  @override
  Future<bool> requestMicrophonePermission() async {
    microphoneRequests += 1;
    return true;
  }

  @override
  Future<bool> requestLocationPermission() async {
    locationRequests += 1;
    return false;
  }

  @override
  Future<bool> requestCalendarPermission() async {
    calendarRequests += 1;
    return false;
  }

  @override
  Future<NotificationPermissionStatus> requestNotificationPermissions() async {
    notificationRequests += 1;
    notificationGranted = notificationRequestGranted;
    return NotificationPermissionStatus(
      notificationsEnabled: notificationGranted,
      exactAlarmsEnabled: exactAlarmGranted,
      fullScreenIntentStatus: PermissionCheckState.needsManualCheck,
    );
  }

  @override
  Future<bool> requestNotificationPermission() async {
    notificationRequests += 1;
    notificationGranted = notificationRequestGranted;
    return notificationRequestGranted;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactAlarmRequests += 1;
    exactAlarmGranted = exactAlarmRequestGranted;
    return exactAlarmRequestGranted;
  }

  @override
  Future<bool> requestFullScreenIntentPermission() async {
    fullScreenIntentRequests += 1;
    fullScreenIntentGranted = true;
    return true;
  }

  @override
  Future<bool> openNotificationSettings() async {
    notificationSettingsOpened = true;
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    appSettingsOpened = true;
    return true;
  }

  @override
  Future<void> markOnboardingCompleted(String userId) async {
    completedUserId = userId;
  }
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
