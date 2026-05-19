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

  test('syncConnectedCalendars keeps throttling across a new service instance',
      () async {
    final firstService = CalendarAutoSyncService(
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
        hasPermission: false,
      ),
      eventRepository: _FakeEventRepository(),
      throttle: const Duration(minutes: 15),
      now: () => DateTime(2026, 5, 9, 9, 0),
    );

    final firstResult = await firstService.syncConnectedCalendars();
    expect(firstResult.didRun, isTrue);

    final secondCalendarSyncService = _FakeCalendarSyncService(
      googleResult: CalendarIntegrationResult.synced(CalendarProvider.google),
      naverResult: CalendarIntegrationResult.synced(CalendarProvider.naver),
    );
    final secondNaverCalDavService = _FakeNaverCalDavService(
      hasSavedCredentials: true,
    );
    final secondDeviceCalendarService = _FakeDeviceCalendarService(
      hasPermission: true,
    );
    final secondService = CalendarAutoSyncService(
      calendarSyncService: secondCalendarSyncService,
      naverCalDavService: secondNaverCalDavService,
      deviceCalendarService: secondDeviceCalendarService,
      eventRepository: _FakeEventRepository(),
      throttle: const Duration(minutes: 15),
      now: () => DateTime(2026, 5, 9, 9, 5),
    );

    final secondResult = await secondService.syncConnectedCalendars();

    expect(secondResult.skippedReason, 'throttled');
    expect(secondCalendarSyncService.googleSyncCallCount, 0);
    expect(secondCalendarSyncService.naverSyncCallCount, 0);
    expect(secondNaverCalDavService.syncAllCallCount, 0);
    expect(secondDeviceCalendarService.importCallCount, 0);
  });

  test(
      'syncConnectedCalendars ignores unfinished background start for throttle',
      () async {
    SharedPreferences.setMockInitialValues({
      'calendar_sync:last_started_at': '2026-05-09T09:00:00.000',
    });
    final calendarSyncService = _FakeCalendarSyncService(
      googleResult: CalendarIntegrationResult.synced(CalendarProvider.google),
      naverResult: CalendarIntegrationResult.synced(CalendarProvider.naver),
    );
    final naverCalDavService = _FakeNaverCalDavService(
      hasSavedCredentials: true,
    );
    final deviceCalendarService = _FakeDeviceCalendarService(
      hasPermission: true,
    );
    final service = CalendarAutoSyncService(
      calendarSyncService: calendarSyncService,
      naverCalDavService: naverCalDavService,
      deviceCalendarService: deviceCalendarService,
      eventRepository: _FakeEventRepository(),
      throttle: const Duration(minutes: 15),
      now: () => DateTime(2026, 5, 9, 9, 5),
    );

    final result = await service.syncConnectedCalendars(reason: 'resume');

    expect(result.didRun, isTrue);
    expect(calendarSyncService.googleSyncCallCount, 1);
    expect(calendarSyncService.naverSyncCallCount, 1);
    expect(naverCalDavService.syncAllCallCount, 1);
    expect(deviceCalendarService.importCallCount, 1);
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

  test(
      'syncConnectedCalendars resyncs preparation for imported external events',
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

    expect(sideEffects.reminderResyncCallCount, 1);
    expect(sideEffects.lastReminderEvents.map((event) => event.id), [
      'event-2',
      'event-1',
    ]);
    expect(sideEffects.alarmRecalculateCallCount, 1);
    expect(sideEffects.lastAlarmEvents.map((event) => event.id), [
      'event-2',
      'event-1',
    ]);
    expect(
      sideEffects.lastExtraDepartureEventIdsToCancel,
      containsAll(<String>['event-1', 'event-2']),
    );
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
          locationLat: 37.7563,
          locationLng: 128.8758,
          source: 'naver_device',
        ),
        EventModel(
          id: 'within-7d-outside-24h',
          userId: 'user-1',
          title: '교보생명 시험',
          startAt: DateTime(2026, 5, 12, 10),
          location: '교보생명',
          locationLat: 37.5702,
          locationLng: 126.9779,
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
    expect(sideEffects.alarmRecalculateCallCount, 1);
    expect(
      sideEffects.lastAlarmEvents.map((event) => event.id),
      containsAll(<String>['within-24h', 'within-7d-outside-24h']),
    );
    expect(
      sideEffects.lastExtraDepartureEventIdsToCancel,
      containsAll(<String>[
        'within-24h',
        'within-7d-outside-24h',
        'past',
        'after-7d',
      ]),
    );
    expect(resyncedEventIds, contains('within-24h'));
    expect(resyncedEventIds, contains('within-7d-outside-24h'));
    expect(resyncedEventIds, isNot(contains('past')));
    expect(resyncedEventIds, isNot(contains('after-7d')));
    expect(preparation.preparedEventIds, ['within-24h']);
  });

  test(
      'syncConnectedCalendars still cancels stale departures when none upcoming',
      () async {
    final repository = _FakeEventRepository(
      events: <EventModel>[
        EventModel(
          id: 'moved-past',
          userId: 'user-1',
          title: '지난 외부 일정',
          startAt: DateTime(2026, 5, 9, 8),
          location: '대전역',
          locationLat: 36.332,
          locationLng: 127.434,
          source: 'naver_device',
        ),
        EventModel(
          id: 'after-7d',
          userId: 'user-1',
          title: '먼 외부 일정',
          startAt: DateTime(2026, 5, 20, 16),
          location: '부산역',
          locationLat: 35.115,
          locationLng: 129.042,
          source: 'naver_device',
        ),
      ],
    );
    final sideEffects = _FakeManualEventSideEffectService();
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
        hasPermission: false,
      ),
      eventRepository: repository,
      sideEffectService: sideEffects,
      eventPreparationService: _FakeEventPreparationService(),
      throttle: Duration.zero,
      now: () => DateTime(2026, 5, 10, 12),
    );

    await service.syncConnectedCalendars(force: true);

    expect(sideEffects.alarmRecalculateCallCount, 1);
    expect(sideEffects.lastAlarmEvents, isEmpty);
    expect(
      sideEffects.lastExtraDepartureEventIdsToCancel,
      containsAll(<String>['moved-past', 'after-7d']),
    );
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
  int googleSyncCallCount = 0;
  int naverSyncCallCount = 0;

  @override
  Future<CalendarIntegrationResult> syncGoogleCalendar({
    bool interactive = true,
  }) async {
    googleSyncCallCount += 1;
    return googleResult;
  }

  @override
  Future<CalendarIntegrationResult> syncNaverCalendar() async {
    naverSyncCallCount += 1;
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
  }) : super(credentialStore: const _FakeNaverCalDavCredentialStore());

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

