import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:planflow/services/oauth_callback_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // banned-ok: Test-only secure-store fake, with no credential values.
  const tokenStore = NaverCalendarOAuthTokenStore();
  group('OAuthCallbackHandler', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      OAuthCallbackHandler.clearInMemoryPendingCallbackForTest();
    });

    tearDown(OAuthCallbackHandler.clearInMemoryPendingCallbackForTest);

    test('detects Supabase password recovery callback type', () {
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse('planflow://auth-callback?type=recovery'),
        ),
        isTrue,
      );
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse(
            'planflow://auth-callback#access_token=token&type=recovery',
          ),
        ),
        isTrue,
      );
    });

    test('detects legacy password recovery callback event', () {
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse('planflow://auth-callback?event=password_recovery'),
        ),
        isTrue,
      );
    });

    test('does not treat normal OAuth callbacks as password recovery', () {
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse('planflow://auth-callback?code=sample'),
        ),
        isFalse,
      );
    });

    test('detects Supabase email sign-up confirmation callback type', () {
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse('planflow://auth-callback?type=signup'),
        ),
        isTrue,
      );
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse(
            'planflow://auth-callback#access_token=token&type=signup',
          ),
        ),
        isTrue,
      );
    });

    test('does not treat normal OAuth callbacks as email confirmation', () {
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse('planflow://auth-callback?code=sample'),
        ),
        isFalse,
      );
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse('planflow://auth-callback?type=recovery'),
        ),
        isFalse,
      );
    });

    test('maps email confirmation access denial to email guidance', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse('planflow://auth-callback?error=access_denied'),
        isEmailConfirmation: true,
        pendingMethod: 'email',
      );

      expect(message, contains('인증 링크'));
      expect(message, isNot(contains('소셜 동의')));
    });

    test('maps expired email confirmation links to email guidance', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse(
          'planflow://auth-callback?error=access_denied&error_code=otp_expired',
        ),
        isEmailConfirmation: true,
        pendingMethod: 'email',
      );

      expect(message, contains('이메일 인증 링크가 만료'));
      expect(message, isNot(contains('소셜')));
    });

    test('keeps social access denial guidance for social pending login', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse('planflow://auth-callback?error=access_denied'),
        pendingMethod: 'kakao',
      );

      expect(message, contains('카카오 동의 화면'));
    });

    test('uses neutral guidance when access denial has no pending method', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse('planflow://auth-callback?error=access_denied'),
      );

      expect(message, contains('인증이 완료되지 않았습니다'));
      expect(message, isNot(contains('소셜 동의')));
    });

    test('tracks pending calendar link callbacks', () {
      OAuthCallbackHandler.markPendingCalendarLink(
        PlanFlowOAuthProvider.naver,
      );

      expect(OAuthCallbackHandler.hasPendingCalendarLink(), isTrue);
      expect(OAuthCallbackHandler.hasPendingLogin(), isFalse);
    });

    test('same provider launch keeps the screen-owned login revision', () {
      final screenAttempt = OAuthCallbackHandler.markPendingLogin(
        PlanFlowOAuthProvider.google,
      );
      final serviceAttempt = OAuthCallbackHandler.markPendingLogin(
        PlanFlowOAuthProvider.google,
      );

      expect(serviceAttempt, screenAttempt);
      expect(OAuthCallbackHandler.pendingLoginRevision, screenAttempt);
    });

    test('login cancellation cannot clear a newer provider or callback purpose',
        () {
      final oldLogin = OAuthCallbackHandler.markPendingLogin(
        PlanFlowOAuthProvider.google,
      );
      OAuthCallbackHandler.markPendingLogin(PlanFlowOAuthProvider.kakao);
      expect(OAuthCallbackHandler.clearPendingLogin(oldLogin), isFalse);
      expect(OAuthCallbackHandler.pendingLoginMethod, 'kakao');

      final kakaoLogin = OAuthCallbackHandler.pendingLoginRevision!;
      OAuthCallbackHandler.markPendingCalendarLink(
        PlanFlowOAuthProvider.naver,
      );
      expect(OAuthCallbackHandler.clearPendingLogin(kakaoLogin), isFalse);
      expect(OAuthCallbackHandler.hasPendingCalendarLink(), isTrue);

      OAuthCallbackHandler.markPendingEmailConfirmation();
      final emailRevision = OAuthCallbackHandler.pendingLoginRevision;
      expect(emailRevision, isNull);
      expect(OAuthCallbackHandler.hasPendingEmailConfirmation(), isTrue);
    });

    test('delayed launch failure cannot clear a newer login or calendar link',
        () {
      final failedLoginRevision = OAuthCallbackHandler.markPendingLogin(
        PlanFlowOAuthProvider.google,
      );
      final retryRevision = OAuthCallbackHandler.markPendingLogin(
        PlanFlowOAuthProvider.kakao,
      );
      expect(
        OAuthCallbackHandler.clearPendingCallbackForAttempt(
          revision: failedLoginRevision,
          purpose: OAuthCallbackPurpose.login,
        ),
        isFalse,
      );
      expect(OAuthCallbackHandler.pendingLoginRevision, retryRevision);

      final failedCalendarRevision =
          OAuthCallbackHandler.markPendingCalendarLink(
        PlanFlowOAuthProvider.naver,
      );
      final newerLoginRevision = OAuthCallbackHandler.markPendingLogin(
        PlanFlowOAuthProvider.google,
      );
      expect(
        OAuthCallbackHandler.clearPendingCallbackForAttempt(
          revision: failedCalendarRevision,
          purpose: OAuthCallbackPurpose.calendarLink,
        ),
        isFalse,
      );
      expect(OAuthCallbackHandler.pendingLoginRevision, newerLoginRevision);
    });

    test('queued persistence leaves the newest pending purpose in storage',
        () async {
      OAuthCallbackHandler.markPendingLogin(PlanFlowOAuthProvider.google);
      OAuthCallbackHandler.markPendingCalendarLink(
        PlanFlowOAuthProvider.naver,
      );
      await OAuthCallbackHandler.flushPendingCallbackPersistenceForTest();

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('oauth_callback_pending_purpose'),
        OAuthCallbackPurpose.calendarLink.name,
      );
      expect(preferences.getString('oauth_callback_pending_method'), 'naver');
    });

    test('restores pending Naver calendar link callback from storage',
        () async {
      final owner = _session('starting-user', 'original-provider');
      expect(
        await OAuthCallbackHandler.prepareNaverOAuthAttempt(
          forCalendar: true,
          initiatingSession: owner,
        ),
        isNotNull,
      );
      OAuthCallbackHandler.clearInMemoryPendingCallbackForTest();

      expect(
        await OAuthCallbackHandler
            .hasRecoverableNaverCalendarLinkCallbackForTest(owner),
        isTrue,
      );
      expect(
        await OAuthCallbackHandler
            .hasRecoverableNaverCalendarLinkCallbackForTest(
          _session('starting-user', 'original-provider', tokenSuffix: '-new'),
        ),
        isFalse,
      );
    });

    test('legacy pending calendar callback without an owner is untrusted',
        () async {
      SharedPreferences.setMockInitialValues({
        'oauth_callback_pending_purpose': 'calendarLink',
        'oauth_callback_pending_method': 'naver',
        'oauth_callback_pending_started_at':
            DateTime.now().millisecondsSinceEpoch,
      });
      expect(
        await OAuthCallbackHandler
            .hasRecoverableNaverCalendarLinkCallbackForTest(
          _session('starting-user', 'original-provider'),
        ),
        isFalse,
      );
    });

    test('isolated calendar link saves for the Google UID without auth sync',
        () async {
      final google = _session('google-user', 'google-token');
      final exchanged = _session('naver-user', 'verified-naver');
      var authSyncCalls = 0;
      final saved = await OAuthCallbackHandler.completeIsolatedNaverOAuth(
        owner: google.user.id,
        readSession: () => google,
        sessionChanges: const Stream.empty(),
        exchange: () async => exchanged,
        onLoginCompleted: () async {
          authSyncCalls++;
        },
        isPending: () => true,
        tokenStore: tokenStore,
      );

      expect(saved, isTrue);
      expect(authSyncCalls, 0);
      expect(await tokenStore.readForUser('google-user'), 'verified-naver');
      expect(await tokenStore.readForUser('naver-user'), isNull);
    });

    test('changed owner before exchange discards the callback', () async {
      final current = _session('different-user', 'different-provider');
      expect(
        await OAuthCallbackHandler.completeIsolatedNaverOAuth(
          owner: 'starting-user',
          readSession: () => current,
          sessionChanges: const Stream.empty(),
          exchange: () async => throw StateError('unexpected exchange'),
          isPending: () => true,
          tokenStore: tokenStore,
        ),
        isFalse,
      );
    });

    test('canceling an isolated callback prevents token persistence', () async {
      final original = _session('starting-user', 'original-provider');
      final exchanged = _session('naver-user', 'verified-naver');
      var pending = true;

      final saved = await OAuthCallbackHandler.completeIsolatedNaverOAuth(
        owner: original.user.id,
        readSession: () => original,
        sessionChanges: const Stream.empty(),
        exchange: () async {
          pending = false;
          return exchanged;
        },
        isPending: () => pending,
        tokenStore: tokenStore,
      );

      expect(saved, isFalse);
      expect(await tokenStore.readForUser('starting-user'), isNull);
    });

    for (final signOut in [false, true]) {
      test('late isolated exchange retains newer ${signOut ? 'sign-out' : 'sign-in'}',
          () async {
        final original = _session('starting-user', 'original-provider');
        final switched = _session('different-user', 'different-provider');
        final exchanged = _session('naver-user', 'verified-naver');
        final latest = signOut ? null : switched;
        Session? current = original;
        final changes = StreamController<Session?>.broadcast(sync: true);
        addTearDown(changes.close);

        final saved = await OAuthCallbackHandler.completeIsolatedNaverOAuth(
          owner: original.user.id,
          readSession: () => current,
          sessionChanges: changes.stream,
          exchange: () async {
            current = latest;
            changes.add(latest);
            return exchanged;
          },
          isPending: () => true,
          tokenStore: tokenStore,
        );

        expect(saved, isFalse);
        expect(current, same(latest));
        for (final user in [original, switched, exchanged]) {
          expect(await tokenStore.readForUser(user.user.id), isNull);
        }
      });
    }

    test('normal Naver login installs only if no newer auth state was seen',
        () async {
      final switched = _session('different-user', 'different-provider');
      final exchanged = _session('naver-user', 'verified-naver');
      final changes = StreamController<Session?>.broadcast(sync: true);
      addTearDown(changes.close);

      final signedIn = await OAuthCallbackHandler.completeIsolatedNaverOAuth(
        owner: null,
        readSession: () => null,
        sessionChanges: changes.stream,
        exchange: () async {
          changes.add(switched);
          changes.add(null);
          return exchanged;
        },
        installLoginSession: (_) async =>
            throw StateError('unexpected session install'),
        isPending: () => true,
        tokenStore: tokenStore,
      );

      expect(signedIn, isFalse);
      expect(await tokenStore.readForUser('naver-user'), isNull);
    });

    test('a verified Naver login cannot replace a calendar link token',
        () async {
      final login = _session('starting-user', 'verified-naver-login');
      var authSyncCalls = 0;
      Future<bool> signIn() {
        Session? current;
        return OAuthCallbackHandler.completeIsolatedNaverOAuth(
          owner: null,
          readSession: () => current,
          sessionChanges: const Stream.empty(),
          exchange: () async => login,
          installLoginSession: (session) async => current = session,
          onLoginCompleted: () async {
            expect(current, same(login));
            authSyncCalls++;
          },
          isPending: () => true,
          tokenStore: tokenStore,
        );
      }

      expect(await signIn(), isTrue);
      expect(authSyncCalls, 1);
      expect(await tokenStore.readForUser('starting-user'), 'verified-naver-login');

      await tokenStore.saveVerifiedCallbackToken(
        userId: 'starting-user',
        token: 'verified-naver-calendar-link',
        stillCurrent: () => true,
        replaceExisting: true,
      );
      expect(await signIn(), isTrue);
      expect(authSyncCalls, 2);
      expect(await tokenStore.readForUser('starting-user'),
          'verified-naver-calendar-link');
    });

    test('Naver launch and exchange use the same isolated S256 challenge',
        () async {
      final first = (await OAuthCallbackHandler.prepareNaverOAuthAttempt(
        forCalendar: false,
        initiatingSession: null,
      ))!;
      final second = (await OAuthCallbackHandler.prepareNaverOAuthAttempt(
        forCalendar: false,
        initiatingSession: null,
      ))!;
      final raw = await const FlutterSecureStorage()
          .read(key: 'planflow_pending_naver_pkce_v1');
      final record = jsonDecode(raw!) as Map<String, dynamic>;
      final verifier = record['verifier'] as String;
      final authorize = AuthService.buildNaverOAuthAuthorizeUri(
        projectUrl: 'https://supabase.example',
        challenge: second.challenge,
        forCalendar: false,
      );
      expect(first.challenge, isNot(second.challenge));
      expect(OAuthCallbackHandler.isCurrentNaverOAuthAttempt(
        first.revision, first.challenge,
      ), isFalse);
      expect(authorize.path, '/auth/v1/authorize');
      expect(authorize.queryParameters['provider'], 'custom:planflow-naver');
      expect(authorize.queryParameters['redirect_to'], 'planflow://auth-callback');
      expect(authorize.queryParameters['flow_type'], 'pkce');
      expect(authorize.queryParameters['code_challenge_method'], 's256');
      expect(authorize.queryParameters['code_challenge'], second.challenge);

      final exchanged = _session('naver-user', 'verified-naver');
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/auth/v1/token');
        expect(request.url.queryParameters, {'grant_type': 'pkce'});
        expect(request.headers['apikey'], 'fixture-key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final sentVerifier = body['code_verifier'] as String;
        final challenge = base64Url
            .encode(sha256.convert(utf8.encode(sentVerifier)).bytes)
            .replaceAll('=', '');
        expect(challenge, authorize.queryParameters['code_challenge']);
        if (body['auth_code'] != 'matched-naver-code') {
          return http.Response('{}', 400);
        }
        return http.Response(jsonEncode(exchanged.toJson()), 200);
      });
      addTearDown(mock.close);

      Future<Session> exchange(String code) =>
          OAuthCallbackHandler.exchangeNaverPkce(
            projectUrl: 'https://supabase.example',
            apiKey: 'fixture-key',
            authCode: code,
            verifier: verifier,
            client: mock,
          );
      await expectLater(exchange('superseded-naver-code'), throwsA(isA<AuthException>()));
      await expectLater(exchange('google-code'), throwsA(isA<AuthException>()));
      expect((await exchange('matched-naver-code')).providerToken, 'verified-naver');

      OAuthCallbackHandler.markPendingLogin(PlanFlowOAuthProvider.google);
      await OAuthCallbackHandler.flushPendingCallbackPersistenceForTest();
      expect(OAuthCallbackHandler.isCurrentNaverOAuthAttempt(
        second.revision, second.challenge,
      ), isFalse);
      expect(await const FlutterSecureStorage().read(
        key: 'planflow_pending_naver_pkce_v1',
      ), isNull);
    });

    test('stale ownership observed after storage write rolls it back',
        () async {
      await tokenStore.saveVerifiedCallbackToken(
        userId: 'starting-user',
        token: 'previous-verified-naver-fixture',
        stillCurrent: () => true,
        replaceExisting: true,
      );
      var checks = 0;
      expect(
        await tokenStore.saveVerifiedCallbackToken(
          userId: 'starting-user',
          token: 'stale-naver-fixture',
          stillCurrent: () => ++checks < 3,
          replaceExisting: true,
        ),
        isFalse,
      );
      expect(await tokenStore.readForUser('starting-user'),
          'previous-verified-naver-fixture');
    });

    test('a timed out calendar exchange leaves the token store empty',
        () async {
      final original = _session('starting-user', 'original-provider');
      await expectLater(
        OAuthCallbackHandler.completeIsolatedNaverOAuth(
          owner: original.user.id,
          readSession: () => original,
          sessionChanges: const Stream.empty(),
          exchange: () async => throw TimeoutException('fixture'),
          isPending: () => true,
          tokenStore: tokenStore,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(await tokenStore.readForUser('starting-user'), isNull);
    });

    test('exchanges calendar link callbacks even with an active session', () {
      expect(
        OAuthCallbackHandler.shouldExchangeOAuthCallback(
          currentSessionPresent: true,
          isPasswordRecovery: false,
          hasPendingCalendarLink: true,
        ),
        isTrue,
      );
    });

    test('trusts provider token only for Naver calendar link callback', () {
      expect(
        OAuthCallbackHandler.shouldTrustProviderTokenForNaverCalendarLink(
          pendingPurpose: OAuthCallbackPurpose.calendarLink,
          pendingMethod: 'naver',
        ),
        isTrue,
      );
      expect(
        OAuthCallbackHandler.shouldTrustProviderTokenForNaverCalendarLink(
          pendingPurpose: OAuthCallbackPurpose.login,
          pendingMethod: 'naver',
        ),
        isFalse,
      );
      expect(
        OAuthCallbackHandler.shouldTrustProviderTokenForNaverCalendarLink(
          pendingPurpose: OAuthCallbackPurpose.calendarLink,
          pendingMethod: 'google',
        ),
        isFalse,
      );
    });

    test('does not re-exchange normal callbacks after a session exists', () {
      expect(
        OAuthCallbackHandler.shouldExchangeOAuthCallback(
          currentSessionPresent: true,
          isPasswordRecovery: false,
          hasPendingCalendarLink: false,
        ),
        isFalse,
      );
    });

    test('exchanges password recovery and missing-session callbacks', () {
      expect(
        OAuthCallbackHandler.shouldExchangeOAuthCallback(
          currentSessionPresent: true,
          isPasswordRecovery: true,
          hasPendingCalendarLink: false,
        ),
        isTrue,
      );
      expect(
        OAuthCallbackHandler.shouldExchangeOAuthCallback(
          currentSessionPresent: false,
          isPasswordRecovery: false,
          hasPendingCalendarLink: false,
        ),
        isTrue,
      );
    });
  });
}

Session _session(String userId, String providerToken, {String tokenSuffix = ''}) =>
    Session.fromJson({
      'access_token': 'fixture-session-$userId$tokenSuffix',
      'refresh_token': 'fixture-refresh-$userId',
      'provider_token': providerToken,
      'token_type': 'bearer',
      'user': {
        'id': userId,
        'aud': 'authenticated',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
        'created_at': '2026-01-01T00:00:00Z',
      },
    })!;
