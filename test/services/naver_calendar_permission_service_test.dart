import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _naverOAuthProvider = 'custom:planflow-naver';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // banned-ok: Test-only secure-store fake, with no credential values.
  const tokenStore = NaverCalendarOAuthTokenStore();
  group('NaverCalendarPermissionService', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    tearDown(() {
      SharedPreferencesAsyncPlatform.instance = null;
    });

    test('classifies successful or validation responses as granted', () {
      final ok = NaverCalendarPermissionService.classifyResponse(
        http.Response('{"result":"ok"}', 200),
      );
      final validation = NaverCalendarPermissionService.classifyResponse(
        http.Response('invalid schedule payload', 400),
      );

      expect(ok.status, NaverCalendarPermissionStatus.granted);
      expect(validation.status, NaverCalendarPermissionStatus.granted);
    });

    test('classifies auth and scope errors as denied', () {
      final unauthorized = NaverCalendarPermissionService.classifyResponse(
        http.Response('unauthorized', 401),
      );
      final scope = NaverCalendarPermissionService.classifyResponse(
        http.Response('insufficient scope permission denied', 400),
      );

      expect(unauthorized.status, NaverCalendarPermissionStatus.denied);
      expect(scope.status, NaverCalendarPermissionStatus.denied);
    });

    test('classifies server errors as network error', () {
      final result = NaverCalendarPermissionService.classifyResponse(
        http.Response('temporary error', 503),
      );

      expect(result.status, NaverCalendarPermissionStatus.networkError);
    });

    test('refreshStatus probes read endpoint without creating dummy schedule',
        () async {
      Uri? requestedUri;
      String? requestedMethod;
      final service = NaverCalendarPermissionService(
        accessTokenProvider: () async => 'token',
        httpClient: MockClient((request) async {
          requestedUri = request.url;
          requestedMethod = request.method;
          return http.Response('{"schedules":[]}', 200);
        }),
      );

      final result = await service.refreshStatus();

      expect(result.status, NaverCalendarPermissionStatus.granted);
      expect(requestedMethod, 'GET');
      expect(requestedUri?.path, '/calendar/findSchedules.json');
      expect(requestedUri?.queryParameters['calendarId'], 'defaultCalendarId');
      expect(requestedUri?.queryParameters['count'], '1');
    });

    for (final provider in [
      'google',
      'kakao',
      'naver',
      'custom:naver',
      'custom:planflow-naver-other',
      _naverOAuthProvider,
    ]) {
      test('$provider session token never reaches Naver', () async {
        var upstreamCalls = 0;
        var storedTokenWrites = 0;
        final client = _testClient((request) async {
          if (request.method == 'POST') storedTokenWrites++;
          return _jsonResponse([]);
        });
        await _recoverSession(
          client,
          provider: provider,
          providers: [provider, _naverOAuthProvider],
        );
        final service = NaverCalendarPermissionService(
          supabaseClient: client,
          httpClient: MockClient((_) async {
            upstreamCalls++;
            return _jsonResponse({'schedules': []});
          }),
        );

        expect(await service.resolveAccessTokenForCalendar(), isNull);
        expect((await service.refreshStatus()).status,
            NaverCalendarPermissionStatus.unknown);
        expect(await service.captureCurrentProviderToken(), isFalse);
        expect(upstreamCalls, 0);
        expect(storedTokenWrites, 0);
      });
    }

    for (final provider in ['google', 'kakao', _naverOAuthProvider]) {
      test('uses a verified Naver callback token for the same $provider UID',
          () async {
      final client = _testClient((_) async => _jsonResponse([]));
      await _recoverSession(client, provider: provider);
      expect(await tokenStore.saveVerifiedCallbackToken(
        userId: 'fixture-user',
        token: 'verified-naver-fixture',
        stillCurrent: () => true,
        replaceExisting: true,
      ), isTrue);
      String? authorization;
      final service = NaverCalendarPermissionService(
        supabaseClient: client,
        httpClient: MockClient((request) async {
          expect(request.url.host, 'openapi.naver.com');
          authorization = request.headers['authorization'];
          return _jsonResponse({'schedules': []});
        }),
      );
      await service.saveStatus(NaverCalendarPermissionStatus.denied);

      expect((await service.probeStatus()).isGranted, isTrue);
      expect(authorization, 'Bearer verified-naver-fixture');
      expect(await service.loadStatus(), NaverCalendarPermissionStatus.denied);
      });
    }

    test('a contaminated legacy row never supplies a Google session token',
        () async {
      var storedTokenReads = 0;
      var upstreamCalls = 0;
      final client = _testClient((request) async {
        if (request.url.path == '/rest/v1/user_settings') storedTokenReads++;
        return _jsonResponse([{'naver_calendar_token': 'fixture-provider-token'}]);
      });
      await _recoverSession(client, provider: 'google');
      final service = NaverCalendarPermissionService(
        supabaseClient: client,
        httpClient: MockClient((_) async {
          upstreamCalls++;
          return _jsonResponse({'schedules': []});
        }),
      );

      expect(await service.resolveAccessTokenForCalendar(), isNull);
      expect((await service.probeStatus()).status,
          NaverCalendarPermissionStatus.unknown);
      expect(storedTokenReads, 0);
      expect(upstreamCalls, 0);
    });

    test('another UID cannot resolve a locally stored Naver token',
        () async {
      final client = _testClient((_) async => _jsonResponse([]));
      await _recoverSession(client, provider: 'kakao', userId: 'different-user');
      await tokenStore.saveVerifiedCallbackToken(
        userId: 'fixture-user',
        token: 'verified-naver-fixture',
        stillCurrent: () => true,
        replaceExisting: true,
      );
      var upstreamCalls = 0;
      final service = NaverCalendarPermissionService(
        supabaseClient: client,
        httpClient: MockClient((_) async {
          upstreamCalls++;
          return _jsonResponse({'schedules': []});
        }),
      );
      expect(await service.resolveAccessTokenForCalendar(), isNull);
      expect((await service.probeStatus()).status,
          NaverCalendarPermissionStatus.unknown);
      expect(upstreamCalls, 0);
    });

    for (final nextUserId in ['fixture-user', 'different-user']) {
      test('drops the Naver probe result after a session change to $nextUserId',
          () async {
        var storedTokenWrites = 0;
        final client = _testClient((request) async {
          if (request.method == 'POST') storedTokenWrites++;
          return _jsonResponse([]);
        });
        await _recoverSession(client, provider: _naverOAuthProvider);
        await tokenStore.saveVerifiedCallbackToken(
          userId: 'fixture-user',
          token: 'verified-naver-fixture',
          stillCurrent: () => true,
          replaceExisting: true,
        );
        final requestStarted = Completer<void>();
        final response = Completer<http.Response>();
        final service = NaverCalendarPermissionService(
          supabaseClient: client,
          httpClient: MockClient((_) {
            requestStarted.complete();
            return response.future;
          }),
        );
        await service.saveStatus(NaverCalendarPermissionStatus.denied);

        final result = service.refreshStatus();
        await requestStarted.future;
        await _recoverSession(client, provider: 'google', userId: nextUserId);
        response.complete(_jsonResponse({'schedules': []}));

        expect((await result).status, NaverCalendarPermissionStatus.unknown);
        expect(await service.loadStatus(), NaverCalendarPermissionStatus.denied);
        expect(storedTokenWrites, 0);
      });
    }

    test('Naver signup metadata cannot authorize a linked provider token',
        () async {
      var upstreamCalls = 0;
      final client = _testClient((_) async => _jsonResponse([]));
      await _recoverSession(
        client,
        provider: _naverOAuthProvider,
        providers: [_naverOAuthProvider, 'google'],
      );
      final service = NaverCalendarPermissionService(
        supabaseClient: client,
        httpClient: MockClient((_) async {
          upstreamCalls++;
          return _jsonResponse({'schedules': []});
        }),
      );

      expect((await service.probeStatus()).status,
          NaverCalendarPermissionStatus.unknown);
      expect(await service.captureCurrentProviderToken(), isFalse);
      expect(upstreamCalls, 0);
    });

    test('a timed out request does not overwrite saved permission status',
        () async {
      final service = NaverCalendarPermissionService(
        accessTokenProvider: () async => 'fixture-naver',
        httpClient: MockClient((_) async => throw TimeoutException('fixture')),
      );
      await service.saveStatus(NaverCalendarPermissionStatus.denied);

      expect((await service.refreshStatus()).isNetworkError, isTrue);
      expect(await service.loadStatus(), NaverCalendarPermissionStatus.denied);
    });
  });
}

SupabaseClient _testClient(Future<http.Response> Function(http.Request) respond) {
  final client = SupabaseClient(
    'https://planflow-fixture.test.invalid',
    'local-fixture-key',
    httpClient: MockClient(respond),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return client;
}

Future<void> _recoverSession(
  SupabaseClient client, {
  required String provider,
  List<String>? providers,
  String userId = 'fixture-user',
}) async {
  final expiresAt =
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
  final claims = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expiresAt, 'sub': userId})))
      .replaceAll('=', '');
  await client.auth.recoverSession(jsonEncode({
    'access_token': 'eyJhbGciOiJub25lIn0.$claims.fixture',
    'refresh_token': 'fixture-refresh',
    'provider_token': 'fixture-provider-token',
    'token_type': 'bearer',
    'expires_in': 86400,
    'expires_at': expiresAt,
    'user': {
      'id': userId,
      'aud': 'authenticated',
      'app_metadata': {'provider': provider, 'providers': providers ?? [provider]},
      'user_metadata': {},
      'created_at': '2026-01-01T00:00:00Z',
    },
  }));
}

http.Response _jsonResponse(Object data) => http.Response(
      jsonEncode(data),
      200,
      headers: {'content-type': 'application/json'},
    );
