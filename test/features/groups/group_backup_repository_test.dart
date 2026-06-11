import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:planflow/features/groups/repositories/group_backup_repository.dart';

SupabaseClient _createClient() {
  return SupabaseClient(
    'https://example.supabase.co',
    'anon-key',
    httpClient: MockClient((request) async {
      return http.Response('{}', 200);
    }),
  );
}

void main() {
  test('archiveGroupWithBackup uses RPC and maps the backup row', () async {
    final client = _createClient();
    var receivedGroupId = '';

    final repository = SupabaseGroupBackupRepository(
      client: client,
      currentUserIdProvider: () => 'user-1',
      archiveGroupWithBackupRpc: (groupId) async {
        receivedGroupId = groupId;
        return <String, dynamic>{
          'id': 'backup-1',
          'group_id': groupId,
          'backup_type': 'archive',
          'snapshot': <String, dynamic>{
            'group': <String, dynamic>{
              'id': groupId,
              'name': 'Planning Team',
            },
            'active_members': <Map<String, dynamic>>[],
          },
          'created_by': 'user-1',
          'created_at': '2026-06-11T00:00:00Z',
        };
      },
    );

    final backup = await repository.archiveGroupWithBackup('group-1');

    expect(receivedGroupId, 'group-1');
    expect(backup.id, 'backup-1');
    expect(backup.groupId, 'group-1');
    expect(backup.backupType, 'archive');
    expect(backup.isArchive, isTrue);
    expect(backup.snapshot['group'], isA<Map<String, dynamic>>());
  });

  test('archiveGroupWithBackup requires an authenticated user', () async {
    final repository = SupabaseGroupBackupRepository(
      client: _createClient(),
      archiveGroupWithBackupRpc: (_) async {
        fail('RPC should not be called when there is no authenticated user.');
      },
    );

    await expectLater(
      repository.archiveGroupWithBackup('group-1'),
      throwsStateError,
    );
  });
}
