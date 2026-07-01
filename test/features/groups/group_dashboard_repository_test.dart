import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/features/groups/models/group_event_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
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
  DateTime? createdAt,
}) {
  return GroupEventModel(
    id: id,
    groupId: groupId,
    title: title,
    startAt: startAt,
    endAt: endAt,
    createdBy: createdBy,
    status: status,
    createdAt: createdAt,
  );
}

void main() {
  test('summary calculation counts today, week, members, and upcoming',
      () async {
    final groupRepository = FakeGroupRepository(
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
    );
    final eventRepository = FakeGroupEventRepository(
      initialEvents: <GroupEventModel>[
        _event(
          id: 'event-1',
          groupId: 'group-1',
          title: '오늘 일정',
          startAt: DateTime.utc(2026, 6, 11, 1),
          endAt: DateTime.utc(2026, 6, 11, 2),
        ),
        _event(
          id: 'event-2',
          groupId: 'group-1',
          title: '이번 주 일정',
          startAt: DateTime.utc(2026, 6, 13, 1),
          endAt: DateTime.utc(2026, 6, 13, 2),
        ),
      ],
    );

    final repository = SupabaseGroupDashboardRepository(
      groupRepository: groupRepository,
      eventRepository: eventRepository,
    );
    final summary = await repository.loadDashboard(
      groupId: 'group-1',
      now: DateTime.utc(2026, 6, 11, 9),
    );

    expect(summary.todayEventCount, 1);
    expect(summary.weekEventCount, 2);
    expect(summary.memberCount, 2);
    expect(summary.upcomingEvents, hasLength(1));
    expect(summary.upcomingEvents.first.id, 'event-2');
  });

  test(
      'memberShareStats aggregates per-member shared counts including zero-share members',
      () async {
    final groupRepository = FakeGroupRepository(
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
          _member(
            id: 'member-3',
            groupId: 'group-1',
            userId: 'user-3',
            role: 'member',
          ),
        ],
      },
    );
    final eventRepository = FakeGroupEventRepository(
      initialEvents: <GroupEventModel>[
        _event(
          id: 'event-1',
          groupId: 'group-1',
          title: 'user-1 첫 일정',
          startAt: DateTime.utc(2026, 6, 11, 1),
          endAt: DateTime.utc(2026, 6, 11, 2),
          createdBy: 'user-1',
          createdAt: DateTime.utc(2026, 6, 11, 1),
        ),
        _event(
          id: 'event-2',
          groupId: 'group-1',
          title: 'user-1 두번째 일정',
          startAt: DateTime.utc(2026, 6, 12, 1),
          endAt: DateTime.utc(2026, 6, 12, 2),
          createdBy: 'user-1',
          createdAt: DateTime.utc(2026, 6, 12, 1),
        ),
        _event(
          id: 'event-3',
          groupId: 'group-1',
          title: 'user-2 일정',
          startAt: DateTime.utc(2026, 6, 13, 1),
          endAt: DateTime.utc(2026, 6, 13, 2),
          createdBy: 'user-2',
          createdAt: DateTime.utc(2026, 6, 13, 1),
        ),
      ],
    );

    final repository = SupabaseGroupDashboardRepository(
      groupRepository: groupRepository,
      eventRepository: eventRepository,
    );
    final summary = await repository.loadDashboard(
      groupId: 'group-1',
      now: DateTime.utc(2026, 6, 11, 9),
    );

    expect(summary.memberShareStats, hasLength(3));

    // sharedCount desc: user-1 (2건) > user-2 (1건) > user-3 (0건)
    expect(summary.memberShareStats[0].userId, 'user-1');
    expect(summary.memberShareStats[0].sharedCount, 2);
    expect(
      summary.memberShareStats[0].lastSharedAt,
      DateTime.utc(2026, 6, 12, 1),
    );

    expect(summary.memberShareStats[1].userId, 'user-2');
    expect(summary.memberShareStats[1].sharedCount, 1);
    expect(
      summary.memberShareStats[1].lastSharedAt,
      DateTime.utc(2026, 6, 13, 1),
    );

    // 0건 멤버도 포함되어야 함 (미참여 멤버 가시성)
    expect(summary.memberShareStats[2].userId, 'user-3');
    expect(summary.memberShareStats[2].sharedCount, 0);
    expect(summary.memberShareStats[2].lastSharedAt, isNull);
  });
}
