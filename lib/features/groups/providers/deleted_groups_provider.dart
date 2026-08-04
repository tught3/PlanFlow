import 'package:flutter/foundation.dart';

import '../models/group_backup_model.dart';
import '../repositories/group_backup_repository.dart';

enum DeletedGroupsLoadState { idle, loading, loaded, error }

/// 삭제된 그룹 백업(또는 보관된 그룹) 목록을 관리하는 간단한 ChangeNotifier.
///
/// 사용 시점:
/// - SettingsScreen 진입점 → DeletedGroupsScreen → 이 provider listMyBackups('delete')
/// - 같은 화면에서 listMyBackups('archive')도 별도로 보여줄 수 있다 (옵션).
class DeletedGroupsProvider extends ChangeNotifier {
  DeletedGroupsProvider({
    GroupBackupRepository? repository,
  }) : _repository = repository ?? GroupBackupRepository.supabase();

  final GroupBackupRepository _repository;

  DeletedGroupsLoadState _state = DeletedGroupsLoadState.idle;
  List<GroupBackupModel> _backups = const <GroupBackupModel>[];
  Object? _lastError;
  String? _restoringBackupId;
  String? _deletingBackupId;

  DeletedGroupsLoadState get state => _state;
  List<GroupBackupModel> get backups => _backups;
  Object? get lastError => _lastError;
  String? get restoringBackupId => _restoringBackupId;
  String? get deletingBackupId => _deletingBackupId;

  bool isRestoring(String backupId) => _restoringBackupId == backupId;
  bool isDeleting(String backupId) => _deletingBackupId == backupId;

  Future<void> load({String backupType = 'delete'}) async {
    _state = DeletedGroupsLoadState.loading;
    _lastError = null;
    notifyListeners();
    try {
      final list = await _repository.listMyBackups(backupType: backupType);
      _backups = list;
      _state = DeletedGroupsLoadState.loaded;
    } catch (error) {
      _lastError = error;
      _state = DeletedGroupsLoadState.error;
    }
    notifyListeners();
  }

  Future<GroupBackupModel?> restore(String backupId) async {
    if (_restoringBackupId != null) {
      return null;
    }
    _restoringBackupId = backupId;
    _lastError = null;
    notifyListeners();
    try {
      final restored = await _repository.restoreGroupFromBackup(backupId);
      // 복원된 항목은 목록에서 제거 (restored_at이 set 되어 더 이상 select ux에서 노출 안 함)
      _backups = _backups.where((b) => b.id != backupId).toList(growable: false);
      return restored;
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _restoringBackupId = null;
      notifyListeners();
    }
  }

  Future<void> permanentlyDelete(String backupId) async {
    if (_deletingBackupId != null) {
      return;
    }
    _deletingBackupId = backupId;
    _lastError = null;
    notifyListeners();
    try {
      await _repository.permanentlyDeleteBackup(backupId);
      _backups = _backups.where((b) => b.id != backupId).toList(growable: false);
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _deletingBackupId = null;
      notifyListeners();
    }
  }
}
