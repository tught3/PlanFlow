// Synthetic wire tests only. No global Supabase, server, or ordinary quota calls.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';

const _uid = '11111111-1111-4111-8111-111111111111';
const _session = '22222222-2222-4222-8222-222222222222';
const _event = '33333333-3333-4333-8333-333333333333';

Map<String, Object?> _wire(String phase) => {
      'status': 'granted',
      'session_id': _session,
      'phase': phase,
      'revision': 4,
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String(),
      'event_id': phase == 'create' ? null : _event,
      'saved_local_date': phase == 'create' ? null : '2030-01-02',
    };

const _context = GuideChargeContext(
  uid: _uid,
  version: 'real_ui_v1',
  sessionId: _session,
  kind: GuideChargeKind.voiceConversation,
  operation: GuideOperation.changeTime,
  phase: GuideStep.editPreview,
  revision: 19,
  serverRevision: 4,
  createdEventId: _event,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('validated preview resumes with preview, never inferred edit wire phase',
      () async {
    final calls = <String>[];
    final service = SupabaseRealUiGuideGrantService.forTesting(
      currentUid: () => _uid,
      rpc: (name, params) async {
        calls.add(name);
        if (name == kRpcBegin) return _wire('preview');
        expect(name, kRpcAuthorize);
        expect(params['p_phase'], 'preview');
        expect(params['p_revision'], 4);
        expect(params['p_operation'], 'changeTime');
        return {
          'status': 'granted',
          'grant_id': 'synthetic-grant',
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 1))
              .toIso8601String(),
        };
      },
    );
    final state = await service.begin(
        uid: _uid, version: 'real_ui_v1', requestId: 'resume');
    expect(state?.step, GuideStep.editPreview);
    final access =
        await service.authorize(context: _context, operationId: 'change-1');
    expect(access.status, GuideAccessStatus.granted);
    expect(calls, [kRpcBegin, kRpcAuthorize]);
  });

  test('UI snapshot alone cannot mint a grant without validated server state',
      () async {
    var calls = 0;
    final service = SupabaseRealUiGuideGrantService.forTesting(
      currentUid: () => _uid,
      rpc: (_, __) async {
        calls++;
        return _wire('preview');
      },
    );
    final access =
        await service.authorize(context: _context, operationId: 'forged');
    expect(access.status, GuideAccessStatus.denied);
    expect(access.permit, isNull);
    expect(calls, 0);
  });

  test('authChanged uses server-supported cancel reason without completion',
      () async {
    Map<String, Object?>? sent;
    final service = SupabaseRealUiGuideGrantService.forTesting(
      currentUid: () => _uid,
      rpc: (name, params) async {
        expect(name, kRpcFinish);
        sent = params;
        return {'status': 'finished'};
      },
    );
    await service.finish(
      snapshot: const GuideSnapshot(
          uid: _uid,
          version: 'real_ui_v1',
          revision: 1,
          serverRevision: 4,
          step: GuideStep.editPreview,
          run: GuideRun.active,
          sessionId: _session),
      exit: GuideExit.authChanged,
      requestId: 'auth-end',
    );
    expect(sent?['p_reason'], 'cancel');
    expect(wireExit(GuideExit.authChanged), 'cancel');
  });

  test(
      'production constructor reads auth UID from the same isolated RPC client, not global SDK',
      () async {
    final requests = <Uri>[];
    final transport = MockClient((request) async {
      requests.add(request.url);
      expect(request.url.host, 'client-scoped.invalid');
      expect(request.url.path, '/rest/v1/rpc/$kRpcBegin');
      return http.Response(jsonEncode(_wire('create')), 200,
          request: request, headers: {'content-type': 'application/json'});
    });
    final client = SupabaseClient(
        'https://client-scoped.invalid', 'noncredential-test-key',
        httpClient: transport,
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    try {
      final expiry = DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch ~/
          1000;
      String part(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token = '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({
            'sub': _uid,
            'exp': expiry,
            'role': 'authenticated'
          })}.synthetic';
      await client.auth.recoverSession(jsonEncode({
        'access_token': token,
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': expiry,
        'user': {
          'id': _uid,
          'aud': 'authenticated',
          'role': 'authenticated',
          'created_at': '2020-01-01T00:00:00Z',
          'app_metadata': {},
          'user_metadata': {}
        },
      }));
      expect(client.auth.currentUser?.id, _uid);
      final service = SupabaseRealUiGuideGrantService(client: client);
      final state = await service.begin(
          uid: _uid, version: 'real_ui_v1', requestId: 'same-client');
      expect(state?.sessionId, _session);
      expect(requests, hasLength(1));
    } finally {
      await client.dispose();
      transport.close();
    }
  });
}
