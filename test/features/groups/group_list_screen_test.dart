import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_invite_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_invite_provider.dart';
import 'package:planflow/features/groups/repositories/group_invite_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_list_screen.dart';

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

class FakeGroupInviteRepository extends GroupInviteRepository {
  @override
  Future<GroupInviteModel> acceptInvite(String inviteId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupInviteModel> cancelInvite(String inviteId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupInviteModel> createInviteByEmail({
    required String groupId,
    required String email,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GroupInviteModel> createInviteByInviteCode({
    required String groupId,
    required String inviteCode,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<GroupInviteModel>> getPendingInvitesForMe() async {
    return const <GroupInviteModel>[];
  }

  @override
  Future<GroupInviteModel> rejectInvite(String inviteId) {
    throw UnimplementedError();
  }
}

GroupModel _group({
  required String id,
  required String name,
  required String createdBy,
  required DateTime createdAt,
  String? description,
  String status = 'active',
}) {
  return GroupModel(
    id: id,
    createdBy: createdBy,
    name: name,
    description: description,
    status: status,
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

  testWidgets('shows empty state when the user has no groups', (tester) async {
    final provider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: const <GroupModel>[],
        membersByGroupId: const <String, List<GroupMemberModel>>{},
      ),
    );
    final inviteProvider = GroupInviteProvider(
      repository: FakeGroupInviteRepository(),
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('group-list-create-button')),
      200,
    );
    await tester.pumpAndSettle();

    expect(find.text('아직 속한 그룹이 없어요'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('group-list-create-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-list-dashboard-button')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('group-list-events-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-list-members-button')),
        findsOneWidget);
  });

  testWidgets('highlights the selected leader group and changes selection',
      (tester) async {
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
    final inviteProvider = GroupInviteProvider(
      repository: FakeGroupInviteRepository(),
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('group-list-item-group-leader')),
      300,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('group-list-item-group-leader')),
        matching: find.text('선택됨'),
      ),
      findsOneWidget,
    );

    await tester
        .tap(find.byKey(const ValueKey('group-list-item-group-member')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('group-list-item-group-member')),
        matching: find.text('선택됨'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('group-list-item-group-leader')),
        matching: find.text('선택됨'),
      ),
      findsNothing,
    );
  });
}
