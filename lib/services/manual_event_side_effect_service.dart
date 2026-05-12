import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/local_time.dart';
import '../data/models/event_model.dart';
import 'notification_service.dart';
import 'smart_preparation_alarm_service.dart';

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

  Future<void> deleteExternalPreparationPreActionsForEvent({
    required String eventId,
    required String userId,
  });

  Future<void> insertReminders(List<Map<String, dynamic>> payloads);

  Future<void> insertPreActions(List<Map<String, dynamic>> payloads);
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
  Future<void> deleteExternalPreparationPreActionsForEvent({
    required String eventId,
    required String userId,
  }) async {
    await _resolvedClient
        .from('pre_actions')
        .delete()
        .eq('event_id', eventId)
        .eq('user_id', userId)
        .eq('source', 'external_preparation');
  }

  @override
  Future<void> insertReminders(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _resolvedClient.from('reminders').insert(payloads);
  }

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {
    if (payloads.isEmpty) {
      return;
    }
    await _resolvedClient.from('pre_actions').insert(payloads);
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
    Duration? reminderOffset = defaultReminderOffset,
    Duration? criticalAlarmOffset,
    int prepTimeMin = SmartPreparationAlarmService.defaultPrepTimeMin,
    int prepPreAlarmOffset =
        SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
    int departPreAlarmOffset =
        SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
    int travelMinutes = SmartPreparationAlarmService.defaultTravelBufferMin,
    bool isFirstExternalEventOfDay = true,
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
      await gateway.deleteRemindersForEvent(eventId: event.id, userId: userId);
      if (clearPreActions) {
        await gateway.deletePreActionsForEvent(
          eventId: event.id,
          userId: userId,
        );
        preActionsCleared = true;
      }
      final externalPreparationPayloads =
          const SmartPreparationAlarmService().buildExternalEventPayloads(
        eventId: event.id,
        userId: userId,
        title: event.title,
        eventStartAt: startAt,
        location: event.location,
        prepTimeMin: prepTimeMin,
        prepPreAlarmOffset: prepPreAlarmOffset,
        departPreAlarmOffset: departPreAlarmOffset,
        travelMinutes: travelMinutes,
        isFirstExternalEventOfDay: isFirstExternalEventOfDay,
      );
      await gateway.insertPreActions(externalPreparationPayloads);
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
      await const SmartPreparationAlarmService().schedulePayloads(
        eventId: event.id,
        eventTitle: event.title,
        payloads: SmartPreparationAlarmService().buildExternalEventPayloads(
          eventId: event.id,
          userId: userId,
          title: event.title,
          eventStartAt: startAt,
          location: event.location,
          prepTimeMin: prepTimeMin,
          prepPreAlarmOffset: prepPreAlarmOffset,
          departPreAlarmOffset: departPreAlarmOffset,
          travelMinutes: travelMinutes,
          isFirstExternalEventOfDay: isFirstExternalEventOfDay,
        ),
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

  Future<bool> resyncExternalPreparationForDay({
    required Iterable<EventModel> dayEvents,
    required String userId,
    required DateTime dayReference,
    int prepTimeMin = SmartPreparationAlarmService.defaultPrepTimeMin,
    int prepPreAlarmOffset =
        SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
    int departPreAlarmOffset =
        SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
    int travelMinutes = SmartPreparationAlarmService.defaultTravelBufferMin,
    DateTime? now,
  }) async {
    final smartService = SmartPreparationAlarmService(
      notificationService: _notifications,
    );
    final externalEvents = dayEvents
        .where(
          (event) =>
              event.startAt != null &&
              planflowIsSameLocalDay(event.startAt!, dayReference) &&
              smartService.isExternalEvent(
                title: event.title,
                location: event.location,
              ),
        )
        .toList(growable: false)
      ..sort(
        (a, b) => (a.startAt ?? DateTime(0)).compareTo(
          b.startAt ?? DateTime(0),
        ),
      );
    if (externalEvents.isEmpty) {
      return true;
    }

    final firstExternalEventId = externalEvents.first.id;
    final payloadsByEvent = <EventModel, List<Map<String, dynamic>>>{};
    for (final event in externalEvents) {
      payloadsByEvent[event] = smartService.buildExternalEventPayloads(
        eventId: event.id,
        userId: userId,
        title: event.title,
        eventStartAt: event.startAt!,
        location: event.location,
        prepTimeMin: prepTimeMin,
        prepPreAlarmOffset: prepPreAlarmOffset,
        departPreAlarmOffset: departPreAlarmOffset,
        travelMinutes: travelMinutes,
        isFirstExternalEventOfDay: event.id == firstExternalEventId,
        now: now,
      );
    }

    try {
      for (final event in externalEvents) {
        await gateway.deleteExternalPreparationPreActionsForEvent(
          eventId: event.id,
          userId: userId,
        );
        await smartService.cancelForEvent(event.id);
      }
      await gateway.insertPreActions(
        payloadsByEvent.values.expand((payloads) => payloads).toList(),
      );
      for (final entry in payloadsByEvent.entries) {
        await smartService.schedulePayloads(
          eventId: entry.key.id,
          eventTitle: entry.key.title,
          payloads: entry.value,
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  List<Map<String, dynamic>> buildReminderPayloads({
    required EventModel event,
    required String userId,
    Duration? reminderOffset = defaultReminderOffset,
    Duration? criticalAlarmOffset,
  }) {
    final startAt = event.startAt;
    if (startAt == null) {
      return const <Map<String, dynamic>>[];
    }

    final payloads = <Map<String, dynamic>>[];

    if (reminderOffset != null) {
      payloads.add(
        _reminderPayload(
          eventId: event.id,
          userId: userId,
          type: 'push',
          notifyAt: startAt.subtract(reminderOffset),
        ),
      );
    }

    final criticalNotifyAt = criticalAlarmOffset == null
        ? null
        : _resolveCriticalNotifyAt(startAt, criticalAlarmOffset);
    if (event.isCritical && criticalNotifyAt != null) {
      payloads.add(
        _reminderPayload(
          eventId: event.id,
          userId: userId,
          type: 'system_alarm',
          notifyAt: criticalNotifyAt,
        ),
      );
    }

    return payloads;
  }

  Future<void> scheduleLocalNotifications(
    EventModel event, {
    Duration? reminderOffset = defaultReminderOffset,
    Duration? criticalAlarmOffset,
  }) async {
    final startAt = event.startAt;
    if (startAt == null) {
      return;
    }

    final now = DateTime.now();
    final reminderNotifyAt =
        reminderOffset == null ? null : startAt.subtract(reminderOffset);
    if (reminderNotifyAt != null && reminderNotifyAt.isAfter(now)) {
      await _notifications.scheduleEventReminder(
        id: _notifications.notificationIdFor('${event.id}:push'),
        title: event.title,
        body: '일정 시작: ${event.title}',
        notifyAt: reminderNotifyAt,
      );
    }

    final criticalNotifyAt = criticalAlarmOffset == null
        ? null
        : _resolveCriticalNotifyAt(startAt, criticalAlarmOffset);
    if (event.isCritical && criticalNotifyAt != null) {
      final result = await _notifications.scheduleCriticalAlarmWithResult(
        id: _notifications.notificationIdFor('${event.id}:critical'),
        title: event.title,
        body: '중요 일정이 곧 시작됩니다.',
        notifyAt: criticalNotifyAt,
      );
      if (!result.isScheduled) {
        throw StateError(result.message ?? '중요 알람 예약 실패');
      }
    }
  }

  DateTime? _resolveCriticalNotifyAt(DateTime eventStartAt, Duration offset) {
    final now = DateTime.now();
    if (!eventStartAt.isAfter(now)) {
      return null;
    }
    final desired = eventStartAt.subtract(offset);
    if (desired.isAfter(now)) {
      return desired;
    }
    return now.add(const Duration(seconds: 10));
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
