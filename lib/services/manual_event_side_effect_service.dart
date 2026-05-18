import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants.dart';
import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'app_permission_service.dart';
import 'departure_alarm_service.dart';
import 'map_service.dart';
import 'notification_service.dart';
import 'smart_preparation_alarm_service.dart';
import 'travel_time_buffer_service.dart';

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
        .schema(DbSchema.planflow)
        .from(DbTable.reminders)
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
        .schema(DbSchema.planflow)
        .from(DbTable.preActions)
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
        .schema(DbSchema.planflow)
        .from(DbTable.preActions)
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
    await _resolvedClient
        .schema(DbSchema.planflow)
        .from(DbTable.reminders)
        .insert(payloads);
  }

  @override
  Future<void> insertPreActions(List<Map<String, dynamic>> payloads) async {
    final dedupedPayloads = _deduplicatePreActionPayloads(payloads);
    if (dedupedPayloads.isEmpty) {
      return;
    }
    await _resolvedClient
        .schema(DbSchema.planflow)
        .from(DbTable.preActions)
        .insert(dedupedPayloads);
  }

  List<Map<String, dynamic>> _deduplicatePreActionPayloads(
    List<Map<String, dynamic>> payloads,
  ) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final payload in payloads) {
      final key = <Object?>[
        payload['event_id'],
        payload['user_id'],
        payload['source'],
        payload['notify_at'],
        payload['title'],
      ].join('|');
      if (seen.add(key)) {
        result.add(payload);
      }
    }
    return result;
  }
}

class ManualEventSideEffectService {
  const ManualEventSideEffectService({
    this.gateway = const SupabaseManualEventSideEffectGateway(),
    EventRepository? eventRepository,
    DepartureAlarmService? departureAlarmService,
    NotificationService? notificationService,
    Future<GeoPoint?> Function()? currentLocationProvider,
    TravelTimeBufferService? travelTimeBufferService,
    DateTime Function()? now,
  })  : _eventRepository = eventRepository,
        _departureAlarmService = departureAlarmService,
        _notificationService = notificationService,
        _currentLocationProvider = currentLocationProvider,
        _travelTimeBufferService = travelTimeBufferService,
        _now = now;

  static const Duration defaultReminderOffset = Duration(minutes: 60);
  static const Duration criticalAlarmOffset = Duration(minutes: 60);
  static final Map<String, Future<bool>> _externalPreparationResyncs =
      <String, Future<bool>>{};

  final ManualEventSideEffectGateway gateway;
  final EventRepository? _eventRepository;
  final DepartureAlarmService? _departureAlarmService;
  final NotificationService? _notificationService;
  final Future<GeoPoint?> Function()? _currentLocationProvider;
  final TravelTimeBufferService? _travelTimeBufferService;
  final DateTime Function()? _now;

  EventRepository get _events => _eventRepository ?? EventRepository.supabase();
  DepartureAlarmService get _departureAlarms =>
      _departureAlarmService ?? const DepartureAlarmService();
  NotificationService get _notifications =>
      _notificationService ?? NotificationService();
  TravelTimeBufferService get _travelTime =>
      _travelTimeBufferService ?? TravelTimeBufferService();
  DateTime get _currentTime => (_now ?? DateTime.now)();

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

    await recalculateUpcomingAlarmsForUser(
      userId: userId,
      seedEvents: <EventModel>[event],
    );

