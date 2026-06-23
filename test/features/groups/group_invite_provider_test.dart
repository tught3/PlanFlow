import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/features/groups/models/group_invite_model.dart';
import 'package:planflow/features/groups/providers/group_invite_provider.dart';
import 'package:planflow/features/groups/repositories/group_invite_repository.dart';

class FakeGroupInviteRepository extends GroupInviteRepository {
  FakeGroupInviteRepository({
    List<GroupInviteModel>? initialInvites,
  }) : pendingInvites = List<GroupInviteModel>.from(initialInvites ?? const []);

  final List<GroupInviteModel> pendingInvites;
  String? lastInviteCode;
  String? lastInviteEmail;
  String? lastAcceptedInviteId;
  String? lastRejectedInviteId;
  String? lastCancelledInviteId;

  @override
  Future<GroupInviteModel> acceptInvite(String inviteId) async {
    lastAcceptedInviteId = inviteId;
    final invite = pendingInvites.firstWhere((item) => item.id == inviteId);
    pendingInvites.removeWhere((item) => item.id == inviteId);
    return GroupInviteModel(
      id: invite.id,
      groupId: invite.groupId,
      invitedBy: invite.invitedBy,
      status: 'accepted',
      expiresAt: invite.expiresAt,
      invitedUserId: invite.invitedUserId,
      invitedEmail: invite.invitedEmail,
      invitedInviteCode: invite.invitedInviteCode,
      acceptedAt: DateTime.utc(2026, 6, 11, 9),
      actedBy: 'user-1',
    );
  }

  @override
  Future<GroupInviteModel> cancelInvite(String inviteId) async {
    lastCancelledInviteId = inviteId;
    final invite = pendingInvites.firstWhere((item) => item.id == inviteId);
    pendingInvites.removeWhere((item) => item.id == inviteId);
    return GroupInviteModel(
      id: invite.id,
      groupId: invite.groupId,
      invitedBy: invite.invitedBy,
      status: 'cancelled',
      expiresAt: invite.expiresAt,
      invitedUserId: invite.invitedUserId,
      invitedEmail: invite.invitedEmail,
      invitedInviteCode: invite.invitedInviteCode,
      cancelledAt: DateTime.utc(2026, 6, 11, 9),
      actedBy: 'user-1',
    );
  }

  @override
  Future<GroupInviteModel> createInviteByEmail({
    required String groupId,
    required String email,
  }) async {
    lastInviteEmail = email;
    final invite = GroupInviteModel(
      id: 'invite-email',
      groupId: groupId,
      invitedBy: 'user-1',
      invitedEmail: email,
      status: 'pending',
      expiresAt: DateTime.utc(2026, 6, 18, 9),
    );
    pendingInvites.add(invite);
    return invite;
  }

  @override
  Future<GroupInviteModel> createInviteByInviteCode({
    required String groupId,
    required String inviteCode,
  }) async {
    lastInviteCode = inviteCode;
    final invite = GroupInviteModel(
      id: 'invite-code',
      groupId: groupId,
      invitedBy: 'user-1',
      invitedInviteCode: inviteCode,
      status: 'pending',
      expiresAt: DateTime.utc(2026, 6, 18, 9),
    );
    pendingInvites.add(invite);
    return invite;
  }

  @override
  Future<List<GroupInviteModel>> getPendingInvitesForMe() async {
    return List<GroupInviteModel>.from(pendingInvites);
  }

  @override
  Future<GroupInviteModel> rejectInvite(String inviteId) async {
    lastRejectedInviteId = inviteId;
    final invite = pendingInvites.firstWhere((item) => item.id == inviteId);
    pendingInvites.removeWhere((item) => item.id == inviteId);
    return GroupInviteModel(
      id: invite.id,
      groupId: invite.groupId,
      invitedBy: invite.invitedBy,
      status: 'rejected',
      expiresAt: invite.expiresAt,
      invitedUserId: invite.invitedUserId,
      invitedEmail: invite.invitedEmail,
      invitedInviteCode: invite.invitedInviteCode,
      rejectedAt: DateTime.utc(2026, 6, 11, 9),
      actedBy: 'user-1',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads current invite code and pending invites', () async {
    final repo = FakeGroupInviteRepository(
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
    );
    final provider = GroupInviteProvider(
      repository: repo,
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await provider.load('user-1');

    expect(provider.currentInviteCode, 'INVITE-0001');
    expect(provider.pendingInvites, hasLength(1));
    expect(provider.hasInviteCode, isTrue);
  });

  test('acceptInvite uses repository and refreshes pending invites', () async {
    final repo = FakeGroupInviteRepository(
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
    );
    final provider = GroupInviteProvider(
      repository: repo,
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await provider.load('user-1');
    await provider.acceptInvite('invite-1');

    expect(repo.lastAcceptedInviteId, 'invite-1');
    expect(provider.pendingInvites, isEmpty);
    expect(provider.message, '초대를 수락했어요.');
  });

  test('createInviteByEmail stores the invite through repository', () async {
    final repo = FakeGroupInviteRepository();
    final provider = GroupInviteProvider(
      repository: repo,
      profileLoader: (userId) async => <String, dynamic>{
        'id': userId,
        'invite_code': 'INVITE-0001',
      },
    );

    await provider.load('user-1');
    await provider.createInviteByEmail(
      groupId: 'group-1',
      email: 'member@example.com',
    );

    expect(repo.lastInviteEmail, 'member@example.com');
    expect(provider.message, '이메일 초대를 보냈어요.');
  });
}
