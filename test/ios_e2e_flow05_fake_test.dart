import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/supabase_auth_options.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/auth_service.dart' show PlanFlowOAuthProvider;
import 'package:planflow/services/oauth_callback_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../integration_test/_harness/fakes/fake_auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    AppEnv.markSupabaseInitialized();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    PlanFlowAuthLocalStorage.endExplicitSignOut();
    OAuthCallbackHandler.clearInMemoryPendingCallbackForTest();
    OAuthCallbackHandler.clearLatestUserMessage();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
    PlanFlowAuthLocalStorage.endExplicitSignOut();
    OAuthCallbackHandler.clearInMemoryPendingCallbackForTest();
    OAuthCallbackHandler.clearLatestUserMessage();
  });

  group('FLOW5 Group A fake host-side coverage', () {
    test('restores a stored session as signed in', () async {
      final fake = FakeAuthService(
        initialSession: FixtureSession.build(
          userId: 'flow5-restore-user',
          email: 'restore@example.test',
        ),
      );
      final provider = AuthProvider(authService: fake);
      addTearDown(provider.dispose);
      addTearDown(fake.dispose);

      provider.start();
      await _drain();

      expect(provider.hasResolvedInitialSession, isTrue);
      expect(provider.sessionStatus, AuthSessionStatus.active);
      expect(provider.isSignedIn, isTrue);
      expect(provider.userId, 'flow5-restore-user');
      expect(provider.email, 'restore@example.test');
      expect(provider.hasAccountSnapshot, isTrue);
    });

    test('moves from signed out to signed in when a session arrives', () async {
      final fake = FakeAuthService();
      final provider = AuthProvider(authService: fake);
      addTearDown(provider.dispose);
      addTearDown(fake.dispose);

      provider.start();
      await _drain();

      expect(provider.hasResolvedInitialSession, isFalse);
      expect(provider.sessionStatus, AuthSessionStatus.unresolved);
      expect(provider.isSignedIn, isFalse);

      fake.emitSignedIn(
        FixtureSession.build(
          userId: 'flow5-login-user',
          email: 'login@example.test',
        ),
      );
      await _drain(2);

      expect(provider.hasResolvedInitialSession, isTrue);
      expect(provider.sessionStatus, AuthSessionStatus.active);
      expect(provider.isSignedIn, isTrue);
      expect(provider.userId, 'flow5-login-user');
      expect(provider.email, 'login@example.test');
      expect(provider.hasAccountSnapshot, isTrue);
    });

    test('stays signed out when no session ever arrives', () async {
      final fake = FakeAuthService();
      final provider = AuthProvider(authService: fake);
      addTearDown(provider.dispose);
      addTearDown(fake.dispose);

      provider.start();
      await _drain();

      expect(provider.hasResolvedInitialSession, isFalse);
      expect(provider.sessionStatus, AuthSessionStatus.unresolved);
      expect(provider.isSignedIn, isFalse);

      await provider.waitForInitialSessionResolution();
      await _drain();

      expect(provider.hasResolvedInitialSession, isTrue);
      expect(provider.sessionStatus, AuthSessionStatus.signedOut);
      expect(provider.hasAccountSnapshot, isFalse);
      expect(provider.userId, isNull);
      expect(provider.email, isNull);
    });

    test('applies explicit sign out and clears the snapshot', () async {
      final fake = FakeAuthService(
        initialSession: FixtureSession.build(
          userId: 'flow5-logout-user',
          email: 'logout@example.test',
        ),
      );
      final provider = AuthProvider(authService: fake);
      addTearDown(provider.dispose);
      addTearDown(fake.dispose);

      provider.start();
      await _drain();
      expect(provider.isSignedIn, isTrue);

      await PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed(
        fake.signOut,
      );
      await _drain(2);

      expect(fake.signOutCallCount, 1);
      expect(provider.sessionStatus, AuthSessionStatus.signedOut);
      expect(provider.isSignedIn, isFalse);
      expect(provider.hasAccountSnapshot, isFalse);
      expect(provider.userId, isNull);
      expect(provider.email, isNull);
    });

    test('treats a success OAuth callback as valid for all login providers',
        () {
      final successUri = Uri.parse('planflow://auth-callback?code=abc123');

      for (final provider in const <PlanFlowOAuthProvider>[
        PlanFlowOAuthProvider.google,
        PlanFlowOAuthProvider.kakao,
        PlanFlowOAuthProvider.naver,
      ]) {
        expect(
          OAuthCallbackHandler.callbackErrorMessageFor(
            successUri,
            pendingMethod: provider.name,
          ),
          isNull,
          reason:
              'provider=${provider.name} should accept a successful callback',
        );
      }
    });

    test('returns provider-specific access_denied messages', () {
      final deniedUri = Uri.parse(
        'planflow://auth-callback?error=access_denied&error_code=access_denied',
      );

      final googleMessage = OAuthCallbackHandler.callbackErrorMessageFor(
        deniedUri,
        pendingMethod: PlanFlowOAuthProvider.google.name,
      );
      final kakaoMessage = OAuthCallbackHandler.callbackErrorMessageFor(
        deniedUri,
        pendingMethod: PlanFlowOAuthProvider.kakao.name,
      );
      final naverMessage = OAuthCallbackHandler.callbackErrorMessageFor(
        deniedUri,
        pendingMethod: PlanFlowOAuthProvider.naver.name,
      );

      expect(googleMessage, isNotNull);
      expect(kakaoMessage, isNotNull);
      expect(naverMessage, isNotNull);

      expect(googleMessage, contains('소셜'));
      expect(googleMessage, isNot(contains('카카오')));
      expect(googleMessage, isNot(contains('네이버')));

      expect(kakaoMessage, contains('카카오'));
      expect(naverMessage, contains('네이버'));
    });
  });
}

Future<void> _drain([int ticks = 1]) async {
  for (var i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
