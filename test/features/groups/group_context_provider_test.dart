import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/services/group_membership_refresh_bus.dart';

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

  @override
  Future<void> deleteGroup(String groupId) {
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

  test('preferred group id overrides saved and leader fallback selection',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'planflow:group_context:selected_group_id:v1:user-1': 'group-saved',
    });

    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-saved',
            name: 'Saved Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
          _group(
            id: 'group-route',
            name: 'Route Group',
            createdBy: 'leader-2',
            createdAt: DateTime.utc(2026, 6, 11, 2),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-saved': <GroupMemberModel>[
            _member(
              id: 'leader-1',
              groupId: 'group-saved',
              userId: 'user-1',
              role: 'leader',
            ),
          ],
          'group-route': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-route',
              userId: 'user-1',
              role: 'member',
            ),
          ],
        },
      ),
    );

    await provider.load('user-1', preferredGroupId: 'group-route');

    expect(provider.selectedGroup?.id, 'group-route');
    expect(provider.selectedGroupRole, 'member');
  });

  test('invalid preferred group id falls back without throwing', () async {
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-leader',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11, 1),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
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

    expect(provider.error, isNull);
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

  test('refresh drops deleted group and selects a remaining group', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final remaining = _group(
      id: 'group-2',
      name: 'Remaining',
      createdBy: 'user-1',
      createdAt: DateTime.utc(2026, 6, 12),
    );
    final mutableGroups = <GroupModel>[
      _group(
        id: 'group-1',
        name: 'Deleted',
        createdBy: 'user-1',
        createdAt: DateTime.utc(2026, 6, 11),
      ),
      remaining,
    ];
    final repository = FakeGroupRepository(
      groups: mutableGroups,
      membersByGroupId: <String, List<GroupMemberModel>>{
        'group-1': <GroupMemberModel>[
          _member(id: 'm1', groupId: 'group-1', userId: 'user-1', role: 'leader'),
        ],
        'group-2': <GroupMemberModel>[
          _member(id: 'm2', groupId: 'group-2', userId: 'user-1', role: 'member'),
        ],
      },
    );
    final provider = GroupContextProvider(repository: repository);
    await provider.load('user-1', preferredGroupId: 'group-1');
    mutableGroups.removeWhere((group) => group.id == 'group-1');
    await provider.refresh();
    expect(provider.groups.map((group) => group.id), <String>['group-2']);
    expect(provider.selectedGroup?.id, 'group-2');
    provider.dispose();
  });

  test('real membership bus refreshes real provider after deletion', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final mutableGroups = <GroupModel>[
      _group(
        id: 'gone',
        name: 'Gone',
        createdBy: 'user-1',
        createdAt: DateTime.utc(2026, 6, 11),
      ),
    ];
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: mutableGroups,
        membersByGroupId: <String, List<GroupMemberModel>>{
          'gone': <GroupMemberModel>[
            _member(id: 'm1', groupId: 'gone', userId: 'user-1', role: 'leader'),
          ],
        },
      ),
    );
    await provider.load('user-1');
    var notifications = 0;
    void listener() {
      notifications++;
      provider.refresh();
    }
    GroupMembershipRefreshBus.instance.addListener(listener);
    mutableGroups.clear();
    GroupMembershipRefreshBus.instance.notifyChanged();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(provider.groups, isEmpty);
    expect(provider.selectedGroup, isNull);
    GroupMembershipRefreshBus.instance.removeListener(listener);
    provider.dispose();
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

  test('keepGroupsOnError keeps loaded groups and selection when reload fails',
      () async {
    final group = _group(
      id: 'group-1',
      name: 'Team',
      createdBy: 'user-1',
      createdAt: DateTime.utc(2026, 6, 11),
    );
    final repository = _TogglableGroupRepository(
      groups: <GroupModel>[group],
      membersByGroupId: <String, List<GroupMemberModel>>{
        'group-1': <GroupMemberModel>[
          _member(id: 'm1', groupId: 'group-1', userId: 'user-1', role: 'leader'),
        ],
      },
    );
    final provider = GroupContextProvider(repository: repository);
    await provider.load('user-1');
    expect(provider.selectedGroup?.id, 'group-1');

    repository.fail = true;
    await provider.load(
      'user-1',
      preferredGroupId: provider.selectedGroup?.id,
      keepGroupsOnError: true,
    );
    expect(provider.groups.map((g) => g.id), <String>['group-1']);
    expect(provider.selectedGroup?.id, 'group-1');
    expect(provider.error, contains('group load failed'));
    expect(provider.isLoading, isFalse);

    await provider.load('user-1');
    expect(provider.groups, isEmpty,
        reason: '기본 동작(keepGroupsOnError=false)은 기존처럼 실패 시 비운다.');
    provider.dispose();
  });
}

class _TogglableGroupRepository extends FakeGroupRepository {
  _TogglableGroupRepository({
    required super.groups,
    required super.membersByGroupId,
  });

  bool fail = false;

  @override
  Future<List<GroupModel>> listGroups() async {
    if (fail) {
      throw StateError('group load failed');
    }
    return groups;
  }
}
