import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_invite_model.dart';
import 'package:planflow/features/groups/models/group_member_model.dart';
import 'package:planflow/features/groups/models/group_model.dart';
import 'package:planflow/features/groups/providers/group_context_provider.dart';
import 'package:planflow/features/groups/providers/group_invite_provider.dart';
import 'package:planflow/features/groups/repositories/group_invite_repository.dart';
import 'package:planflow/features/groups/repositories/group_repository.dart';
import 'package:planflow/features/groups/screens/group_invite_screen.dart';

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
  FakeGroupInviteRepository({
    List<GroupInviteModel>? initialInvites,
  }) : pendingInvites = List<GroupInviteModel>.from(initialInvites ?? const []);

  final List<GroupInviteModel> pendingInvites;

  @override
  Future<GroupInviteModel> acceptInvite(String inviteId) async {
    final invite = pendingInvites.firstWhere((item) => item.id == inviteId);
    pendingInvites.removeWhere((item) => item.id == inviteId);
    return GroupInviteModel(
      id: invite.id,
      groupId: invite.groupId,
      invitedBy: invite.invitedBy,
      status: 'accepted',
      expiresAt: invite.expiresAt,
      invitedEmail: invite.invitedEmail,
      invitedInviteCode: invite.invitedInviteCode,
      actedBy: 'user-1',
      acceptedAt: DateTime.utc(2026, 6, 11, 9),
    );
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
    return List<GroupInviteModel>.from(pendingInvites);
  }

  @override
  Future<GroupInviteModel> rejectInvite(String inviteId) async {
    final invite = pendingInvites.firstWhere((item) => item.id == inviteId);
    pendingInvites.removeWhere((item) => item.id == inviteId);
    return GroupInviteModel(
      id: invite.id,
      groupId: invite.groupId,
      invitedBy: invite.invitedBy,
      status: 'rejected',
      expiresAt: invite.expiresAt,
      invitedEmail: invite.invitedEmail,
      invitedInviteCode: invite.invitedInviteCode,
      actedBy: 'user-1',
      rejectedAt: DateTime.utc(2026, 6, 11, 9),
    );
  }
}

