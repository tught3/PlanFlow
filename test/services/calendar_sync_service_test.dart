import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:planflow/services/calendar_sync_service.dart';

void main() {
  group('CalendarSyncService', () {
    test('returns scaffold states without requiring Google credentials',
        () async {
      final service = CalendarSyncService();

      final status = await service.fetchStatus();

      expect(status.google.status, CalendarIntegrationStatus.notConfigured);
      expect(status.google.provider, CalendarProvider.google);
      expect(status.naver.status, CalendarIntegrationStatus.unsupported);
      expect(status.naver.provider, CalendarProvider.naver);
    });

    test('returns a clear placeholder result for Naver sync', () async {
      final service = CalendarSyncService();

      final result = await service.syncNaverCalendar();

      expect(result.status, CalendarIntegrationStatus.unsupported);
      expect(result.message, contains('현재 사용할 수 없습니다'));
      expect(result.provider, CalendarProvider.naver);
      expect(result.isSuccess, isFalse);
    });

    test('does not call Google sign-in on unsupported platforms', () async {
      final service = CalendarSyncService(
        googleClientId: 'test-client-id',
        googlePlatformSupported: false,
        googleTargetPlatform: TargetPlatform.windows,
      );

      final status = await service.getGoogleStatus();
      final sync = await service.syncGoogleCalendar(interactive: false);

      expect(status.status, CalendarIntegrationStatus.unsupported);
      expect(sync.status, CalendarIntegrationStatus.unsupported);
      expect(status.provider, CalendarProvider.google);
      expect(sync.provider, CalendarProvider.google);
    });

    test('treats blank Google client configuration as not configured',
        () async {
      final service = CalendarSyncService(
        googleClientId: '   ',
        googleServerClientId: '',
        googlePlatformSupported: true,
      );

      final status = await service.getGoogleStatus();

      expect(status.status, CalendarIntegrationStatus.notConfigured);
      expect(status.provider, CalendarProvider.google);
    });

    test(
        'returns notConfigured on Android when serverClientId is missing even if clientId exists',
        () async {
      final googleSignIn = _FakeGoogleSignIn();
      final service = CalendarSyncService(
        googleClientId: 'android-client-id',
        googleSignIn: googleSignIn,
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.notConfigured);
      expect(result.message, contains('Web OAuth Client ID'));
      expect(googleSignIn.signInCallCount, 0);
    });

    test('enters Google sign-in path on Android when serverClientId exists',
        () async {
      final googleSignIn = _FakeGoogleSignIn();
      final service = CalendarSyncService(
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googleSignIn: googleSignIn,
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.signedOut);
      expect(googleSignIn.signInCallCount, 1);
    });

    test('classifies Google sign-in cancellation with actionable message',
        () async {
      final service = CalendarSyncService(
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) {
          throw const PlatformException(
            code: 'sign_in_canceled',
            message: 'The user canceled sign-in.',
          );
        },
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.failed);
      expect(result.message, contains('취소'));
      expect(result.message, contains('Calendar 권한'));
    });

    test('classifies Google OAuth configuration failures clearly', () async {
      final service = CalendarSyncService(
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) {
          throw const PlatformException(
            code: 'sign_in_failed',
            message: 'ApiException: 10',
          );
        },
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.failed);
      expect(result.message, contains('OAuth 설정'));
      expect(result.message, contains('Android SHA'));
    });
  });
}

class _FakeGoogleSignIn extends GoogleSignIn {
  _FakeGoogleSignIn() : super(scopes: const <String>[]);

  int signInCallCount = 0;

  @override
  Future<GoogleSignInAccount?> signIn() async {
    signInCallCount += 1;
    return null;
  }
}
