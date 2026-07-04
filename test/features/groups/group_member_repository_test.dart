import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:planflow/features/groups/repositories/group_repository.dart';

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
  test('removeGroupMember uses RPC and maps the removed row', () async {
    final client = _createClient();
    var receivedGroupId = '';
    var receivedUserId = '';

    final repository = SupabaseGroupRepository(
      client: client,
      currentUserIdProvider: () => 'leader-1',
      ensureLeaderOfGroup: (groupId, userId) async {
        expect(groupId, 'group-1');
        expect(userId, 'leader-1');
      },
      removeGroupMemberRpc: (groupId, userId) async {
        receivedGroupId = groupId;
        receivedUserId = userId;
        return <String, dynamic>{
          'id': 'member-1',
          'group_id': groupId,
          'user_id': userId,
          'role': 'member',
          'status': 'removed',
          'joined_at': '2026-06-11T00:00:00Z',
          'removed_at': '2026-06-13T00:00:00Z',
          'removed_by': 'leader-1',
          'created_at': '2026-06-11T00:00:00Z',
          'updated_at': '2026-06-13T00:00:00Z',
        };
      },
    );

    final removed = await repository.removeGroupMember('group-1', 'user-2');

    expect(receivedGroupId, 'group-1');
    expect(receivedUserId, 'user-2');
    expect(removed.id, 'member-1');
    expect(removed.groupId, 'group-1');
    expect(removed.userId, 'user-2');
    expect(removed.status, 'removed');
    expect(removed.removedBy, 'leader-1');
  });

  test('removeGroupMember requires an authenticated leader', () async {
    final repository = SupabaseGroupRepository(
      client: _createClient(),
      removeGroupMemberRpc: (_, __) async {
        fail('RPC should not be called when there is no authenticated user.');
      },
    );

    await expectLater(
      repository.removeGroupMember('group-1', 'user-2'),
      throwsStateError,
    );
  });

  test('leaveGroup uses RPC and maps the removed row', () async {
    final client = _createClient();
    var receivedGroupId = '';

    final repository = SupabaseGroupRepository(
      client: client,
      currentUserIdProvider: () => 'member-9',
      leaveGroupRpc: (groupId) async {
        receivedGroupId = groupId;
        return <String, dynamic>{
          'id': 'membership-9',
          'group_id': groupId,
          'user_id': 'member-9',
          'role': 'member',
          'status': 'removed',
          'joined_at': '2026-06-11T00:00:00Z',
          'removed_at': '2026-06-13T00:00:00Z',
          'removed_by': 'member-9',
          'created_at': '2026-06-11T00:00:00Z',
          'updated_at': '2026-06-13T00:00:00Z',
        };
      },
    );

    final left = await repository.leaveGroup('group-1');

    expect(receivedGroupId, 'group-1');
    expect(left.id, 'membership-9');
    expect(left.groupId, 'group-1');
    expect(left.userId, 'member-9');
    expect(left.status, 'removed');
    expect(left.removedBy, 'member-9');
  });

  test('leaveGroup requires an authenticated user', () async {
    final repository = SupabaseGroupRepository(
      client: _createClient(),
      leaveGroupRpc: (_) async {
        fail('RPC should not be called when there is no authenticated user.');
      },
    );

    await expectLater(
      repository.leaveGroup('group-1'),
      throwsStateError,
    );
  });
}
