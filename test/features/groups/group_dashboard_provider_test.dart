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
  String? lastGroupId;
  String? lastMemberUserId;
  DateTime? lastFrom;
  DateTime? lastTo;

  @override
  Future<GroupDashboardSummary> loadDashboard({
    required String groupId,
    required DateTime now,
  }) async {
    lastGroupId = groupId;
    return summary;
  }

  @override
  Future<List<GroupEventModel>> fetchMemberEvents({
    required String groupId,
    required String memberUserId,
    required DateTime from,
    required DateTime to,
  }) async {
    lastGroupId = groupId;
    lastMemberUserId = memberUserId;
    lastFrom = from;
    lastTo = to;
    return memberEvents;
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
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: 'user-1',
    status: status,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads dashboard for the selected leader group', () async {
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
    final repository = FakeGroupDashboardRepository(
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
    );
    final provider = GroupDashboardProvider(
      contextProvider: contextProvider,
      repository: repository,
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await provider.load('user-1');

    expect(provider.selectedGroup?.name, 'Leader Group');
    expect(provider.selectedGroupRole, 'leader');
    expect(provider.todayEventCount, 1);
    expect(provider.weekEventCount, 2);
    expect(provider.memberCount, 1);
    expect(provider.upcomingEvents, hasLength(1));
    expect(repository.lastGroupId, 'group-1');
  });

  test('shows empty state when no group exists', () async {
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

    await provider.load('user-1');

    expect(provider.hasSelectedGroup, isFalse);
    expect(provider.isPersonalMode, isTrue);
    expect(provider.todayEventCount, 0);
    expect(provider.memberCount, 0);
  });

  test('fetchMemberEvents delegates to repository with selected group id',
      () async {
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
    final memberEvent = _event(
      id: 'event-1',
      groupId: 'group-1',
      title: '멤버 일정',
      startAt: DateTime.utc(2026, 6, 11, 1),
      endAt: DateTime.utc(2026, 6, 11, 2),
    );
    final repository = FakeGroupDashboardRepository(
      summary: GroupDashboardSummary(
        todayEventCount: 0,
        weekEventCount: 0,
        memberCount: 1,
        upcomingEvents: const <GroupEventModel>[],
      ),
      memberEvents: <GroupEventModel>[memberEvent],
    );
    final provider = GroupDashboardProvider(
      contextProvider: contextProvider,
      repository: repository,
      nowProvider: () => DateTime.utc(2026, 6, 11, 9),
    );

    await provider.load('user-1');

    final from = DateTime.utc(2026, 6, 5);
    final to = DateTime.utc(2026, 6, 12);
    final result = await provider.fetchMemberEvents(
      memberUserId: 'user-1',
      from: from,
      to: to,
    );

    expect(result, hasLength(1));
    expect(result.first.id, 'event-1');
    expect(repository.lastGroupId, 'group-1');
    expect(repository.lastMemberUserId, 'user-1');
    expect(repository.lastFrom, from);
    expect(repository.lastTo, to);
  });
}
