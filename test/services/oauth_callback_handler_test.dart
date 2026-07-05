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
  });

  // -----------------------------------------------------------------------
  // shouldAdoptExistingSessionForCallback 회귀 테스트
  // -----------------------------------------------------------------------
  group('shouldAdoptExistingSessionForCallback', () {
    // 교차 오염 케이스: 로그인 pending + 기존 세션 존재 → 채택 금지
    test(
        'login pending + pre-existing session (no calendar/recovery/email) '
        '=> must NOT adopt (returns false)', () {
      expect(
        OAuthCallbackHandler.shouldAdoptExistingSessionForCallback(
          pendingPurpose: OAuthCallbackPurpose.login,
          currentSessionPresent: true,
          isPasswordRecovery: false,
          isEmailConfirmation: false,
          hasPendingCalendarLink: false,
        ),
        isFalse,
      );
    });

    // 정상 단일 로그인: 세션 없음 → 채택 허용
    test('login pending + no pre-existing session => adopt (true)', () {
      expect(
        OAuthCallbackHandler.shouldAdoptExistingSessionForCallback(
          pendingPurpose: OAuthCallbackPurpose.login,
          currentSessionPresent: false,
          isPasswordRecovery: false,
          isEmailConfirmation: false,
          hasPendingCalendarLink: false,
        ),
        isTrue,
      );
    });

    // 캘린더 연동 pending + 세션 존재 → 기존 동작 유지(채택 허용)
    test('calendarLink pending + session present => adopt/allowed (true)', () {
      expect(
        OAuthCallbackHandler.shouldAdoptExistingSessionForCallback(
          pendingPurpose: OAuthCallbackPurpose.calendarLink,
          currentSessionPresent: true,
          isPasswordRecovery: false,
          isEmailConfirmation: false,
          hasPendingCalendarLink: true,
        ),
        isTrue,
      );
    });

    // 비밀번호 복구 → 채택 허용
    test('passwordRecovery => adopt allowed (true)', () {
      expect(
        OAuthCallbackHandler.shouldAdoptExistingSessionForCallback(
          pendingPurpose: OAuthCallbackPurpose.login,
          currentSessionPresent: true,
          isPasswordRecovery: true,
          isEmailConfirmation: false,
          hasPendingCalendarLink: false,
        ),
        isTrue,
      );
    });

    // 이메일 인증 → 채택 허용
    test('emailConfirmation => adopt allowed (true)', () {
      expect(
        OAuthCallbackHandler.shouldAdoptExistingSessionForCallback(
          pendingPurpose: OAuthCallbackPurpose.emailConfirmation,
          currentSessionPresent: true,
          isPasswordRecovery: false,
          isEmailConfirmation: true,
          hasPendingCalendarLink: false,
        ),
        isTrue,
      );
    });

    // pending 없음(만료·소비) + 세션 존재 → 중복 콜백으로 채택 허용
    test(
        'no pending (null) + session present '
        '=> adopt (true) — duplicate/stale callback', () {
      expect(
        OAuthCallbackHandler.shouldAdoptExistingSessionForCallback(
          pendingPurpose: null,
          currentSessionPresent: true,
          isPasswordRecovery: false,
          isEmailConfirmation: false,
          hasPendingCalendarLink: false,
        ),
        isTrue,
      );
    });

    // pending 없음 + 세션 없음 → 채택 허용
    test('no pending (null) + no session => adopt (true)', () {
      expect(
        OAuthCallbackHandler.shouldAdoptExistingSessionForCallback(
          pendingPurpose: null,
          currentSessionPresent: false,
          isPasswordRecovery: false,
          isEmailConfirmation: false,
          hasPendingCalendarLink: false,
        ),
        isTrue,
      );
    });
  });
}
