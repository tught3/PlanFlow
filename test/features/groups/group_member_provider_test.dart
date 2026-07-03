import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_member_provider.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';

class FakeGroupRepository extends GroupRepository {
  FakeGroupRepository({
    required this.groups,
    required this.membersByGroupId,
    this.throwOnListGroups = false,
  });

  final List<GroupModel> groups;
  final Map<String, List<GroupMemberModel>> membersByGroupId;
  final bool throwOnListGroups;

  @override
  Future<List<GroupModel>> listGroups() async {
    if (throwOnListGroups) {
      throw StateError('group load failed');
    }
    return groups;
  }

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
    return List<GroupMemberModel>.from(
      membersByGroupId[groupId] ?? const <GroupMemberModel>[],
    );
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) {
    throw UnimplementedError();
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) async {
    final groupMembers = membersByGroupId[member.groupId];
    if (groupMembers == null) {
      throw StateError('missing group members');
    }
    final index = groupMembers.indexWhere((item) => item.id == member.id);
    if (index == -1) {
      throw StateError('missing member');
    }
    groupMembers[index] = member;
    return member;
  }

  @override
  Future<GroupMemberModel> updateMemberDisplayName(
    String memberId,
    String? displayName,
  ) async {
    for (final entry in membersByGroupId.entries) {
      final index = entry.value.indexWhere((item) => item.id == memberId);
      if (index == -1) {
        continue;
      }
      final updated = entry.value[index].copyWith(
        displayName: displayName,
        clearDisplayName: displayName == null || displayName.trim().isEmpty,
      );
      entry.value[index] = updated;
      return updated;
    }
    throw StateError('missing member');
  }

  @override
  Future<GroupMemberModel> removeGroupMember(
    String groupId,
    String userId,
  ) async {
    final groupMembers = membersByGroupId[groupId];
    if (groupMembers == null) {
      throw StateError('missing group members');
    }
    final index = groupMembers.indexWhere((item) => item.userId == userId);
    if (index == -1) {
      throw StateError('missing member');
    }
    final current = groupMembers[index];
    final removed = current.copyWith(
      status: 'removed',
      removedAt: DateTime.utc(2026, 6, 13),
      removedBy: 'user-1',
      updatedAt: DateTime.utc(2026, 6, 13),
    );
    groupMembers[index] = removed;
    return removed;
  }
}

GroupModel _group({
  required String id,
  required String name,
  required String createdBy,
  required DateTime createdAt,
  String status = 'active',
}) {
  return GroupModel(
    id: id,
    createdBy: createdBy,
    name: name,
    status: status,
    createdAt: createdAt,
  );
}

GroupMemberModel _member({
  required String id,
  required String groupId,
  required String userId,
  required String role,
  String status = 'active',
  DateTime? joinedAt,
  DateTime? createdAt,
}) {
  return GroupMemberModel(
    id: id,
    groupId: groupId,
    userId: userId,
    role: role,
    status: status,
    joinedAt: joinedAt,
    createdAt: createdAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('selects personal mode when there are no groups', () async {
    final repository = FakeGroupRepository(
      groups: const <GroupModel>[],
      membersByGroupId: const <String, List<GroupMemberModel>>{},
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await provider.load('user-1');

    expect(provider.isPersonalMode, isTrue);
    expect(provider.hasSelectedGroup, isFalse);
    expect(provider.hasMembers, isFalse);
  });

  test('loads members for the selected leader group', () async {
    final repository = FakeGroupRepository(
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
            id: 'leader-1',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
            joinedAt: DateTime.utc(2026, 6, 11, 1),
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
          _member(
            id: 'member-1',
            groupId: 'group-1',
            userId: 'user-2',
            role: 'member',
            joinedAt: DateTime.utc(2026, 6, 11, 2),
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await provider.load('user-1');

    expect(provider.selectedGroup?.id, 'group-1');
    expect(provider.selectedGroupRole, 'leader');
    expect(provider.isLeaderOfSelectedGroup, isTrue);
    expect(provider.members.length, 2);
    expect(provider.canRemoveMember(provider.members.last), isTrue);
  });

  test('prevents self removal and last leader removal', () async {
    final repository = FakeGroupRepository(
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
            id: 'leader-1',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await provider.load('user-1');

    expect(
      () => provider.removeMember(provider.members.first),
      throwsStateError,
    );
    expect(provider.canRemoveMember(provider.members.first), isFalse);
  });

  test('can remove another member and marks the row removed', () async {
    final repository = FakeGroupRepository(
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
            id: 'leader-1',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
          _member(
            id: 'member-1',
            groupId: 'group-1',
            userId: 'user-2',
            role: 'member',
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await provider.load('user-1');
    final removed = await provider.removeMember(provider.members.last);

    expect(removed.status, 'removed');
    expect(removed.removedBy, 'user-1');
    expect(removed.removedAt, isNotNull);
    expect(provider.members.last.status, 'removed');
  });

  test('leader updates member display name', () async {
    final repository = FakeGroupRepository(
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
            id: 'leader-1',
            groupId: 'group-1',
            userId: 'user-1',
            role: 'leader',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
          _member(
            id: 'member-1',
            groupId: 'group-1',
            userId: 'user-2',
            role: 'member',
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
        ],
      },
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await provider.load('user-1');
    final updated = await provider.updateMemberDisplayName(
      provider.members.last,
      '민수',
    );

    expect(updated.displayName, '민수');
    expect(provider.members.last.effectiveDisplayName, '민수');
  });

  test('records error state when repository load fails', () async {
    final repository = FakeGroupRepository(
      groups: const <GroupModel>[],
      membersByGroupId: const <String, List<GroupMemberModel>>{},
      throwOnListGroups: true,
    );
    final provider = GroupMemberProvider(
      contextProvider: GroupContextProvider(repository: repository),
      repository: repository,
    );

    await provider.load('user-1');

    expect(provider.error, contains('group load failed'));
    expect(provider.isLoading, isFalse);
    expect(provider.hasSelectedGroup, isFalse);
  });
}
