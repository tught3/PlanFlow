import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';

void main() {
  group('ManualEventSideEffectService', () {
    test('builds default reminder row for manual events', () {
      final service = ManualEventSideEffectService(
        gateway: _FakeManualEventGateway(),
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: _FakeNotificationService(),
      );
      final startAt = DateTime.utc(2026, 5, 2, 12);
      final event = EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '회의',
        startAt: startAt,
      );

      final payloads = service.buildReminderPayloads(
        event: event,
        userId: 'user-1',
      );

      expect(payloads, hasLength(1));
      expect(payloads.single['event_id'], 'event-1');
      expect(payloads.single['user_id'], 'user-1');
      expect(payloads.single['type'], 'push');
      expect(
        payloads.single['notify_at'],
        startAt.subtract(const Duration(minutes: 60)).toIso8601String(),
      );
      expect(payloads.single['is_sent'], false);
    });

    test('replaces reminders and clears pre-actions before rescheduling',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      final event = EventModel(
        id: 'event-2',
        userId: 'user-1',
        title: '중요 발표',
        startAt: DateTime.now().add(const Duration(hours: 3)),
        isCritical: true,
      );

      final result = await service.syncAfterSave(
        event: event,
        userId: 'user-1',
      );

      expect(result.isFullySynced, true);
      expect(gateway.deletedReminderEventIds, ['event-2']);
      expect(gateway.deletedPreActionEventIds, ['event-2']);
      expect(gateway.insertedReminders, hasLength(2));
      expect(gateway.insertedReminders.map((row) => row['type']), [
        'push',
        'system_alarm',
      ]);
      expect(notifications.cancelledEventIds, ['event-2']);
      expect(notifications.scheduledEventReminderIds, hasLength(1));
      expect(notifications.scheduledCriticalAlarmIds, hasLength(1));
      expect(
        notifications.scheduledCriticalNotifyAts.single,
        event.startAt!.subtract(const Duration(minutes: 60)),
      );
    });

    test('delete cleanup cancels local notifications for the event', () async {
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: _FakeManualEventGateway(),
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );

      await service.cleanupAfterDelete('event-3');

      expect(notifications.cancelledEventIds, ['event-3']);
    });

    test('syncAfterSave recalculates prep and departure alarms for the day',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final departure = _FakeDepartureAlarmService();
      final tenOClock = EventModel(
        id: 'ten-place',
        userId: 'user-1',
        title: '10시 거래처 방문',
        startAt: DateTime(2026, 5, 8, 10),
        location: '강릉아산병원',
        locationLat: 37.7563,
        locationLng: 128.8758,
      );
      final nineOClock = EventModel(
        id: 'nine-place',
        userId: 'user-1',
        title: '9시 고객 미팅',
        startAt: DateTime(2026, 5, 8, 9),
        location: '강릉역',
        locationLat: 37.7646,
        locationLng: 128.8995,
      );
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(
          events: <EventModel>[nineOClock, tenOClock],
        ),
        departureAlarmService: departure,
        notificationService: notifications,
        now: () => DateTime(2026, 5, 8, 6),
      );

      await service.syncAfterSave(
        event: nineOClock,
        userId: 'user-1',
      );

      final nineTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'nine-place')
          .map((row) => row['title'].toString());
      final tenTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'ten-place')
          .map((row) => row['title'].toString());
      expect(
        nineTitles.any((title) => title.contains('지금 준비 시작하세요')),
        true,
      );
      expect(
        tenTitles.any((title) => title.contains('지금 준비 시작하세요')),
        false,
      );
      expect(
        notifications.cancelledNotificationIds,
        containsAll(<int>[
          notifications.notificationIdFor('nine-place:departure'),
          notifications.notificationIdFor('ten-place:departure'),
        ]),
      );
      expect(departure.scheduledEventIds, containsAll(<String>[
        'nine-place',
        'ten-place',
      ]));
      expect(departure.scheduleNextMonitorCallCount, 1);
    });

    test('location coordinate changes rebuild smart prep with live travel time',
        () async {
      final gateway = _FakeManualEventGateway();
      final event = EventModel(
        id: 'place-event',
        userId: 'user-1',
        title: '병원 방문',
        startAt: DateTime(2026, 5, 8, 13),
        location: '원주세브란스기독병원',
        locationLat: 37.349,
        locationLng: 127.948,
      );
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(events: <EventModel>[event]),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: _FakeNotificationService(),
        currentLocationProvider: () async => const GeoPoint(
          latitude: 37.5665,
          longitude: 126.978,
        ),
        travelTimeBufferService: _FakeTravelTimeBufferService(minutes: 74),
        now: () => DateTime(2026, 5, 8, 8),
      );

      await service.syncAfterSave(event: event, userId: 'user-1');

      final departureTitle = gateway.insertedPreActions
          .map((row) => row['title'].toString())
          .singleWhere((title) => title.contains('지금 출발하세요'));
      expect(departureTitle, contains('이동 약 74분'));
    });

    test('delete cleanup recalculates remaining alarms for the signed-in user',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final departure = _FakeDepartureAlarmService();
      final remaining = EventModel(
        id: 'remaining-place',
        userId: 'user-1',
        title: '남은 외부 일정',
        startAt: DateTime(2026, 5, 8, 10),
        location: '대전역',
        locationLat: 36.332,
        locationLng: 127.434,
      );
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(events: <EventModel>[remaining]),
        departureAlarmService: departure,
        notificationService: notifications,
        now: () => DateTime(2026, 5, 8, 6),
      );

      await service.cleanupAfterDelete('deleted-event', userId: 'user-1');

      expect(notifications.cancelledEventIds, ['deleted-event']);
      expect(gateway.deletedExternalPreActionEventIds, ['remaining-place']);
      final remainingTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'remaining-place')
          .map((row) => row['title'].toString());
      expect(
        remainingTitles.any((title) => title.contains('지금 준비 시작하세요')),
        true,
      );
      expect(
        notifications.cancelledNotificationIds,
        contains(notifications.notificationIdFor('remaining-place:departure')),
      );
      expect(departure.scheduledEventIds, ['remaining-place']);
    });

    test('recalculate cancels stale departure alarms even with no upcoming events',
        () async {
      final notifications = _FakeNotificationService();
      final departure = _FakeDepartureAlarmService();
      final service = ManualEventSideEffectService(
        gateway: _FakeManualEventGateway(),
        eventRepository: _FakeEventRepository(),
        departureAlarmService: departure,
        notificationService: notifications,
        now: () => DateTime(2026, 5, 8, 12),
      );

      final result = await service.recalculateAlarmsForEvents(
        events: <EventModel>[
          EventModel(
            id: 'moved-past',
            userId: 'user-1',
            title: '이미 지난 외부 일정',
            startAt: DateTime(2026, 5, 8, 8),
            location: '강릉아산병원',
            locationLat: 37.7563,
            locationLng: 128.8758,
          ),
        ],
        userId: 'user-1',
        extraDepartureEventIdsToCancel: const <String>['moved-past'],
      );

      expect(result.departureScheduled, 0);
      expect(result.departureSkipped, 0);
      expect(
        notifications.cancelledNotificationIds,
        contains(notifications.notificationIdFor('moved-past:departure')),
      );
      expect(departure.scheduledEventIds, isEmpty);
    });

    test('resyncRemindersForEvents replaces DB rows and local alarms',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      final event = EventModel(
        id: 'external-1',
        userId: 'user-1',
        title: '아이스크림 전달',
        startAt: DateTime.now().add(const Duration(hours: 3)),
        location: '강릉아산병원',
        source: 'naver_device',
      );

      final result = await service.resyncRemindersForEvents(
        events: <EventModel>[event],
        userId: 'user-1',
      );

      expect(result, true);
      expect(gateway.deletedReminderEventIds, ['external-1']);
      expect(gateway.insertedReminders, hasLength(1));
      expect(gateway.insertedReminders.single['event_id'], 'external-1');
      expect(gateway.insertedReminders.single['type'], 'push');
      expect(
          notifications.cancelledNotificationIds,
          containsAll(<int>[
            notifications.notificationIdFor('external-1:push'),
            notifications.notificationIdFor('external-1:critical'),
          ]));
      expect(notifications.scheduledEventReminderIds, hasLength(1));
    });

    test('resyncRemindersForEvents keeps push and critical rows separate',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      final event = EventModel(
        id: 'critical-external',
        userId: 'user-1',
        title: '중요 외부 일정',
        startAt: DateTime.now().add(const Duration(hours: 3)),
        location: '강릉아산병원',
        source: 'naver_device',
        isCritical: true,
      );

      final result = await service.resyncRemindersForEvents(
        events: <EventModel>[event],
        userId: 'user-1',
      );

      expect(result, true);
      expect(gateway.insertedReminders, hasLength(2));
      expect(
        gateway.insertedReminders.map((row) => row['type']),
        containsAll(<String>['push', 'system_alarm']),
      );
      expect(notifications.scheduledEventReminderIds, hasLength(1));
      expect(notifications.scheduledCriticalAlarmIds, hasLength(1));
    });

    test('resyncExternalPreparationForDay reuses an in-flight resync',
        () async {
      final gateway = _SlowManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      final event = EventModel(
        id: 'trip',
        userId: 'user-1',
        title: '대전 내려가기',
        startAt: DateTime(2026, 5, 8, 10),
        location: '대전역',
      );

      final first = service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[event],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        now: DateTime(2026, 5, 8, 6),
      );
      final second = service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[event],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        now: DateTime(2026, 5, 8, 6),
      );

      expect(
          await Future.wait(<Future<bool>>[first, second]), <bool>[true, true]);
      expect(gateway.insertPreActionsCallCount, 1);
      expect(notifications.cancelledSmartPreparationEventIds, ['trip']);
    });

    test('resyncExternalPreparationForDay reruns live travel resync after inflight work',
        () async {
      final gateway = _SlowManualEventGateway();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: _FakeNotificationService(),
        travelTimeBufferService: _FakeTravelTimeBufferService(minutes: 74),
      );
      final event = EventModel(
        id: 'trip',
        userId: 'user-1',
        title: '병원 방문',
        startAt: DateTime(2026, 5, 8, 13),
        location: '원주세브란스기독병원',
        locationLat: 37.349,
        locationLng: 127.948,
      );

      final first = service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[event],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        now: DateTime(2026, 5, 8, 6),
      );
      final second = service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[event],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        currentLocation: const GeoPoint(
          latitude: 37.5665,
          longitude: 126.978,
        ),
        now: DateTime(2026, 5, 8, 6),
      );

      expect(
          await Future.wait(<Future<bool>>[first, second]), <bool>[true, true]);
      expect(gateway.insertPreActionsCallCount, 2);
      expect(
        gateway.insertedPreActions
            .map((row) => row['title'].toString())
            .where((title) => title.contains('이동 약 74분')),
        isNotEmpty,
      );
    });

    test('resyncExternalPreparationForDay promotes earliest place event',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      final phoneCall = EventModel(
        id: 'phone',
        userId: 'user-1',
        title: '본사 전화하기',
        startAt: DateTime(2026, 5, 8, 9),
      );
      final trip = EventModel(
        id: 'trip',
        userId: 'user-1',
        title: '대전 내려가기',
        startAt: DateTime(2026, 5, 8, 10),
        location: '대전역',
      );
      final meeting = EventModel(
        id: 'meeting',
        userId: 'user-1',
        title: '광명 미팅',
        startAt: DateTime(2026, 5, 8, 13),
        location: '광명역',
      );

      final result = await service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[meeting, phoneCall, trip],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8, 9),
        now: DateTime(2026, 5, 8, 6),
      );

      expect(result, true);
      expect(gateway.deletedExternalPreActionEventIds, ['trip', 'meeting']);
      expect(notifications.cancelledSmartPreparationEventIds, [
        'trip',
        'meeting',
      ]);
      final tripTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'trip')
          .map((row) => row['title']);
      final meetingTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'meeting')
          .map((row) => row['title']);
      expect(
        tripTitles.any((title) => title.toString().contains('지금 준비 시작하세요')),
        true,
      );
      expect(
        meetingTitles.any((title) => title.toString().contains('지금 준비 시작하세요')),
        false,
      );
      expect(meetingTitles, contains('지금 출발하세요 🚗 (이동 약 30분)'));
    });

    test(
        'resyncExternalPreparationForDay moves prep start to newly earlier place event',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      final tenOClock = EventModel(
        id: 'ten-place',
        userId: 'user-1',
        title: '10시 거래처 방문',
        startAt: DateTime(2026, 5, 8, 10),
        location: '강릉아산병원',
      );
      final nineOClock = EventModel(
        id: 'nine-place',
        userId: 'user-1',
        title: '9시 고객 미팅',
        startAt: DateTime(2026, 5, 8, 9),
        location: '강릉역',
      );

      final result = await service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[tenOClock, nineOClock],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        now: DateTime(2026, 5, 8, 6),
      );

      expect(result, true);
      expect(gateway.deletedExternalPreActionEventIds, [
        'nine-place',
        'ten-place',
      ]);
      expect(notifications.cancelledSmartPreparationEventIds, [
        'nine-place',
        'ten-place',
      ]);
      final nineTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'nine-place')
          .map((row) => row['title']);
      final tenTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'ten-place')
          .map((row) => row['title']);
      expect(
        nineTitles.any((title) => title.toString().contains('지금 준비 시작하세요')),
        true,
      );
      expect(
        tenTitles.any((title) => title.toString().contains('지금 준비 시작하세요')),
        false,
      );
      expect(tenTitles, contains('지금 출발하세요 🚗 (이동 약 30분)'));
    });

    test(
        'resyncExternalPreparationForDay ignores earlier event without place for prep target',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      final noPlace = EventModel(
        id: 'nine-no-place',
        userId: 'user-1',
        title: '9시 전화 회의',
        startAt: DateTime(2026, 5, 8, 9),
      );
      final place = EventModel(
        id: 'ten-place',
        userId: 'user-1',
        title: '10시 거래처 방문',
        startAt: DateTime(2026, 5, 8, 10),
        location: '강릉아산병원',
      );

      final result = await service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[noPlace, place],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        now: DateTime(2026, 5, 8, 6),
      );

      expect(result, true);
      expect(gateway.deletedExternalPreActionEventIds, ['ten-place']);
      expect(notifications.cancelledSmartPreparationEventIds, ['ten-place']);
      final noPlaceTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'nine-no-place')
          .map((row) => row['title']);
      final placeTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'ten-place')
          .map((row) => row['title']);
      expect(noPlaceTitles, isEmpty);
      expect(
        placeTitles.any((title) => title.toString().contains('지금 준비 시작하세요')),
        true,
      );
    });
  });
}

