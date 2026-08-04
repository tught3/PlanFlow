import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group_backup_model.dart';

abstract class GroupBackupRepository {
  const GroupBackupRepository();

  factory GroupBackupRepository.supabase({SupabaseClient? client}) =
      SupabaseGroupBackupRepository;

  Future<GroupBackupModel> createArchiveBackup(
    String groupId,
    Map<String, dynamic> snapshot,
  );

  Future<List<GroupBackupModel>> getBackupsForGroup(String groupId);

  Future<GroupBackupModel> markBackupRestored(String backupId);

  Future<GroupBackupModel> archiveGroupWithBackup(
    String groupId,
  );

  /// 본인이 만든 미복원 백업을 최신 순으로 가져온다.
  /// [backupType]이 null이면 모든 타입, 그 외엔 'archive' 또는 'delete'로 필터.
  Future<List<GroupBackupModel>> listMyBackups({String? backupType});

  Future<GroupBackupModel> restoreGroupFromBackup(String backupId);

  Future<void> permanentlyDeleteBackup(String backupId);

  /// 그룹을 'delete' 백업으로 저장한 후 원본을 삭제한다.
  /// 백업 실패 시 그룹은 그대로 남는다.
  Future<GroupBackupModel> deleteGroupWithBackup(String groupId);
}

class SupabaseGroupBackupRepository extends GroupBackupRepository {
  SupabaseGroupBackupRepository({
    SupabaseClient? client,
    String? Function()? currentUserIdProvider,
    Future<Map<String, dynamic>> Function(String groupId)?
        archiveGroupWithBackupRpc,
    Future<Map<String, dynamic>> Function(String groupId)?
        deleteGroupWithBackupRpc,
    Future<Map<String, dynamic>> Function(String backupId)?
        restoreGroupFromBackupRpc,
    Future<void> Function(String backupId)? permanentlyDeleteBackupRpc,
  })  : _client = client ?? Supabase.instance.client,
        _currentUserIdProvider = currentUserIdProvider,
        _archiveGroupWithBackupRpc = archiveGroupWithBackupRpc,
        _deleteGroupWithBackupRpc = deleteGroupWithBackupRpc,
        _restoreGroupFromBackupRpc = restoreGroupFromBackupRpc,
        _permanentlyDeleteBackupRpc = permanentlyDeleteBackupRpc;

  final SupabaseClient _client;
  final String? Function()? _currentUserIdProvider;
  final Future<Map<String, dynamic>> Function(String groupId)?
      _archiveGroupWithBackupRpc;
  final Future<Map<String, dynamic>> Function(String groupId)?
      _deleteGroupWithBackupRpc;
  final Future<Map<String, dynamic>> Function(String backupId)?
      _restoreGroupFromBackupRpc;
  final Future<void> Function(String backupId)? _permanentlyDeleteBackupRpc;

