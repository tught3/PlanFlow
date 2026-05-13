import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/calendar_auto_sync_service.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/device_calendar_service.dart';
import 'package:planflow/services/event_preparation_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
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
      eventRepository: _FakeEventRepository(),
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

  test('syncConnectedCalendars imports Naver CalDAV when credentials exist',
      () async {
    final naverCalDav = _FakeNaverCalDavService(
      hasSavedCredentials: true,
      syncResult: const NaverCalDavSyncResult(
        success: true,
        message: '네이버 CalDAV 자동 가져오기를 완료했습니다.',
      ),
    );
    final service = CalendarAutoSyncService(
      calendarSyncService: _FakeCalendarSyncService(
        googleResult: CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: 'Google Calendar가 연결되어 있지 않아 건너뜁니다.',
        ),
        naverResult: CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver 직접 연동이 연결되어 있지 않아 건너뜁니다.',
        ),
      ),
      naverCalDavService: naverCalDav,
      deviceCalendarService: _FakeDeviceCalendarService(
        hasPermission: false,
      ),
      eventRepository: _FakeEventRepository(),
      throttle: Duration.zero,
      now: () => DateTime(2026, 5, 9, 9, 30),
    );

    final result = await service.syncConnectedCalendars(force: true);
    final snapshot = await service.loadSnapshot();

    expect(naverCalDav.syncAllCallCount, 1);
    expect(result.completed, contains('naver_caldav_auto_import'));
    expect(
      snapshot.provider('naver_caldav_auto_import').message,
      '네이버 CalDAV 자동 가져오기를 완료했습니다.',
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
      eventRepository: _FakeEventRepository(),
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

  test('syncConnectedCalendars resyncs preparation for imported external events',
      () async {
    final tomorrowExternalEvent = EventModel(
      id: 'event-1',
      userId: 'user-1',
      title: '아이스크림 전달',
      startAt: DateTime(2026, 5, 10, 9),
      location: '강릉아산병원',
      source: 'naver_device',
    );
    final repository = _FakeEventRepository(
      events: <EventModel>[
        tomorrowExternalEvent,
        EventModel(
          id: 'event-2',
          userId: 'user-1',
          title: '전화하기',
          startAt: DateTime(2026, 5, 10, 8),
          source: 'manual',
        ),
      ],
    );
    final sideEffects = _FakeManualEventSideEffectService();
    final preparation = _FakeEventPreparationService();
    final service = CalendarAutoSyncService(
      calendarSyncService: _FakeCalendarSyncService(
        googleResult: CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: 'Google Calendar가 연결되어 있지 않아 건너뜁니다.',
        ),
        naverResult: CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver 직접 연동이 연결되어 있지 않아 건너뜁니다.',
        ),
      ),
      naverCalDavService: _FakeNaverCalDavService(
        hasSavedCredentials: false,
      ),
      deviceCalendarService: _FakeDeviceCalendarService(
        hasPermission: true,
        importResult: const DeviceCalendarImportResult(
          status: DeviceCalendarImportStatus.imported,
          message: '휴대폰 내부 캘린더 일정 1개를 PlanFlow로 가져왔습니다.',
        ),
      ),
      eventRepository: repository,
      sideEffectService: sideEffects,
      eventPreparationService: preparation,
      throttle: Duration.zero,
      now: () => DateTime(2026, 5, 9, 15),
    );

    await service.syncConnectedCalendars(force: true);

    expect(sideEffects.resyncCallCount, 1);
    expect(sideEffects.lastDayEvents.map((event) => event.id),
        containsAll(<String>['event-1', 'event-2']));
    expect(preparation.preparedEventIds, contains('event-1'));
    expect(preparation.preparedEventIds, isNot(contains('event-2')));
    expect(repository.requestedUserIds, everyElement('user-1'));
    expect(sideEffects.lastUserId, 'user-1');
  });

  test('syncConnectedCalendars limits preparation resync and departure window',
      () async {
    final repository = _FakeEventRepository(
      events: <EventModel>[
        EventModel(
          id: 'within-24h',
          userId: 'user-1',
          title: '강릉아산병원 방문',
          startAt: DateTime(2026, 5, 10, 8),
          location: '강릉아산병원',
          source: 'naver_device',
        ),
        EventModel(
          id: 'within-7d-outside-24h',
          userId: 'user-1',
          title: '교보생명 시험',
          startAt: DateTime(2026, 5, 12, 10),
          location: '교보생명',
          source: 'naver_caldav',
        ),
        EventModel(
          id: 'past',
          userId: 'user-1',
          title: '지난 외부 일정',
          startAt: DateTime(2026, 5, 9, 8),
          location: '대전역',
          source: 'naver_device',
        ),
        EventModel(
          id: 'after-7d',
          userId: 'user-1',
          title: '먼 외부 일정',
          startAt: DateTime(2026, 5, 17, 16, 1),
          location: '부산역',
          source: 'naver_device',
        ),
      ],
    );
    final sideEffects = _FakeManualEventSideEffectService();
    final preparation = _FakeEventPreparationService();
    final service = CalendarAutoSyncService(
      calendarSyncService: _FakeCalendarSyncService(
        googleResult: CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: 'Google Calendar가 연결되어 있지 않아 건너뜁니다.',
        ),
        naverResult: CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver 직접 연동이 연결되어 있지 않아 건너뜁니다.',
        ),
      ),
      naverCalDavService: _FakeNaverCalDavService(
        hasSavedCredentials: false,
      ),
      deviceCalendarService: _FakeDeviceCalendarService(
        hasPermission: true,
        importResult: const DeviceCalendarImportResult(
          status: DeviceCalendarImportStatus.imported,
          message: '휴대폰 내부 캘린더 일정 1개를 PlanFlow로 가져왔습니다.',
        ),
      ),
      eventRepository: repository,
      sideEffectService: sideEffects,
      eventPreparationService: preparation,
      throttle: Duration.zero,
      now: () => DateTime(2026, 5, 10, 7),
    );

    await service.syncConnectedCalendars(force: true);

    final resyncedEventIds =
        sideEffects.dayEventIdsByCall.expand((ids) => ids).toSet();
    expect(resyncedEventIds, contains('within-24h'));
    expect(resyncedEventIds, contains('within-7d-outside-24h'));
    expect(resyncedEventIds, isNot(contains('past')));
    expect(resyncedEventIds, isNot(contains('after-7d')));
    expect(preparation.preparedEventIds, ['within-24h']);
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
  int syncAllCallCount = 0;

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
    syncAllCallCount += 1;
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
  _FakeEventRepository({this.events = const <EventModel>[]});

  final List<EventModel> events;
  final requestedUserIds = <String?>[];

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    requestedUserIds.add(userId);
    return events.where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeManualEventSideEffectService extends ManualEventSideEffectService {
  int resyncCallCount = 0;
  List<EventModel> lastDayEvents = const <EventModel>[];
  String? lastUserId;
  final List<List<String>> dayEventIdsByCall = <List<String>>[];

  @override
  Future<bool> resyncExternalPreparationForDay({
    required Iterable<EventModel> dayEvents,
    required String userId,
    required DateTime dayReference,
    int prepTimeMin = 30,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    int travelMinutes = 30,
    DateTime? now,
  }) async {
    resyncCallCount += 1;
    lastDayEvents = dayEvents.toList(growable: false);
    lastUserId = userId;
    dayEventIdsByCall.add(
      lastDayEvents.map((event) => event.id).toList(growable: false),
    );
    return true;
  }
}

class _FakeEventPreparationService extends EventPreparationService {
  final List<String> preparedEventIds = <String>[];

  @override
  Future<EventPreparationResult> prepareAfterSave(EventModel event) async {
    preparedEventIds.add(event.id);
    return EventPreparationResult(
      event: event,
      locationResolved: false,
      travelEstimateCount: 0,
    );
  }
}