GroupModel _group({
  required String id,
  required String name,
  required String createdBy,
  required DateTime createdAt,
  String? inviteToken,
}) {
  return GroupModel(
    id: id,
    createdBy: createdBy,
    name: name,
    inviteToken: inviteToken,
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

  testWidgets('shows invite code card and leader invitation form',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Leader Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
            inviteToken: 'token-123',
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
    final inviteProvider = GroupInviteProvider(
      repository: FakeGroupInviteRepository(),
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupInviteScreen(
          contextProvider: contextProvider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('내 초대 코드'), findsOneWidget);
    expect(find.text('INVITE-0001'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('group-invite-code-field'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('group-invite-email-field'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-invite-link-copy-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-invite-link-qr-code')),
      findsOneWidget,
    );
    expect(find.text('카메라로 QR을 스캔해도 참여할 수 있어요.'), findsOneWidget);
    expect(find.text('코드로 초대', skipOffstage: false), findsOneWidget);
    expect(find.text('이메일 초대', skipOffstage: false), findsOneWidget);
  });

  testWidgets('hides invitation form when the selected group is a member group',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Member Group',
            createdBy: 'leader-2',
            createdAt: DateTime.utc(2026, 6, 11),
          ),
        ],
        membersByGroupId: <String, List<GroupMemberModel>>{
          'group-1': <GroupMemberModel>[
            _member(
              id: 'member-1',
              groupId: 'group-1',
              userId: 'user-1',
              role: 'member',
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
        home: GroupInviteScreen(
          contextProvider: contextProvider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('현재 그룹의 리더만 초대를 보낼 수 있어요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-invite-code-field')), findsNothing);
    expect(
        find.byKey(const ValueKey('group-invite-email-field')), findsNothing);
  });

  testWidgets('shows pending invite accept and reject buttons', (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: const <GroupModel>[],
        membersByGroupId: const <String, List<GroupMemberModel>>{},
      ),
    );
    final inviteProvider = GroupInviteProvider(
      repository: FakeGroupInviteRepository(
        initialInvites: <GroupInviteModel>[
          GroupInviteModel(
            id: 'invite-1',
            groupId: 'group-1',
            invitedBy: 'leader-1',
            invitedEmail: 'member@example.com',
            status: 'pending',
            expiresAt: DateTime.utc(2026, 6, 18, 9),
          ),
        ],
      ),
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupInviteScreen(
          contextProvider: contextProvider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('invite-accept-invite-1')),
      120,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
        find.byKey(const ValueKey('invite-accept-invite-1')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('invite-reject-invite-1')), findsOneWidget);
  });

  testWidgets('shows group switcher with multiple chips when user leads multiple groups',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'First Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
            inviteToken: 'token-1',
          ),
          _group(
            id: 'group-2',
            name: 'Second Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 12),
            inviteToken: 'token-2',
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
          'group-2': <GroupMemberModel>[
            _member(
              id: 'member-2',
              groupId: 'group-2',
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
        home: GroupInviteScreen(
          contextProvider: contextProvider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Should see "그룹 선택" label
    expect(find.text('그룹 선택'), findsOneWidget);

    // Should see both group chips
    expect(
      find.byKey(const ValueKey('group-switcher-group-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-switcher-group-2')),
      findsOneWidget,
    );

    // First group should be initially selected (default behavior)
    expect(find.text('First Group'), findsWidgets);
    expect(find.text('Second Group'), findsWidgets);

    // Verify the switcher exists with correct structure
    expect(find.text('현재 그룹'), findsOneWidget);
    final selectedGroupCardFinder = find.byType(Card);
    final cards = selectedGroupCardFinder.evaluate();
    expect(cards.isNotEmpty, true);
  });

  testWidgets('switches group when tapping different group chip',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'First Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
            inviteToken: 'token-1',
          ),
          _group(
            id: 'group-2',
            name: 'Second Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 12),
            inviteToken: 'token-2',
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
          'group-2': <GroupMemberModel>[
            _member(
              id: 'member-2',
              groupId: 'group-2',
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

    // 초대 링크 복사 버튼이 ListView 하단에 있어 기본 테스트 뷰포트(600 높이)에서는
    // 스크롤 없이 안 보인다. 스크롤 제스처 대신 뷰포트를 넉넉히 키워
    // 모든 카드가 한 화면에 들어오게 해 스크롤 관련 테스트 취약성을 없앤다.
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: GroupInviteScreen(
          contextProvider: contextProvider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 클립보드에 실제로 복사되는 텍스트를 가로채, 이름 텍스트뿐 아니라
    // 초대 링크/토큰 자체가 그룹 전환에 따라 바뀌는지 검증한다.
    final copiedTexts = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          copiedTexts.add(args['text'] as String? ?? '');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    // Initially First Group should be shown in the selected group card
    expect(find.text('First Group'), findsWidgets);

    // 전환 전: 초대 링크 복사 결과가 First Group의 토큰(token-1)을 담고 있어야 한다.
    final copyButtonFinder =
        find.byKey(const ValueKey('group-invite-link-copy-button'));
    await tester.tap(copyButtonFinder);
    await tester.pumpAndSettle();
    expect(copiedTexts, isNotEmpty);
    expect(copiedTexts.last, contains('token-1'));
    expect(copiedTexts.last, isNot(contains('token-2')));

    // Tap the Second Group chip
    final secondGroupChipFinder =
        find.byKey(const ValueKey('group-switcher-group-2'));
    await tester.tap(secondGroupChipFinder);
    await tester.pumpAndSettle();

    // After tap, the selected group should change to Second Group
    // The selected group card should now show Second Group
    expect(
      find.descendant(
        of: find.byType(Card),
        matching: find.text('Second Group'),
      ),
      findsOneWidget,
    );

    // The invite link/form should now reflect the Second Group's token
    expect(find.text('초대 링크'), findsOneWidget);

    // 전환 후(핵심 회귀 방지): 초대 링크 복사 결과가 이름만 바뀐 게 아니라
    // 실제로 Second Group의 토큰(token-2)을 담고 있어야 한다.
    await tester.tap(copyButtonFinder);
    await tester.pumpAndSettle();
    expect(copiedTexts.last, contains('token-2'));
    expect(copiedTexts.last, isNot(contains('token-1')));
  });

  testWidgets('does not show group switcher when user has only one group',
      (tester) async {
    final contextProvider = GroupContextProvider(
      repository: FakeGroupRepository(
        groups: <GroupModel>[
          _group(
            id: 'group-1',
            name: 'Only Group',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 6, 11),
            inviteToken: 'token-1',
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
    final inviteProvider = GroupInviteProvider(
      repository: FakeGroupInviteRepository(),
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: GroupInviteScreen(
          contextProvider: contextProvider,
          inviteProvider: inviteProvider,
          currentUserIdOverride: 'user-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Should not see "그룹 선택" label
    expect(find.text('그룹 선택'), findsNothing);

    // Should not see any group switcher chips
    expect(find.byKey(const ValueKey('group-switcher-group-1')), findsNothing);
  });
}
