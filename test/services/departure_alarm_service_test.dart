import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/pending_departure_store.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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
    expect(
      preflight.preflightTimes.single,
      result.notifyAt!.subtract(const Duration(seconds: 30)),
    );
    expect(preflight.safetyMargins.single, const Duration(minutes: 20));
    expect(notifications.criticalTitles, ['지금 출발해야 해요']);
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
    expect(notifications.criticalBodies, hasLength(1));
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

    final pendingStore = _FakePendingDepartureStore();
    final serviceWithPending = DepartureAlarmService(
      notificationService: notifications,
      preflightCanceller: (alarmId) async {
        cancelledAlarmIds.add(alarmId);
        return true;
      },
      pendingDepartureStore: pendingStore,
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

    // [PREVENT] acknowledgeDeparture는 출발 전용 알람 화면이 다시 뜨지 않도록
    // 보류 중인 출발 정보(pending departure)도 함께 지워야 한다.
    await serviceWithPending.acknowledgeDeparture('event-ack-2');
    expect(pendingStore.clearCallCount, 1);

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
    final route = NotificationService.routeForNotificationResponse(
      NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: notifications.payloads.single,
      ),
    );
    expect(Uri.parse(route!).queryParameters['eventId'], 'event-1');
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
    expect(
      preflight.preflightTimes.single,
      result.notifyAt!.subtract(const Duration(seconds: 30)),
    );
    expect(notifications.criticalTitles, ['지금 출발해야 해요']);
    expect(notifications.titles, isEmpty);
  });

  test(
      'preflight keeps its fallback on fetch failure and replaces the same slot '
      'after a successful refresh', () async {
    AppEnv.markSupabaseInitialized();
    var now = DateTime.now();
    const origin = GeoPoint(latitude: 37.5, longitude: 127);
    final event = EventModel(
      id: 'event-fallback',
      userId: 'user-1',
      title: '출발 테스트',
      startAt: now.add(const Duration(hours: 3)),
      location: '목적지',
      locationLat: 36.327,
      locationLng: 127.427,
    );
    final events = _FakeEventRepository(events: [event]);
    final notifications = _FakeNotificationService();
    final service = DepartureAlarmService(
      eventRepository: events,
      currentLocationProvider: () async => origin,
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

    final initial =
        await service.scheduleForEvent(event, rescheduleMonitor: false);
    final originalNotifyAt = initial.notifyAt!;
    final originalId = notifications.departureIds.single;
    now = originalNotifyAt.subtract(const Duration(seconds: 30));
    events.rejectFetch = true;
    await expectLater(
      service.runPreflightForEvent(
        event.id,
        userId: event.userId,
        fallbackAt: originalNotifyAt,
      ),
      throwsStateError,
    );
    expect(notifications.departureNotifyAts, [originalNotifyAt]);
    expect(notifications.cancelledNotificationIds, isEmpty);
    expect(notifications.pendingIds, contains(originalId));

    events.rejectFetch = false;
    events.events[0] = event.copyWith(
      startAt: event.startAt!.add(const Duration(minutes: 10)),
    );
    final refreshed = await service.runPreflightForEvent(
      event.id,
      userId: event.userId,
      fallbackAt: originalNotifyAt,
    );
    final refreshedNotifyAt = originalNotifyAt.add(const Duration(minutes: 10));
    expect(refreshed.notifyAt, refreshedNotifyAt);
    expect(notifications.departureIds, [originalId, originalId]);
    expect(notifications.departureNotifyAts,
        [originalNotifyAt, refreshedNotifyAt]);

    now = refreshedNotifyAt;
    final overdue = await service.runPreflightForEvent(
      event.id,
      userId: event.userId,
      fallbackAt: refreshedNotifyAt,
    );
    expect(overdue.skippedReason, 'fallback_already_due');
    expect(notifications.departureIds, hasLength(2));
  });

  group('P5b departure regression', () {
    final utcToday = DateTime.now().toUtc();
    final initialTime =
        DateTime.utc(utcToday.year, utcToday.month, utcToday.day);
    final event = EventModel(
      id: 'p5b',
      userId: 'test-user',
      title: 'Departure',
      startAt: initialTime.add(const Duration(hours: 2)),
      location: 'Destination',
      locationLat: 37.39,
      locationLng: 127.11,
    );
    late DateTime now;
    late _FakeEventRepository events;
    late _FakeNotificationService notifications;
    late _FakeDeparturePreflightScheduler preflight;
    late List<int> cancelledPreflightIds;
    late DepartureAlarmService service;
    late GeoPoint? origin;

    setUp(() {
      AppEnv.markSupabaseInitialized();
      now = initialTime;
      origin = const GeoPoint(latitude: 37.5, longitude: 127);
      events = _FakeEventRepository(events: [event]);
      notifications = _FakeNotificationService(blockCritical: true);
      preflight = _FakeDeparturePreflightScheduler();
      cancelledPreflightIds = [];
      service = DepartureAlarmService(
        eventRepository: events,
        currentLocationProvider: () async => origin,
        travelTimeBufferService: _FakeTravelTimeBufferService(
          routeEstimate: const TravelTimeBufferEstimate(
            buffer: Duration(minutes: 30),
            source: TravelTimeBufferSource.coordinates,
            reason: 'test',
          ),
        ),
        notificationService: notifications,
        preflightScheduler: preflight.call,
        preflightCanceller: (id) async {
          cancelledPreflightIds.add(id);
          return true;
        },
        now: () => now,
      );
    });

    test('keeps booked fallback when preflight returns no row', () async {
      final booked =
          await service.scheduleForEvent(event, rescheduleMonitor: false);
      now = booked.notifyAt!.subtract(const Duration(seconds: 30));
      events.events.clear();

      final preflightResult = await service.runPreflightForEvent(
        event.id,
        userId: event.userId,
        fallbackAt: booked.notifyAt,
      );

      expect(preflightResult.skippedReason, 'event_not_found');
      expect(notifications.cancelledNotificationIds, isEmpty);
      expect(notifications.departureNotifyAts, [booked.notifyAt]);
      expect(notifications.payloads, hasLength(1));
    });

    for (final missingOrigin in [false, true]) {
      test(
          'cancels fallback outside the new event window '
          'when origin is ${missingOrigin ? 'missing' : 'available'}',
          () async {
        final booked =
            await service.scheduleForEvent(event, rescheduleMonitor: false);
        final slotId = notifications.departureIds.single;
        notifications.pendingIds.add(slotId);
        now = initialTime.add(const Duration(minutes: 30));
        final moved = event.copyWith(
          startAt: now.add(const Duration(minutes: 10)),
        );
        events.events[0] = moved;
        expect(booked.notifyAt!.isAfter(moved.startAt!), isTrue);
        if (missingOrigin) {
          origin = null;
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(DepartureAlarmService.cachedOriginLatKey);
          await prefs.remove(DepartureAlarmService.cachedOriginLngKey);
        }

        final result = await service.scheduleForEvent(
          moved,
          rescheduleMonitor: false,
          cacheOnlyLocation: true,
        );

        expect(result.skippedReason,
            missingOrigin ? 'missing_origin' : 'departure_time_passed');
        expect(notifications.departureNotifyAts, [booked.notifyAt]);
        expect(notifications.pendingIds, isNot(contains(slotId)));
        expect(notifications.cancelledNotificationIds, contains(slotId));
      });
    }

    test(
        'keeps a future fallback before the unchanged event start when origin '
        'is unavailable', () async {
      final booked =
          await service.scheduleForEvent(event, rescheduleMonitor: false);
      final slotId = notifications.departureIds.single;
      notifications.pendingIds.add(slotId);
      origin = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(DepartureAlarmService.cachedOriginLatKey);
      await prefs.remove(DepartureAlarmService.cachedOriginLngKey);
      now = booked.notifyAt!.subtract(const Duration(minutes: 1));

      final result = await service.scheduleForEvent(
        event,
        rescheduleMonitor: false,
        cacheOnlyLocation: true,
      );

      expect(result.skippedReason, 'missing_origin');
      expect(notifications.departureNotifyAts, [booked.notifyAt]);
      expect(notifications.pendingIds, contains(slotId));
      expect(notifications.cancelledNotificationIds, isEmpty);
    });

    for (final minutes in [0, 10]) {
      test('elapsed departure refresh does not rebook at $minutes minutes',
          () async {
        await DepartureAlarmService.saveRepeatIntervalMinutes(minutes);
        final booked =
            await service.scheduleForEvent(event, rescheduleMonitor: false);
        // The OS no longer lists a delivered notification as pending.
        notifications.pendingIds.clear();
        now = booked.notifyAt!.add(const Duration(seconds: 1));

        for (var attempt = 0; attempt < 2; attempt++) {
          final result =
              await service.scheduleForEvent(event, rescheduleMonitor: false);
          expect(result.skippedReason, 'departure_time_passed');
        }
        expect(notifications.departureNotifyAts, [booked.notifyAt]);
        expect(notifications.cancelledNotificationIds, isEmpty);

        final due = await service.scheduleForEvent(
          event,
          rescheduleMonitor: false,
          fireDueDeparture: true,
        );
        final repeat = await service.scheduleForEvent(
          event,
          rescheduleMonitor: false,
          fireDueDeparture: true,
        );
        expect(due.isScheduled, isTrue);
        expect(notifications.payloads, hasLength(2));
        expect(repeat.skippedReason, 'departure_repeat_throttled');
      });
    }

    test('preflight removes the fired record if no preflight is rebooked',
        () async {
      final recurring = event.copyWith(recurrenceRule: 'FREQ=DAILY');
      events.events[0] = recurring;
      final startAt = recurring.startAt!;
      final booked =
          await service.scheduleForEvent(recurring, rescheduleMonitor: false);
      now = booked.notifyAt!;
      final result = await service.runPreflightForEvent(
        recurring.id,
        userId: recurring.userId,
        occurrenceStartAt: startAt,
        fallbackAt: booked.notifyAt,
      );

      expect(result.skippedReason, 'fallback_already_due');
      expect(cancelledPreflightIds, [
        notifications.notificationIdFor(
          eventAlarmKey(recurring, 'departure_preflight'),
        ),
      ]);
      expect(notifications.cancelledNotificationIds, isEmpty);
    });

    test('preflight keeps the rebooked record for the same alarm ID', () async {
      final booked =
          await service.scheduleForEvent(event, rescheduleMonitor: false);
      now = booked.notifyAt!.subtract(const Duration(seconds: 30));
      final moved = event.copyWith(
        startAt: event.startAt!.add(const Duration(minutes: 10)),
      );
      events.events[0] = moved;
      final result = await service.runPreflightForEvent(
        event.id,
        userId: event.userId,
        fallbackAt: booked.notifyAt,
      );

      expect(result.isScheduled, isTrue);
      expect(preflight.preflightTimes, hasLength(2));
      expect(cancelledPreflightIds, isEmpty);
    });

    test('native departure action acknowledges only the delivered occurrence',
        () async {
      final today = event.copyWith(recurrenceRule: 'FREQ=DAILY');
      final tomorrow = today.copyWith(
        startAt: today.startAt!.add(const Duration(days: 1)),
      );
      final first =
          await service.scheduleForEvent(today, rescheduleMonitor: false);
      await service.scheduleForEvent(tomorrow, rescheduleMonitor: false);
      final todayId =
          notifications.notificationIdFor(eventAlarmKey(today, 'departure'));
      final tomorrowId =
          notifications.notificationIdFor(eventAlarmKey(tomorrow, 'departure'));
      now = first.notifyAt!;

      await handleNotificationResponseAction(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          id: todayId,
          actionId: NotificationService.departureAcknowledgedActionId,
          payload: notifications.payloads.first,
        ),
        notificationService: notifications,
        eventRepository: events,
      );
      expect(notifications.cancelledNotificationIds, [todayId, todayId]);
      final acknowledgedToday =
          await service.scheduleForEvent(today, rescheduleMonitor: false);
      final stillDueTomorrow =
          await service.scheduleForEvent(tomorrow, rescheduleMonitor: false);
      expect(acknowledgedToday.skippedReason, 'departure_acknowledged');
      expect(stillDueTomorrow.isScheduled, isTrue);
      expect(notifications.cancelledNotificationIds, contains(todayId));
      expect(
          notifications.cancelledNotificationIds, isNot(contains(tomorrowId)));
    });

    test('departure notification tap carries the scheduled occurrence to route',
        () {
      final occurrence = CriticalAlarmOccurrence(event.startAt!);
      final route = NotificationService.routeForNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: NotificationService.departurePayloadFor(
            event.id,
            occurrence: occurrence,
          ),
        ),
      );

      expect(route, isNotNull);
      final query = Uri.parse(route!).queryParameters;
      expect(query['eventId'], event.id);
      expect(query.values, contains(occurrence.token));
    });

    test('confirming after the occurrence starts does not acknowledge tomorrow',
        () async {
      final today = event.copyWith(recurrenceRule: 'FREQ=DAILY');
      final tomorrow = today.copyWith(
        startAt: today.startAt!.add(const Duration(days: 1)),
      );
      events.events[0] = today;
      await service.scheduleForEvent(today, rescheduleMonitor: false);
      await service.scheduleForEvent(tomorrow, rescheduleMonitor: false);
      now = today.startAt!.add(const Duration(minutes: 1));

      await service.acknowledgeDeparture(today.id);
      final todayId =
          notifications.notificationIdFor(eventAlarmKey(today, 'departure'));
      final tomorrowId =
          notifications.notificationIdFor(eventAlarmKey(tomorrow, 'departure'));
      expect(notifications.cancelledNotificationIds, contains(todayId));
      expect(
          notifications.cancelledNotificationIds, isNot(contains(tomorrowId)));

      final result =
          await service.scheduleForEvent(tomorrow, rescheduleMonitor: false);
      expect(result.isScheduled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final key = NotificationService.departureAcknowledgementKey(
        today.id,
        CriticalAlarmOccurrence(today.startAt!),
      );
      expect(prefs.containsKey('departure_alarm:ack:$key'), isTrue);
    });

    test('P5c late legacy confirmation preserves the next occurrence',
        () async {
      final recurring = event.copyWith(recurrenceRule: 'FREQ=DAILY');
      events.events[0] = recurring;
      final next = recurring.copyWith(
        startAt: recurring.startAt!.add(const Duration(days: 1)),
      );
      final nextId =
          notifications.notificationIdFor(eventAlarmKey(next, 'departure'));
      now = recurring.startAt!.add(const Duration(hours: 2));

      await service.acknowledgeDeparture(recurring.id);

      final prefs = await SharedPreferences.getInstance();
      final nextKey = NotificationService.departureAcknowledgementKey(
        recurring.id,
        CriticalAlarmOccurrence(next.startAt!),
      );
      expect(prefs.containsKey('departure_alarm:ack:$nextKey'), isFalse);
      expect(notifications.cancelledNotificationIds, isNot(contains(nextId)));
    });

    test('P5c legacy confirmation can select an open future departure',
        () async {
      final recurring = event.copyWith(recurrenceRule: 'FREQ=DAILY');
      events.events[0] = recurring;
      now = recurring.startAt!.subtract(const Duration(minutes: 10));

      await service.acknowledgeDeparture(recurring.id);

      final prefs = await SharedPreferences.getInstance();
      final key = NotificationService.departureAcknowledgementKey(
        recurring.id,
        CriticalAlarmOccurrence(recurring.startAt!),
      );
      expect(prefs.containsKey('departure_alarm:ack:$key'), isTrue);
      expect(
          notifications.cancelledNotificationIds,
          contains(notifications
              .notificationIdFor(eventAlarmKey(recurring, 'departure'))));
    });

    for (final atBookedTime in [false, true]) {
      test(
          'P5c review2 legacy acknowledgement respects actual booked time '
          '${atBookedTime ? 'at' : 'before'} notification', () async {
        final recurring = event.copyWith(recurrenceRule: 'FREQ=DAILY');
        events.events[0] = recurring;
        final occurrence = CriticalAlarmOccurrence(recurring.startAt!);
        final departureId = notifications.notificationIdFor(
          eventAlarmKey(recurring, 'departure'),
        );
        final preflightId = notifications.notificationIdFor(
          eventAlarmKey(recurring, 'departure_preflight'),
        );
        final bookedAt =
            recurring.startAt!.subtract(const Duration(minutes: 5));
        notifications.pendingIds.add(departureId);
        notifications.pendingPayloads[departureId] =
            NotificationService.departurePayloadFor(
          recurring.id,
          occurrence: occurrence,
          notifyAt: bookedAt,
        );
        now = bookedAt.subtract(Duration(seconds: atBookedTime ? 0 : 1));

        await service.acknowledgeDeparture(recurring.id);

        final prefs = await SharedPreferences.getInstance();
        final key = NotificationService.departureAcknowledgementKey(
          recurring.id,
          occurrence,
        );
        expect(prefs.containsKey('departure_alarm:ack:$key'), atBookedTime);
        expect(notifications.pendingIds.contains(departureId), !atBookedTime);
        expect(notifications.cancelledNotificationIds.contains(departureId),
            atBookedTime);
        expect(cancelledPreflightIds.contains(preflightId), atBookedTime);
      });
    }

    test('P5c explicit occurrence wins over legacy inference', () async {
      final recurring = event.copyWith(recurrenceRule: 'FREQ=DAILY');
      events.events[0] = recurring;
      final occurrence = CriticalAlarmOccurrence(recurring.startAt!);
      final next = recurring.copyWith(
          startAt: recurring.startAt!.add(const Duration(days: 1)));
      now = recurring.startAt!.add(const Duration(hours: 2));
      final confirmationService = DepartureAlarmService(
        eventRepository: events,
        notificationService: notifications,
        confirmationOccurrence: occurrence,
        preflightCanceller: (_) async => true,
        now: () => now,
      );

      await confirmationService.acknowledgeDeparture(recurring.id);

      final prefs = await SharedPreferences.getInstance();
      final key = NotificationService.departureAcknowledgementKey(
          recurring.id, occurrence);
      final nextKey = NotificationService.departureAcknowledgementKey(
        recurring.id,
        CriticalAlarmOccurrence(next.startAt!),
      );
      expect(prefs.containsKey('departure_alarm:ack:$key'), isTrue);
      expect(prefs.containsKey('departure_alarm:ack:$nextKey'), isFalse);
      expect(
          notifications.cancelledNotificationIds,
          isNot(contains(notifications
              .notificationIdFor(eventAlarmKey(next, 'departure')))));
    });

    test('notification occurrence can be confirmed when event lookup fails',
        () async {
      final today = event.copyWith(recurrenceRule: 'FREQ=DAILY');
      final occurrence = CriticalAlarmOccurrence(today.startAt!);
      now = today.startAt!.add(const Duration(minutes: 1));
      events.rejectFetch = true;
      final confirmationService = DepartureAlarmService(
        eventRepository: events,
        notificationService: notifications,
        confirmationOccurrence: occurrence,
        preflightCanceller: (_) async => true,
        now: () => now,
      );

      await confirmationService.acknowledgeDeparture(today.id);

      final prefs = await SharedPreferences.getInstance();
      final key = NotificationService.departureAcknowledgementKey(
        today.id,
        occurrence,
      );
      expect(prefs.containsKey('departure_alarm:ack:$key'), isTrue);
      expect(notifications.cancelledNotificationIds, [
        notifications.notificationIdFor(eventAlarmKey(today, 'departure')),
      ]);
    });

    test(
        'confirmation prunes only expired occurrence departure acknowledgements',
        () async {
      String key(String id, DateTime startAt) {
        final occurrence = CriticalAlarmOccurrence(startAt);
        return 'departure_alarm:ack:'
            '${NotificationService.departureAcknowledgementKey(id, occurrence)}';
      }

      final prefs = await SharedPreferences.getInstance();
      final expired = key('series', now.subtract(const Duration(days: 31)));
      final recent = key('series', now.subtract(const Duration(days: 29)));
      const oneOff = 'departure_alarm:ack:one-off';
      await prefs.setBool(expired, true);
      await prefs.setBool(recent, true);
      await prefs.setBool(oneOff, true);

      await service.acknowledgeDeparture(event.id);

      expect(prefs.containsKey(expired), isFalse);
      expect(prefs.getBool(recent), isTrue);
      expect(prefs.getBool(oneOff), isTrue);
    });
  });

  test('preference read failure does not interrupt departure ack cleanup',
      () async {
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _ReadFailurePreferences();
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previousPlatform;
    });
    final notifications = _FakeNotificationService();
    final pending = _FakePendingDepartureStore();
    final service = DepartureAlarmService(
      notificationService: notifications,
      pendingDepartureStore: pending,
      preflightCanceller: (_) async => true,
    );

    await expectLater(service.clearAcknowledgement('series'), completes);

    expect(notifications.cancelledNotificationIds,
        contains(notifications.notificationIdFor('series:departure')));
    expect(pending.clearCallCount, 1);
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
    // 위치를 못 구해도 알람은 뜨고, 본문에 목적지와 '출발' 버튼 안내가 포함된다.
    expect(notifications.criticalBodies.single, contains("'출발' 버튼"));
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
      notificationService: _FakeNotificationService(),
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
      notificationService: _FakeNotificationService(),
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

  test('standalone monitor counts surviving pending alerts', () async {
    AppEnv.markSupabaseInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final now = DateTime.now();
    EventModel departure(String id, DateTime startAt) => EventModel(
          id: id,
          userId: 'user-1',
          title: id,
          startAt: startAt,
          locationLat: 37.39,
          locationLng: 127.11,
        );
    final due = departure('due', now.add(const Duration(minutes: 10)));
    final later = departure('later', now.add(const Duration(hours: 4)));
    final notifications = _FakeNotificationService();
    final dueId = notifications.notificationIdFor(
      eventAlarmKey(due, 'departure'),
    );
    final laterId = notifications.notificationIdFor(
      eventAlarmKey(later, 'departure'),
    );
    const unrelatedId = 911;
    notifications.pendingIds.addAll([dueId, laterId, unrelatedId]);
    notifications.pendingPayloads[dueId] =
        NotificationService.departurePayloadFor(
      due.id,
      notifyAt: now.add(const Duration(minutes: 1)),
    );
    final service = DepartureAlarmService(
      eventRepository: _FakeEventRepository(events: [
        due,
        for (var index = 0; index < 56; index++)
          departure('early-$index', now.add(Duration(minutes: 60 + index))),
        later,
      ]),
      notificationService: notifications,
      currentLocationProvider: () async =>
          const GeoPoint(latitude: 37.5, longitude: 127),
      travelTimeBufferService: _FakeTravelTimeBufferService(
        routeEstimate: const TravelTimeBufferEstimate(
          buffer: Duration(minutes: 30),
          source: TravelTimeBufferSource.coordinates,
          reason: 'test',
        ),
      ),
      preflightScheduler: _FakeDeparturePreflightScheduler().call,
      now: () => now,
    );

    final result = await service.refreshUpcoming(userId: 'user-1');

    expect(result.scheduled, 54);
    expect(notifications.pendingIds, hasLength(56));
    expect(notifications.pendingIds, containsAll([dueId, unrelatedId]));
    expect(notifications.pendingIds, isNot(contains(laterId)));
    expect(notifications.cancelledNotificationIds, [laterId]);
  });

  for (final stale in [true, false]) {
    test(
        'P5c review2 over-cap monitor ${stale ? 'cancels stale' : 'keeps valid'} departure',
        () async {
      AppEnv.markSupabaseInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final now = DateTime.now();
      final event = EventModel(
        id: 'over-cap-departure',
        userId: 'user-1',
        title: 'departure',
        startAt: now.add(const Duration(minutes: 10)),
        locationLat: 37.39,
        locationLng: 127.11,
      );
      final notifications = _FakeNotificationService();
      final id =
          notifications.notificationIdFor(eventAlarmKey(event, 'departure'));
      notifications.pendingIds.add(id);
      for (var index = 0; notifications.pendingIds.length < 57; index++) {
        if (index != id) notifications.pendingIds.add(index);
      }
      notifications.pendingPayloads[id] =
          NotificationService.departurePayloadFor(
        event.id,
        notifyAt: now.add(Duration(minutes: stale ? 20 : 5)),
      );
      final cancelledPreflights = <int>[];
      final service = DepartureAlarmService(
        eventRepository: _FakeEventRepository(events: [event]),
        notificationService: notifications,
        currentLocationProvider: () async => null,
        preflightCanceller: (id) async {
          cancelledPreflights.add(id);
          return true;
        },
        now: () => now,
      );

      await service.refreshUpcoming(userId: event.userId);

      expect(notifications.pendingIds.contains(id), !stale);
      expect(notifications.cancelledNotificationIds.contains(id), stale);
      expect(
          cancelledPreflights.contains(notifications.notificationIdFor(
            eventAlarmKey(event, 'departure_preflight'),
          )),
          stale);
      expect(notifications.pendingIds.length, stale ? 56 : 57);
    });
  }

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
      reason:
          '캐시된 위치가 없고 cacheOnly=true이면 출발 알람이 missing_origin으로 skip되어야 합니다.',
    );
    // 중요: 알림이 등록되지 않아야 한다 (원인 없이 발화하면 안 됨)
    expect(
      notifications.criticalTitles,
      isEmpty,
      reason: '위치 정보 없이 출발 알람을 등록하면 안 됩니다.',
    );
  });

  // [PREVENT] 출발 알람이 "지금(±즉시)" 발동할 때만 pending departure를 기록해야
  // shell_screen이 알림 대신 곧바로 출발 알람 화면으로 이동할 수 있다.
  test(
      'fireDueDeparture immediate-notify path (origin missing) writes pending departure',
      () async {
    final now = DateTime(2026, 5, 8, 9);
    final notifications = _FakeNotificationService();
    final pendingStore = _FakePendingDepartureStore();
    final service = DepartureAlarmService(
      currentLocationProvider: () async => null,
      notificationService: notifications,
      pendingDepartureStore: pendingStore,
      now: () => now,
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-due-now',
        userId: 'user-1',
        title: '지금 출발',
        startAt: DateTime(2026, 5, 8, 12),
        location: '판교',
        locationLat: 37.39,
        locationLng: 127.11,
      ),
      rescheduleMonitor: false,
      fireDueDeparture: true,
    );

    expect(result.isScheduled, isTrue);
    expect(pendingStore.written, hasLength(1));
    expect(pendingStore.written.single.eventId, 'event-due-now');
    expect(pendingStore.written.single.title, '지금 출발');
  });

  test(
      'future-scheduled departure notification (isDueNow=false) does not write pending departure',
      () async {
    final now = DateTime(2026, 5, 8, 9);
    final notifications = _FakeNotificationService();
    final pendingStore = _FakePendingDepartureStore();
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
      // preflight scheduling 실패 → fallback으로 즉시(비-preflight) 알림 예약 경로를 타지만,
      // fireDueDeparture=false(기본값)이므로 isDueNow=false 여야 한다.
      preflightScheduler:
          _FakeDeparturePreflightScheduler(shouldSchedule: false).call,
      pendingDepartureStore: pendingStore,
      now: () => now,
    );

    final result = await service.scheduleForEvent(
      EventModel(
        id: 'event-future',
        userId: 'user-1',
        title: '나중에 출발',
        startAt: DateTime(2026, 5, 8, 12),
        location: '대전 성심당',
        locationLat: 36.327,
        locationLng: 127.427,
      ),
      rescheduleMonitor: false,
    );

    expect(result.isScheduled, isTrue);
    expect(notifications.criticalTitles, isNotEmpty);
    expect(pendingStore.written, isEmpty);
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
  bool rejectFetch = false;

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    if (rejectFetch) throw StateError('offline');
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

class _ReadFailurePreferences extends InMemorySharedPreferencesStore {
  _ReadFailurePreferences() : super.empty();

  @override
  Future<Map<String, Object>> getAll() async =>
      throw PlatformException(code: 'channel-error');
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

class _FakePendingDepartureStore extends PendingDepartureStore {
  final written = <PendingDeparture>[];
  int clearCallCount = 0;

  @override
  Future<void> write(PendingDeparture pending) async {
    written.add(pending);
  }

  @override
  Future<PendingDeparture?> read() async {
    return written.isEmpty ? null : written.last;
  }

  @override
  Future<void> clear() async {
    clearCallCount += 1;
  }
}

class _FakeNotificationService extends NotificationService {
  @override
  Future<void> cancelResponseNotification(int? id) async {
    if (id != null) await cancel(id);
  }

  _FakeNotificationService({this.blockCritical = false});

  final bool blockCritical;
  final titles = <String>[];
  final bodies = <String>[];
  final payloads = <String?>[];
  final criticalTitles = <String>[];
  final criticalBodies = <String?>[];
  final departureIds = <int>[];
  final departureNotifyAts = <DateTime>[];
  final cancelledNotificationIds = <int>[];
  final pendingIds = <int>{};
  final pendingPayloads = <int, String?>{};

  @override
  Future<List<PendingNotificationRequest>> pendingRequestsForCleanup() async =>
      pendingIds
          .map((id) =>
              PendingNotificationRequest(id, null, null, pendingPayloads[id]))
          .toList();

  @override
  Future<void> cancel(int id) async {
    cancelledNotificationIds.add(id);
    pendingIds.remove(id);
    pendingPayloads.remove(id);
  }

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
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
    bool useStrongAlarm = true,
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
    departureIds.add(id);
    departureNotifyAts.add(notifyAt);
    if (!blockCritical) {
      pendingIds.add(id);
      pendingPayloads[id] = payload;
    }
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
    pendingPayloads[id] = payload;
    pendingIds.add(id);
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }
}
