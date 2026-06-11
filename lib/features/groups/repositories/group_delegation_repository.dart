import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_role_delegation_model.dart';

abstract class GroupDelegationRepository {
  const GroupDelegationRepository();

  factory GroupDelegationRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupDelegationRepository;

  Future<GroupRoleDelegationModel> createDelegation({
    required String groupId,
    required String delegateUserId,
    required List<String> permissions,
    required DateTime startsAt,
    required DateTime endsAt,
  });

  Future<List<GroupRoleDelegationModel>> getDelegationsForGroup(
    String groupId,
  );

  Future<List<GroupRoleDelegationModel>> getDelegationsForMe();

  Future<GroupRoleDelegationModel> cancelDelegation(String delegationId);
}

class SupabaseGroupDelegationRepository extends GroupDelegationRepository {
  SupabaseGroupDelegationRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<GroupRoleDelegationModel> createDelegation({
    required String groupId,
    required String delegateUserId,
    required List<String> permissions,
    required DateTime startsAt,
    required DateTime endsAt,
  }) async {
    final currentUser = _requireCurrentUser();
    await _ensureActiveGroupAndLeader(groupId, currentUser.id);
    final normalizedPermissions = _validatePermissions(permissions);
    if (delegateUserId == currentUser.id) {
      throw StateError('자기 자신에게는 위임할 수 없습니다.');
    }
    if (!endsAt.isAfter(startsAt)) {
      throw StateError('종료 시각은 시작 시각보다 뒤여야 합니다.');
    }

    final response = await _client
        .from('group_role_delegations')
        .insert(
          <String, dynamic>{
            'group_id': groupId,
            'delegator_user_id': currentUser.id,
            'delegate_user_id': delegateUserId,
            'permissions': normalizedPermissions,
            'starts_at': startsAt.toUtc().toIso8601String(),
            'ends_at': endsAt.toUtc().toIso8601String(),
            'status': 'active',
          },
        )
        .select()
        .single();
    return GroupRoleDelegationModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<List<GroupRoleDelegationModel>> getDelegationsForGroup(
    String groupId,
  ) async {
    final response = await _client
        .from('group_role_delegations')
        .select()
        .eq('group_id', groupId)
        .order('starts_at', ascending: false);
    return response
        .map<GroupRoleDelegationModel>(
          (row) => GroupRoleDelegationModel.fromJson(_rowAsJson(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<List<GroupRoleDelegationModel>> getDelegationsForMe() async {
    final currentUser = _requireCurrentUser();
    final rows = <Map<String, dynamic>>[];
    rows.addAll(
      await _fetchDelegationsByColumn('delegator_user_id', currentUser.id),
    );
    rows.addAll(
      await _fetchDelegationsByColumn('delegate_user_id', currentUser.id),
    );

    final uniqueRows = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      uniqueRows[row['id'].toString()] = row;
    }
    return uniqueRows.values
        .map<GroupRoleDelegationModel>(
          (row) => GroupRoleDelegationModel.fromJson(_rowAsJson(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupRoleDelegationModel> cancelDelegation(String delegationId) async {
    final currentUser = _requireCurrentUser();
    final delegation = await _fetchDelegation(delegationId);
    if (delegation.status != 'active') {
      throw StateError('활성 위임만 취소할 수 있습니다.');
    }
    await _ensureCanManageDelegation(delegation.groupId, currentUser.id);

    final updated = await _client
        .from('group_role_delegations')
        .update(
          <String, dynamic>{
            'status': 'cancelled',
            'cancelled_at': DateTime.now().toUtc().toIso8601String(),
            'cancelled_by': currentUser.id,
          },
        )
        .eq('id', delegationId)
        .select()
        .single();
    return GroupRoleDelegationModel.fromJson(_rowAsJson(updated));
  }

  User _requireCurrentUser() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }
    return user;
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
      throw StateError('팀 리더만 위임을 관리할 수 있습니다.');
    }
  }

  Future<void> _ensureActiveGroupAndLeader(
      String groupId, String userId) async {
    final groupResponse = await _client
        .from('groups')
        .select('id')
        .eq('id', groupId)
        .eq('status', 'active')
        .maybeSingle();
    if (groupResponse == null) {
      throw StateError('활성 그룹에서만 위임을 생성할 수 있습니다.');
    }
    await _ensureLeaderOfGroup(groupId, userId);
  }

  Future<void> _ensureCanManageDelegation(String groupId, String userId) async {
    final delegatorResponse = await _client
        .from('group_role_delegations')
        .select('id')
        .eq('group_id', groupId)
        .eq('delegator_user_id', userId)
        .eq('status', 'active')
        .maybeSingle();
    if (delegatorResponse != null) {
      return;
    }
    await _ensureLeaderOfGroup(groupId, userId);
  }

  List<String> _validatePermissions(List<String> permissions) {
    if (permissions.isEmpty) {
      throw StateError('최소 하나의 위임 권한이 필요합니다.');
    }
    final normalizedPermissions =
        permissions.map((item) => item.trim()).toList(growable: false);
    if (normalizedPermissions.any((item) => item.isEmpty)) {
      throw StateError('빈 권한 값은 허용되지 않습니다.');
    }
    if (normalizedPermissions.toSet().length != normalizedPermissions.length) {
      throw StateError('중복된 위임 권한은 허용되지 않습니다.');
    }
    final invalidPermissions = normalizedPermissions
        .where((item) =>
            !GroupRoleDelegationModel.allowedPermissions.contains(item))
        .toList(growable: false);
    if (invalidPermissions.isNotEmpty) {
      throw StateError('허용되지 않은 위임 권한이 포함되어 있습니다.');
    }
    return normalizedPermissions;
  }

  Future<GroupRoleDelegationModel> _fetchDelegation(String delegationId) async {
    final response = await _client
        .from('group_role_delegations')
        .select()
        .eq('id', delegationId)
        .single();
    return GroupRoleDelegationModel.fromJson(_rowAsJson(response));
  }

  Future<List<Map<String, dynamic>>> _fetchDelegationsByColumn(
    String column,
    String value,
  ) async {
    final response =
        await _client.from('group_role_delegations').select().eq(column, value);
    return response
        .map<Map<String, dynamic>>((row) => _rowAsJson(row))
        .toList(growable: false);
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}
