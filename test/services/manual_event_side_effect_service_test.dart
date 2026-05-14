import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/notification_service.dart';

void main() {
  group('ManualEventSideEffectService', () {
    test('builds default reminder row for manual events', () {
      final service = ManualEventSideEffectService(
        gateway: _FakeManualEventGateway(),
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
        notificationService: notifications,
      );

      await service.cleanupAfterDelete('event-3');

      expect(notifications.cancelledEventIds, ['event-3']);
    });

    test('resyncRemindersForEvents replaces DB rows and local alarms',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
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

    test('resyncExternalPreparationForDay promotes earliest place event',
        () async {
      final gateway = _FakeManualEventGateway();
      final notifications = _FakeNotificationService();
      final service = ManualEventSideEffectService(
        gateway: gateway,
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
