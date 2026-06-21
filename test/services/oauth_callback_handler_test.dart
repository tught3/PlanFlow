import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/oauth_callback_handler.dart';

void main() {
  group('OAuthCallbackHandler', () {
    test('detects Supabase password recovery callback type', () {
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse('planflow-v2://auth-callback?type=recovery'),
        ),
        isTrue,
      );
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse(
            'planflow-v2://auth-callback#access_token=token&type=recovery',
          ),
        ),
        isTrue,
      );
    });

    test('detects legacy password recovery callback event', () {
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse('planflow-v2://auth-callback?event=password_recovery'),
        ),
        isTrue,
      );
    });

    test('does not treat normal OAuth callbacks as password recovery', () {
      expect(
        OAuthCallbackHandler.isPasswordRecoveryCallback(
          Uri.parse('planflow-v2://auth-callback?code=sample'),
        ),
        isFalse,
      );
    });

    test('detects Supabase email sign-up confirmation callback type', () {
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse('planflow-v2://auth-callback?type=signup'),
        ),
        isTrue,
      );
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse(
            'planflow-v2://auth-callback#access_token=token&type=signup',
          ),
        ),
        isTrue,
      );
    });

    test('does not treat normal OAuth callbacks as email confirmation', () {
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse('planflow-v2://auth-callback?code=sample'),
        ),
        isFalse,
      );
      expect(
        OAuthCallbackHandler.isEmailConfirmationCallback(
          Uri.parse('planflow-v2://auth-callback?type=recovery'),
        ),
        isFalse,
      );
    });

    test('maps email confirmation access denial to email guidance', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse('planflow-v2://auth-callback?error=access_denied'),
        isEmailConfirmation: true,
        pendingMethod: 'email',
      );

      expect(message, contains('인증 링크'));
      expect(message, isNot(contains('소셜 동의')));
    });

    test('maps expired email confirmation links to email guidance', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse(
          'planflow-v2://auth-callback?error=access_denied&error_code=otp_expired',
        ),
        isEmailConfirmation: true,
        pendingMethod: 'email',
      );

      expect(message, contains('이메일 인증 링크가 만료'));
      expect(message, isNot(contains('소셜')));
    });

    test('keeps social access denial guidance for social pending login', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse('planflow-v2://auth-callback?error=access_denied'),
        pendingMethod: 'kakao',
      );

      expect(message, contains('카카오 동의 화면'));
    });

    test('uses neutral guidance when access denial has no pending method', () {
      final message = OAuthCallbackHandler.callbackErrorMessageFor(
        Uri.parse('planflow-v2://auth-callback?error=access_denied'),
      );

      expect(message, contains('인증이 완료되지 않았습니다'));
      expect(message, isNot(contains('소셜 동의')));
    });
  });
}
