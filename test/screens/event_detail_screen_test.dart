import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:planflow/core/constants.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/screens/event/event_detail_screen.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      Supabase.instance;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://example.com',
        anonKey: 'public-anon-key',
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
      );
    }
  });

  testWidgets('EventDetailScreen back falls back to home when opened directly',
      (tester) async {
    final event = EventModel(
      id: 'event-1',
      userId: 'user-1',
      title: '돌아가기 테스트 일정',
      startAt: DateTime.utc(2026, 5, 13, 0),
      endAt: DateTime.utc(2026, 5, 13, 1),
    );
    final router = GoRouter(
      initialLocation: '${AppRoutes.eventDetail}/${event.id}',
      routes: [
        GoRoute(
          path: '${AppRoutes.eventDetail}/:eventId',
          builder: (_, __) => EventDetailScreen(
            event: event,
            eventRepository: _FakeEventRepository(event),
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('홈')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('홈'), findsOneWidget);
  });

  testWidgets('EventDetailScreen departure prompt acknowledges departure',
      (tester) async {
    final event = EventModel(
      id: 'event-2',
      userId: 'user-1',
      title: '출발 알림',
      startAt: DateTime.utc(2026, 5, 13, 0),
      endAt: DateTime.utc(2026, 5, 13, 1),
    );
    final departureAlarmService = _FakeDepartureAlarmService();
    final router = GoRouter(
      initialLocation: '${AppRoutes.eventDetail}/${event.id}',
      routes: [
        GoRoute(
          path: '${AppRoutes.eventDetail}/:eventId',
          builder: (_, __) => EventDetailScreen(
            event: event,
            eventRepository: _FakeEventRepository(event),
            showDeparturePrompt: true,
            departureAlarmService: departureAlarmService,
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('홈')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('출발하셨나요?'), findsOneWidget);
    expect(find.text('아직 출발 전'), findsOneWidget);
    await tester.tap(find.text('출발'));
    await tester.pumpAndSettle();

    expect(departureAlarmService.acknowledgedEventIds, ['event-2']);
    expect(find.text('출발 알림을 멈췄어요.'), findsOneWidget);
  });

  testWidgets(
      'EventDetailScreen shows linked-group dialog and cascades cancel when chosen',
      (tester) async {
    final event = EventModel(
      id: 'event-3',
      userId: 'user-1',
      title: '그룹 연동 일정',
      startAt: DateTime.utc(2026, 5, 13, 0),
      endAt: DateTime.utc(2026, 5, 13, 1),
      groupEventId: 'group-event-3',
    );
    final eventRepository = _FakeEventRepository(event);
    final groupEventRepository = _FakeGroupEventRepository()
      ..linkedGroupEvents = [
        GroupEventModel(
          id: 'group-event-3',
          groupId: 'group-1',
          title: '그룹 연동 일정',
          startAt: DateTime.utc(2026, 5, 13, 0),
          endAt: DateTime.utc(2026, 5, 13, 1),
          createdBy: 'user-1',
          personalEventId: 'event-3',
          status: 'active',
        ),
      ];
    final router = GoRouter(
      initialLocation: '${AppRoutes.eventDetail}/${event.id}',
      routes: [
        GoRoute(
          path: '${AppRoutes.eventDetail}/:eventId',
          builder: (_, __) => EventDetailScreen(
            event: event,
            eventRepository: eventRepository,
            groupEventRepository: groupEventRepository,
            groupRepository: _FakeGroupRepository(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (_, __) => const Scaffold(body: Text('캘린더')),
        ),
      ],
    );

    AppEnv.markSupabaseInitialized();
    addTearDown(AppEnv.resetSupabaseInitializationState);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('일정 삭제'));
    await tester.pumpAndSettle();

    // 연동 그룹일정이 있으므로 "함께 취소할 그룹" 체크리스트 시트가 떠야 한다.
    expect(find.textContaining('함께 취소할 그룹'), findsOneWidget);
    expect(find.text('우리 팀'), findsOneWidget);

    // 기본 전체 선택 상태로 '삭제' 확인 → 그룹일정도 취소된다.
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();

    expect(groupEventRepository.cancelledEventIds, ['group-event-3']);
    expect(eventRepository.deletedEventIds, ['event-3']);
    expect(find.text('캘린더'), findsOneWidget);
  });

  testWidgets(
      'EventDetailScreen personal-only delete does not cancel linked group event',
      (tester) async {
    final event = EventModel(
      id: 'event-4',
      userId: 'user-1',
      title: '그룹 연동 일정 2',
      startAt: DateTime.utc(2026, 5, 13, 0),
      endAt: DateTime.utc(2026, 5, 13, 1),
      groupEventId: 'group-event-4',
    );
    final eventRepository = _FakeEventRepository(event);
    final groupEventRepository = _FakeGroupEventRepository()
      ..linkedGroupEvents = [
        GroupEventModel(
          id: 'group-event-4',
          groupId: 'group-1',
          title: '그룹 연동 일정 2',
          startAt: DateTime.utc(2026, 5, 13, 0),
          endAt: DateTime.utc(2026, 5, 13, 1),
          createdBy: 'user-1',
          personalEventId: 'event-4',
          status: 'active',
        ),
      ];
    final router = GoRouter(
      initialLocation: '${AppRoutes.eventDetail}/${event.id}',
      routes: [
        GoRoute(
          path: '${AppRoutes.eventDetail}/:eventId',
          builder: (_, __) => EventDetailScreen(
            event: event,
            eventRepository: eventRepository,
            groupEventRepository: groupEventRepository,
            groupRepository: _FakeGroupRepository(),
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (_, __) => const Scaffold(body: Text('캘린더')),
        ),
      ],
    );

    AppEnv.markSupabaseInitialized();
    addTearDown(AppEnv.resetSupabaseInitializationState);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('일정 삭제'));
    await tester.pumpAndSettle();

    expect(find.textContaining('함께 취소할 그룹'), findsOneWidget);

    // 그룹 체크를 해제하면 개인일정만 삭제되고 그룹일정은 취소되지 않는다.
    await tester.tap(find.text('우리 팀'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();

    expect(groupEventRepository.cancelledEventIds, isEmpty);
    expect(eventRepository.deletedEventIds, ['event-4']);
    expect(find.text('캘린더'), findsOneWidget);
  });
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.event);

  final EventModel event;
  final deletedEventIds = <String>[];

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return event;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return [event];
  }

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedEventIds.add(eventId);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    return event;
  }
}

class _FakeGroupEventRepository extends GroupEventRepository {
  final cancelledEventIds = <String>[];
  // 개인일정에 연동된 그룹일정들(다중 그룹 공유). 테스트에서 주입한다.
  List<GroupEventModel> linkedGroupEvents = const [];

  GroupEventModel _fakeGroupEvent(String eventId, {String status = 'active'}) {
    return GroupEventModel(
      id: eventId,
      groupId: 'group-1',
      title: '그룹 연동 일정',
      startAt: DateTime.utc(2026, 5, 13, 0),
      endAt: DateTime.utc(2026, 5, 13, 1),
      createdBy: 'user-1',
      status: status,
    );
  }

  @override
  Future<List<GroupEventModel>> getGroupEventsByPersonalEventId(
    String personalEventId,
  ) async {
    return linkedGroupEvents
        .where((event) => event.personalEventId == personalEventId)
        .toList(growable: false);
  }

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return const [];
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) async {
    return event;
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) async {
    return event;
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) async {
    cancelledEventIds.add(eventId);
    return _fakeGroupEvent(eventId, status: 'cancelled');
  }

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) async {
    return _fakeGroupEvent(eventId, status: 'archived');
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) async {
    return _fakeGroupEvent(eventId);
  }
}

class _FakeGroupRepository extends GroupRepository {
  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    return GroupModel(
      id: groupId,
      createdBy: 'leader-1',
      name: '우리 팀',
      createdAt: DateTime.utc(2026, 5, 1),
    );
  }

  @override
  Future<List<GroupModel>> listGroups() async => const [];

  @override
  Future<GroupModel> createGroup(GroupModel group) => throw UnimplementedError();

  @override
  Future<GroupModel> updateGroup(GroupModel group) => throw UnimplementedError();

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async => const [];

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) =>
      throw UnimplementedError();

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) =>
      throw UnimplementedError();
}

class _FakeDepartureAlarmService extends DepartureAlarmService {
  final acknowledgedEventIds = <String>[];

  @override
  Future<void> acknowledgeDeparture(String eventId) async {
    acknowledgedEventIds.add(eventId);
  }
}
