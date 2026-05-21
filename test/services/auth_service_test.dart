import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/auth_service.dart';

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
}
