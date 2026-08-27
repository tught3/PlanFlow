import 'dart:io';

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
        <GroupBackupModel>[backup(type: 'archive')],
      ),
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

  test('reloads deleted-group visibility after either groups route returns',
      () {
    final source = File(
      'lib/screens/settings/settings_widgets.dart',
    ).readAsStringSync();

    expect(source, contains('_openAndRefresh(AppRoutes.groups)'));
    expect(source, contains('_openAndRefresh(AppRoutes.deletedGroups)'));
    expect(source, contains('await context.push(route)'));
    expect(source, contains('_hasDeletedGroups = _loadVisibility();'));
  });

  test('hides the deleted-groups button while a refreshed result is pending',
      () {
    expect(
      shouldRenderDeletedGroupsButton(
        connectionState: ConnectionState.waiting,
        hasDeletedGroups: true,
      ),
      isFalse,
    );
    expect(
      shouldRenderDeletedGroupsButton(
        connectionState: ConnectionState.done,
        hasDeletedGroups: true,
      ),
      isTrue,
    );
    expect(
      shouldRenderDeletedGroupsButton(
        connectionState: ConnectionState.done,
        hasDeletedGroups: false,
      ),
      isFalse,
    );
  });
}
