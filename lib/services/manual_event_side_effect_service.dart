import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models/event_model.dart';
import 'notification_service.dart';

abstract class ManualEventSideEffectGateway {
  const ManualEventSideEffectGateway();

  Future<void> deleteRemindersForEvent({
    required String eventId,
    required String userId,
  });

  Future<void> deletePreActionsForEvent({
    required String eventId,
    required String userId,
  });

  Future<void> insertReminders(List<Map<String, dynamic>> payloads);
}

class SupabaseManualEventSideEffectGateway
    extends ManualEventSideEffectGateway {
  const SupabaseManualEventSideEffectGateway({SupabaseClient? client})
      : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _resolvedClient => _client ?? Supabase.instance.client;

  @override
  Future<void> deleteRemindersForEvent({
    required String eventId,
    required String userId,
  }) async {
    await _resolvedClient
        .from('reminders')
        .delete()
        .eq('event_id', eventId)
        .eq('user_id', userId);
  }

  @override
  Future<void> deletePreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {
    await _resolvedClient
        .from('pre_actions')
        .delete()
        .eq('event_id', eventId)
        .eq('user_id', userId);
  }

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _resolvedClient.from('reminders').insert(payloads);
  }
}

class ManualEventSideEffectService {
  const ManualEventSideEffectService({
    this.gateway = const SupabaseManualEventSideEffectGateway(),
    NotificationService? notificationService,
  }) : _notificationService = notificationService;

  static const Duration defaultReminderOffset = Duration(minutes: 60);
  static const Duration criticalAlarmOffset = Duration(minutes: 60);

  final ManualEventSideEffectGateway gateway;
  final NotificationService? _notificationService;

  NotificationService get _notifications =>
      _notificationService ?? NotificationService();

  Future<ManualEventSideEffectResult> syncAfterSave({
    required EventModel event,
    required String userId,
    bool clearPreActions = true,
    Duration reminderOffset = defaultReminderOffset,
    Duration? criticalAlarmOffset,
  }) async {
    final startAt = event.startAt;
    if (startAt == null) {
      return const ManualEventSideEffectResult(
        remindersSynced: false,
        notificationsSynced: false,
        preActionsCleared: false,
      );
    }

    var remindersSynced = false;
    var notificationsSynced = false;
    var preActionsCleared = !clearPreActions;

    await _notifications.cancelEventNotifications(event.id);

    try {
      await gateway.deleteRemindersForEvent(
        eventId: event.id,
        userId: userId,
      );
      if (clearPreActions) {
        await gateway.deletePreActionsForEvent(
          eventId: event.id,
          userId: userId,
        );
        preActionsCleared = true;
      }
      await gateway.insertReminders(
        buildReminderPayloads(
          event: event,
          userId: userId,
          reminderOffset: reminderOffset,
          criticalAlarmOffset: criticalAlarmOffset ?? reminderOffset,
        ),
      );
      remindersSynced = true;
    } catch (_) {
      remindersSynced = false;
    }

    try {
      await scheduleLocalNotifications(
        event,
        reminderOffset: reminderOffset,
        criticalAlarmOffset: criticalAlarmOffset ?? reminderOffset,
      );
      notificationsSynced = true;
    } catch (_) {
      notificationsSynced = false;
    }

    return ManualEventSideEffectResult(
      remindersSynced: remindersSynced,
      notificationsSynced: notificationsSynced,
      preActionsCleared: preActionsCleared,
    );
  }

  Future<void> cleanupAfterDelete(String eventId) {
    return _notifications.cancelEventNotifications(eventId);
  }

  List<Map<String, dynamic>> buildReminderPayloads({
    required EventModel event,
    required String userId,
    Duration reminderOffset = defaultReminderOffset,
    Duration? criticalAlarmOffset,
  }) {
    final startAt = event.startAt;
    if (startAt == null) {
      return const <Map<String, dynamic>>[];
    }

    final payloads = <Map<String, dynamic>>[
      _reminderPayload(
        eventId: event.id,
        userId: userId,
        type: 'push',
        notifyAt: startAt.subtract(reminderOffset),
      ),
    ];

    if (event.isCritical) {
      payloads.add(
        _reminderPayload(
          eventId: event.id,
          userId: userId,
          type: 'system_alarm',
          notifyAt: startAt.subtract(criticalAlarmOffset ?? reminderOffset),
        ),
      );
    }

    return payloads;
  }

  Future<void> scheduleLocalNotifications(
    EventModel event, {
    Duration reminderOffset = defaultReminderOffset,
    Duration? criticalAlarmOffset,
  }) async {
    final startAt = event.startAt;
    if (startAt == null) {
      return;
    }

    final now = DateTime.now();
    final reminderNotifyAt = startAt.subtract(reminderOffset);
    if (reminderNotifyAt.isAfter(now)) {
      await _notifications.scheduleEventReminder(
        id: _notifications.notificationIdFor('${event.id}:push'),
        title: event.title,
        body: '일정 시작: ${event.title}',
        notifyAt: reminderNotifyAt,
      );
    }

    final criticalNotifyAt =
        startAt.subtract(criticalAlarmOffset ?? reminderOffset);
    if (event.isCritical && criticalNotifyAt.isAfter(now)) {
      await _notifications.scheduleCriticalAlarm(
        id: _notifications.notificationIdFor('${event.id}:critical'),
        title: event.title,
        body: '중요 일정이 곧 시작됩니다.',
        notifyAt: criticalNotifyAt,
      );
    }
  }

  Map<String, dynamic> _reminderPayload({
    required String eventId,
    required String userId,
    required String type,
    required DateTime notifyAt,
  }) {
    return <String, dynamic>{
      'event_id': eventId,
      'user_id': userId,
      'type': type,
      'notify_at': notifyAt.toIso8601String(),
      'is_sent': false,
    };
  }
}

class ManualEventSideEffectResult {
  const ManualEventSideEffectResult({
    required this.remindersSynced,
    required this.notificationsSynced,
    required this.preActionsCleared,
  });

  final bool remindersSynced;
  final bool notificationsSynced;
  final bool preActionsCleared;

  bool get isFullySynced =>
      remindersSynced && notificationsSynced && preActionsCleared;
}
