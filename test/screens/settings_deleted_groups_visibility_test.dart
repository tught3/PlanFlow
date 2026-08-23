import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/features/groups/models/group_backup_model.dart';
import 'package:planflow/screens/settings/settings_screen.dart';

void main() {
  GroupBackupModel backup({
    String type = 'delete',
    DateTime? restoredAt,
  }) {
    return GroupBackupModel(
      id: 'backup-1',
      groupId: 'group-1',
      backupType: type,
      snapshot: const <String, dynamic>{},
      restoredAt: restoredAt,
    );
  }

  test('deleted groups button is hidden for empty or archive-only backups', () {
    expect(shouldShowDeletedGroupsButton(const <GroupBackupModel>[]), isFalse);
    expect(
      shouldShowDeletedGroupsButton(
          <GroupBackupModel>[backup(type: 'archive')]),
      isFalse,
    );
  });

  test('deleted groups button is hidden after a delete backup is restored', () {
    expect(
      shouldShowDeletedGroupsButton(<GroupBackupModel>[
        backup(restoredAt: DateTime.utc(2026, 8, 23)),
      ]),
      isFalse,
    );
  });

  test('deleted groups button is shown for one active delete backup', () {
    expect(
      shouldShowDeletedGroupsButton(<GroupBackupModel>[
        backup(type: 'archive'),
        backup(),
      ]),
      isTrue,
    );
  });
}
