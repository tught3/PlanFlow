import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('schedules departure alarm from live route estimate plus safety margin',
      () async {
    final now = DateTime(2026, 5, 8, 9);
    final notifications = _FakeNotificationService();
    final preflight = _FakeDeparturePreflightScheduler();
    final service = DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 90),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      preflightScheduler: preflight.call,
      now: () => now,
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '성심당',
        startAt: DateTime(2026, 5, 8, 12),
        location: '대전 성심당',
        locationLat: 36.327,
        locationLng: 127.427,
      ),
      rescheduleMonitor: false,
    );

    expect(result.isScheduled, isTrue);
    expect(result.travelMinutes, 90);
    expect(result.notifyAt, DateTime(2026, 5, 8, 10, 10));
    expect(preflight.eventIds.single, 'event-1');
    expect(preflight.preflightTimes.single, DateTime(2026, 5, 8, 10, 10));
    expect(preflight.safetyMargins.single, const Duration(minutes: 20));
    expect(notifications.criticalTitles, isEmpty);
    expect(notifications.payloads, isEmpty);

    final status = await service.loadRuntimeStatus();
    expect(status.lastEventId, 'event-1');
    expect(status.lastEventTitle, '성심당');
    expect(status.lastStatus, 'scheduled');
    expect(status.lastNotifyAt, DateTime(2026, 5, 8, 10, 10));
    expect(status.lastTravelMinutes, 90);
  });

  test('uses caller-supplied safety margin when computing departure time',
      () async {
    final now = DateTime(2026, 5, 8, 9);
    final notifications = _FakeNotificationService();
    final preflight = _FakeDeparturePreflightScheduler();
    final service = DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 90),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      preflightScheduler: preflight.call,
      now: () => now,
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-2',
        userId: 'user-1',
        title: '테스트 일정',
        startAt: DateTime(2026, 5, 8, 12),
        location: '테스트 위치',
        locationLat: 36.327,
        locationLng: 127.427,
      ),
      rescheduleMonitor: false,
      safetyMarginOverride: const Duration(minutes: 20),
    );

    expect(result.isScheduled, isTrue);
    expect(result.notifyAt, DateTime(2026, 5, 8, 10, 10));
    expect(preflight.safetyMargins.single, const Duration(minutes: 20));
    expect(notifications.criticalBodies, isEmpty);
  });

  test('skips events without geocoded destination', () async {
    final service = DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      notificationService: _FakeNotificationService(),
      now: () => DateTime(2026, 5, 8, 9),
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '성심당',
        startAt: DateTime(2026, 5, 8, 12),
        location: '대전 성심당',
      ),
      rescheduleMonitor: false,
    );

    expect(result.isScheduled, isFalse);
    expect(result.skippedReason, 'missing_destination');

    final status = await service.loadRuntimeStatus();
    expect(status.lastEventId, 'event-1');
    expect(status.lastStatus, 'skipped');
    expect(status.lastSkippedReason, 'missing_destination');
    expect(status.lastNotifyAt, isNull);
  });

  test('acknowledged departures are skipped and cancel their artifacts',
      () async {
    final notifications = _FakeNotificationService();
    final cancelledAlarmIds = <int>[];
    final service = DepartureAlarmService(
      notificationService: notifications,
      preflightCanceller: (alarmId) async {
        cancelledAlarmIds.add(alarmId);
        return true;
      },
      now: () => DateTime(2026, 5, 8, 9),
    );

    await service.acknowledgeDeparture('event-ack');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('departure_alarm:ack:event-ack'), isTrue);
    expect(
      notifications.cancelledNotificationIds,
      contains(notifications.notificationIdFor('event-ack:departure')),
    );
    expect(cancelledAlarmIds, isNotEmpty);

    final skippedSchedule = await service.scheduleForEvent(
      EventModel(
        id: 'event-ack',
        userId: 'user-1',
        title: '출발 확인됨',
        startAt: DateTime(2026, 5, 8, 12),
        location: '장소',
        locationLat: 36.327,
        locationLng: 127.427,
      ),
      rescheduleMonitor: false,
    );

    expect(skippedSchedule.isScheduled, isFalse);
    expect(skippedSchedule.skippedReason, 'departure_acknowledged');
    expect(notifications.titles, isEmpty);
    expect(notifications.criticalTitles, isEmpty);
  });

  test('runPreflightForEvent skips acknowledged departures', () async {
    SharedPreferences.setMockInitialValues({
      'departure_alarm:ack:event-ack': true,
    });
    AppEnv.markSupabaseInitialized();
    final notifications = _FakeNotificationService();
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-ack',
            userId: 'user-1',
            title: '출발 확인됨',
            startAt: DateTime(2026, 5, 8, 12),
            location: '장소',
            locationLat: 36.327,
            locationLng: 127.427,
          ),
        ],
      ),
      notificationService: notifications,
      preflightScheduler: _FakeDeparturePreflightScheduler().call,
      now: () => DateTime(2026, 5, 8, 9),
    );

    final result = await service.runPreflightForEvent(
      'event-ack',
      userId: 'user-1',
    );

    expect(result.isScheduled, isFalse);
    expect(result.skippedReason, 'departure_acknowledged');
    expect(notifications.criticalTitles, isEmpty);
  });

  test('falls back to normal notification when critical channel is blocked',
      () async {
    final now = DateTime(2026, 5, 8, 9);
    final notifications = _FakeNotificationService(blockCritical: true);
    final service = DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 90),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      preflightScheduler:
          _FakeDeparturePreflightScheduler(shouldSchedule: false).call,
      now: () => now,
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '성심당',
        startAt: DateTime(2026, 5, 8, 12),
        location: '대전 성심당',
        locationLat: 36.327,
        locationLng: 127.427,
      ),
      rescheduleMonitor: false,
    );

    expect(result.isScheduled, isTrue);
    expect(notifications.criticalTitles.single, '지금 출발해야 해요');
    expect(notifications.titles.single, '지금 출발해야 해요');
    expect(notifications.payloads.single, 'departure:event-1');
  });

  test('preflight fires visible departure alarm when recalculated time is due',
      () async {
    AppEnv.markSupabaseInitialized();
    final now = DateTime(2026, 5, 8, 10, 10);
    final notifications = _FakeNotificationService();
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '성심당',
            startAt: DateTime(2026, 5, 8, 12),
            location: '대전 성심당',
            locationLat: 36.327,
            locationLng: 127.427,
          ),
        ],
      ),
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 90),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      preflightScheduler: _FakeDeparturePreflightScheduler().call,
      now: () => now,
    );

    final result = await service.runPreflightForEvent(
      'event-1',
      userId: 'user-1',
    );

    expect(result.isScheduled, isTrue);
    expect(result.notifyAt, now.add(const Duration(seconds: 3)));
    expect(notifications.criticalTitles.single, '지금 출발해야 해요');
    expect(notifications.criticalBodies.single, contains('대전 성심당'));
    expect(notifications.criticalBodies.single, contains('90분'));
  });

  test('preflight reschedules itself when recalculated departure is later',
      () async {
    AppEnv.markSupabaseInitialized();
    final now = DateTime(2026, 5, 8, 9);
    final notifications = _FakeNotificationService();
    final preflight = _FakeDeparturePreflightScheduler();
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '성심당',
            startAt: DateTime(2026, 5, 8, 12),
            location: '대전 성심당',
            locationLat: 36.327,
            locationLng: 127.427,
          ),
        ],
      ),
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 90),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      preflightScheduler: preflight.call,
      now: () => now,
    );

    final result = await service.runPreflightForEvent(
      'event-1',
      userId: 'user-1',
    );

    expect(result.isScheduled, isTrue);
    expect(result.notifyAt, DateTime(2026, 5, 8, 10, 10));
    expect(preflight.eventIds.single, 'event-1');
    expect(preflight.preflightTimes.single, DateTime(2026, 5, 8, 10, 10));
    expect(notifications.criticalTitles, isEmpty);
    expect(notifications.titles, isEmpty);
  });

  test('preflight still alerts when live location is unavailable', () async {
    AppEnv.markSupabaseInitialized();
    final now = DateTime(2026, 5, 8, 10, 10);
    final notifications = _FakeNotificationService();
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '성심당',
            startAt: DateTime(2026, 5, 8, 12),
            location: '대전 성심당',
            locationLat: 36.327,
            locationLng: 127.427,
          ),
        ],
      ),
      currentLocationProvider: () async => null,
      notificationService: notifications,
      preflightScheduler: _FakeDeparturePreflightScheduler().call,
      now: () => now,
    );

    final result = await service.runPreflightForEvent(
      'event-1',
      userId: 'user-1',
    );

    expect(result.isScheduled, isTrue);
    expect(result.travelMinutes, isNull);
    expect(result.notifyAt, now.add(const Duration(seconds: 3)));
    expect(notifications.criticalTitles.single, '지금 출발해야 해요');
    expect(notifications.criticalBodies.single, contains('현재 위치'));
    expect(notifications.criticalBodies.single, contains('대전 성심당'));
  });

  test('refreshUpcoming records signed-out monitor status', () async {
    final service = DepartureAlarmService(
      now: () => DateTime(2026, 5, 8, 9),
    );

    final result = await service.refreshUpcoming();

    expect(result.skippedReason, 'signed_out');
    final status = await service.loadRuntimeStatus();
    expect(status.lastMonitorAt, DateTime(2026, 5, 8, 9));
    expect(status.lastMonitorSkippedReason, 'signed_out');
  });

  test('refreshUpcoming skips acknowledged events', () async {
    SharedPreferences.setMockInitialValues({
      'departure_alarm:ack:event-1': true,
    });
    AppEnv.markSupabaseInitialized();
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-1',
            userId: 'user-1',
            title: '출발 확인됨',
            startAt: DateTime(2026, 5, 8, 14),
            location: '장소',
            locationLat: 36.327,
            locationLng: 127.427,
          ),
        ],
      ),
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 30),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      preflightScheduler: _FakeDeparturePreflightScheduler().call,
      now: () => DateTime(2026, 5, 8, 9),
    );

    final result = await service.refreshUpcoming(userId: 'user-1');

    expect(result.skipped, 1);
    expect(result.scheduled, 0);
  });

  test('refreshUpcoming uses urgent interval when event is within six hours',
      () async {
    AppEnv.markSupabaseInitialized();
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-3',
            userId: 'user-1',
            title: '긴급 일정',
            startAt: DateTime(2026, 5, 8, 14),
            location: '회사',
            locationLat: 36.327,
            locationLng: 127.427,
          ),
        ],
      ),
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 30),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      preflightScheduler: _FakeDeparturePreflightScheduler().call,
      now: () => DateTime(2026, 5, 8, 9),
    );

    final result = await service.refreshUpcoming(userId: 'user-1');

    expect(
      result.nextMonitorInterval,
      Duration(minutes: DepartureAlarmService.defaultRepeatIntervalMin),
    );
    expect(result.scheduled, 1);
  });

  test(
      'refreshUpcoming uses default interval when events are farther than six hours',
      () async {
    AppEnv.markSupabaseInitialized();
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-4',
            userId: 'user-1',
            title: '여유 일정',
            startAt: DateTime(2026, 5, 9, 9),
            location: '회사',
            locationLat: 36.327,
            locationLng: 127.427,
          ),
        ],
      ),
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 30),
          source: TravelTimeBufferSource.tmap,
          reason: 'test',
        ),
      ),
      preflightScheduler: _FakeDeparturePreflightScheduler().call,
      now: () => DateTime(2026, 5, 8, 9),
    );

    final result = await service.refreshUpcoming(userId: 'user-1');

    expect(result.nextMonitorInterval, DepartureAlarmService.monitorInterval);
    expect(result.scheduled, 1);
  });

  test('fireDueDeparture is throttled by configured repeat interval', () async {
    final now = DateTime(2026, 5, 8, 9);
    await DepartureAlarmService.saveRepeatIntervalMinutes(15);
    final notifications = _FakeNotificationService();
    final event = EventModel(
      id: 'event-repeat',
      userId: 'user-1',
      title: '판교 방문',
      startAt: DateTime(2026, 5, 8, 10),
      location: '판교',
      locationLat: 37.39,
      locationLng: 127.11,
    );
    final service = DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 50),
          source: TravelTimeBufferSource.coordinates,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      preflightScheduler: _FakeDeparturePreflightScheduler(
        shouldSchedule: false,
      ).call,
      now: () => now,
    );

    final first = await service.scheduleForEvent(
      event,
      fireDueDeparture: true,
      rescheduleMonitor: false,
    );
    final second = await service.scheduleForEvent(
      event,
      fireDueDeparture: true,
      rescheduleMonitor: false,
    );

    expect(first.isScheduled, isTrue);
    expect(second.skippedReason, 'departure_repeat_throttled');
    expect(notifications.criticalTitles, hasLength(1));
  });

  test('uses cached recent origin when live current location is unavailable',
      () async {
    final now = DateTime(2026, 5, 8, 9);
    final event = EventModel(
      id: 'event-cached-origin',
      userId: 'user-1',
      title: '판교 방문',
      startAt: DateTime(2026, 5, 8, 10),
      location: '판교',
      locationLat: 37.39,
      locationLng: 127.11,
    );
    final travel = _FakeTravelTimeBufferService(
      routeEstimate: const TravelTimeBufferEstimate(
        buffer: Duration(minutes: 20),
        source: TravelTimeBufferSource.coordinates,
        reason: 'test',
      ),
    );
    final preflight = _FakeDeparturePreflightScheduler(shouldSchedule: false);

    await DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127.0),
      travelTimeBufferService: travel,
      notificationService: _FakeNotificationService(),
      preflightScheduler: preflight.call,
      now: () => now,
    ).scheduleForEvent(event, rescheduleMonitor: false);

    final notifications = _FakeNotificationService();
    final second = await DepartureAlarmService(
      currentLocationProvider: () async => null,
      travelTimeBufferService: travel,
      notificationService: notifications,
      preflightScheduler: preflight.call,
      now: () => now.add(const Duration(minutes: 1)),
    ).scheduleForEvent(event, rescheduleMonitor: false);

    expect(second.isScheduled, isTrue);
    expect(travel.lastOriginLat, 37.5);
    expect(travel.lastOriginLng, 127.0);
    expect(notifications.criticalTitles, contains('지금 출발해야 해요'));
  });

  // [PREVENT] 백그라운드(cacheOnlyLocation)에선 이동시간 routes API(원격)를 호출하지 않는다.
  // 실증: scheduleForEvent가 cacheOnly여도 estimateWithMapApis를 원격 호출하면
  // TMAP routes API가 매 모니터/동기화마다 모든 일정에 호출돼 폭주 → 네트워크/CPU 폭주
  // → 삼성 excessive cpu kill → 알람 미발생. 정확한 이동시간은 출발 직전 preflight(1회)만.
  test('cacheOnlyLocation일 때 이동시간은 로컬 추정만 사용한다(skipRemote=true)', () async {
    final now = DateTime(2026, 5, 8, 9);
    final event = EventModel(
      id: 'event-skip-remote',
      userId: 'user-1',
      title: '판교 방문',
      startAt: DateTime(2026, 5, 8, 10),
      location: '판교',
      locationLat: 37.39,
      locationLng: 127.11,
    );
    final travel = _FakeTravelTimeBufferService(
      routeEstimate: const TravelTimeBufferEstimate(
        buffer: Duration(minutes: 20),
        source: TravelTimeBufferSource.coordinates,
        reason: 'test',
      ),
    );
    // 먼저 라이브로 origin 캐시를 채운다.
    await DepartureAlarmService(
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127.0),
      travelTimeBufferService: travel,
      notificationService: _FakeNotificationService(),
      preflightScheduler:
          _FakeDeparturePreflightScheduler(shouldSchedule: false).call,
      now: () => now,
    ).scheduleForEvent(event, rescheduleMonitor: false);

    // 백그라운드: cacheOnlyLocation=true → estimateWithMapApis가 skipRemote=true로 호출돼야 함.
    travel.lastSkipRemote = false;
    await DepartureAlarmService(
      currentLocationProvider: () async => null,
      travelTimeBufferService: travel,
      notificationService: _FakeNotificationService(),
      preflightScheduler:
          _FakeDeparturePreflightScheduler(shouldSchedule: false).call,
      now: () => now.add(const Duration(minutes: 1)),
    ).scheduleForEvent(
      event,
      rescheduleMonitor: false,
      cacheOnlyLocation: true,
    );

    expect(
      travel.lastSkipRemote,
      isTrue,
      reason: '백그라운드(cacheOnly)에선 routes 원격 API 대신 로컬 추정(skipRemote)만 써야 합니다.',
    );
  });

  // [PREVENT] 백그라운드 모니터 콜백에서 AppPermissionService 라이브 위치 조회 금지 회귀 테스트
  // 실증: refreshUpcoming이 cacheOnlyLocation=true 없이 scheduleForEvent를 호출하면
  // LocationManager 폭주 → 삼성 기기 excessive cpu kill로 앱 종료 → 알람 미발생
  //
  // 검증 전략: cacheOnly=true이면 _permissions.checkLocationPermission() 경로에
  // 진입하지 않는다 → SharedPreferences 캐시만으로 origin을 결정한다.
  // AppPermissionService는 주입하지 않고(기본값=플랫폼 채널), 캐시 없이 실행하면
  // 'missing_origin'으로 skip되어야 한다. 즉, 라이브 조회를 시도했다면 플랫폼
  // 채널 예외가 발생했을 것이므로 테스트가 예외 없이 skip 결과를 반환하면
  // cacheOnly 경로가 정상 작동하는 것이다.
  test(
      'refreshUpcoming with cacheOnly skips events when no cache — no live location lookup',
      () async {
    AppEnv.markSupabaseInitialized();
    // 캐시 없음: cacheOnly=true이면 missing_origin으로 skip (라이브 조회 시도하지 않음)
    SharedPreferences.setMockInitialValues({});

    final notifications = _FakeNotificationService();
    final preflight = _FakeDeparturePreflightScheduler(shouldSchedule: false);
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'event-bg-monitor',
            userId: 'user-1',
            title: '배경 모니터 테스트',
            startAt: DateTime(2026, 5, 8, 14),
            location: '판교',
            locationLat: 37.39,
            locationLng: 127.11,
          ),
        ],
      ),
      // currentLocationProvider 주입 없음 → 플랫폼 채널(AppPermissionService) 경로
      // cacheOnly=true이면 이 경로에 도달하지 않아야 한다.
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 30),
          source: TravelTimeBufferSource.coordinates,
          reason: 'test',
        ),
      ),
      notificationService: notifications,
      preflightScheduler: preflight.call,
      now: () => DateTime(2026, 5, 8, 9),
    );

    // cacheOnly=true + 캐시 없음이면 'missing_origin'으로 skip되어야 한다.
    // 라이브 OS 위치 조회를 시도했다면 플랫폼 채널 MissingPluginException이 발생했을 것이다.
    final result = await service.refreshUpcoming(userId: 'user-1');

    expect(
      result.skipped,
      greaterThanOrEqualTo(1),
      reason: '캐시된 위치가 없고 cacheOnly=true이면 출발 알람이 missing_origin으로 skip되어야 합니다.',
    );
    // 중요: 알림이 등록되지 않아야 한다 (원인 없이 발화하면 안 됨)
    expect(
      notifications.criticalTitles,
      isEmpty,
      reason: '위치 정보 없이 출발 알람을 등록하면 안 됩니다.',
    );
  });
}

