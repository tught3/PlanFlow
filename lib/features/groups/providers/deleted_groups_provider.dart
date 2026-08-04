import 'package:flutter/foundation.dart';

import '../models/group_backup_model.dart';
import '../repositories/group_backup_repository.dart';

enum DeletedGroupsLoadState { idle, loading, loaded, error }

/// 삭제/보관된 그룹 백업 목록을 관리하는 간단한 ChangeNotifier.
///
/// 사용 시점:
/// - SettingsScreen 진입점 → DeletedGroupsScreen → 이 provider load()
/// - 기본은 ['delete', 'archive'] 둘 다 로드하므로 보관된 그룹도 같은 화면에서 복원 가능.
class DeletedGroupsProvider extends ChangeNotifier {
  DeletedGroupsProvider({
    GroupBackupRepository? repository,
  }) : _repository = repository ?? GroupBackupRepository.supabase();

  final GroupBackupRepository _repository;

  static const List<String> _defaultBackupTypes = <String>['delete', 'archive'];

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

  Future<void> load({List<String>? backupTypes}) async {
    _state = DeletedGroupsLoadState.loading;
    _lastError = null;
    notifyListeners();
    try {
      final list = await _repository.listMyBackups(
        backupTypes: backupTypes ?? _defaultBackupTypes,
      );
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
