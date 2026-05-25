import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/oauth_callback_handler.dart';

void main() {
  group('OAuthCallbackHandler', () {
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
  });
}
