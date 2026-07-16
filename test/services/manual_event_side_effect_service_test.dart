import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/diag_logger.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    // [PREVENT] 1시간 이내 시작 일정은 reminder(기본 60분 전)가 과거가 되어
    // 스킵되던 버그 → 시작 정각으로 보정해 알림이 오게 한다.
    test('1시간 이내 시작 일정은 reminder를 시작 정각에 예약한다(60분 전이 과거여도 스킵 안 함)', () async {
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: _FakeManualEventGateway(),
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
      );
      // 지금부터 30분 뒤 시작 → 60분 전 알림은 과거 → 시작 정각(startAt)으로 보정돼야 함
      final startAt = DateTime.now().add(const Duration(minutes: 30));
      final event = EventModel(
        id: 'event-soon',
        userId: 'user-1',
        title: '곧 시작',
        startAt: startAt,
      );

      await service.scheduleLocalNotifications(event);

      expect(notifications.scheduledEventReminderNotifyAts, hasLength(1));
      expect(notifications.scheduledEventReminderNotifyAts.single, startAt);
    });

    test('replaces reminders and clears pre-actions before rescheduling',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final departure = _FakeDepartureAlarmService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: departure,
        notificationService: notifications,
      );
      final event = EventModel(
        id: 'event-2',
        userId: 'user-1',
        title: '중요 발표',
        startAt: DateTime.now().add(const Duration(hours: 3)),
        isCritical: true,
        // 3bc6a28 이후 system_alarm은 useStrongAlarm 필드로 제어됨 (isCritical과 분리)
        useStrongAlarm: true,
      );

      final result = await service.syncAfterSave(
        event: event,
        userId: 'user-1',
      );

      expect(result.isFullySynced, true);
      expect(gateway.deletedReminderEventIds, ['event-2']);
      expect(gateway.deletedPreActionEventIds, ['event-2']);
      expect(departure.clearedAcknowledgementEventIds, ['event-2']);
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

    test('marks event critical when generated pre-actions exist', () async {
      final gateway = _FakeManualEventGateway();
      final repository = _FakeEventRepository();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: repository,
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: notifications,
        travelTimeBufferService: _FakeTravelTimeBufferService(routeMinutes: 20),
        currentLocationProvider: () async => const GeoPoint(
          latitude: 37.5,
          longitude: 127,
        ),
      );
      final event = EventModel(
        id: 'event-critical-by-pre-action',
        userId: 'user-1',
        title: '외부 미팅',
        startAt: DateTime.now().add(const Duration(hours: 3)),
        location: '강남역',
        locationLat: 37.4979,
        locationLng: 127.0276,
        isCritical: false,
        // 3bc6a28 이후 system_alarm은 useStrongAlarm 필드로 제어됨.
        // pre-action 생성 시 isCritical이 true로 자동 설정되지만
        // useStrongAlarm은 사용자 토글 값 그대로 유지됨.
        useStrongAlarm: true,
      );

      await service.syncAfterSave(
        event: event,
        userId: 'user-1',
      );

      expect(gateway.insertedPreActions, isNotEmpty);
      expect(repository.updatedEvents, hasLength(1));
      expect(repository.updatedEvents.single.id, event.id);
      expect(repository.updatedEvents.single.isCritical, isTrue);
      expect(
        gateway.insertedReminders.map((row) => row['type']),
        containsAll(<String>['push', 'system_alarm']),
      );
      expect(notifications.scheduledCriticalAlarmIds, hasLength(1));
    });

    test('delete cleanup cancels local notifications for the event', () async {
      final notifications = _FakeNotificationService();
      final departure = _FakeDepartureAlarmService();
      final service = ManualEventSideEffectService(
        gateway: _FakeManualEventGateway(),
        eventRepository: _FakeEventRepository(),
        departureAlarmService: departure,
        notificationService: notifications,
      );

      await service.cleanupAfterDelete('event-3');

      expect(notifications.cancelledEventIds, ['event-3']);
      expect(departure.clearedAcknowledgementEventIds, ['event-3']);
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
      expect(nineTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(tenTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(nineTitles.any(_isPreparationStartAlarmTitle), true);
      expect(tenTitles.any(_isPreparationStartAlarmTitle), false);
      expect(
        notifications.cancelledNotificationIds,
        containsAll(<int>[
          notifications.notificationIdFor('nine-place:departure'),
          notifications.notificationIdFor('ten-place:departure'),
        ]),
      );
      expect(
        departure.scheduledEventIds,
        containsAll(<String>[
          'nine-place',
          'ten-place',
        ]),
      );
      expect(departure.scheduleNextMonitorCallCount, 1);
    });

    test('syncAfterSave passes custom departure safety margin to alarms',
        () async {
      final departure = _FakeDepartureAlarmService();
      final service = ManualEventSideEffectService(
        gateway: _FakeManualEventGateway(),
        eventRepository: _FakeEventRepository(
          events: <EventModel>[
            EventModel(
              id: 'target-place',
              userId: 'user-1',
              title: '10시 거래처 방문',
              startAt: DateTime(2026, 5, 8, 10),
              location: '강릉아산병원',
              locationLat: 37.7563,
              locationLng: 128.8758,
            ),
          ],
        ),
        departureAlarmService: departure,
        notificationService: _FakeNotificationService(),
        now: () => DateTime(2026, 5, 8, 6),
      );

      await service.syncAfterSave(
        event: EventModel(
          id: 'target-place',
          userId: 'user-1',
          title: '10시 거래처 방문',
          startAt: DateTime(2026, 5, 8, 10),
          location: '강릉아산병원',
          locationLat: 37.7563,
          locationLng: 128.8758,
        ),
        userId: 'user-1',
        departureSafetyMargin: const Duration(minutes: 17),
      );

      expect(departure.lastSafetyMarginOverride, const Duration(minutes: 17));
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
      expect(departure.clearedAcknowledgementEventIds, ['deleted-event']);
      expect(gateway.deletedExternalPreActionEventIds, ['remaining-place']);
      final remainingTitles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'remaining-place')
          .map((row) => row['title'].toString());
      expect(remainingTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(
        notifications.cancelledNotificationIds,
        contains(notifications.notificationIdFor('remaining-place:departure')),
      );
      expect(departure.scheduledEventIds, ['remaining-place']);
    });

    test(
        'syncAfterSave uses dynamic travel minutes when route can be estimated',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final fakeTravelTime = _FakeTravelTimeBufferService(
        routeMinutes: 90,
      );
      final service = ManualEventSideEffectService(
        gateway: gateway,
        notificationService: notifications,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        travelTimeBufferService: fakeTravelTime,
        currentLocationProvider: () async =>
            const GeoPoint(latitude: 37.5, longitude: 127),
        now: () => DateTime(2026, 5, 8, 6),
      );
      final event = EventModel(
        id: 'route-event',
        userId: 'user-1',
        title: 'Client visit',
        startAt: DateTime(2026, 5, 8, 10),
        location: 'Seoul Station',
        locationLat: 37.7646,
        locationLng: 128.8995,
      );

      await service.syncAfterSave(
        event: event,
        userId: 'user-1',
        travelMode: 'car',
      );

      final externalRows = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'route-event')
          .toList();
      expect(fakeTravelTime.lastMode, MapTravelMode.car);
      expect(externalRows, isNotEmpty,
          reason: 'external preparation rows should exist');
      expect(
        externalRows.any((row) => row['title'].toString().contains('90')),
        true,
      );
      final departureRow = externalRows.firstWhere(
        (row) => row['title'].toString().contains('90'),
        orElse: () => const <String, dynamic>{},
      );
      expect(fakeTravelTime.lastMode, MapTravelMode.car);
      expect(
        departureRow,
        isNot(const <String, dynamic>{}),
      );
      expect(
        departureRow['notify_at'],
        DateTime(2026, 5, 8, 8, 10).toIso8601String(),
      );
    });

    test('syncAfterSave geocodes destination text before estimating travel',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final fakeTravelTime = _FakeTravelTimeBufferService(
        routeMinutes: 42,
      );
      final lookup = _FakeLocationLookupService(
        result: const LocationLookupResult(
          name: 'Wonju Severance Christian Hospital',
          address: 'Gangwon-do Wonju-si',
          latitude: 37.3421,
          longitude: 127.9421,
        ),
      );
      final service = ManualEventSideEffectService(
        gateway: gateway,
        notificationService: notifications,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        travelTimeBufferService: fakeTravelTime,
        locationLookupService: lookup,
        currentLocationProvider: () async =>
            const GeoPoint(latitude: 37.5, longitude: 127),
        now: () => DateTime(2026, 5, 8, 6),
      );
      final event = EventModel(
        id: 'geo-event',
        userId: 'user-1',
        title: 'Client visit',
        startAt: DateTime(2026, 5, 8, 10),
        location: 'Wonju Severance Christian Hospital',
      );

      await service.syncAfterSave(
        event: event,
        userId: 'user-1',
        travelMode: 'transit',
      );

      expect(lookup.searchQueries, ['Wonju Severance Christian Hospital']);
      expect(fakeTravelTime.lastMode, MapTravelMode.transit);
      expect(fakeTravelTime.lastDestinationLat, 37.3421);
      expect(fakeTravelTime.lastDestinationLng, 127.9421);
      expect(
        gateway.insertedPreActions.any(
          (row) => row['event_id'] == 'geo-event',
        ),
        true,
      );
    });

    // [PREVENT] event_preparation_service.dart와 동일한 목적지 쿼리 캡 회귀
    // 테스트(중복 구현 _buildDestinationSearchQueries/_resolveDestinationForEvent
    // 쪽). 이벤트 1건의 좌표 미해결 검색이 tmap POI 레이트리밋(60/60s)을 혼자
    // 잡아먹는 폭주를 막기 위해 단독 쿼리(location/title/memo) 3개까지만
    // 시도해야 한다(2026-07-04 실측: window_count=60 폭주 신고).
    test(
        'syncAfterSave caps destination search queries when all variants '
        'are unresolvable (rate-limit storm prevention)', () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final lookup = _FakeLocationLookupService(
        result: const LocationLookupResult(
          name: '',
          address: '',
          latitude: 0,
          longitude: 0,
        ),
        alwaysEmpty: true,
      );
      final service = ManualEventSideEffectService(
        gateway: gateway,
        notificationService: notifications,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        travelTimeBufferService: _FakeTravelTimeBufferService(routeMinutes: 30),
        locationLookupService: lookup,
        currentLocationProvider: () async =>
            const GeoPoint(latitude: 37.5, longitude: 127),
        now: () => DateTime(2026, 5, 8, 6),
      );
      final event = EventModel(
        id: 'unresolvable-event',
        userId: 'user-1',
        title: 'Totally Unrelated Title Text',
        location: 'Totally Unrelated Location Text',
        memo: 'Totally Unrelated Memo Text',
        startAt: DateTime(2026, 5, 8, 10),
        // location/title/memo가 전부 달라 _buildDestinationSearchQueries가
        // 6개(단독 3 + 조합 3)의 서로 다른 쿼리를 만들어낸다.
      );

      await service.syncAfterSave(
        event: event,
        userId: 'user-1',
        travelMode: 'car',
      );

      expect(
        lookup.searchQueries.length,
        lessThanOrEqualTo(3),
        reason: '목적지 쿼리는 최대 3개(단독 location/title/memo)까지만 시도해야 한다. '
            '조합형 쿼리 3개까지 전부 시도하면 이벤트 1건만으로 tmap POI가 '
            '최대 36콜까지 치솟아 60/60s 레이트리밋을 혼자 소진한다.',
      );
    });

    test(
        'resyncExternalPreparationForDay uses destination coordinates when current location is unavailable',
        () async {
      final gateway = _FakeManualEventGateway();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        notificationService: _FakeNotificationService(),
        currentLocationProvider: () async => null,
        now: () => DateTime(2026, 5, 8, 6),
      );
      final event = EventModel(
        id: 'coords-no-origin',
        userId: 'user-1',
        title: '거래처 방문',
        startAt: DateTime(2026, 5, 8, 10),
        location: '강남역',
        locationLat: 37.4979,
        locationLng: 127.0276,
      );

      final result = await service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[event],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        now: DateTime(2026, 5, 8, 6),
        cacheOnlyLocation: true,
      );

      expect(result, true);
      final titles = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'coords-no-origin')
          .map((row) => row['title'].toString())
          .toList();
      expect(titles.any(_isDepartureExternalAlarmTitle), true);
      expect(
        titles.any((title) => title.contains('위치 확인 불가, 기본값')),
        false,
      );
      expect(titles, isNot(contains('지금 출발하세요 🚗 (이동 약 30분)')));
    });

    // [PREVENT] 유령 장소 주입 회귀 방지 (2026-07-16).
    // 과거: location이 비어도 event.title/event.memo를 장소 검색어로 폴백해
    // 무관한 POI가 사용자 일정에 주입됐다. 이제는 event.location(사용자가 이름으로
    // 적은 장소)만 검색어로 쓰고, title/memo는 절대 쓰지 않는다. 또한 좌표 backfill
    // 시 사용자 location 원문을 POI 공식명(bestPlaceLabel)으로 덮어쓰지 않고
    // 좌표만 채운다.
    test(
        'syncAfterSave geocodes using event.location only, never title/memo, '
        'and preserves the user-entered location text', () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final fakeTravelTime = _FakeTravelTimeBufferService(
        routeMinutes: 55,
      );
      final lookup = _FakeLocationLookupService(
        result: const LocationLookupResult(
          // 검색 결과의 공식명이 사용자 원문과 다르더라도 덮어쓰면 안 된다.
          name: 'Wonju Severance Christian Hospital (official)',
          address: 'Gangwon-do Wonju-si',
          latitude: 37.3421,
          longitude: 127.9421,
        ),
      );
      final repository = _FakeEventRepository();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        notificationService: notifications,
        eventRepository: repository,
        departureAlarmService: _FakeDepartureAlarmService(),
        travelTimeBufferService: fakeTravelTime,
        locationLookupService: lookup,
        currentLocationProvider: () async =>
            const GeoPoint(latitude: 37.5, longitude: 127),
        now: () => DateTime(2026, 5, 8, 6),
      );
      final event = EventModel(
        id: 'location-event',
        userId: 'user-1',
        title: '회의',
        memo: 'Totally unrelated memo text',
        location: '원주세브란스',
        startAt: DateTime(2026, 5, 8, 10),
      );

      await service.syncAfterSave(
        event: event,
        userId: 'user-1',
      );

      // title/memo는 검색어로 전달되면 안 되고, location 텍스트만 검색한다.
      expect(lookup.searchQueries, contains('원주세브란스'));
      expect(lookup.searchQueries, isNot(contains('회의')));
      expect(
        lookup.searchQueries,
        isNot(contains('Totally unrelated memo text')),
      );
      expect(fakeTravelTime.lastDestinationLat, 37.3421);
      expect(fakeTravelTime.lastDestinationLng, 127.9421);
      // 이 이벤트에 대한 updateEvent는 좌표 backfill 외에 critical 플래그 동기화
      // 등으로 여러 번 일어날 수 있다. 어떤 업데이트도 사용자 location 원문을 POI
      // 공식명으로 덮어써서는 안 되며, 좌표를 채운 backfill은 사용자 원문을
      // 그대로 유지해야 한다.
      final updatesForEvent = repository.updatedEvents
          .where((e) => e.id == 'location-event')
          .toList();
      expect(
        updatesForEvent
            .every((e) => e.location != 'Wonju Severance Christian Hospital (official)'),
        true,
        reason: 'POI 검색 공식명이 사용자 location 원문을 덮어쓰면 안 된다.',
      );
      final coordBackfills = updatesForEvent
          .where((e) => e.locationLat == 37.3421 && e.locationLng == 127.9421)
          .toList();
      expect(coordBackfills, isNotEmpty,
          reason: '좌표 backfill이 최소 1회 일어나야 한다.');
      expect(
        coordBackfills.every((e) => e.location == '원주세브란스'),
        true,
        reason: '좌표를 채운 backfill은 사용자가 적은 location 원문을 유지해야 한다.',
      );
    });

    test(
        'recalculate cancels stale departure alarms even with no upcoming events',
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
        // 3bc6a28 이후 system_alarm은 useStrongAlarm 필드로 제어됨 (isCritical과 분리)
        useStrongAlarm: true,
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

    test(
        'resyncExternalPreparationForDay uses dynamic travel minutes from route estimate',
        () async {
      final fakeTravelTime = _FakeTravelTimeBufferService(routeMinutes: 90);
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
        eventRepository: _FakeEventRepository(),
        departureAlarmService: _FakeDepartureAlarmService(),
        travelTimeBufferService: fakeTravelTime,
        currentLocationProvider: () async =>
            const GeoPoint(latitude: 37.5, longitude: 127),
        notificationService: notifications,
        now: () => DateTime(2026, 5, 8, 6),
      );
      final event = EventModel(
        id: 'trip-route',
        userId: 'user-1',
        title: '버스 이용 미팅',
        startAt: DateTime(2026, 5, 8, 10),
        location: '서울역',
        locationLat: 37.7646,
        locationLng: 128.8995,
      );

      await service.resyncExternalPreparationForDay(
        dayEvents: <EventModel>[event],
        userId: 'user-1',
        dayReference: DateTime(2026, 5, 8),
        travelMode: 'transit',
        now: DateTime(2026, 5, 8, 6),
      );

      final externalRows = gateway.insertedPreActions
          .where((row) => row['event_id'] == 'trip-route')
          .toList();
      expect(
        externalRows.any((row) => row['title'].toString().contains('90')),
        true,
      );
      final departureRow = externalRows.firstWhere(
        (row) => row['title'].toString().contains('90'),
        orElse: () => const <String, dynamic>{},
      );
      expect(
        departureRow,
        isNot(const <String, dynamic>{}),
      );
      expect(fakeTravelTime.lastMode, MapTravelMode.transit);
      expect(
        departureRow['notify_at'],
        DateTime(2026, 5, 8, 8, 10).toIso8601String(),
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
      expect(tripTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(meetingTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(tripTitles.any(_isPreparationStartAlarmTitle), true);
      expect(meetingTitles.any(_isPreparationStartAlarmTitle), false);
      expect(
        meetingTitles,
        contains('지금 출발하세요 🚗 (이동 약 30분 — 위치 확인 불가, 기본값)'),
      );
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
      expect(nineTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(tenTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(nineTitles.any(_isPreparationStartAlarmTitle), true);
      expect(tenTitles.any(_isPreparationStartAlarmTitle), false);
      expect(
        tenTitles,
        contains('지금 출발하세요 🚗 (이동 약 30분 — 위치 확인 불가, 기본값)'),
      );
    });

    // ── DiagLogger 로깅 검증 테스트 ──────────────────────────────────────────
    // 편집 경로(syncAfterSave)에서 DiagLogger에 ManualSideEffect 태그 로그가
    // 실제로 남는지 검증한다.  confirm 경로와 달리 이 경로엔 진단 로그가 없어
    // 기기에서 알람 등록 여부를 추적할 수 없었던 문제를 방지한다.
    group('DiagLogger 로깅', () {
      setUp(DiagLogger.clear);

      test('syncAfterSave: 장소 있는 일정 저장 시 ManualSideEffect 로그가 기록된다', () async {
        final service = ManualEventSideEffectService(
          gateway: _FakeManualEventGateway(),
          eventRepository: _FakeEventRepository(),
          departureAlarmService: _FakeDepartureAlarmService(),
          notificationService: _FakeNotificationService(),
          now: () => DateTime(2026, 5, 8, 6),
        );
        final event = EventModel(
          id: 'diag-event',
          userId: 'user-1',
          title: '외부 미팅',
          startAt: DateTime(2026, 5, 8, 10),
          location: '강남역',
          locationLat: 37.4979,
          locationLng: 127.0276,
        );

        await service.syncAfterSave(event: event, userId: 'user-1');

        final dump = DiagLogger.dump();
        // 진입 로그: hasLocation=true 포함 여부
        expect(
          dump,
          contains('ManualSideEffect'),
          reason: 'ManualSideEffect 태그 로그가 DiagLogger에 기록되어야 한다',
        );
        expect(
          dump,
          contains('syncAfterSave 시작'),
          reason: '편집 경로 진입 로그가 기록되어야 한다',
        );
        expect(
          dump,
          contains('hasLocation=true'),
          reason: '장소 있는 일정이면 hasLocation=true로 기록되어야 한다',
        );
      });

      test('syncAfterSave: 장소 없는 일정 저장 시 hasLocation=false가 기록된다', () async {
        final service = ManualEventSideEffectService(
          gateway: _FakeManualEventGateway(),
          eventRepository: _FakeEventRepository(),
          departureAlarmService: _FakeDepartureAlarmService(),
          notificationService: _FakeNotificationService(),
          now: () => DateTime(2026, 5, 8, 6),
        );
        final event = EventModel(
          id: 'diag-no-place',
          userId: 'user-1',
          title: '전화 회의',
          startAt: DateTime(2026, 5, 8, 10),
        );

        await service.syncAfterSave(event: event, userId: 'user-1');

        expect(
          DiagLogger.dump(),
          contains('hasLocation=false'),
          reason: '장소 없는 일정이면 hasLocation=false로 기록되어야 한다',
        );
      });

      test('recalculateAlarmsForEvents: 장소 없는 일정은 DepartureAlarm 스킵 로그가 기록된다',
          () async {
        final departure = _FakeDepartureAlarmService();
        final service = ManualEventSideEffectService(
          gateway: _FakeManualEventGateway(),
          eventRepository: _FakeEventRepository(),
          departureAlarmService: departure,
          notificationService: _FakeNotificationService(),
          now: () => DateTime(2026, 5, 8, 6),
        );
        final noPlaceEvent = EventModel(
          id: 'no-place-event',
          userId: 'user-1',
          title: '내부 회의',
          startAt: DateTime(2026, 5, 8, 10),
        );

        await service.recalculateAlarmsForEvents(
          events: <EventModel>[noPlaceEvent],
          userId: 'user-1',
          now: DateTime(2026, 5, 8, 6),
        );

        expect(
          DiagLogger.dump(),
          contains('DepartureAlarm 스킵(장소없음)'),
          reason: '장소 없는 일정은 출발 알람 스킵 로그가 남아야 한다',
        );
        expect(
          departure.scheduledEventIds,
          isEmpty,
          reason: '장소 없는 일정에는 출발 알람이 등록되지 않아야 한다',
        );
      });

      test('recalculateAlarmsForEvents: 장소 있는 일정은 DepartureAlarm 등록 로그가 기록된다',
          () async {
        final departure = _FakeDepartureAlarmService();
        final service = ManualEventSideEffectService(
          gateway: _FakeManualEventGateway(),
          eventRepository: _FakeEventRepository(),
          departureAlarmService: departure,
          notificationService: _FakeNotificationService(),
          now: () => DateTime(2026, 5, 8, 6),
        );
        final placeEvent = EventModel(
          id: 'place-event',
          userId: 'user-1',
          title: '거래처 방문',
          startAt: DateTime(2026, 5, 8, 10),
          location: '강남역',
          locationLat: 37.4979,
          locationLng: 127.0276,
        );

        await service.recalculateAlarmsForEvents(
          events: <EventModel>[placeEvent],
          userId: 'user-1',
          now: DateTime(2026, 5, 8, 6),
        );

        final dump = DiagLogger.dump();
        expect(
          dump,
          contains('DepartureAlarm 등록'),
          reason: '장소 있는 일정은 출발 알람 등록 로그가 남아야 한다',
        );
        expect(
          departure.scheduledEventIds,
          contains('place-event'),
          reason: '장소 있는 일정에는 출발 알람이 등록되어야 한다',
        );
      });

      test(
          'resyncExternalPreparationForDay: 두 번째 외부일정은 준비 알람 payload가 0개임을 로그로 확인',
          () async {
        final gateway = _FakeManualEventGateway();
        final service = ManualEventSideEffectService(
          gateway: gateway,
          eventRepository: _FakeEventRepository(),
          departureAlarmService: _FakeDepartureAlarmService(),
          notificationService: _FakeNotificationService(),
          now: () => DateTime(2026, 5, 8, 6),
        );
        final firstEvent = EventModel(
          id: 'first-event',
          userId: 'user-1',
          title: '9시 거래처 방문',
          startAt: DateTime(2026, 5, 8, 9),
          location: '강남역',
        );
        final secondEvent = EventModel(
          id: 'second-event',
          userId: 'user-1',
          title: '11시 병원 방문',
          startAt: DateTime(2026, 5, 8, 11),
          location: '서울대병원',
        );

        await service.resyncExternalPreparationForDay(
          dayEvents: <EventModel>[firstEvent, secondEvent],
          userId: 'user-1',
          dayReference: DateTime(2026, 5, 8),
          now: DateTime(2026, 5, 8, 6),
        );

        final dump = DiagLogger.dump();
        // 첫 번째 일정: isFirst=true → 준비 알람 포함
        expect(
          dump,
          contains('eventId=first-event'),
          reason: '첫 번째 일정 로그가 기록되어야 한다',
        );
        // 두 번째 일정: isFirst=false → 준비 알람 없음(출발 알람만)
        expect(
          dump,
          contains('eventId=second-event'),
          reason: '두 번째 일정 로그가 기록되어야 한다',
        );

        // 첫 번째 일정에 준비 시작 알람이 있고, 두 번째엔 없음
        final firstPayloads = gateway.insertedPreActions
            .where((row) => row['event_id'] == 'first-event')
            .map((row) => row['title'].toString());
        final secondPayloads = gateway.insertedPreActions
            .where((row) => row['event_id'] == 'second-event')
            .map((row) => row['title'].toString());
        expect(
          firstPayloads.any(_isPreparationStartAlarmTitle),
          isTrue,
          reason: '첫 번째 외부 일정에는 준비 시작 알람이 있어야 한다',
        );
        expect(
          secondPayloads.any(_isPreparationStartAlarmTitle),
          isFalse,
          reason: '두 번째 외부 일정에는 준비 시작 알람이 없어야 한다(isFirst=false)',
        );
        expect(
          secondPayloads.any(_isDepartureExternalAlarmTitle),
          isTrue,
          reason: '두 번째 외부 일정에도 출발 알람은 있어야 한다',
        );
      });
    });
    // ── DiagLogger 로깅 검증 테스트 끝 ──────────────────────────────────────

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
      expect(placeTitles.any(_isDepartureExternalAlarmTitle), true);
      expect(placeTitles.any(_isPreparationStartAlarmTitle), true);
    });
  });
}

