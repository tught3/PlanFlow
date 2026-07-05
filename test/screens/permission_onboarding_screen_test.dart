import 'dart:ui' as ui;

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
    'PermissionOnboardingScreen hides full-screen intent permission on normal phones',
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
      // exactAlarm은 필수 권한으로 포함됨 — 일반폰에서도 요청된다
      expect(permissionService.exactAlarmRequests, 1);
      expect(permissionService.locationRequests, 1);
      expect(permissionService.calendarRequests, 1);
      expect(permissionService.fullScreenIntentRequests, 0);
      // exactAlarm 기본값(true)이므로 허용됨
      expect(permissionService.exactAlarmGranted, isTrue);
      expect(permissionService.fullScreenIntentGranted, isFalse);
      expect(
        find.byKey(const ValueKey('permission-onboarding-request-all-button')),
        findsOneWidget,
      );

      final fullScreenIntentTile = find.byKey(
        const ValueKey('permission-onboarding-full-screen-intent-tile'),
      );
      expect(fullScreenIntentTile, findsNothing);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen does not treat a cutout as a foldable display feature',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final permissionService = _FakePermissionService();

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            displayFeatures: <ui.DisplayFeature>[
              ui.DisplayFeature(
                bounds: const Rect.fromLTWH(180, 0, 30, 24),
                type: ui.DisplayFeatureType.unknown,
                state: ui.DisplayFeatureState.postureFlat,
              ),
            ],
          ),
          child: MaterialApp(
            home: PermissionOnboardingScreen(
              permissionService: permissionService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
            const ValueKey('permission-onboarding-full-screen-intent-tile')),
        findsNothing,
      );
      expect(permissionService.fullScreenIntentRequests, isZero);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen shows full-screen intent permission as required on foldables',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final permissionService = _FakePermissionService();

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(1000, 800),
            displayFeatures: <ui.DisplayFeature>[
              ui.DisplayFeature(
                bounds: Rect.fromLTWH(495, 0, 10, 800),
                type: ui.DisplayFeatureType.hinge,
                state: ui.DisplayFeatureState.postureHalfOpened,
              ),
            ],
          ),
          child: MaterialApp(
            home: PermissionOnboardingScreen(
              permissionService: permissionService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fullScreenIntentTile = find.byKey(
        const ValueKey('permission-onboarding-full-screen-intent-tile'),
      );
      await tester.scrollUntilVisible(
        fullScreenIntentTile,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(fullScreenIntentTile, findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('permission-onboarding-request-all-button')),
      );
      await tester.pumpAndSettle();

      expect(permissionService.fullScreenIntentRequests, 1);
      expect(permissionService.fullScreenIntentGranted, isTrue);
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
    'PermissionOnboardingScreen does not reopen notification settings in a loop after resume when still denied',
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

      await tester.tap(
        find.byKey(const ValueKey('permission-onboarding-request-all-button')),
      );
      await tester.pumpAndSettle();

      expect(permissionService.notificationSettingsOpened, isTrue);
      expect(permissionService.notificationRequests, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(permissionService.notificationSettingsOpened, isTrue);
      expect(permissionService.notificationRequests, 1);
    },
  );

  testWidgets(
    'PermissionOnboardingScreen does not open generic app settings when exact alarm stays denied',
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

      await tester.tap(
        find.byKey(const ValueKey('permission-onboarding-request-all-button')),
      );
      await tester.pumpAndSettle();

      expect(permissionService.appSettingsOpened, isFalse);
      expect(permissionService.exactAlarmGranted, isFalse);
      expect(permissionService.alarmSettingsOpened, isTrue);
    },
  );
}

class _FakePermissionService extends AppPermissionService {
  _FakePermissionService()
      : super(notificationService: _FakeNotificationService());

  bool microphoneGranted = false;
  bool locationGranted = false;
  bool calendarGranted = false;
  bool exactAlarmGranted = false;
  bool fullScreenIntentGranted = false;
  bool notificationGranted = false;
  bool notificationRequestGranted = true;
  bool exactAlarmRequestGranted = true;
  bool notificationSettingsOpened = false;
  bool alarmSettingsOpened = false;
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
      microphoneGranted: microphoneGranted,
      locationGranted: locationGranted,
      calendarGranted: calendarGranted,
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
    microphoneGranted = true;
    return true;
  }

  @override
  Future<bool> requestLocationPermission() async {
    locationRequests += 1;
    locationGranted = true;
    return true;
  }

  @override
  Future<bool> requestCalendarPermission() async {
    calendarRequests += 1;
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
  Future<bool> openAlarmSettings() async {
    alarmSettingsOpened = true;
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
