import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/calendar_auto_sync_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/external_calendar_sync_guide_service.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('shows guide when user has not seen it and no calendar is connected',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final service = ExternalCalendarSyncGuideService(
      preferences: preferences,
      calendarSyncService: _FakeCalendarSyncService(
        googleStatus:
            CalendarIntegrationResult.signedOut(CalendarProvider.google),
      ),
      naverCalDavService: _FakeNaverCalDavService(hasSavedCredentials: false),
      calendarAutoSyncService: _FakeCalendarAutoSyncService(
        snapshot: _snapshot(),
      ),
    );

    expect(await service.shouldShowForUser('user-1'), isTrue);
    expect(
      preferences.getBool(
        ExternalCalendarSyncGuideService.guideSeenKey('user-1'),
      ),
      isNull,
    );
  });

  test('skips and marks seen when Google Calendar is already connected',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final service = ExternalCalendarSyncGuideService(
      preferences: preferences,
      calendarSyncService: _FakeCalendarSyncService(
        googleStatus: CalendarIntegrationResult.ready(CalendarProvider.google),
      ),
      naverCalDavService: _FakeNaverCalDavService(hasSavedCredentials: false),
      calendarAutoSyncService: _FakeCalendarAutoSyncService(
        snapshot: _snapshot(),
      ),
    );

    expect(await service.shouldShowForUser('user-1'), isFalse);
    expect(
      preferences.getBool(
        ExternalCalendarSyncGuideService.guideSeenKey('user-1'),
      ),
      isTrue,
    );
  });

  test('skips and marks seen when Naver CalDAV credentials exist', () async {
    final preferences = await SharedPreferences.getInstance();
    final service = ExternalCalendarSyncGuideService(
      preferences: preferences,
      calendarSyncService: _FakeCalendarSyncService(
        googleStatus:
            CalendarIntegrationResult.signedOut(CalendarProvider.google),
      ),
      naverCalDavService: _FakeNaverCalDavService(hasSavedCredentials: true),
      calendarAutoSyncService: _FakeCalendarAutoSyncService(
        snapshot: _snapshot(),
      ),
    );

    expect(await service.shouldShowForUser('user-1'), isFalse);
    expect(
      preferences.getBool(
        ExternalCalendarSyncGuideService.guideSeenKey('user-1'),
      ),
      isTrue,
    );
  });

  test('skips and marks seen when a device calendar sync snapshot is healthy',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final service = ExternalCalendarSyncGuideService(
      preferences: preferences,
      calendarSyncService: _FakeCalendarSyncService(
        googleStatus:
            CalendarIntegrationResult.signedOut(CalendarProvider.google),
      ),
      naverCalDavService: _FakeNaverCalDavService(hasSavedCredentials: false),
      calendarAutoSyncService: _FakeCalendarAutoSyncService(
        snapshot: _snapshot(
          providers: const <CalendarAutoSyncProviderSnapshot>[
            CalendarAutoSyncProviderSnapshot(
              key: 'device_calendar_auto_import',
              label: '휴대폰 내부 캘린더',
              status: 'connected',
              message: '휴대폰 내부 캘린더를 가져왔습니다.',
              checkedAt: null,
              lastSuccessAt: null,
            ),
          ],
        ),
      ),
    );

    expect(await service.shouldShowForUser('user-1'), isFalse);
    expect(
      preferences.getBool(
        ExternalCalendarSyncGuideService.guideSeenKey('user-1'),
      ),
      isTrue,
    );
  });
}

CalendarAutoSyncSnapshot _snapshot({
  List<CalendarAutoSyncProviderSnapshot> providers =
      const <CalendarAutoSyncProviderSnapshot>[],
}) {
  return CalendarAutoSyncSnapshot(
    lastReason: null,
    lastAttemptAt: null,
    completed: const <String>[],
    failed: const <String>[],
    skipped: const <String>[],
    providers: providers,
  );
}

class _FakeCalendarSyncService extends CalendarSyncService {
  _FakeCalendarSyncService({required this.googleStatus});

  final CalendarIntegrationResult googleStatus;

  @override
  Future<CalendarIntegrationResult> getGoogleStatus() async => googleStatus;
}

class _FakeCalendarAutoSyncService extends CalendarAutoSyncService {
  _FakeCalendarAutoSyncService({required this.snapshot});

  final CalendarAutoSyncSnapshot snapshot;

  @override
  Future<CalendarAutoSyncSnapshot> loadSnapshot() async => snapshot;
}

class _FakeNaverCalDavService extends NaverCalDavService {
  _FakeNaverCalDavService({required this.hasSavedCredentials});

  final bool hasSavedCredentials;

  @override
  Future<bool> hasCredentials() async => hasSavedCredentials;
}
