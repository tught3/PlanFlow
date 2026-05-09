import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/calendar_auto_sync_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/device_calendar_service.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppEnv.markSupabaseInitialized();
    authProvider.setUser('user-1');
  });

  tearDown(() {
    authProvider.setUser(null);
  });

  test('syncConnectedCalendars records skipped providers separately', () async {
    final service = CalendarAutoSyncService(
      calendarSyncService: _FakeCalendarSyncService(
        googleResult: CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: 'Google Calendar가 연결되어 있지 않아 건너뜁니다.',
        ),
        naverResult: CalendarIntegrationResult.synced(
          CalendarProvider.naver,
          message: 'Naver Calendar로 보낼 예정 일정이 없습니다.',
        ),
      ),
      naverCalDavService: _FakeNaverCalDavService(
        hasSavedCredentials: false,
      ),
      deviceCalendarService: _FakeDeviceCalendarService(
        hasPermission: false,
      ),
      throttle: Duration.zero,
      now: () => DateTime(2026, 5, 9, 9),
    );

    final result = await service.syncConnectedCalendars(force: true);
    final snapshot = await service.loadSnapshot();

    expect(result.completed, contains('naver_api_auto_export'));
    expect(result.skipped, contains('google_auto_sync'));
    expect(result.skipped, contains('naver_caldav_auto_import'));
    expect(result.skipped, contains('device_calendar_auto_import'));
    expect(result.failed, isEmpty);

    final google = snapshot.provider('google_auto_sync');
    final calDav = snapshot.provider('naver_caldav_auto_import');
    final device = snapshot.provider('device_calendar_auto_import');
    expect(google.status, 'skipped');
    expect(calDav.status, 'skipped');
    expect(
      calDav.message,
      'Naver CalDAV가 아직 연결되지 않아 자동 가져오기를 건너뜁니다.',
    );
    expect(device.status, 'skipped');
    expect(
      device.message,
      '휴대폰 캘린더 권한이 없어 자동 가져오기를 건너뜁니다.',
    );
  });

  test('syncConnectedCalendars records attention for reauth and import errors',
      () async {
    final service = CalendarAutoSyncService(
      calendarSyncService: _FakeCalendarSyncService(
        googleResult: CalendarIntegrationResult.reauthRequired(
          CalendarProvider.google,
          message: 'Google Calendar 재인증이 필요합니다.',
        ),
        naverResult: CalendarIntegrationResult.failed(
          CalendarProvider.naver,
          error: 'permission-check-failed',
          message: 'Naver Calendar 권한 확인에 실패했습니다.',
        ),
      ),
      naverCalDavService: _FakeNaverCalDavService(
        hasSavedCredentials: true,
        syncResult: const NaverCalDavSyncResult(
          success: false,
          message: 'Naver CalDAV 앱 비밀번호를 확인해 주세요.',
        ),
      ),
      deviceCalendarService: _FakeDeviceCalendarService(
        hasPermission: true,
        importResult: const DeviceCalendarImportResult(
          status: DeviceCalendarImportStatus.permissionDenied,
          message: '기기 캘린더 권한이 필요합니다.',
        ),
      ),
      throttle: Duration.zero,
      now: () => DateTime(2026, 5, 9, 10),
    );

    final result = await service.syncConnectedCalendars(force: true);
    final snapshot = await service.loadSnapshot();

    expect(result.failed, contains('google_auto_sync'));
    expect(result.failed, contains('naver_api_auto_export'));
    expect(result.failed, contains('naver_caldav_auto_import'));
    expect(result.failed, contains('device_calendar_auto_import'));
    expect(snapshot.provider('google_auto_sync').status, 'attention');
    expect(snapshot.provider('naver_api_auto_export').status, 'attention');
    expect(snapshot.provider('naver_caldav_auto_import').message,
        'Naver CalDAV 앱 비밀번호를 확인해 주세요.');
    expect(
        snapshot.provider('device_calendar_auto_import').status, 'attention');
  });
}

extension on CalendarAutoSyncSnapshot {
  CalendarAutoSyncProviderSnapshot provider(String key) {
    return providers.singleWhere((provider) => provider.key == key);
  }
}

class _FakeCalendarSyncService extends CalendarSyncService {
  _FakeCalendarSyncService({
    required this.googleResult,
    required this.naverResult,
  }) : super(
          naverStatusProvider: () async {
            return const NaverCalendarPermissionResult(
              status: NaverCalendarPermissionStatus.granted,
              message: '테스트 권한 상태',
            );
          },
          naverAccessTokenProvider: () async => 'naver-token',
          naverStatusSaver: (_) async {},
        );

  final CalendarIntegrationResult googleResult;
  final CalendarIntegrationResult naverResult;

  @override
  Future<CalendarIntegrationResult> syncGoogleCalendar({
    bool interactive = true,
  }) async {
    return googleResult;
  }

  @override
  Future<CalendarIntegrationResult> syncNaverCalendar() async {
    return naverResult;
  }
}

class _FakeNaverCalDavService extends NaverCalDavService {
  _FakeNaverCalDavService({
    required this.hasSavedCredentials,
    this.syncResult = const NaverCalDavSyncResult(
      success: true,
      message: '네이버 CalDAV 일정이 최신입니다.',
    ),
  });

  final bool hasSavedCredentials;
  final NaverCalDavSyncResult syncResult;

  @override
  Future<bool> hasCredentials() async => hasSavedCredentials;

  @override
  Future<NaverCalDavSyncResult> syncAll({
    String? userId,
    DateTime? from,
    DateTime? to,
    NaverCalDavSyncMode mode = NaverCalDavSyncMode.custom,
    bool skipUnchanged = true,
    bool diagnosticImport = false,
    NaverCalDavProgressCallback? onProgress,
  }) async {
    return syncResult;
  }
}

class _FakeDeviceCalendarService extends DeviceCalendarService {
  _FakeDeviceCalendarService({
    required this.hasPermission,
    this.importResult = const DeviceCalendarImportResult(
      status: DeviceCalendarImportStatus.noEvents,
      message: '휴대폰 내부 캘린더에서 가져올 일정이 없습니다.',
    ),
  }) : super(
          gateway: _FakeDeviceCalendarGateway(hasPermission),
          eventRepository: _FakeEventRepository(),
          currentUserId: 'user-1',
        );

  final bool hasPermission;
  final DeviceCalendarImportResult importResult;

  @override
  Future<bool> checkCalendarPermission() async => hasPermission;

  @override
  Future<DeviceCalendarImportResult> importNaverEvents({
    String? userId,
    DateTime? startAt,
    DateTime? endAt,
  }) async {
    return importResult;
  }
}

class _FakeDeviceCalendarGateway implements DeviceCalendarGateway {
  const _FakeDeviceCalendarGateway(this.hasPermission);

  final bool hasPermission;

  @override
  Future<bool> checkCalendarPermission() async => hasPermission;

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendarEvents({
    required List<String> calendarIds,
    required DateTime startAt,
    required DateTime endAt,
  }) async {
    return const [];
  }

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendars() async => const [];

  @override
  Future<bool> requestCalendarPermission() async => hasPermission;

  @override
  Future<bool> upsertDeviceCalendarEvent(EventModel event) async => true;
}

class _FakeEventRepository extends EventRepository {
  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => const [];

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}
