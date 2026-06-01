import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
  });

  testWidgets('EventEditScreen uses inline calendar style editor',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(2026, 5, 13, 0),
            endAt: DateTime.utc(2026, 5, 13, 1),
            category: '업무',
          ),
        ),
      ),
    );

    expect(find.text('하루'), findsNothing);
    expect(find.text('연속'), findsNothing);
    expect(find.text('서울 (GMT+9:00)'), findsNothing);
    expect(find.text('기본 정보'), findsOneWidget);
    expect(find.text('날짜 · 시간'), findsOneWidget);
    expect(find.text('시작 시간 조정'), findsNothing);

    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();

    expect(find.text('시작 시간 조정'), findsOneWidget);
  });

  testWidgets('EventEditScreen initializes new event date from selected date',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          initialDate: DateTime(2026, 6, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('26. 6. 15.(월)'), findsWidgets);
  });

  testWidgets(
      'EventEditScreen asks for full-screen consent when critical is enabled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final permissions = _FakePermissionService();

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          permissionService: permissions,
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(2026, 5, 13, 0),
            endAt: DateTime.utc(2026, 5, 13, 1),
            category: '업무',
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('알림 옵션'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('알림 옵션'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('강한 알림'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('강한 알림'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('강한 알림으로 예약'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('강한 알림으로 예약'));
    await tester.pumpAndSettle();

    expect(find.text('중요 알람 권한이 필요해요'), findsOneWidget);

    await tester.tap(find.text('허용하러 가기'));
    await tester.pumpAndSettle();

    expect(permissions.notificationPermissionsRequested, isTrue);
    expect(permissions.exactAlarmRequested, isTrue);
    expect(permissions.fullScreenIntentRequested, isTrue);
  });

  testWidgets('EventEditScreen keeps expanded sections visible',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '팀장 동행방문',
            startAt: DateTime.utc(2026, 5, 13, 0),
            endAt: DateTime.utc(2026, 5, 13, 1),
            category: '업무',
          ),
        ),
      ),
    );

    final cases = <({String header, String revealed})>[
      (header: '반복 설정', revealed: '반복 안 함'),
      (header: '설명 · 준비물', revealed: '준비물'),
      (header: '알림 옵션', revealed: '미리알림'),
      (header: '강한 알림', revealed: '강한 알림으로 예약'),
    ];

    for (final item in cases) {
      await tester.scrollUntilVisible(
        find.text(item.header),
        260,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text(item.header));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item.header));
      await tester.pumpAndSettle();

      final revealedRect = tester.getRect(find.text(item.revealed).last);
      expect(revealedRect.bottom, lessThanOrEqualTo(640));

      await tester.tap(find.text(item.header));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('EventEditScreen back falls back to home when opened directly',
      (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.eventEdit,
      routes: [
        GoRoute(
          path: AppRoutes.eventEdit,
          builder: (_, __) => EventEditScreen(
            event: EventModel(
              id: 'event-1',
              userId: 'user-1',
              title: '알림으로 연 일정',
              startAt: DateTime.utc(2026, 5, 13, 0),
              endAt: DateTime.utc(2026, 5, 13, 1),
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('홈탭')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('홈탭'), findsOneWidget);
  });
}

class _FakePermissionService extends AppPermissionService {
  bool notificationPermissionsRequested = false;
  bool exactAlarmRequested = false;
  bool fullScreenIntentRequested = false;

  @override
  Future<AppPermissionSnapshot> checkAll() async {
    return AppPermissionSnapshot(
      microphoneGranted: true,
      locationGranted: true,
      calendarGranted: true,
      notificationStatus: NotificationPermissionStatus(
        notificationsEnabled: notificationPermissionsRequested,
        exactAlarmsEnabled: exactAlarmRequested,
        fullScreenIntentStatus: fullScreenIntentRequested
            ? PermissionCheckState.granted
            : PermissionCheckState.denied,
      ),
    );
  }

  @override
  Future<NotificationPermissionStatus> requestNotificationPermissions() async {
    notificationPermissionsRequested = true;
    return const NotificationPermissionStatus(
      notificationsEnabled: true,
      exactAlarmsEnabled: false,
      fullScreenIntentStatus: PermissionCheckState.denied,
    );
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactAlarmRequested = true;
    return true;
  }

  @override
  Future<bool> requestFullScreenIntentPermission() async {
    fullScreenIntentRequested = true;
    return true;
  }
}