bool _isDepartureExternalAlarmTitle(Object? title) {
  final text = title?.toString() ?? '';
  return text.contains('지금 출발하세요') || text.contains('출발 알림');
}

bool _isPreparationStartAlarmTitle(Object? title) {
  final text = title?.toString() ?? '';
  return text.contains('지금 준비 시작하세요') || text.contains('준비 시작');
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

class _FakeTravelTimeBufferService extends TravelTimeBufferService {
  _FakeTravelTimeBufferService({required this.routeMinutes});

  final int routeMinutes;
  MapTravelMode? lastMode;
  double? lastOriginLat;
  double? lastOriginLng;
  double? lastDestinationLat;
  double? lastDestinationLng;

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
    lastMode = mode;
    lastOriginLat = originLat;
    lastOriginLng = originLng;
    lastDestinationLat = destinationLat;
    lastDestinationLng = destinationLng;
    return TravelTimeBufferEstimate(
      buffer: Duration(minutes: routeMinutes),
      source: TravelTimeBufferSource.googleMaps,
      reason: 'fake route estimate',
    );
  }
}

class _FakeLocationLookupService extends LocationLookupService {
  _FakeLocationLookupService({required this.result, this.alwaysEmpty = false});

  final LocationLookupResult result;
  final bool alwaysEmpty;
  final searchQueries = <String>[];