class _FakeManualEventGateway extends ManualEventSideEffectGateway {
  final deletedReminderEventIds = <String>[];
  final deletedPreActionEventIds = <String>[];
  final insertedReminders = <Map<String, dynamic>>[];
  final insertedPreActions = <Map<String, dynamic>>[];

  @override
  Future<void> deleteRemindersForEvent({
    required String eventId,
    required String userId,
  }) async {
    deletedReminderEventIds.add(eventId);
  }

  @override
  Future<void> deletePreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {
    deletedPreActionEventIds.add(eventId);
  }

  @override
  Future<void> deleteExternalPreparationPreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {
    deletedExternalPreActionEventIds.add(eventId);
  }

  final deletedExternalPreActionEventIds = <String>[];

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    insertedReminders.addAll(payloads);
  }

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {
    insertedPreActions.addAll(payloads);
  }
}

class _SlowManualEventGateway extends _FakeManualEventGateway {
  int insertPreActionsCallCount = 0;

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {
    insertPreActionsCallCount += 1;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await super.insertPreActions(payloads);
  }
}

class _FakeEventRepository extends EventRepository {
  const _FakeEventRepository({this.events = const <EventModel>[]});

  final List<EventModel> events;

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
    return events
        .where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;
}

class _FakeNotificationService extends NotificationService {
  final cancelledEventIds = <String>[];
  final cancelledNotificationIds = <int>[];
  final scheduledEventReminderIds = <int>[];
  final scheduledCriticalAlarmIds = <int>[];
  final scheduledCriticalNotifyAts = <DateTime>[];
  final cancelledSmartPreparationEventIds = <String>[];