class _FakeTravelTimeBufferService extends TravelTimeBufferService {
  _FakeTravelTimeBufferService({required this.routeEstimate});

  final TravelTimeBufferEstimate routeEstimate;
  double? lastOriginLat;
  double? lastOriginLng;

  bool lastSkipRemote = false;

  @override
  Future<TravelTimeBufferEstimate> estimateWithMapApis({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
    String? locationText,
    bool skipRemote = false,
  }) async {
    lastOriginLat = originLat;
    lastOriginLng = originLng;
    lastSkipRemote = skipRemote;
    return routeEstimate;
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({required this.events});

  final List<EventModel> events;

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in events) {
      if (event.id == eventId && (userId == null || event.userId == userId)) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return events
        .where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeDeparturePreflightScheduler {
  _FakeDeparturePreflightScheduler({this.shouldSchedule = true});

  final bool shouldSchedule;
  final eventIds = <String>[];
  final preflightTimes = <DateTime>[];
  final safetyMargins = <Duration>[];
  final travelModes = <MapTravelMode>[];

  Future<bool> call({
    required EventModel event,
    required DateTime preflightAt,
    required Duration safetyMargin,
    required MapTravelMode travelMode,
  }) async {
    eventIds.add(event.id);
    preflightTimes.add(preflightAt);
    safetyMargins.add(safetyMargin);
    travelModes.add(travelMode);
    return shouldSchedule;
  }
}

class _FakeNotificationService extends NotificationService {
  _FakeNotificationService({this.blockCritical = false});

  final bool blockCritical;
  final titles = <String>[];
  final bodies = <String>[];
  final payloads = <String?>[];
  final criticalTitles = <String>[];
  final criticalBodies = <String?>[];
  final cancelledNotificationIds = <int>[];

  @override
  Future<void> cancel(int id) async {
    cancelledNotificationIds.add(id);
  }

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    titles.add(title);
    bodies.add(body);
    payloads.add(payload);
  }

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
  }) async {
    criticalTitles.add(title);
    criticalBodies.add(body);
    return NotificationScheduleResult(
      status: blockCritical
          ? NotificationScheduleStatus.permissionBlocked
          : NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
      message: blockCritical ? 'blocked' : null,
    );
  }

  @override
  Future<NotificationScheduleResult> scheduleDepartureAlarmWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    criticalTitles.add(title);
    criticalBodies.add(body);
    return NotificationScheduleResult(
      status: blockCritical
          ? NotificationScheduleStatus.permissionBlocked
          : NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
      message: blockCritical ? 'blocked' : null,
    );
  }

  @override
  Future<NotificationScheduleResult> scheduleDepartureFallbackWithResult({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    titles.add(title);
    bodies.add(body);
    payloads.add(payload);
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }
}