  @override
  Future<GroupBackupModel> createArchiveBackup(
    String groupId,
    Map<String, dynamic> snapshot,
  ) async {
    final currentUserId = _requireCurrentUserId();
    await _ensureActiveGroupAndLeader(groupId, currentUserId);

    final response = await _client
        .from('group_backups')
        .insert(
          <String, dynamic>{
            'group_id': groupId,
            'backup_type': 'archive',
            'snapshot': snapshot,
            'created_by': currentUserId,
          },
        )
        .select()
        .single();
    return GroupBackupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<List<GroupBackupModel>> getBackupsForGroup(String groupId) async {
    final currentUserId = _requireCurrentUserId();
    await _ensureLeaderOfGroup(groupId, currentUserId);

    final response = await _client
        .from('group_backups')
        .select()
        .eq('group_id', groupId)
        .order('created_at', ascending: false);
    return response
        .map<GroupBackupModel>(
          (row) => GroupBackupModel.fromJson(_rowAsJson(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupBackupModel> markBackupRestored(String backupId) async {
    final currentUserId = _requireCurrentUserId();
    final backup = await _fetchBackup(backupId);
    await _ensureLeaderOfGroup(backup.groupId, currentUserId);

    if (backup.isRestored) {
      throw StateError('이미 복원된 백업입니다.');
    }

    final response = await _client
        .from('group_backups')
        .update(
          <String, dynamic>{
            'restored_at': DateTime.now().toUtc().toIso8601String(),
            'restored_by': currentUserId,
          },
        )
        .eq('id', backupId)
        .select()
        .single();
    return GroupBackupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<GroupBackupModel> archiveGroupWithBackup(
    String groupId,
  ) async {
    _requireCurrentUserId();
    final response =
        await (_archiveGroupWithBackupRpc ?? _archiveGroupWithBackupWithRpc)(
      groupId,
    );
    return GroupBackupModel.fromJson(response);
  }

  @override
  Future<List<GroupBackupModel>> listMyBackups({String? backupType}) async {
    _requireCurrentUserId();
    final List<Map<String, dynamic>> response;
    if (backupType != null) {
      // .eq()는 select() 직후(filter stage)에만 사용 가능. order()는 다음 단계.
      response = await _client
          .from('group_backups')
          .select()
          .eq('backup_type', backupType)
          .order('created_at', ascending: false);
    } else {
      response = await _client
          .from('group_backups')
          .select()
          .order('created_at', ascending: false);
    }
    return response
        .map<GroupBackupModel>(
          (row) => GroupBackupModel.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupBackupModel> restoreGroupFromBackup(String backupId) async {
    _requireCurrentUserId();
    final response =
        await (_restoreGroupFromBackupRpc ?? _restoreGroupFromBackupWithRpc)(
      backupId,
    );
    return GroupBackupModel.fromJson(response);
  }

  @override
  Future<void> permanentlyDeleteBackup(String backupId) async {
    _requireCurrentUserId();
    await (_permanentlyDeleteBackupRpc ?? _permanentlyDeleteBackupWithRpc)(
      backupId,
    );
  }

  @override
  Future<GroupBackupModel> deleteGroupWithBackup(String groupId) async {
    _requireCurrentUserId();
    final response =
        await (_deleteGroupWithBackupRpc ?? _deleteGroupWithBackupWithRpc)(
      groupId,
    );
    return GroupBackupModel.fromJson(response);
  }

  String _requireCurrentUserId() {
    final currentUserId =
        _currentUserIdProvider?.call() ?? _client.auth.currentUser?.id;
    if (currentUserId == null || currentUserId.trim().isEmpty) {
      throw StateError('로그인이 필요합니다.');
    }
    return currentUserId;
  }

  Future<Map<String, dynamic>> _archiveGroupWithBackupWithRpc(
    String groupId,
  ) async {
    final response = await _client
        .rpc('archive_group_with_backup', params: <String, dynamic>{
          'group_id_input': groupId,
        })
        .select()
        .single();
    return _rowAsJson(response);
  }

  Future<Map<String, dynamic>> _deleteGroupWithBackupWithRpc(
    String groupId,
  ) async {
    final response = await _client
        .rpc('delete_group_with_backup', params: <String, dynamic>{
          'group_id_input': groupId,
        })
        .select()
        .single();
    return _rowAsJson(response);
  }

  Future<Map<String, dynamic>> _restoreGroupFromBackupWithRpc(
    String backupId,
  ) async {
    final response = await _client
        .rpc('restore_group_from_backup', params: <String, dynamic>{
          'backup_id_input': backupId,
        })
        .select()
        .single();
    return _rowAsJson(response);
  }

  Future<void> _permanentlyDeleteBackupWithRpc(String backupId) async {
    await _client.rpc(
      'permanently_delete_backup',
      params: <String, dynamic>{'backup_id_input': backupId},
    );
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
      throw StateError('그룹 리더만 백업을 관리할 수 있습니다.');
    }
  }

  Future<void> _ensureActiveGroupAndLeader(
    String groupId,
    String userId,
  ) async {
    final groupResponse = await _client
        .from('groups')
        .select('id')
        .eq('id', groupId)
        .eq('status', 'active')
        .maybeSingle();
    if (groupResponse == null) {
      throw StateError('활성 그룹에서만 백업을 생성할 수 있습니다.');
    }
    await _ensureLeaderOfGroup(groupId, userId);
  }

  Future<GroupBackupModel> _fetchBackup(String backupId) async {
    final response = await _client
        .from('group_backups')
        .select()
        .eq('id', backupId)
        .single();
    return GroupBackupModel.fromJson(_rowAsJson(response));
  }

  Map<String, dynamic> _rowAsJson(Object row) {
    return Map<String, dynamic>.from(row as Map);
  }
}