  @override
  Future<LocationLookupSearchResult> searchWithFallback(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    searchQueries.add(query);
    return LocationLookupSearchResult(
      originalQuery: query,
      results: alwaysEmpty
          ? const <LocationLookupResult>[]
          : <LocationLookupResult>[result],
      searchedQueries: <String>[query],
      fallbackQueries: const <String>[],
    );
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({this.events = const <EventModel>[]});

  final List<EventModel> events;
  final List<EventModel> updatedEvents = <EventModel>[];

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
  Future<EventModel> updateEvent(EventModel event) async {
    updatedEvents.add(event);
    return event;
  }
}

class _FakeNotificationService extends NotificationService {
  final cancelledEventIds = <String>[];
  final cancelledNotificationIds = <int>[];
  final scheduledEventReminderIds = <int>[];
  final scheduledEventReminderNotifyAts = <DateTime>[];
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
    bool includeDepartureAction = false,
  }) async {
    scheduledEventReminderIds.add(id);
    scheduledEventReminderNotifyAts.add(notifyAt);
  }

  @override
  Future<void> scheduleCriticalAlarm({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
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
    String? payload,
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
  final acknowledgedEventIds = <String>[];
  final clearedAcknowledgementEventIds = <String>[];
  Duration? lastSafetyMarginOverride;

  @override
  Future<DepartureAlarmScheduleResult> scheduleForEvent(
    EventModel event, {
    bool rescheduleMonitor = true,
    Duration? safetyMarginOverride,
    MapTravelMode? travelModeOverride,
    bool fireDueDeparture = false,
    bool cacheOnlyLocation = false,
  }) async {
    scheduleForEventCallCount += 1;
    scheduledEventIds.add(event.id);
    lastSafetyMarginOverride = safetyMarginOverride;
    return DepartureAlarmScheduleResult.scheduled(
      notifyAt: DateTime(2026, 5, 8, 8),
      travelMinutes: 30,
    );
  }

  @override
  Future<bool> scheduleNextMonitor({
    Duration? interval,
  }) async {
    scheduleNextMonitorCallCount += 1;
    return true;
  }

  @override
  Future<void> acknowledgeDeparture(String eventId) async {
    acknowledgedEventIds.add(eventId);
  }

  @override
  Future<void> clearAcknowledgement(String eventId) async {
    clearedAcknowledgementEventIds.add(eventId);
  }
}
