import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:planflow/features/groups/repositories/group_invite_repository.dart';

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
  test('acceptInvite uses RPC and maps the accepted invite', () async {
    final client = _createClient();
    var receivedInviteId = '';

    final repository = SupabaseGroupInviteRepository(
      client: client,
      currentUserIdProvider: () => 'user-1',
      acceptInviteRpc: (inviteId) async {
        receivedInviteId = inviteId;
        return <String, dynamic>{
          'id': inviteId,
          'group_id': 'group-1',
          'invited_user_id': 'user-1',
          'invited_email': 'member@example.com',
          'invited_invite_code': 'invite-1234',
          'invited_by': 'leader-1',
          'status': 'accepted',
          'expires_at': '2026-06-20T00:00:00Z',
          'accepted_at': '2026-06-11T00:00:00Z',
          'acted_by': 'user-1',
          'created_at': '2026-06-10T00:00:00Z',
          'updated_at': '2026-06-11T00:00:00Z',
        };
      },
    );

    final invite = await repository.acceptInvite('invite-1');

    expect(receivedInviteId, 'invite-1');
    expect(invite.id, 'invite-1');
    expect(invite.groupId, 'group-1');
    expect(invite.status, 'accepted');
    expect(invite.isAccepted, isTrue);
    expect(invite.actedBy, 'user-1');
  });

  test('acceptInvite requires an authenticated user', () async {
    final repository = SupabaseGroupInviteRepository(
      client: _createClient(),
      acceptInviteRpc: (_) async {
        fail('RPC should not be called when there is no authenticated user.');
      },
    );

    await expectLater(
      repository.acceptInvite('invite-1'),
      throwsStateError,
    );
  });
}
