import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_dashboard_provider.dart';
import 'package:planflow/features/groups/repositories/group_dashboard_repository.dart';
import 'package:planflow/features/groups/repositories/group_event_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_dashboard_screen.dart';
import 'package:planflow/features/groups/widgets/member_shared_events_sheet.dart';

class FakeGroupRepository extends GroupRepository {
  FakeGroupRepository({
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

class FakeGroupEventRepository extends GroupEventRepository {
  FakeGroupEventRepository({List<GroupEventModel>? initialEvents})
      : events = List<GroupEventModel>.from(initialEvents ?? const []);

  final List<GroupEventModel> events;

  @override
  Future<GroupEventModel> archiveGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> cancelGroupEvent(String eventId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> createGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupEventModel>> getEventsForGroup(
    String groupId,
    DateTime from,
    DateTime to,
  ) async {
    return events
        .where(
          (event) =>
              event.groupId == groupId &&
              event.status == 'active' &&
              !event.startAt.isAfter(to) &&
              !event.endAt.isBefore(from),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupEventModel> updateGroupEvent(GroupEventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<GroupEventModel> fetchGroupEvent(String eventId) {
    throw UnimplementedError();
  }
}

class FakeGroupDashboardRepository extends GroupDashboardRepository {
  FakeGroupDashboardRepository({
    required this.summary,
    this.memberEvents = const <GroupEventModel>[],
  });

  final GroupDashboardSummary summary;
  final List<GroupEventModel> memberEvents;

  @override
  Future<GroupDashboardSummary> loadDashboard({
    required String groupId,
    required DateTime now,
  }) async {
    return summary;
  }

  @override
  Future<List<GroupEventModel>> fetchMemberEvents({
    required String groupId,
    required String memberUserId,
    required DateTime from,
    required DateTime to,
  }) async {
    return memberEvents
        .where((event) => event.createdBy == memberUserId)
        .toList(growable: false);
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

GroupMemberModel _member({
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
  );
}

GroupEventModel _event({
  required String id,
  required String groupId,
  required String title,
  required DateTime startAt,
  required DateTime endAt,
  String status = 'active',
  String createdBy = 'user-1',
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: createdBy,
    status: status,
  );
}

MemberShareStat _stat({
  required String userId,
  required String displayName,
  required int sharedCount,
  required bool isLeader,
  DateTime? lastSharedAt,
}) {
  return MemberShareStat(
    userId: userId,
    displayName: displayName,
    sharedCount: sharedCount,
    isLeader: isLeader,
    lastSharedAt: lastSharedAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('shows dashboard metrics and upcoming events', (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );
    final provider = GroupDashboardProvider(
      contextProvider: contextProvider,
      repository: FakeGroupDashboardRepository(
        summary: GroupDashboardSummary(
          todayEventCount: 1,
          weekEventCount: 2,
          memberCount: 1,
          upcomingEvents: <GroupEventModel>[
            _event(
              id: 'event-1',
              groupId: 'group-1',
              title: '오늘 일정',
              startAt: DateTime.utc(2026, 6, 11, 1),
              endAt: DateTime.utc(2026, 6, 11, 2),
            ),
          ],
        ),
      ),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDashboardScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정'), findsWidgets);
    expect(find.text('이번 주 일정'), findsWidgets);
    expect(find.text('멤버 수'), findsWidgets);
    expect(find.text('다가오는 일정'), findsWidgets);
    expect(find.text('오늘 일정'), findsWidgets);
  });

  testWidgets('shows empty state when no group is selected', (tester) async {
    final provider = GroupDashboardProvider(
      contextProvider: GroupContextProvider(
        repository: FakeGroupRepository(
          groups: const <GroupModel>[],
          membersByGroupId: const <String, List<GroupMemberModel>>{},
        ),
      ),
      repository: FakeGroupDashboardRepository(
        summary: GroupDashboardSummary(
          todayEventCount: 0,
          weekEventCount: 0,
          memberCount: 0,
          upcomingEvents: const <GroupEventModel>[],
        ),
      ),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDashboardScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('선택된 그룹이 없어요'), findsWidgets);
    expect(find.byKey(const ValueKey('group-dashboard-group-list-button')),
        findsOneWidget);
  });

  testWidgets(
      'tapping a member share row opens the bottom sheet showing that member name',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
            _member(
              id: 'member-2',
              groupId: 'group-1',
              userId: 'user-2',
              role: 'member',
            ),
          ],
        },
      ),
    );
    final provider = GroupDashboardProvider(
      contextProvider: contextProvider,
      repository: FakeGroupDashboardRepository(
        summary: GroupDashboardSummary(
          todayEventCount: 0,
          weekEventCount: 1,
          memberCount: 2,
          upcomingEvents: const <GroupEventModel>[],
          memberShareStats: <MemberShareStat>[
            _stat(
              userId: 'user-1',
              displayName: '리더 홍길동',
              sharedCount: 0,
              isLeader: true,
            ),
            _stat(
              userId: 'user-2',
              displayName: '멤버 김철수',
              sharedCount: 1,
              isLeader: false,
            ),
          ],
        ),
      ),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDashboardScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rowFinder =
        find.byKey(const ValueKey('group-dashboard-member-share-user-2'));
    expect(rowFinder, findsOneWidget);
    await tester.ensureVisible(rowFinder);
    await tester.pumpAndSettle();

    await tester.tap(rowFinder);
    await tester.pumpAndSettle();

    expect(find.byType(MemberSharedEventsSheet), findsOneWidget);
    expect(find.text('멤버 김철수'), findsWidgets);
  });

  testWidgets(
      'bottom sheet default range shows last-7-days events and empty state when none',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );
    final provider = GroupDashboardProvider(
      contextProvider: contextProvider,
      repository: FakeGroupDashboardRepository(
        summary: GroupDashboardSummary(
          todayEventCount: 0,
          weekEventCount: 0,
          memberCount: 1,
          upcomingEvents: const <GroupEventModel>[],
          memberShareStats: <MemberShareStat>[
            _stat(
              userId: 'user-1',
              displayName: '리더 홍길동',
              sharedCount: 0,
              isLeader: true,
            ),
          ],
        ),
        memberEvents: const <GroupEventModel>[],
      ),
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDashboardScreen(
          provider: provider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rowFinder =
        find.byKey(const ValueKey('group-dashboard-member-share-user-1'));
    await tester.ensureVisible(rowFinder);
    await tester.pumpAndSettle();

    await tester.tap(rowFinder);
    await tester.pumpAndSettle();

    expect(find.text('최근 7일'), findsOneWidget);
    expect(find.text('이 기간에 공유한 일정이 없어요.'), findsOneWidget);
  });
}
