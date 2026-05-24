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

    expect(result.nextMonitorInterval,
        DepartureAlarmService.monitorUrgentInterval);
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
}

class _FakeTravelTimeBufferService extends TravelTimeBufferService {
  _FakeTravelTimeBufferService({required this.routeEstimate});

  final TravelTimeBufferEstimate routeEstimate;

  @override
  Future<TravelTimeBufferEstimate> estimateWithMapApis({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
    String? locationText,
  }) async {
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
}
