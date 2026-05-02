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
  });
}

class _FakeManualEventGateway extends ManualEventSideEffectGateway {
  final deletedReminderEventIds = <String>[];
  final deletedPreActionEventIds = <String>[];
  final insertedReminders = <Map<String, dynamic>>[];

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
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    insertedReminders.addAll(payloads);
  }
}

class _FakeNotificationService extends NotificationService {
  final cancelledEventIds = <String>[];
  final scheduledEventReminderIds = <int>[];
  final scheduledCriticalAlarmIds = <int>[];
  final scheduledCriticalNotifyAts = <DateTime>[];

  @override
  Future<void> cancelEventNotifications(String eventId) async {
    cancelledEventIds.add(eventId);
  }

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
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
}
