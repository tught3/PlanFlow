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
}

class SupabaseGroupBackupRepository extends GroupBackupRepository {
  SupabaseGroupBackupRepository({
    SupabaseClient? client,
    String? Function()? currentUserIdProvider,
    Future<Map<String, dynamic>> Function(String groupId)?
        archiveGroupWithBackupRpc,
  })  : _client = client ?? Supabase.instance.client,
        _currentUserIdProvider = currentUserIdProvider,
        _archiveGroupWithBackupRpc = archiveGroupWithBackupRpc;

  final SupabaseClient _client;
  final String? Function()? _currentUserIdProvider;
  final Future<Map<String, dynamic>> Function(String groupId)?
      _archiveGroupWithBackupRpc;

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
      throw StateError('팀 리더만 백업을 관리할 수 있습니다.');
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
