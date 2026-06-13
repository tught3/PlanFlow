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
            .byKey(const ValueKey('permission-onboarding-request-all-button'))
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
    'PermissionOnboardingScreen request-all asks only required permissions sequentially',
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

      expect(permissionService.requestLog, <String>[
        'microphone',
        'notification',
        'exactAlarm',
      ]);
      expect(permissionService.microphoneGranted, isTrue);
      expect(permissionService.notificationGranted, isTrue);
      expect(permissionService.exactAlarmGranted, isTrue);
      expect(permissionService.locationGranted, isFalse);
      expect(permissionService.calendarGranted, isFalse);
      expect(
        (await permissionService.checkAll()).requiredPermissionsGranted,
        isTrue,
      );
      expect(permissionService.microphoneRequests, 1);
      expect(permissionService.notificationRequests, 1);
      expect(permissionService.exactAlarmRequests, 1);
      expect(permissionService.locationRequests, isZero);
      expect(permissionService.calendarRequests, isZero);
      expect(permissionService.fullScreenIntentRequests, isZero);
      expect(find.text('시작하기'), findsOneWidget);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen hides full-screen intent from first-install onboarding',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            permissionService: _FakePermissionService()
              ..fullScreenIntentStatus = PermissionCheckState.unsupported,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey('permission-onboarding-full-screen-intent-tile'),
        ),
        findsNothing,
      );
      expect(find.textContaining('폴드'), findsNothing);
      expect(find.textContaining('플립'), findsNothing);
      expect(find.textContaining('겉화면'), findsNothing);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen treats optional permissions as non-blocking',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

      final permissionService = _FakePermissionService()
        ..microphoneGranted = true
        ..notificationGranted = true
        ..exactAlarmGranted = true;

      await tester.pumpWidget(
        MaterialApp(
          home:
              PermissionOnboardingScreen(permissionService: permissionService),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('시작하기'), findsOneWidget);
      expect(permissionService.locationRequests, isZero);
      expect(permissionService.calendarRequests, isZero);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen requests full-screen intent when device supports it',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);

      final permissionService = _FakePermissionService()
        ..fullScreenIntentStatus = PermissionCheckState.denied;

      await tester.pumpWidget(
        MaterialApp(
          home:
              PermissionOnboardingScreen(permissionService: permissionService),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('permission-onboarding-request-all-button')),
      );
      await tester.pumpAndSettle();

      expect(permissionService.requestLog, <String>[
        'microphone',
        'notification',
        'exactAlarm',
        'fullScreenIntent',
      ]);
      expect(permissionService.fullScreenIntentRequests, 1);
      expect(find.text('시작하기'), findsOneWidget);
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
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.ensureVisible(requestButton);
      await tester.tap(requestButton);
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
  bool microphoneGranted = false;
  bool locationGranted = false;
  bool calendarGranted = false;
  bool notificationGranted = false;
  bool notificationRequestGranted = true;
  bool exactAlarmRequestGranted = true;
  PermissionCheckState fullScreenIntentStatus =
      PermissionCheckState.unsupported;
  bool notificationSettingsOpened = false;
  bool appSettingsOpened = false;
  final List<String> requestLog = <String>[];
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
      microphoneGranted: microphoneGranted,
      locationGranted: locationGranted,
      calendarGranted: calendarGranted,
      notificationStatus: NotificationPermissionStatus(
        notificationsEnabled: notificationGranted,
        exactAlarmsEnabled: exactAlarmGranted,
        fullScreenIntentStatus: fullScreenIntentGranted
            ? PermissionCheckState.granted
            : fullScreenIntentStatus,
      ),
    );
  }

  @override
  Future<bool> requestMicrophonePermission() async {
    microphoneRequests += 1;
    requestLog.add('microphone');
    microphoneGranted = true;
    return true;
  }

  @override
  Future<bool> requestLocationPermission() async {
    locationRequests += 1;
    requestLog.add('location');
    locationGranted = true;
    return true;
  }

  @override
  Future<bool> requestCalendarPermission() async {
    calendarRequests += 1;
    requestLog.add('calendar');
    calendarGranted = true;
    return true;
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
    requestLog.add('notification');
    notificationGranted = notificationRequestGranted;
    return notificationRequestGranted;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactAlarmRequests += 1;
    requestLog.add('exactAlarm');
    exactAlarmGranted = exactAlarmRequestGranted;
    return exactAlarmRequestGranted;
  }

  @override
  Future<bool> requestFullScreenIntentPermission() async {
    fullScreenIntentRequests += 1;
    requestLog.add('fullScreenIntent');
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