    return ManualEventSideEffectResult(
      remindersSynced: remindersSynced,
      notificationsSynced: notificationsSynced,
      preActionsCleared: preActionsCleared,
    );
  }

  Future<void> cleanupAfterDelete(String eventId, {String? userId}) async {
    await _notifications.cancelEventNotifications(eventId);
    final resolvedUserId = userId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return;
    }
    await recalculateUpcomingAlarmsForUser(userId: resolvedUserId);
  }

  Future<ManualEventAlarmRecalculationResult> recalculateUpcomingAlarmsForUser({
    required String userId,
    Iterable<EventModel> seedEvents = const <EventModel>[],
    DateTime? now,
    bool resyncDepartureAlarms = true,
  }) async {
    final effectiveNow = now ?? _currentTime;
    final until = effectiveNow.add(const Duration(days: 7));
    var events = seedEvents.toList(growable: true);

    try {
      final repositoryEvents = await _events.listEvents(userId: userId);
      events = repositoryEvents;
    } catch (error, stackTrace) {
      if (events.isEmpty) {
        debugPrint('Manual event alarm recalculation skipped: $error');
        debugPrintStack(stackTrace: stackTrace);
        return const ManualEventAlarmRecalculationResult(
          skippedReason: 'events_unavailable',
        );
      }
      debugPrint(
        'Manual event alarm recalculation using seed events: $error',
      );
    }

    return recalculateAlarmsForEvents(
      events: events,
      userId: userId,
      now: effectiveNow,
      until: until,
      resyncDepartureAlarms: resyncDepartureAlarms,
    );
  }

  Future<ManualEventAlarmRecalculationResult> recalculateAlarmsForEvents({
    required Iterable<EventModel> events,
    required String userId,
    DateTime? now,
    DateTime? until,
    Iterable<String> extraDepartureEventIdsToCancel = const <String>[],
    bool resyncDepartureAlarms = true,
  }) async {
    final effectiveNow = now ?? _currentTime;
    final effectiveUntil = until ?? effectiveNow.add(const Duration(days: 7));
    final upcomingEvents = events.where((event) {
      final startAt = event.startAt;
      return startAt != null &&
          startAt.isAfter(effectiveNow) &&
          startAt.isBefore(effectiveUntil);
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

    var preparationDays = 0;
    var preparationFailed = false;
    final dayEvents = <String, List<EventModel>>{};
    for (final event in upcomingEvents) {
      final startAt = event.startAt;
      if (startAt == null) {
        continue;
      }
      final localDay = planflowLocal(startAt);
      final key = '${localDay.year.toString().padLeft(4, '0')}-'
          '${localDay.month.toString().padLeft(2, '0')}-'
          '${localDay.day.toString().padLeft(2, '0')}';
      dayEvents.putIfAbsent(key, () => <EventModel>[]).add(event);
    }

    GeoPoint? currentLocation;

    for (final eventsForDay in dayEvents.values) {
      final shouldEstimateTravel = eventsForDay.any(
            (event) => event.locationLat != null && event.locationLng != null,
          ) &&
          currentLocation == null;
      if (shouldEstimateTravel) {
        currentLocation = await _currentLocationForTravel();
      }
      final reference = eventsForDay
          .map((event) => event.startAt)
          .whereType<DateTime>()
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final ok = await resyncExternalPreparationForDay(
        dayEvents: eventsForDay,
        userId: userId,
        dayReference: reference,
        currentLocation: currentLocation,
        now: effectiveNow,
      );
      preparationDays += 1;
      preparationFailed = preparationFailed || !ok;
    }

    var departureScheduled = 0;
    var departureSkipped = 0;
    if (resyncDepartureAlarms) {
      final departureUntil =
          effectiveNow.add(DepartureAlarmService.monitorLookAhead);
      final cancelledDepartureEventIds = extraDepartureEventIdsToCancel
          .where((id) => id.trim().isNotEmpty)
          .toSet();
      for (final event in upcomingEvents.where((event) {
        final startAt = event.startAt;
        return startAt != null && startAt.isBefore(departureUntil);
      })) {
        cancelledDepartureEventIds.add(event.id);
      }
      for (final eventId in cancelledDepartureEventIds) {
        await _notifications.cancel(
          _notifications.notificationIdFor('$eventId:departure'),
        );
      }
      for (final event in upcomingEvents.where((event) {
        final startAt = event.startAt;
        return startAt != null && startAt.isBefore(departureUntil);
      })) {
        if (!_hasPlace(event)) {
          departureSkipped += 1;
          continue;
        }
        final result = await _departureAlarms.scheduleForEvent(
          event,
          rescheduleMonitor: false,
        );
        if (result.isScheduled) {
          departureScheduled += 1;
        } else {
          departureSkipped += 1;
        }
      }
      if (departureScheduled > 0 || departureSkipped > 0) {
        await _departureAlarms.scheduleNextMonitor();
      }
    }

    if (upcomingEvents.isEmpty) {
      return ManualEventAlarmRecalculationResult(
        departureScheduled: departureScheduled,
        departureSkipped: departureSkipped,
      );
    }

    return ManualEventAlarmRecalculationResult(
      preparationDays: preparationDays,
      preparationSucceeded: !preparationFailed,
      departureScheduled: departureScheduled,
      departureSkipped: departureSkipped,
    );
  }

  Future<bool> resyncRemindersForEvents({
    required Iterable<EventModel> events,
    required String userId,
    Duration? reminderOffset = defaultReminderOffset,
    Duration? criticalAlarmOffset =
        ManualEventSideEffectService.criticalAlarmOffset,
  }) async {
    final futureEvents = events
        .where(
          (event) =>
              event.startAt != null && event.startAt!.isAfter(DateTime.now()),
        )
        .toList(growable: false);
    if (futureEvents.isEmpty) {
      return true;
    }

    try {
      for (final event in futureEvents) {
        await gateway.deleteRemindersForEvent(
          eventId: event.id,
          userId: userId,
        );
        await _notifications.cancel(
          _notifications.notificationIdFor('${event.id}:push'),
        );
        await _notifications.cancel(
          _notifications.notificationIdFor('${event.id}:critical'),
        );
      }

      await gateway.insertReminders(
        _deduplicatePayloads(
          futureEvents.expand(
            (event) => buildReminderPayloads(
              event: event,
              userId: userId,
              reminderOffset: reminderOffset,
              criticalAlarmOffset: criticalAlarmOffset ?? reminderOffset,
            ),
          ),
        ),
      );

      for (final event in futureEvents) {
        await scheduleLocalNotifications(
          event,
          reminderOffset: reminderOffset,
          criticalAlarmOffset: criticalAlarmOffset ?? reminderOffset,
        );
      }

      return true;
    } catch (_) {
      return false;
    }
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
    GeoPoint? currentLocation,
    DateTime? now,
  }) async {
    final resyncKey = _externalPreparationResyncKey(userId, dayReference);
    final existing = _externalPreparationResyncs[resyncKey];
    if (existing != null) {
      if (currentLocation == null) {
        return existing;
      }
      final previousResult = await existing;
      if (identical(_externalPreparationResyncs[resyncKey], existing)) {
        _externalPreparationResyncs.remove(resyncKey);
      }
      if (!previousResult) {
        return false;
      }
    }

    late final Future<bool> resyncFuture;
    resyncFuture = _resyncExternalPreparationForDayUnlocked(
      dayEvents: dayEvents,
      userId: userId,
      dayReference: dayReference,
      prepTimeMin: prepTimeMin,
      prepPreAlarmOffset: prepPreAlarmOffset,
      departPreAlarmOffset: departPreAlarmOffset,
      travelMinutes: travelMinutes,
      currentLocation: currentLocation,
      now: now,
    );
    _externalPreparationResyncs[resyncKey] = resyncFuture;
    try {
      return await resyncFuture;
    } finally {
      if (identical(_externalPreparationResyncs[resyncKey], resyncFuture)) {
        _externalPreparationResyncs.remove(resyncKey);
      }
    }
  }

  Future<bool> _resyncExternalPreparationForDayUnlocked({
    required Iterable<EventModel> dayEvents,
    required String userId,
    required DateTime dayReference,
    required int prepTimeMin,
    required int prepPreAlarmOffset,
    required int departPreAlarmOffset,
    required int travelMinutes,
    GeoPoint? currentLocation,
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
      final eventTravelMinutes = await _travelMinutesForEvent(
        event,
        fallbackMinutes: travelMinutes,
        currentLocation: currentLocation,
      );
      payloadsByEvent[event] = smartService.buildExternalEventPayloads(
        eventId: event.id,
        userId: userId,
        title: event.title,
        eventStartAt: event.startAt!,
        location: event.location,
        prepTimeMin: prepTimeMin,
        prepPreAlarmOffset: prepPreAlarmOffset,
        departPreAlarmOffset: departPreAlarmOffset,
        travelMinutes: eventTravelMinutes,
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
        _deduplicatePayloads(
          payloadsByEvent.values.expand((payloads) => payloads),
        ),
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

  String _externalPreparationResyncKey(String userId, DateTime dayReference) {
    final localDay = planflowLocal(dayReference);
    final yyyy = localDay.year.toString().padLeft(4, '0');
    final mm = localDay.month.toString().padLeft(2, '0');
    final dd = localDay.day.toString().padLeft(2, '0');
    return '$userId:$yyyy-$mm-$dd';
  }

  bool _hasPlace(EventModel event) {
    final location = event.location?.trim();
    return (location != null && location.isNotEmpty) ||
        (event.locationLat != null && event.locationLng != null);
  }

  Future<GeoPoint?> _currentLocationForTravel() async {
    try {
      return await (_currentLocationProvider?.call() ??
          AppPermissionService().getCurrentLocation());
    } catch (_) {
      return null;
    }
  }

  Future<int> _travelMinutesForEvent(
    EventModel event, {
    required int fallbackMinutes,
    required GeoPoint? currentLocation,
  }) async {
    final destinationLat = event.locationLat;
    final destinationLng = event.locationLng;
    if (destinationLat == null || destinationLng == null) {
      return fallbackMinutes;
    }
    if (currentLocation == null) {
      return fallbackMinutes;
    }
    try {
      final estimate = await _travelTime.estimateWithMapApis(
        originLat: currentLocation.latitude,
        originLng: currentLocation.longitude,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        mode: _travelModeFromEvent(event),
        locationText: event.location,
      );
      return estimate.minutes;
    } catch (error, stackTrace) {
      debugPrint('Smart preparation travel estimate skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return fallbackMinutes;
    }
  }

  MapTravelMode _travelModeFromEvent(EventModel event) {
    final text = <String>[
      event.title,
      event.location ?? '',
      event.memo ?? '',
    ].join(' ');
    if (text.contains('대중교통') ||
        text.contains('버스') ||
        text.contains('지하철') ||
        text.contains('기차')) {
      return MapTravelMode.transit;
    }
    return MapTravelMode.car;
  }

  String? _currentSupabaseUserId() {
    try {
      final auth = Supabase.instance.client.auth;
      return auth.currentSession?.user.id ?? auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _deduplicatePayloads(
    Iterable<Map<String, dynamic>> payloads,
  ) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final payload in payloads) {
      final key = <Object?>[
        payload['event_id'],
        payload['user_id'],
        payload['source'],
        payload['type'],
        payload['notify_at'],
        payload['title'],
      ].join('|');
      if (seen.add(key)) {
        result.add(payload);
      }
    }
    return result;
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

class ManualEventAlarmRecalculationResult {
  const ManualEventAlarmRecalculationResult({
    this.preparationDays = 0,
    this.preparationSucceeded = true,
    this.departureScheduled = 0,
    this.departureSkipped = 0,
    this.skippedReason,
  });

  final int preparationDays;
  final bool preparationSucceeded;
  final int departureScheduled;
  final int departureSkipped;
  final String? skippedReason;

  bool get isFullySynced => preparationSucceeded && skippedReason == null;
}
