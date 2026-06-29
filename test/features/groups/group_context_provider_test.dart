import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
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
  return GroupMemberModel(id: id, groupId: groupId, userId: userId, role: role);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('selects personal mode when there are no groups', () async {
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: const <GroupModel>[],
        membersByGroupId: const <String, List<GroupMemberModel>>{},
      ),
    );

    await provider.load('user-1');

    expect(provider.isPersonalMode, isTrue);
    expect(provider.hasGroups, isFalse);
    expect(provider.selectedGroup, isNull);
    expect(provider.selectedGroupRole, isNull);
  });

  test('prefers leader groups when there is no saved selection', () async {
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-member',
            name: 'Member Group',
            createdBy: 'leader-2',
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
          _group(
            id: 'group-leader',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-member': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-member',
              userId: 'user-1',
              role: 'member',
            ),
          ],
          'group-leader': <GroupMemberModel>[
            _member(
              id: 'leader-1',
              groupId: 'group-leader',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );

    await provider.load('user-1');

    expect(provider.selectedGroup?.id, 'group-leader');
    expect(provider.selectedGroupRole, 'leader');
    expect(provider.isLeaderOfSelectedGroup, isTrue);
  });

  test('falls back to member groups when no leader group exists', () async {
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-member',
            name: 'Member Group',
            createdBy: 'leader-2',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-member': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-member',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );

    await provider.load('user-1');

    expect(provider.selectedGroup?.id, 'group-member');
    expect(provider.selectedGroupRole, 'member');
    expect(provider.isLeaderOfSelectedGroup, isFalse);
  });

  test('restores the last selected group before fallback rules', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'planflow:group_context:selected_group_id:v1:user-1': 'group-member',
    });

    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-member',
            name: 'Member Group',
            createdBy: 'leader-2',
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
          _group(
            id: 'group-leader',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-member': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-member',
              userId: 'user-1',
              role: 'member',
            ),
          ],
          'group-leader': <GroupMemberModel>[
            _member(
              id: 'leader-1',
              groupId: 'group-leader',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );

    await provider.load('user-1');

    expect(provider.selectedGroup?.id, 'group-member');
    expect(provider.selectedGroupRole, 'member');
  });

  test('preferred group from navigation overrides stored selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'planflow:group_context:selected_group_id:v1:user-1': 'group-leader',
    });

    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-member',
            name: 'Member Group',
            createdBy: 'leader-2',
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
          _group(
            id: 'group-leader',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-member': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-member',
              userId: 'user-1',
              role: 'member',
            ),
          ],
          'group-leader': <GroupMemberModel>[
            _member(
              id: 'leader-1',
              groupId: 'group-leader',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );

    await provider.load('user-1', preferredGroupId: 'group-member');

    expect(provider.selectedGroup?.id, 'group-member');
    expect(provider.selectedGroupRole, 'member');

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(
        'planflow:group_context:selected_group_id:v1:user-1',
      ),
      'group-member',
    );
  });

  test('invalid preferred group falls back to the stored selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'planflow:group_context:selected_group_id:v1:user-1': 'group-leader',
    });

    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-member',
            name: 'Member Group',
            createdBy: 'leader-2',
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
          _group(
            id: 'group-leader',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-member': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-member',
              userId: 'user-1',
              role: 'member',
            ),
          ],
          'group-leader': <GroupMemberModel>[
            _member(
              id: 'leader-1',
              groupId: 'group-leader',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );

    await provider.load('user-1', preferredGroupId: 'missing-group');

    expect(provider.selectedGroup?.id, 'group-leader');
    expect(provider.selectedGroupRole, 'leader');
  });

  test('can switch selected group and clear back to personal mode', () async {
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'leader-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
        },
      ),
    );

    await provider.load('user-1');
    await provider.selectGroup('group-1');

    expect(provider.selectedGroup?.id, 'group-1');
    expect(provider.selectedGroupRole, 'leader');
    expect(provider.isPersonalMode, isFalse);

    await provider.clearSelectedGroup();

    expect(provider.selectedGroup, isNull);
    expect(provider.selectedGroupRole, isNull);
    expect(provider.isPersonalMode, isTrue);
  });

  test('records error state when repository load fails', () async {
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: const <GroupModel>[],
        membersByGroupId: const <String, List<GroupMemberModel>>{},
        throwOnListGroups: true,
      ),
    );

    await provider.load('user-1');

    expect(provider.error, contains('group load failed'));
    expect(provider.isLoading, isFalse);
    expect(provider.selectedGroup, isNull);
    expect(provider.hasGroups, isFalse);
  });
}
