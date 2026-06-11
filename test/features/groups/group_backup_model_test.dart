import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/features/groups/models/group_backup_model.dart';

void main() {
  test('GroupBackupModel round-trips snapshot payloads', () {
    final model = GroupBackupModel.fromJson(<String, dynamic>{
      'id': 'backup-1',
      'group_id': 'group-1',
      'backup_type': 'archive',
      'snapshot': <String, dynamic>{
        'name': 'Planning Team',
        'members': 4,
        'tags': <String>['team', 'archive'],
      },
      'created_by': 'user-1',
      'created_at': '2026-06-11T00:00:00Z',
    });

    expect(model.id, 'backup-1');
    expect(model.groupId, 'group-1');
    expect(model.backupType, 'archive');
    expect(model.snapshot['name'], 'Planning Team');
    expect(model.snapshot['members'], 4);
    expect(model.snapshot['tags'], <String>['team', 'archive']);
    expect(model.isArchive, isTrue);
    expect(model.isRestored, isFalse);

    final payload = model.toJson();

    expect(payload['group_id'], 'group-1');
    expect(payload['backup_type'], 'archive');
    expect(payload['snapshot'], isA<Map<String, dynamic>>());
    expect(payload['created_by'], 'user-1');
  });
}
