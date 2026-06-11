import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_json.dart';
import '../models/group_invite_model.dart';

abstract class GroupInviteRepository {
  const GroupInviteRepository();

  factory GroupInviteRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupInviteRepository;

  Future<GroupInviteModel> createInviteByInviteCode({
    required String groupId,
    required String inviteCode,
  });

  Future<GroupInviteModel> createInviteByEmail({
    required String groupId,
    required String email,
  });

  Future<List<GroupInviteModel>> getPendingInvitesForMe();

  Future<GroupInviteModel> acceptInvite(String inviteId);

  Future<GroupInviteModel> rejectInvite(String inviteId);

  Future<GroupInviteModel> cancelInvite(String inviteId);
}

class SupabaseGroupInviteRepository extends GroupInviteRepository {
  SupabaseGroupInviteRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<GroupInviteModel> createInviteByInviteCode({
    required String groupId,
    required String inviteCode,
  }) async {
    final normalizedInviteCode = inviteCode.trim().toLowerCase();
    final currentUser = _requireCurrentUser();
    await _ensureLeaderOfGroup(groupId, currentUser.id);
    final targetUser = await _fetchUserByInviteCode(normalizedInviteCode);
    if (targetUser == null) {
      throw StateError('초대 코드를 찾을 수 없습니다.');
    }
    await _ensureUserIsNotActiveMember(groupId, targetUser['id'] as String);
    final response = await _client
        .from('group_invites')
        .insert(
          <String, dynamic>{
            'group_id': groupId,
            'invited_user_id': targetUser['id'],
            'invited_email': targetUser['email'],
            'invited_invite_code': normalizedInviteCode,
            'invited_by': currentUser.id,
            'status': 'pending',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(days: 7))
                .toIso8601String(),
          },
        )
        .select()
        .single();
    return GroupInviteModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupInviteModel> createInviteByEmail({
    required String groupId,
    required String email,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final currentUser = _requireCurrentUser();
    await _ensureLeaderOfGroup(groupId, currentUser.id);
    final targetUser = await _fetchUserByEmail(normalizedEmail);
    if (targetUser != null) {
      await _ensureUserIsNotActiveMember(groupId, targetUser['id'] as String);
    }
    final response = await _client
        .from('group_invites')
        .insert(
          <String, dynamic>{
            'group_id': groupId,
            'invited_user_id': targetUser?['id'],
            'invited_email': normalizedEmail,
            'invited_invite_code': targetUser?['invite_code'],
            'invited_by': currentUser.id,
            'status': 'pending',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(days: 7))
                .toIso8601String(),
          },
        )
        .select()
        .single();
    return GroupInviteModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<List<GroupInviteModel>> getPendingInvitesForMe() async {
    final currentUser = _requireCurrentUser();
    final profile = await _fetchCurrentUserProfile();

    final rows = <Map<String, dynamic>>[];
    rows.addAll(
      await _fetchPendingInvitesByColumn('invited_user_id', currentUser.id),
    );
    if (profile['email'] != null &&
        profile['email'].toString().trim().isNotEmpty) {
      rows.addAll(
        await _fetchPendingInvitesByColumn(
          'invited_email',
          profile['email'].toString().trim().toLowerCase(),
        ),
      );
    }
    if (profile['invite_code'] != null &&
        profile['invite_code'].toString().trim().isNotEmpty) {
      rows.addAll(
        await _fetchPendingInvitesByColumn(
          'invited_invite_code',
          profile['invite_code'].toString().trim().toLowerCase(),
        ),
      );
    }

    final uniqueRows = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      uniqueRows[row['id'].toString()] = row;
    }
    return uniqueRows.values
        .map<GroupInviteModel>(
          (row) => GroupInviteModel.fromJson(_rowAsJson(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupInviteModel> acceptInvite(String inviteId) async {
    final currentUser = _requireCurrentUser();
    final profile = await _fetchCurrentUserProfile();
    final invite = await _fetchInvite(inviteId);
    _ensureTargetMatchesCurrentUser(invite, currentUser.id, profile);
    await _ensureUserIsNotActiveMember(invite.groupId, currentUser.id);

    final updated = await _client
        .from('group_invites')
        .update(
          <String, dynamic>{
            'status': 'accepted',
            'accepted_at': DateTime.now().toUtc().toIso8601String(),
            'acted_by': currentUser.id,
          },
        )
        .eq('id', inviteId)
        .select()
        .single();

    await _client.from('group_members').insert(
      <String, dynamic>{
        'group_id': invite.groupId,
        'user_id': currentUser.id,
        'role': 'member',
        'status': 'active',
        'joined_at': DateTime.now().toUtc().toIso8601String(),
      },
    );

    return GroupInviteModel.fromJson(_rowAsJson(updated));
  }

  @override
  Future<GroupInviteModel> rejectInvite(String inviteId) async {
    final currentUser = _requireCurrentUser();
    final profile = await _fetchCurrentUserProfile();
    final invite = await _fetchInvite(inviteId);
    _ensureTargetMatchesCurrentUser(invite, currentUser.id, profile);
    final updated = await _client
        .from('group_invites')
        .update(
          <String, dynamic>{
            'status': 'rejected',
            'rejected_at': DateTime.now().toUtc().toIso8601String(),
            'acted_by': currentUser.id,
          },
        )
        .eq('id', inviteId)
        .select()
        .single();
    return GroupInviteModel.fromJson(_rowAsJson(updated));
  }

  @override
  Future<GroupInviteModel> cancelInvite(String inviteId) async {
    final currentUser = _requireCurrentUser();
    final invite = await _fetchInvite(inviteId);
    await _ensureLeaderOfGroup(invite.groupId, currentUser.id);
    final updated = await _client
        .from('group_invites')
        .update(
          <String, dynamic>{
            'status': 'cancelled',
            'cancelled_at': DateTime.now().toUtc().toIso8601String(),
            'acted_by': currentUser.id,
          },
        )
        .eq('id', inviteId)
        .select()
        .single();
    return GroupInviteModel.fromJson(_rowAsJson(updated));
  }

  User _requireCurrentUser() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    return user;
  }

  Future<Map<String, dynamic>> _fetchCurrentUserProfile() async {
    final currentUser = _requireCurrentUser();
    final response = await _client
        .from('users')
        .select('id,email,invite_code')
        .eq('id', currentUser.id)
        .single();
    return _rowAsJson(response);
  }

  Future<Map<String, dynamic>?> _fetchUserByInviteCode(
      String inviteCode) async {
    final response = await _client
        .from('users')
        .select('id,email,invite_code')
        .eq('invite_code', inviteCode)
        .maybeSingle();
    if (response == null) {
      return null;
    }
    return _rowAsJson(response);
  }

  Future<Map<String, dynamic>?> _fetchUserByEmail(String email) async {
    final response = await _client
        .from('users')
        .select('id,email,invite_code')
        .eq('email', email)
        .maybeSingle();
    if (response == null) {
      return null;
    }
    return _rowAsJson(response);
  }

  Future<void> _ensureUserIsNotActiveMember(
    String groupId,
    String userId,
  ) async {
    final response = await _client
        .from('group_members')
        .select('id')
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .eq('status', 'active')
        .maybeSingle();
    if (response != null) {
      throw StateError('이미 활성 멤버인 사용자는 초대할 수 없습니다.');
    }
  }

  Future<void> _ensureLeaderOfGroup(String groupId, String userId) async {
    final groupResponse = await _client
        .from('groups')
        .select('id')
        .eq('id', groupId)
        .eq('status', 'active')
        .maybeSingle();
    if (groupResponse == null) {
      throw StateError('활성화된 그룹만 초대할 수 있습니다.');
    }

    final response = await _client
        .from('group_members')
        .select('id')
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .eq('role', 'leader')
        .eq('status', 'active')
        .maybeSingle();
    if (response == null) {
      throw StateError('팀 리더만 초대할 수 있습니다.');
    }
  }

  Future<GroupInviteModel> _fetchInvite(String inviteId) async {
    final response = await _client
        .from('group_invites')
        .select()
        .eq('id', inviteId)
        .single();
    return GroupInviteModel.fromJson(_rowAsJson(response));
  }

  Future<List<Map<String, dynamic>>> _fetchPendingInvitesByColumn(
    String column,
    String value,
  ) async {
    final response = await _client
        .from('group_invites')
        .select()
        .eq('status', 'pending')
        .eq(column, value);
    return response
        .map<Map<String, dynamic>>((row) => _rowAsJson(row))
        .toList(growable: false);
  }

  void _ensureTargetMatchesCurrentUser(
    GroupInviteModel invite,
    String currentUserId,
    Map<String, dynamic> profile,
  ) {
    final currentEmail = stringValue(profile['email']).trim().toLowerCase();
    final currentInviteCode =
        stringValue(profile['invite_code']).trim().toLowerCase();
    final invitedInviteCode = invite.invitedInviteCode?.trim().toLowerCase();
    final invitedEmail = invite.invitedEmail?.trim().toLowerCase();

    final matches = invite.invitedUserId == currentUserId ||
        (invitedEmail != null && invitedEmail == currentEmail) ||
        (invitedInviteCode != null && invitedInviteCode == currentInviteCode);

    if (!matches) {
      throw StateError('내 초대만 처리할 수 있습니다.');
    }
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}
