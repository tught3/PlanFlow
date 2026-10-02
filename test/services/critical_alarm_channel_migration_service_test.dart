import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/critical_alarm_acknowledgement_store.dart';
import 'package:planflow/services/critical_alarm_channel_migration_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('CriticalAlarmChannelMigrationService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('reschedules only future critical events once per channel', () async {
      final now = DateTime.utc(2026, 5, 24, 3);
      final repository = _FakeEventRepository(<EventModel>[
        _event('past-critical', now.subtract(const Duration(hours: 1)), true),
        _event('future-normal', now.add(const Duration(hours: 2)), false),
        _event('future-critical', now.add(const Duration(hours: 3)), true),
      ]);
      final sideEffects = _FakeManualEventSideEffectService();
      final service = CriticalAlarmChannelMigrationService(
        eventRepository: repository,
        sideEffectService: sideEffects,
        now: () => now,
      );

      expect(
        await service.migrateFutureCriticalAlarmsIfNeeded('user-1'),
        isTrue,
      );
      expect(repository.listCalls, 1);
      expect(sideEffects.resyncedEventIds, <String>['future-critical']);

      expect(
        await service.migrateFutureCriticalAlarmsIfNeeded('user-1'),
        isTrue,
      );
      expect(repository.listCalls, 1);
      expect(sideEffects.calls, 1);
    });

    test('uses current critical alarm channel id in migration key', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = CriticalAlarmChannelMigrationService(
        eventRepository: _FakeEventRepository(const <EventModel>[]),
        sideEffectService: _FakeManualEventSideEffectService(),
      );

      expect(
          await service.migrateFutureCriticalAlarmsIfNeeded('user-1'), isTrue);

      expect(
        prefs.getBool(
          'critical_alarm_channel_migration:user-1:'
          '${NotificationService.criticalAlarmChannelId}',
        ),
        isTrue,
      );
    });

    test(
        '사용자가 확인(출발) 누른 일정은 채널 마이그레이션이 다시 알람을 '
        '예약하지 않는다 (gate 통과 검증)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 테스트는 시스템 타임존에서 돌기 때문에 미래 시각을 직접 사용한다.
      // startAt이 과거면 resyncRemindersForEvents에서 필터링된다.
      final startAt = DateTime.now().add(const Duration(hours: 1));
      const ackStore =
          SharedPreferencesCriticalAlarmAcknowledgementStore();
      await ackStore.markAcknowledged('acked-critical', startAt);

      final now = DateTime.now();
      final repository = _FakeEventRepository(<EventModel>[
        // acked → 재예약되면 안 됨.
        _event('acked-critical', startAt, true),
        // 미확인 → 재예약되어야 함.
        _event('unacked-critical',
            now.add(const Duration(hours: 3)), true),
      ]);

      // 실제 `scheduleLocalNotifications` 로직을 그대로 타도록 같은
      // notificationService/ackStore를 주입한 ManualEventSideEffectService를
      // 사용한다. 즉, 마이그레이션이 `resyncRemindersForEvents`를 호출하면
      // 실제 게이트(strong alarm ack)를 통과한다.
      final notifications = _RecordingNotificationService();
      final sideEffects = ManualEventSideEffectService(
        gateway: const _FakeManualEventSideEffectGateway(),
        departureAlarmService: const _NoopDepartureAlarmService(),
        notificationService: notifications,
        criticalAlarmAcknowledgementStore: ackStore,
      );
      final service = CriticalAlarmChannelMigrationService(
        eventRepository: repository,
        sideEffectService: sideEffects,
        now: () => now,
      );

      expect(
        await service.migrateFutureCriticalAlarmsIfNeeded('user-1'),
        isTrue,
      );

      // acked 일정은 강한알람 예약이 호출되지 않아야 한다.
      expect(
        notifications.scheduledCriticalIdsByEventId.contains('acked-critical'),
        isFalse,
        reason: '채널 마이그레이션도 ack 게이트를 통과해 확인된 일정의 '
            '강한알람은 다시 예약되면 안 된다.',
      );
      // 미확인 일정은 정상 예약.
      expect(
        notifications.scheduledCriticalIdsByEventId.contains('unacked-critical'),
        isTrue,
      );
    });
  });
}

EventModel _event(String id, DateTime startAt, bool isCritical) {
  return EventModel(
    id: id,
    userId: 'user-1',
    title: id,
    startAt: startAt,
    isCritical: isCritical,
  );
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.events);

  final List<EventModel> events;
  int listCalls = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    listCalls += 1;
    return events;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeManualEventSideEffectService extends ManualEventSideEffectService {
  final resyncedEventIds = <String>[];
  int calls = 0;

  @override
  Future<bool> resyncRemindersForEvents({
    required Iterable<EventModel> events,
    required String userId,
    Duration? reminderOffset =
        ManualEventSideEffectService.defaultReminderOffset,
    Duration? criticalAlarmOffset =
        ManualEventSideEffectService.criticalAlarmOffset,
  }) async {
    calls += 1;
    resyncedEventIds.addAll(events.map((event) => event.id));
    return true;
  }
}

class _FakeManualEventSideEffectGateway extends ManualEventSideEffectGateway {
  const _FakeManualEventSideEffectGateway();

  @override
  Future<void> deleteRemindersForEvent({
    required String eventId,
    required String userId,
  }) async {}

  @override
  Future<void> deletePreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {}

  @override
  Future<void> deleteExternalPreparationPreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {}

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {}

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {}
}

/// 강한알람 재예약 호출을 eventId 기준으로 기록하는 NotificationService 페이크.
/// ManualEventSideEffectService가 알람을 예약하려고 시도한 eventId들을 모아
/// 테스트가 검증한다.
class _RecordingNotificationService extends NotificationService {
  final scheduledCriticalIdsByEventId = <String>[];

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> cancelEventNotifications(String eventId) async {}

  @override
  Future<void> cancelEventReminderNotifications(String eventId) async {}

  @override
  Future<NotificationScheduleResult> scheduleCriticalAlarmWithResult({
    required int id,
    required String title,
    required DateTime notifyAt,
    String? body,
    String? payload,
    bool useStrongAlarm = true,
  }) async {
    // payload 'event:<id>:critical' 형태에서 eventId를 추출한다.
    final p = payload ?? '';
    if (p.startsWith('event:')) {
      var value = p.substring('event:'.length);
      if (value.endsWith(':critical')) {
        value = value.substring(0, value.length - ':critical'.length);
      }
      scheduledCriticalIdsByEventId.add(value);
    }
    return NotificationScheduleResult(
      status: NotificationScheduleStatus.scheduled,
      notifyAt: notifyAt,
    );
  }
}

class _NoopDepartureAlarmService extends DepartureAlarmService {
  const _NoopDepartureAlarmService();

  @override
  Future<DepartureAlarmScheduleResult> scheduleForEvent(
    EventModel event, {
    bool rescheduleMonitor = true,
    Duration? safetyMarginOverride,
    MapTravelMode? travelModeOverride,
    bool fireDueDeparture = false,
    bool cacheOnlyLocation = false,
  }) async {
    return const DepartureAlarmScheduleResult.skipped('noop');
  }

  @override
  Future<void> acknowledgeDeparture(String eventId) async {}

  @override
  Future<void> clearAcknowledgement(String eventId) async {}
}