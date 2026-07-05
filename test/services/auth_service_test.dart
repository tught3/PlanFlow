import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:planflow/services/oauth_callback_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('AuthService OAuth scopes', () {
    test('Kakao login does not request unconfigured account_email scope', () {
      final scopes = AuthService.oauthScopesFor(PlanFlowOAuthProvider.kakao);

      expect(scopes, isNotNull);
      expect(scopes, isNot(contains('account_email')));
      expect(scopes, contains('openid'));
      expect(scopes, contains('profile_nickname'));
    });

    test('Naver login keeps the email scope for custom provider userinfo', () {
      expect(
        AuthService.oauthScopesFor(PlanFlowOAuthProvider.naver),
        'email',
      );
    });

    test('Naver calendar connection requests calendar consent scope', () {
      expect(
        AuthService.oauthScopesFor(
          PlanFlowOAuthProvider.naver,
          forCalendar: true,
        ),
        'email,calendar',
      );
    });

    test('Naver recheck uses reprompt without changing normal login', () {
      expect(
        AuthService.oauthQueryParamsFor(PlanFlowOAuthProvider.naver),
        isNull,
      );
      expect(
        AuthService.oauthQueryParamsFor(
          PlanFlowOAuthProvider.naver,
          forceConsent: true,
        ),
        const <String, String>{'auth_type': 'reprompt'},
      );
      expect(
        AuthService.oauthQueryParamsFor(
          PlanFlowOAuthProvider.kakao,
          forceConsent: true,
        ),
        isNull,
      );
    });
  });

  group('AuthService cached OAuth state cleanup', () {
    test('clears pending OAuth state and Google cache', () async {
      final googleSignIn = _FakeGoogleSignIn();
      final service = AuthService(
        client: SupabaseClient(
          'https://example.com',
          'public-anon-key',
          authOptions: const FlutterAuthClientOptions(
            detectSessionInUri: false,
            autoRefreshToken: false,
          ),
        ),
        googleSignIn: googleSignIn,
      );

      OAuthCallbackHandler.markPendingLogin(PlanFlowOAuthProvider.google);
      OAuthCallbackHandler.latestUserMessage.value = 'stale';

      await service.clearCachedOAuthState();

      expect(OAuthCallbackHandler.hasPendingLogin(), isFalse);
      expect(OAuthCallbackHandler.latestUserMessage.value, isNull);
      expect(googleSignIn.disconnectCallCount, 1);
    });
  });
}

class _FakeGoogleSignIn extends GoogleSignIn {
  _FakeGoogleSignIn() : super(scopes: const <String>[]);

  int disconnectCallCount = 0;
  int signOutCallCount = 0;

  @override
  Future<GoogleSignInAccount?> disconnect() async {
    disconnectCallCount += 1;
    return null;
  }

  @override
  Future<GoogleSignInAccount?> signOut() async {
    signOutCallCount += 1;
    return null;
  }
}