class _FakeNaverCalDavCredentialStore implements NaverCalDavCredentialStore {
  const _FakeNaverCalDavCredentialStore();

  @override
  Future<void> clearCredentials() async {}

  @override
  Future<NaverCalDavCredentials?> readCredentials() async => null;

  @override
  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  }) async {}
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
  int importCallCount = 0;

  @override
  Future<bool> checkCalendarPermission() async => hasPermission;

  @override
  Future<DeviceCalendarImportResult> importNaverEvents({
    String? userId,
    DateTime? startAt,
    DateTime? endAt,
  }) async {
    importCallCount += 1;
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
    return events
        .where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeManualEventSideEffectService extends ManualEventSideEffectService {
  int resyncCallCount = 0;
  int reminderResyncCallCount = 0;
  int alarmRecalculateCallCount = 0;
  List<EventModel> lastDayEvents = const <EventModel>[];
  List<EventModel> lastReminderEvents = const <EventModel>[];
  List<EventModel> lastAlarmEvents = const <EventModel>[];
  Set<String> lastExtraDepartureEventIdsToCancel = const <String>{};
  String? lastUserId;
  final List<List<String>> dayEventIdsByCall = <List<String>>[];

  @override
  Future<bool> resyncRemindersForEvents({
    required Iterable<EventModel> events,
    required String userId,
    Duration? reminderOffset =
        ManualEventSideEffectService.defaultReminderOffset,
    Duration? criticalAlarmOffset =
        ManualEventSideEffectService.criticalAlarmOffset,
  }) async {
    reminderResyncCallCount += 1;
    lastReminderEvents = events.toList(growable: false);
    lastUserId = userId;
    return true;
  }

  @override
  Future<bool> resyncExternalPreparationForDay({
    required Iterable<EventModel> dayEvents,
    required String userId,
    required DateTime dayReference,
    int prepTimeMin = 30,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    int travelMinutes = 30,
    String travelMode = 'car',
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

  @override
  Future<ManualEventAlarmRecalculationResult> recalculateAlarmsForEvents({
    required Iterable<EventModel> events,
    required String userId,
    DateTime? now,
    DateTime? until,
    Iterable<String> extraDepartureEventIdsToCancel = const <String>[],
    bool resyncDepartureAlarms = true,
    int prepTimeMin = 30,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    String travelMode = 'car',
  }) async {
    alarmRecalculateCallCount += 1;
    lastAlarmEvents = events.toList(growable: false);
    lastExtraDepartureEventIdsToCancel = extraDepartureEventIdsToCancel.toSet();
    lastUserId = userId;
    final dayGroups = <String, List<EventModel>>{};
    for (final event in lastAlarmEvents) {
      final startAt = event.startAt;
      if (startAt == null) {
        continue;
      }
      final key = '${startAt.year}-${startAt.month}-${startAt.day}';
      dayGroups.putIfAbsent(key, () => <EventModel>[]).add(event);
    }
    for (final dayEvents in dayGroups.values) {
      await resyncExternalPreparationForDay(
        dayEvents: dayEvents,
        userId: userId,
        dayReference: dayEvents.first.startAt!,
        travelMode: travelMode,
        now: now,
      );
    }
    return ManualEventAlarmRecalculationResult(
      preparationDays: dayGroups.length,
      departureScheduled: resyncDepartureAlarms
          ? lastAlarmEvents
              .where((event) =>
                  event.locationLat != null && event.locationLng != null)
              .length
          : 0,
    );
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
