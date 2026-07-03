import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_member_model.dart';
import '../models/group_model.dart';

abstract class GroupRepository {
  const GroupRepository();

  factory GroupRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupRepository;

  Future<List<GroupModel>> listGroups();

  Future<GroupModel?> fetchGroup(String groupId);

  Future<GroupModel> createGroup(GroupModel group);

  Future<GroupModel> updateGroup(GroupModel group);

  Future<List<GroupMemberModel>> listMembers(String groupId);

  Future<GroupMemberModel> addMember(GroupMemberModel member);

  Future<GroupMemberModel> updateMember(GroupMemberModel member);

  Future<GroupMemberModel> updateMemberDisplayName(
    String memberId,
    String? displayName,
  ) async {
    throw UnimplementedError();
  }

  Future<GroupMemberModel> removeGroupMember(
    String groupId,
    String userId,
  ) async {
    throw UnimplementedError();
  }

  Future<void> deleteGroup(String groupId) async {
    throw UnimplementedError();
  }
}

class SupabaseGroupRepository extends GroupRepository {
  static const _memberUserSelect =
      '*, users!group_members_user_id_fkey(display_name,name,email,invite_code)';

  SupabaseGroupRepository({
    SupabaseClient? client,
    String? Function()? currentUserIdProvider,
    Future<void> Function(String groupId, String userId)? ensureLeaderOfGroup,
    Future<Map<String, dynamic>> Function(
      String groupId,
      String userId,
    )? removeGroupMemberRpc,
  })  : _client = client ?? Supabase.instance.client,
        _currentUserIdProvider = currentUserIdProvider,
        _ensureLeaderOfGroupOverride = ensureLeaderOfGroup,
        _removeGroupMemberRpc = removeGroupMemberRpc;

  final SupabaseClient _client;
  final String? Function()? _currentUserIdProvider;
  final Future<void> Function(String groupId, String userId)?
      _ensureLeaderOfGroupOverride;
  final Future<Map<String, dynamic>> Function(
    String groupId,
    String userId,
  )? _removeGroupMemberRpc;

  @override
  Future<List<GroupModel>> listGroups() async {
    final response = await _client
        .from('groups')
        .select()
        .order('created_at', ascending: false);
    return response
        .map<GroupModel>((row) => GroupModel.fromJson(_rowAsJson(row)))
        .toList(growable: false);
  }

  @override
  Future<GroupModel?> fetchGroup(String groupId) async {
    final response =
        await _client.from('groups').select().eq('id', groupId).maybeSingle();
    if (response == null) {
      return null;
    }
    return GroupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupModel> createGroup(GroupModel group) async {
    // INSERT...RETURNING은 PostgreSQL READ COMMITTED 스냅샷 특성상 같은 statement 내
    // AFTER 트리거(handle_new_group → group_members INSERT)가 보이지 않아
    // is_group_member → FALSE → SELECT 정책 42501이 발생한다.
    // security definer RPC로 우회하면 트리거는 정상 작동하고 RLS 스냅샷 문제를 피할 수 있다.
    final response = await _client.rpc('create_group_for_user', params: {
      'p_name': group.name,
      'p_description': group.description,
      'p_created_by': group.createdBy,
      'p_status': group.status,
    });
    return GroupModel.fromJson(Map<String, dynamic>.from(response as Map));
  }

  @override
  Future<GroupModel> updateGroup(GroupModel group) async {
    final response = await _client
        .from('groups')
        .update(group.toUpdateJson())
        .eq('id', group.id)
        .select()
        .single();
    return GroupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<List<GroupMemberModel>> listMembers(String groupId) async {
    final response = await _client
        .from('group_members')
        .select(_memberUserSelect)
        .eq('group_id', groupId)
        .order('created_at', ascending: true);
    return response
        .map<GroupMemberModel>(
          (row) => GroupMemberModel.fromJson(_rowAsJson(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupMemberModel> addMember(GroupMemberModel member) async {
    final response = await _client
        .from('group_members')
        .insert(member.toJson(includeId: member.id.trim().isNotEmpty))
        .select()
        .single();
    return GroupMemberModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupMemberModel> updateMember(GroupMemberModel member) async {
    final response = await _client
        .from('group_members')
        .update(member.toUpdateJson())
        .eq('id', member.id)
        .select()
        .single();
    return GroupMemberModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupMemberModel> updateMemberDisplayName(
    String memberId,
    String? displayName,
  ) async {
    final trimmed = displayName?.trim();
    final response = await _client
        .from('group_members')
        .update(<String, dynamic>{
          'display_name': trimmed == null || trimmed.isEmpty ? null : trimmed,
        })
        .eq('id', memberId)
        .select(_memberUserSelect)
        .single();
    return GroupMemberModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupMemberModel> removeGroupMember(
    String groupId,
    String userId,
  ) async {
    final currentUserId = _requireCurrentUserId();
    await (_ensureLeaderOfGroupOverride ?? _ensureLeaderOfGroup)(
      groupId,
      currentUserId,
    );
    final response = await (_removeGroupMemberRpc ?? _removeGroupMemberWithRpc)(
      groupId,
      userId,
    );
    return GroupMemberModel.fromJson(response);
  }

  String _requireCurrentUserId() {
    final currentUserId =
        _currentUserIdProvider?.call() ?? _client.auth.currentUser?.id;
    if (currentUserId == null || currentUserId.trim().isEmpty) {
      throw StateError('로그인이 필요합니다.');
    }
    return currentUserId;
  }

  Future<Map<String, dynamic>> _removeGroupMemberWithRpc(
    String groupId,
    String userId,
  ) async {
    final response = await _client
        .rpc('remove_group_member', params: <String, dynamic>{
          'group_id_input': groupId,
          'member_user_id_input': userId,
        })
        .select()
        .single();
    return _rowAsJson(response);
  }

  Future<void> _ensureLeaderOfGroup(String groupId, String userId) async {
    final response = await _client
        .from('group_members')
        .select('id')
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .eq('role', 'leader')
        .eq('status', 'active')
        .maybeSingle();
    if (response == null) {
      throw StateError('팀 리더만 멤버를 제거할 수 있습니다.');
    }
  }

  @override
  Future<void> deleteGroup(String groupId) async {
    await _client.rpc(
      'delete_group_for_user',
      params: {'p_group_id': groupId},
    );
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}
