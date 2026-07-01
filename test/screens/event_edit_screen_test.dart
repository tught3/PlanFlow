import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/screens/event/event_edit_screen.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/widgets/calendar_style_event_editor.dart';
import 'package:planflow/widgets/schedule_save_scope_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
    expect(find.text('저장'), findsOneWidget);
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

  testWidgets('EventEditScreen shows save target options for selected group',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          initialDate: DateTime(2026, 6, 15),
          currentUserIdOverride: 'user-1',
          groupContextProvider: contextProvider,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('저장 범위'), findsOneWidget);
    expect(find.text('개인 일정만'), findsOneWidget);
    expect(find.text('개인 + 우리 팀'), findsOneWidget);
    expect(find.text('우리 팀만'), findsOneWidget);
  });

  testWidgets('EventEditScreen does not crash when auto-share pref is enabled',
      (tester) async {
    // Pre-set auto-share preference before creating widget
    SharedPreferences.setMockInitialValues(<String, Object>{
      'planflow:group_auto_share:v1:user-1:group-1': true,
    });

    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          initialDate: DateTime(2026, 6, 15),
          currentUserIdOverride: 'user-1',
          groupContextProvider: contextProvider,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The '저장 범위' card should exist when a group is selected
    expect(find.text('저장 범위'), findsOneWidget);
    expect(find.text('개인 일정만'), findsOneWidget);
    expect(find.text('개인 + 우리 팀'), findsOneWidget);

    // 자동 공유 pref가 켜져 있으면 새 일정의 저장 범위 기본값이
    // '개인 + 그룹'(personalAndGroup)으로 선택돼 있어야 한다(단순 무크래시가 아니라 동작 검증).
    final scopeCard = tester.widget<ScheduleSaveScopeCard>(
      find.byType(ScheduleSaveScopeCard),
    );
    expect(scopeCard.selected, ScheduleSaveTarget.personalAndGroup);
  });

  testWidgets(
      '자동 공유 pref가 꺼져 있으면 새 일정 저장 범위 기본값은 개인만이다',
      (tester) async {
    // pref 미설정(기본 OFF)
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final contextProvider = GroupContextProvider(
      repository: _FakeGroupRepository(
        groups: <GroupModel>[
          GroupModel(
            id: 'group-1',
            createdBy: 'leader-1',
            name: '우리 팀',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            GroupMemberModel(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          initialDate: DateTime(2026, 6, 15),
          currentUserIdOverride: 'user-1',
          groupContextProvider: contextProvider,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scopeCard = tester.widget<ScheduleSaveScopeCard>(
      find.byType(ScheduleSaveScopeCard),
    );
    expect(scopeCard.selected, ScheduleSaveTarget.personalOnly);
  });

  testWidgets('EventEditScreen keeps duration when start date changes',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventEditScreen(
          event: EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '김창민 만나기',
            startAt: DateTime.utc(2026, 6, 12, 9),
            endAt: DateTime.utc(2026, 6, 12, 10),
            category: '개인',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('26. 6. 12.(금)'), findsWidgets);

    final editor = tester.widget<CalendarStyleEventEditor>(
      find.byType(CalendarStyleEventEditor),
    );
    editor.onStartChanged(DateTime(2026, 6, 10, 9));
    await tester.pumpAndSettle();

    expect(find.text('26. 6. 10.(수)'), findsWidgets);
    expect(find.text('26. 6. 12.(금)'), findsNothing);
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
      find.text('중요한 일정'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('중요한 일정'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('중요한 일정으로 표시'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('중요한 일정으로 표시'));
    await tester.pumpAndSettle();

    expect(find.text('중요한 일정 알림 권한이 필요해요'), findsOneWidget);

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
      (header: '중요한 일정', revealed: '중요한 일정으로 표시'),
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

  testWidgets('EventEditScreen asks edit scope for linked group event',
      (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.eventEdit,
      routes: [
        GoRoute(
          path: AppRoutes.eventEdit,
          builder: (_, __) => EventEditScreen(
            currentUserIdOverride: 'user-1',
            eventRepository: _FakeEventRepository(),
            groupEventRepository: _FakeGroupEventRepository(),
            event: EventModel(
              id: 'event-1',
              userId: 'user-1',
              title: '팀 회의',
              startAt: DateTime.utc(2026, 6, 29, 1),
              endAt: DateTime.utc(2026, 6, 29, 2),
              category: '업무',
              groupEventId: 'group-event-1',
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (_, __) => const Scaffold(body: Text('달력')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('저장').last);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('그룹 일정도 같이 수정할까요?'), findsOneWidget);
    expect(find.text('개인만 수정'), findsOneWidget);
    expect(find.text('그룹도 같이 수정'), findsOneWidget);
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

class _FakeGroupRepository extends GroupRepository {
  _FakeGroupRepository({
    required this.groups,
    required this.membersByGroupId,
  });

  final List<GroupModel> groups;
  final Map<String, List<GroupMemberModel>> membersByGroupId;

  @override
  Future<List<GroupModel>> listGroups() async => groups;

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    for (final group in groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  @override
  Future<GroupModel> createGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    return membersByGroupId[groupId] ?? const <GroupMemberModel>[];
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) {
    throw UnimplementedError();
  }
}

class _FakeEventRepository extends EventRepository {
  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return const <EventModel>[];
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return null;
  }

  @override
  Future<List<EventModel>> findOverlappingEvents({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    String? userId,
    String? excludedEventId,
  }) async {
    return const <EventModel>[];
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    return event.copyWith(id: event.id.isEmpty ? 'event-created' : event.id);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
}

class _FakeGroupEventRepository extends GroupEventRepository {
  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return const <GroupEventModel>[];
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    return event.copyWith(id: 'group-event-created');
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    return event;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    return GroupEventModel(
      id: eventId,
      groupId: 'group-1',
      title: '팀 회의',
      startAt: DateTime.utc(2026, 6, 29, 1),
      endAt: DateTime.utc(2026, 6, 29, 2),
      createdBy: 'user-1',
      personalEventId: 'event-1',
    );
  }
}