  @override
  Future<void> cancel(int id) async {
    cancelledNotificationIds.add(id);
  }

  @override
  Future<void> cancelEventNotifications(String eventId) async {
    cancelledEventIds.add(eventId);
  }

  @override
  Future<void> cancelSmartPreparationAlarms(String eventId) async {
    cancelledSmartPreparationEventIds.add(eventId);
  }

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
  }) async {
    scheduledEventReminderIds.add(id);
  }

  @override
  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
  }) async {
    scheduledCriticalAlarmIds.add(id);
    scheduledCriticalNotifyAts.add(notifyAt);
  }

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
  }) async {
    scheduledCriticalAlarmIds.add(id);
    scheduledCriticalNotifyAts.add(notifyAt);
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }
}

class _FakeDepartureAlarmService extends DepartureAlarmService {
  int scheduleForEventCallCount = 0;
  int scheduleNextMonitorCallCount = 0;
  final scheduledEventIds = <String>[];

  @override
  Future<DepartureAlarmScheduleResult> scheduleForEvent(
    EventModel event, {
    bool rescheduleMonitor = true,
  }) async {
    scheduleForEventCallCount += 1;
    scheduledEventIds.add(event.id);
    return DepartureAlarmScheduleResult.scheduled(
      notifyAt: DateTime(2026, 5, 8, 8),
      travelMinutes: 30,
    );
  }

  @override
  Future<bool> scheduleNextMonitor() async {
    scheduleNextMonitorCallCount += 1;
    return true;
  }
}

class _FakeTravelTimeBufferService extends TravelTimeBufferService {
  _FakeTravelTimeBufferService({required this.minutes});

  final int minutes;

  @override
  Future<TravelTimeBufferEstimate> estimateWithMapApis({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
    String? locationText,
  }) async {
    return TravelTimeBufferEstimate(
      buffer: Duration(minutes: minutes),
      source: TravelTimeBufferSource.tmap,
      reason: 'test',
    );
  }
}
