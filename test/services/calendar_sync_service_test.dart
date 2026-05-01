import 'package:flutter_test/flutter_test.dart';

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
      expect(result.message, contains('placeholder'));
      expect(result.provider, CalendarProvider.naver);
      expect(result.isSuccess, isFalse);
    });

    test('does not call Google sign-in on unsupported platforms', () async {
      final service = CalendarSyncService(
        googleClientId: 'test-client-id',
        googlePlatformSupported: false,
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
  });
}
