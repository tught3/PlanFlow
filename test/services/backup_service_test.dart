import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/backup_service.dart';

void main() {
  test('automaticBackupIdsToPrune keeps recent daily backups and monthly rollups',
      () {
    final now = DateTime.utc(2026, 5, 19, 3);
    final backups = <BackupSnapshot>[
      _backup(
        id: 'manual-1',
        label: '수동 백업',
        createdAt: now.subtract(const Duration(days: 400)),
      ),
      _backup(
        id: 'auto-recent-1',
        label: '자동 백업',
        createdAt: now.subtract(const Duration(days: 5)),
      ),
      _backup(
        id: 'auto-recent-2',
        label: '자동 백업',
        createdAt: now.subtract(const Duration(days: 18)),
      ),
      _backup(
        id: 'auto-april-keep',
        label: '자동 백업',
        createdAt: now.subtract(const Duration(days: 35)),
      ),
      _backup(
        id: 'auto-april-prune',
        label: '자동 백업',
        createdAt: now.subtract(const Duration(days: 45)),
      ),
      _backup(
        id: 'auto-march-keep',
        label: '자동 백업',
        createdAt: now.subtract(const Duration(days: 75)),
      ),
      _backup(
        id: 'auto-old-prune',
        label: '자동 백업',
        createdAt: now.subtract(const Duration(days: 400)),
      ),
    ];

    final pruneIds = BackupService.automaticBackupIdsToPrune(
      backups,
      now: now,
    );

    expect(pruneIds, contains('auto-april-prune'));
    expect(pruneIds, contains('auto-old-prune'));
    expect(pruneIds, isNot(contains('manual-1')));
    expect(pruneIds, isNot(contains('auto-recent-1')));
    expect(pruneIds, isNot(contains('auto-recent-2')));
    expect(pruneIds, isNot(contains('auto-april-keep')));
    expect(pruneIds, isNot(contains('auto-march-keep')));
  });
}

BackupSnapshot _backup({
  required String id,
  required String label,
  required DateTime createdAt,
}) {
  return BackupSnapshot(
    id: id,
    label: label,
    createdAt: createdAt,
    itemCounts: const <String, int>{},
  );
}
