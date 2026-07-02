import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/features/groups/models/calendar_overlay_item.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_calendar_overlay_provider.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/event_refresh_bus.dart';

void main() {
  testWidgets('CalendarScreen does not show a loading panel while loading',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CalendarScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('\uD655\uC778\uC911'), findsNothing);
    expect(find.textContaining('Supabase'), findsOneWidget);
  });

  test(
      'mergeCalendarEventsAfterReload preserves existing events after suspiciously small reload',
      () {
    final now = DateTime.now();
    final merged = mergeCalendarEventsAfterReload(
      previous: [
        _event('old-1', '기존 일정 1', now.add(const Duration(minutes: 1))),
        _event('old-2', '기존 일정 2', now.add(const Duration(minutes: 2))),
      ],
      loaded: [
        _event('new-1', '새 일정', now.add(const Duration(minutes: 3))),
      ],
    );

    expect(merged.map((event) => event.id), ['old-1', 'old-2', 'new-1']);
  });

  testWidgets(
      'CalendarScreen runs a queued reload after refresh signal arrives while loading',
      (tester) async {
    // 자정 경계 flaky 방지: 실제 현재시각 대신 오늘 정오로 고정해
    // now+1h/+2h가 같은 날(오늘 뷰)에 머물게 한다.
    final today = DateTime.now();
    final now = DateTime(today.year, today.month, today.day, 12);
    final firstLoad = Completer<List<EventModel>>();
    final repository = _AsyncEventRepository([
      firstLoad.future,
      Future.value([
        _event('old-1', '기존 일정', now.add(const Duration(hours: 1))),
        _event('new-1', '새 일정', now.add(const Duration(hours: 2))),
      ]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: now,
        ),
      ),
    );
    await tester.pump();

    EventRefreshBus.instance.notifyChanged(
      reason: 'test_queued',
      startAt: now,
    );
    await tester.pump();

    firstLoad.complete([
      _event('old-1', '기존 일정', now.add(const Duration(hours: 1))),
    ]);
    await tester.pumpAndSettle();

    expect(repository.listCalls, 2);
    expect(find.text('기존 일정'), findsWidgets);
    expect(find.text('새 일정'), findsWidgets);
  });

  testWidgets('CalendarScreen opens selected day sheet from initialDate',
      (tester) async {
    final selectedDay = DateTime(2026, 5, 15, 9);
    final repository = _AsyncEventRepository([
      Future.value([
        _event('selected-1', '선택한 날짜 일정', selectedDay),
        _event('other-1', '다른 날짜 일정', selectedDay.add(const Duration(days: 1))),
      ]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: selectedDay,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('calendar-day-events-draggable-sheet')),
      findsOneWidget,
    );
    final dayEventsList =
        find.byKey(const ValueKey('calendar-day-events-list'));
    expect(
      find.descendant(
        of: dayEventsList,
        matching: find.text('선택한 날짜 일정'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dayEventsList,
        matching: find.text('다른 날짜 일정'),
      ),
      findsNothing,
    );
  });

  testWidgets('CalendarScreen direct add passes selected date to edit route',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final selectedDay = DateTime(2026, 6, 15, 9);
    final repository = _AsyncEventRepository([
      Future.value(<EventModel>[]),
    ]);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => CalendarScreen(
            eventRepository: repository,
            userId: 'user-1',
            initialDate: selectedDay,
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEdit,
          builder: (_, state) => Scaffold(
            body: Text('edit-date:${state.uri.queryParameters['date']}'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('직접 추가').last);
    await tester.pumpAndSettle();

    expect(find.text('edit-date:2026-06-15'), findsOneWidget);
  });

  test('calendar marks date-range events across every local day', () {
    final rangeEvent = EventModel(
      id: 'range-1',
      userId: 'user-1',
      title: '원주집방문',
      startAt: DateTime.utc(2026, 4, 30, 15),
      endAt: DateTime.utc(2026, 5, 10, 15),
      isMultiDay: false,
    );

    expect(calendarEventSpansMultipleLocalDays(rangeEvent), isTrue);

    final markers = buildCalendarEventMarkerColorsByDay(
      events: <EventModel>[rangeEvent],
      focusedMonth: DateTime(2026, 5),
    );

    for (var day = 1; day <= 10; day += 1) {
      expect(markers[day], PlanFlowColors.active);
    }
    expect(markers[11], isNull);
  });

  test('calendar treats midnight end as the previous display day', () {
    final event = EventModel(
      id: 'range-midnight',
      userId: 'user-1',
      title: '테스트',
      startAt: DateTime.utc(2026, 5, 18, 15),
      endAt: DateTime.utc(2026, 5, 22, 15),
      isMultiDay: true,
    );

    final markers = buildCalendarEventMarkerColorsByDay(
      events: <EventModel>[event],
      focusedMonth: DateTime(2026, 5),
    );

    for (var day = 19; day <= 22; day += 1) {
      expect(markers[day], PlanFlowColors.active);
    }
    expect(markers[23], isNull);
  });

  test(
      'calendar mini month cells reserve multi-day bands and overflow after four slots',
      () {
    final cells = buildCalendarMiniMonthCells(
      focusedMonth: DateTime(2026, 6),
      events: <EventModel>[
        EventModel(
          id: 'multi',
          userId: 'user-1',
          title: '연속 일정',
          startAt: DateTime(2026, 6, 1, 9),
          endAt: DateTime(2026, 6, 3, 9),
          isMultiDay: true,
        ),
        _event('a', 'A', DateTime(2026, 6, 1, 10)),
        _event('b', 'B', DateTime(2026, 6, 1, 11)),
        _event('c', 'C', DateTime(2026, 6, 1, 12)),
        _event('d', 'D', DateTime(2026, 6, 1, 13)),
        _event('e', 'E', DateTime(2026, 6, 1, 14)),
      ],
    );

    final day1 = cells.firstWhere((cell) => cell.dayNumber == 1);
    final day2 = cells.firstWhere((cell) => cell.dayNumber == 2);

    expect(day1.events.length, 4);
    expect(day1.events.first.id, 'multi');
    expect(day1.overflowCount, 2);
    expect(day2.events.first.id, 'multi');
  });

  testWidgets('CalendarScreen paints holiday day numbers red', (tester) async {
    final repository = _AsyncEventRepository([
      Future.value([
        _event('holiday', '현충일', DateTime(2026, 6, 6, 9)),
      ]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: DateTime(2026, 6, 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dayLabel = tester.widget<Text>(
      find.byKey(const ValueKey('calendar-mini-day-2026-6-6')),
    );
    expect(dayLabel.style?.color, calendarCriticalEventMarkerColor);
  });

  testWidgets('CalendarScreen shows cross-month range on selected end day',
      (tester) async {
    final selectedDay = DateTime(2026, 6);
    final repository = _AsyncEventRepository([
      Future.value([
        EventModel(
          id: 'wonju-home',
          userId: 'user-1',
          title: '원주집방문',
          startAt: DateTime.utc(2026, 5, 25, 15),
          endAt: DateTime.utc(2026, 6, 1, 14, 59, 59),
          isAllDay: true,
          isMultiDay: true,
        ),
      ]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: selectedDay,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dayEventsList =
        find.byKey(const ValueKey('calendar-day-events-list'));
    expect(
      find.descendant(
        of: dayEventsList,
        matching: find.text('원주집방문'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('CalendarScreen overlays group events in the day sheet',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final selectedDay = DateTime(2026, 6, 15, 9);
    final repository = _AsyncEventRepository([
      Future.value([
        _event('personal-1', '개인 일정', selectedDay),
      ]),
    ]);
    final overlayProvider = _staticOverlayProvider(
      groups: <GroupModel>[
        _group(
          id: 'group-1',
          name: '서울1팀',
          createdBy: 'leader-1',
          createdAt: DateTime.utc(2026, 6, 11),
        ),
      ],
      membersByGroupId: <String, List<GroupMemberModel>>{
        'group-1': <GroupMemberModel>[
          _groupMember(
            id: 'leader-row',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
          ),
        ],
      },
      eventsByGroupId: <String, List<GroupEventModel>>{
        'group-1': <GroupEventModel>[
          _groupEvent(
            id: 'group-event-1',
            groupId: 'group-1',
            title: '그룹 회의',
            startAt: DateTime.utc(2026, 6, 15, 10),
            endAt: DateTime.utc(2026, 6, 15, 11),
          ),
        ],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          eventRepository: repository,
          userId: 'user-1',
          initialDate: selectedDay,
          groupCalendarOverlayProvider: overlayProvider,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('개인 일정'), findsWidgets);
    expect(find.text('그룹 일정'), findsWidgets);
    expect(
      find.byKey(const ValueKey('calendar-group-overlay-event-group-event-1')),
      findsOneWidget,
    );
    expect(find.text('서울1팀'), findsWidgets);
  });

  testWidgets('CalendarScreen routes group overlay taps to detail screen',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final selectedDay = DateTime(2026, 6, 15, 9);
    final repository = _AsyncEventRepository([
      Future.value([
        _event('personal-1', '개인 일정', selectedDay),
      ]),
    ]);
    final overlayProvider = _staticOverlayProvider(
      groups: <GroupModel>[
        _group(
          id: 'group-1',
          name: '서울1팀',
          createdBy: 'leader-1',
          createdAt: DateTime.utc(2026, 6, 11),
        ),
      ],
      membersByGroupId: <String, List<GroupMemberModel>>{
        'group-1': <GroupMemberModel>[
          _groupMember(
            id: 'leader-row',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
          ),
        ],
      },
      eventsByGroupId: <String, List<GroupEventModel>>{
        'group-1': <GroupEventModel>[
          _groupEvent(
            id: 'group-event-1',
            groupId: 'group-1',
            title: '그룹 회의',
            startAt: DateTime.utc(2026, 6, 15, 10),
            endAt: DateTime.utc(2026, 6, 15, 11),
          ),
        ],
      },
    );
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => CalendarScreen(
            eventRepository: repository,
            userId: 'user-1',
            initialDate: selectedDay,
            groupCalendarOverlayProvider: overlayProvider,
          ),
        ),
        GoRoute(
          path: AppRoutes.groupEventDetail,
          builder: (_, state) => Scaffold(
            body: Text('group-detail:${state.pathParameters['eventId']}'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    final groupCard =
        find.byKey(const ValueKey('calendar-group-overlay-event-group-event-1'));
    expect(groupCard, findsOneWidget);

    await tester.tap(groupCard);
    await tester.pumpAndSettle();

    expect(find.text('group-detail:group-event-1'), findsOneWidget);
  });
}

EventModel _event(String id, String title, DateTime startAt) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: title,
    startAt: startAt,
    endAt: startAt.add(const Duration(minutes: 30)),
  );
}

class _AsyncEventRepository extends EventRepository {
  _AsyncEventRepository(this._responses);

  final List<Future<List<EventModel>>> _responses;
  int listCalls = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    final index = listCalls;
    listCalls += 1;
    if (index >= _responses.length) {
      return _responses.last;
    }
    return _responses[index];
  }

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    throw UnimplementedError();
  }
}

class _StaticGroupCalendarOverlayProvider
    extends GroupCalendarOverlayProvider {
  _StaticGroupCalendarOverlayProvider({
    required List<CalendarOverlayItem> items,
    required GroupModel? selectedGroup,
    required String? selectedGroupRole,
    required List<GroupModel> groups,
    required Map<String, List<GroupMemberModel>> membersByGroupId,
  })  : _items = List<CalendarOverlayItem>.unmodifiable(items),
        _selectedGroup = selectedGroup,
        _selectedGroupRole = selectedGroupRole,
        super(
          contextProvider: GroupContextProvider(
            repository: _FakeGroupRepository(
              groups: groups,
              membersByGroupId: membersByGroupId,
            ),
          ),
          repository: _FakeGroupEventRepository(
            const <String, List<GroupEventModel>>{},
          ),
        );

  final List<CalendarOverlayItem> _items;
  final GroupModel? _selectedGroup;
  final String? _selectedGroupRole;

  @override
  List<CalendarOverlayItem> get items => _items;

  @override
  GroupModel? get selectedGroup => _selectedGroup;

  @override
  String? get selectedGroupRole => _selectedGroupRole;

  @override
  Future<void> loadForMonth(String userId, DateTime focusedMonth) async {}

  @override
  Future<void> clear() async {}
}

_StaticGroupCalendarOverlayProvider _staticOverlayProvider({
  required List<GroupModel> groups,
  required Map<String, List<GroupMemberModel>> membersByGroupId,
  required Map<String, List<GroupEventModel>> eventsByGroupId,
  GroupModel? selectedGroup,
  String? selectedGroupRole,
}) {
  final selected = selectedGroup ?? (groups.isEmpty ? null : groups.first);
  final items = <CalendarOverlayItem>[];
  if (selected != null) {
    final events = eventsByGroupId[selected.id] ?? const <GroupEventModel>[];
    items.addAll(
      events.map(
        (event) => CalendarOverlayItem.fromGroupEvent(
          event,
          groupName: selected.name,
        ),
      ),
    );
  }
  return _StaticGroupCalendarOverlayProvider(
    items: items,
    selectedGroup: selected,
    selectedGroupRole: selectedGroupRole,
    groups: groups,
    membersByGroupId: membersByGroupId,
  );
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

class _FakeGroupEventRepository extends GroupEventRepository {
  _FakeGroupEventRepository(this.eventsByGroupId);

  final Map<String, List<GroupEventModel>> eventsByGroupId;

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return List<GroupEventModel>.from(
      eventsByGroupId[groupId] ?? const <GroupEventModel>[],
    );
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
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
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }
}

GroupModel _group({
  required String id,
  required String name,
  required String createdBy,
  required DateTime createdAt,
}) {
  return GroupModel(
    id: id,
    createdBy: createdBy,
    name: name,
    createdAt: createdAt,
  );
}

GroupMemberModel _groupMember({
  required String id,
  required String groupId,
  required String userId,
  required String role,
}) {
  return GroupMemberModel(
    id: id,
    groupId: groupId,
    userId: userId,
    role: role,
    status: 'active',
    createdAt: DateTime.utc(2026, 6, 11),
  );
}

GroupEventModel _groupEvent({
  required String id,
  required String groupId,
  required String title,
  required DateTime startAt,
  required DateTime endAt,
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: 'leader-1',
    location: '회의실',
  );
}
