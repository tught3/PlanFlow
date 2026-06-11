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
    Map<String, dynamic> snapshot,
  );
}

class SupabaseGroupBackupRepository extends GroupBackupRepository {
  SupabaseGroupBackupRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<GroupBackupModel> createArchiveBackup(
    String groupId,
    Map<String, dynamic> snapshot,
  ) async {
    final currentUser = _requireCurrentUser();
    await _ensureActiveGroupAndLeader(groupId, currentUser.id);

    final response = await _client
        .from('group_backups')
        .insert(
          <String, dynamic>{
            'group_id': groupId,
            'backup_type': 'archive',
            'snapshot': snapshot,
            'created_by': currentUser.id,
          },
        )
        .select()
        .single();
    return GroupBackupModel.fromJson(_rowAsJson(response));
  }

  @override
  Future<List<GroupBackupModel>> getBackupsForGroup(String groupId) async {
    final currentUser = _requireCurrentUser();
    await _ensureLeaderOfGroup(groupId, currentUser.id);

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
    final currentUser = _requireCurrentUser();
    final backup = await _fetchBackup(backupId);
    await _ensureLeaderOfGroup(backup.groupId, currentUser.id);

    if (backup.isRestored) {
      throw StateError('이미 복원된 백업입니다.');
    }

    final response = await _client
        .from('group_backups')
        .update(
          <String, dynamic>{
            'restored_at': DateTime.now().toUtc().toIso8601String(),
            'restored_by': currentUser.id,
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
    Map<String, dynamic> snapshot,
  ) async {
    final currentUser = _requireCurrentUser();
    await _ensureActiveGroupAndLeader(groupId, currentUser.id);
    final backup = await createArchiveBackup(groupId, snapshot);

    await _client
        .from('groups')
        .update(
          <String, dynamic>{
            'status': 'archived',
            'archived_at': DateTime.now().toUtc().toIso8601String(),
          },
        )
        .eq('id', groupId)
        .eq('status', 'active')
        .select('id')
        .single();

    return backup;
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
