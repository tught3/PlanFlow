import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_deletion_notice_model.dart';
import 'package:planflow/features/groups/models/group_invite_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_invite_provider.dart';
import 'package:planflow/features/groups/repositories/group_invite_repository.dart';
import 'package:planflow/features/groups/repositories/group_deletion_notice_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_list_screen.dart';
import 'package:planflow/providers/auth_provider.dart';

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

  @override
  Future<void> deleteGroup(String groupId) {
    throw UnimplementedError();
  }
}

class FakeGroupInviteRepository extends GroupInviteRepository {
  @override
  Future<GroupInviteModel> acceptInvite(String inviteId) {
    throw UnimplementedError();
  }

  @override
  Future<GroupInviteModel> acceptInviteLink({
    required String groupId,
    required String inviteToken,
  }) {
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

class FakeGroupDeletionNoticeRepository extends GroupDeletionNoticeRepository {
  FakeGroupDeletionNoticeRepository({List<GroupDeletionNoticeModel>? notices})
      : _notices = List<GroupDeletionNoticeModel>.of(
          notices ?? const <GroupDeletionNoticeModel>[],
        );

  final List<GroupDeletionNoticeModel> _notices;
  final List<String> acknowledgedIds = <String>[];

  @override
  Future<List<GroupDeletionNoticeModel>> listPendingForUser(
          String userId) async =>
      List<GroupDeletionNoticeModel>.of(_notices);

  @override
  Future<void> acknowledge({
    required String noticeId,
    required String userId,
  }) async {
    acknowledgedIds.add(noticeId);
    _notices.removeWhere((notice) => notice.id == noticeId);
  }
}

class PendingGroupDeletionNoticeRepository
    extends GroupDeletionNoticeRepository {
  final Completer<void> requestStarted = Completer<void>();
  final Completer<List<GroupDeletionNoticeModel>> response =
      Completer<List<GroupDeletionNoticeModel>>();
  final List<String> queriedUserIds = <String>[];
  final List<String> acknowledgedIds = <String>[];

  @override
  Future<List<GroupDeletionNoticeModel>> listPendingForUser(
    String userId,
  ) {
    queriedUserIds.add(userId);
    if (!requestStarted.isCompleted) requestStarted.complete();
    return response.future;
  }

  @override
  Future<void> acknowledge({
    required String noticeId,
    required String userId,
  }) async {
    acknowledgedIds.add(noticeId);
  }
}

GroupDeletionNoticeModel _deletionNotice(String id, String groupName) =>
    GroupDeletionNoticeModel(
      id: id,
      deletedGroupId: 'deleted-$id',
      groupName: groupName,
      deletedAt: DateTime.utc(2026, 9, 29),
    );

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
        'display_name': '민수',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          deletionNoticeRepository: FakeGroupDeletionNoticeRepository(),
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
    expect(
      find.byKey(
        const ValueKey('group-list-display-name-edit-button'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(find.text('(민수)'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('group-list-invite-management-button'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'shows a placeholder when the display name has not been set',
    (tester) async {
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
          'display_name': null,
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupListScreen(
            provider: provider,
            inviteProvider: inviteProvider,
            deletionNoticeRepository: FakeGroupDeletionNoticeRepository(),
            currentUserIdOverride: 'user-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('(이름없음)'), findsOneWidget);
    },
  );

  testWidgets('highlights the selected leader group', (tester) async {
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
        'display_name': '민수',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          deletionNoticeRepository: FakeGroupDeletionNoticeRepository(),
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

    expect(
      find.byKey(
        const ValueKey('group-list-display-name-edit-button'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('group-list-invite-management-button'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('group-list-item-group-leader')),
        matching: find.text('선택됨'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'shows each group deletion notice once and acknowledges only on OK',
      (tester) async {
    authProvider.setUser('user-1');
    addTearDown(() => authProvider.setUser(null));
    final repository = FakeGroupDeletionNoticeRepository(
      notices: <GroupDeletionNoticeModel>[
        _deletionNotice('notice-1', '첫 번째 그룹'),
        _deletionNotice('notice-2', '두 번째 그룹'),
      ],
    );
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
        'display_name': '민수',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          deletionNoticeRepository: repository,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsOneWidget);
    final noticeDialog = tester.widget<AlertDialog>(
      find.byKey(const ValueKey('group-deletion-notice-dialog')),
    );
    expect(noticeDialog.actions, hasLength(1));
    expect(noticeDialog.actionsAlignment, MainAxisAlignment.center);
    expect(find.text('「첫 번째 그룹」 그룹의 리더가 그룹을 삭제했습니다. 그룹이 삭제되어 멤버에서 자동 탈퇴되었습니다.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('group-deletion-notice-confirm')),
        findsOneWidget);
    expect(repository.acknowledgedIds, isEmpty);

    await tester
        .tap(find.byKey(const ValueKey('group-deletion-notice-confirm')));
    await tester.pumpAndSettle();
    expect(repository.acknowledgedIds, <String>['notice-1']);
    expect(find.text('「두 번째 그룹」 그룹의 리더가 그룹을 삭제했습니다. 그룹이 삭제되어 멤버에서 자동 탈퇴되었습니다.'),
        findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('group-deletion-notice-confirm')));
    await tester.pumpAndSettle();
    expect(repository.acknowledgedIds, <String>['notice-1', 'notice-2']);
    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          deletionNoticeRepository: repository,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsNothing);
  });

  testWidgets('does not display a fetched notice after account changes',
      (tester) async {
    authProvider.setUser('account-a');
    addTearDown(() => authProvider.setUser(null));
    final repository = PendingGroupDeletionNoticeRepository();
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
        'display_name': '민수',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          deletionNoticeRepository: repository,
        ),
      ),
    );
    await repository.requestStarted.future;
    authProvider.setUser('account-b');
    repository.response.complete(<GroupDeletionNoticeModel>[
      _deletionNotice('notice-a', 'A 그룹'),
    ]);
    await tester.pumpAndSettle();

    expect(repository.queriedUserIds, <String>['account-a']);
    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsNothing);
    expect(repository.acknowledgedIds, isEmpty);
  });

  testWidgets('closes notice without acknowledgment when account changes',
      (tester) async {
    authProvider.setUser('account-a');
    addTearDown(() => authProvider.setUser(null));
    final repository = FakeGroupDeletionNoticeRepository(
      notices: <GroupDeletionNoticeModel>[
        _deletionNotice('notice-a', 'A 그룹'),
      ],
    );
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
        'display_name': '민수',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          deletionNoticeRepository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsOneWidget);

    authProvider.setUser('account-b');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsNothing);
    expect(repository.acknowledgedIds, isEmpty);
  });

  testWidgets('removes the exact hidden notice route after account changes',
      (tester) async {
    authProvider.setUser('account-a');
    addTearDown(() => authProvider.setUser(null));
    final repository = FakeGroupDeletionNoticeRepository(
      notices: <GroupDeletionNoticeModel>[
        _deletionNotice('notice-a', 'A 그룹'),
      ],
    );
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
        'display_name': '민수',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupListScreen(
          provider: provider,
          inviteProvider: inviteProvider,
          deletionNoticeRepository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsOneWidget);

    final navigator =
        Navigator.of(tester.element(find.byType(GroupListScreen)));
    unawaited(navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering route')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('covering route'), findsOneWidget);

    authProvider.setUser('account-b');
    await tester.pumpAndSettle();
    expect(find.text('covering route'), findsOneWidget);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-deletion-notice-dialog')),
        findsNothing);
    expect(repository.acknowledgedIds, isEmpty);
  });
}
