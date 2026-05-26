import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'app_permission_service.dart';
import 'departure_alarm_service.dart';
import 'location_lookup_service.dart';
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
    final dedupedPayloads = _deduplicatePreActionPayloads(payloads);
    if (dedupedPayloads.isEmpty) {
      return;
    }
    await _resolvedClient.from('pre_actions').insert(dedupedPayloads);
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
    TravelTimeBufferService? travelTimeBufferService,
    LocationLookupService? locationLookupService,
    Future<GeoPoint?> Function()? currentLocationProvider,
    DateTime Function()? now,
  })  : _eventRepository = eventRepository,
        _departureAlarmService = departureAlarmService,
        _notificationService = notificationService,
        _travelTimeBufferService = travelTimeBufferService,
        _locationLookupService = locationLookupService,
        _currentLocationProvider = currentLocationProvider,
        _now = now;

  static const Duration defaultReminderOffset = Duration(minutes: 60);
  static const Duration criticalAlarmOffset = Duration(minutes: 60);
  static final Map<String, Future<bool>> _externalPreparationResyncs =
      <String, Future<bool>>{};

  final ManualEventSideEffectGateway gateway;
  final EventRepository? _eventRepository;
  final DepartureAlarmService? _departureAlarmService;
  final NotificationService? _notificationService;
  final TravelTimeBufferService? _travelTimeBufferService;
  final LocationLookupService? _locationLookupService;
  final Future<GeoPoint?> Function()? _currentLocationProvider;
  final DateTime Function()? _now;

  EventRepository get _events => _eventRepository ?? EventRepository.supabase();
  DepartureAlarmService get _departureAlarms =>
      _departureAlarmService ?? const DepartureAlarmService();
  NotificationService get _notifications =>
      _notificationService ?? NotificationService();
  TravelTimeBufferService get _travelTimeBuffer =>
      _travelTimeBufferService ?? TravelTimeBufferService();
  LocationLookupService get _locationLookup =>
      _locationLookupService ?? LocationLookupService();
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
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
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
    final effectiveNow = _currentTime;
    final resolvedTravelMinutes = await _resolveTravelMinutesForEvent(
      event,
      fallbackTravelMinutes: travelMinutes,
      travelMode: travelMode,
    );

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
        travelMinutes: resolvedTravelMinutes.minutes,
        travelMinutesIsFallback: resolvedTravelMinutes.isFallback,
        departureSafetyMarginMin: departureSafetyMargin.inMinutes,
        isFirstExternalEventOfDay: isFirstExternalEventOfDay,
        now: effectiveNow,
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
          travelMinutes: resolvedTravelMinutes.minutes,
          travelMinutesIsFallback: resolvedTravelMinutes.isFallback,
          departureSafetyMarginMin: departureSafetyMargin.inMinutes,
          isFirstExternalEventOfDay: isFirstExternalEventOfDay,
          now: effectiveNow,
        ),
      );
      notificationsSynced = true;
    } catch (_) {
      notificationsSynced = false;
    }

    await recalculateUpcomingAlarmsForUser(
      userId: userId,
      seedEvents: <EventModel>[event],
      travelMode: travelMode,
      departureSafetyMargin: departureSafetyMargin,
    );

    return ManualEventSideEffectResult(
      remindersSynced: remindersSynced,
      notificationsSynced: notificationsSynced,
      preActionsCleared: preActionsCleared,
    );
  }

  Future<void> cleanupAfterDelete(
    String eventId, {
    String? userId,
    int prepTimeMin = SmartPreparationAlarmService.defaultPrepTimeMin,
    int prepPreAlarmOffset =
        SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
    int departPreAlarmOffset =
        SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
  }) async {
    await _notifications.cancelEventNotifications(eventId);
    final resolvedUserId = userId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return;
    }
    await recalculateUpcomingAlarmsForUser(
      userId: resolvedUserId,
      prepTimeMin: prepTimeMin,
      prepPreAlarmOffset: prepPreAlarmOffset,
      departPreAlarmOffset: departPreAlarmOffset,
      departureSafetyMargin: departureSafetyMargin,
      travelMode: travelMode,
    );
  }

  Future<ManualEventAlarmRecalculationResult> recalculateUpcomingAlarmsForUser({
    required String userId,
    Iterable<EventModel> seedEvents = const <EventModel>[],
    DateTime? now,
    bool resyncDepartureAlarms = true,
    int prepTimeMin = SmartPreparationAlarmService.defaultPrepTimeMin,
    int prepPreAlarmOffset =
        SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
    int departPreAlarmOffset =
        SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
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
      prepTimeMin: prepTimeMin,
      prepPreAlarmOffset: prepPreAlarmOffset,
      departPreAlarmOffset: departPreAlarmOffset,
      departureSafetyMargin: departureSafetyMargin,
      travelMode: travelMode,
    );
  }

  Future<ManualEventAlarmRecalculationResult> recalculateAlarmsForEvents({
    required Iterable<EventModel> events,
    required String userId,
    DateTime? now,
    DateTime? until,
    Iterable<String> extraDepartureEventIdsToCancel = const <String>[],
    bool resyncDepartureAlarms = true,
    int prepTimeMin = SmartPreparationAlarmService.defaultPrepTimeMin,
    int prepPreAlarmOffset =
        SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
    int departPreAlarmOffset =
        SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
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

    for (final eventsForDay in dayEvents.values) {
      final reference = eventsForDay
          .map((event) => event.startAt)
          .whereType<DateTime>()
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final ok = await resyncExternalPreparationForDay(
        dayEvents: eventsForDay,
        userId: userId,
        dayReference: reference,
        prepTimeMin: prepTimeMin,
        prepPreAlarmOffset: prepPreAlarmOffset,
        departPreAlarmOffset: departPreAlarmOffset,
        now: effectiveNow,
        travelMode: travelMode,
      );
      preparationDays += 1;
      preparationFailed = preparationFailed || !ok;
    }

    var departureScheduled = 0;
    var departureSkipped = 0;
    if (resyncDepartureAlarms) {
      final departureUntil =
          effectiveNow.add(DepartureAlarmService.monitorLookAhead);
      var hasUrgentDepartureMonitorEvent = false;
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
        if (event.startAt != null &&
            event.startAt!.isBefore(
              effectiveNow.add(DepartureAlarmService.monitorUrgentWindow),
            )) {
          hasUrgentDepartureMonitorEvent = true;
        }
        final result = await _departureAlarms.scheduleForEvent(
          event,
          rescheduleMonitor: false,
          safetyMarginOverride: departureSafetyMargin,
        );
        if (result.isScheduled) {
          departureScheduled += 1;
        } else {
          departureSkipped += 1;
        }
      }
      if (departureScheduled > 0 || departureSkipped > 0) {
        await _departureAlarms.scheduleNextMonitor(
          interval: hasUrgentDepartureMonitorEvent
              ? DepartureAlarmService.monitorUrgentInterval
              : DepartureAlarmService.monitorInterval,
        );
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
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
    DateTime? now,
  }) async {
    final resyncKey = _externalPreparationResyncKey(userId, dayReference);
    final existing = _externalPreparationResyncs[resyncKey];
    if (existing != null) {
      return existing;
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
      departureSafetyMargin: departureSafetyMargin,
      travelMode: travelMode,
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
    required Duration departureSafetyMargin,
    required String travelMode,
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
      final resolvedTravelMinutes = await _resolveTravelMinutesForEvent(
        event,
        fallbackTravelMinutes: travelMinutes,
        travelMode: travelMode,
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
        travelMinutes: resolvedTravelMinutes.minutes,
        travelMinutesIsFallback: resolvedTravelMinutes.isFallback,
        departureSafetyMarginMin: departureSafetyMargin.inMinutes,
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

  Future<_TravelMinutesResolution> _resolveTravelMinutesForEvent(
    EventModel event, {
    required int fallbackTravelMinutes,
    required String travelMode,
  }) async {
    if (fallbackTravelMinutes !=
        SmartPreparationAlarmService.defaultTravelBufferMin) {
      return _TravelMinutesResolution(
        minutes: fallbackTravelMinutes,
        isFallback: false,
      );
    }
    final origin = await _resolveOriginLocation();
    final destination =
        await _resolveDestinationForEvent(event, origin: origin);
    if (destination == null) {
      debugPrint(
        'Smart preparation travel fallback: no destination coordinates for ${event.id}.',
      );
      return _TravelMinutesResolution.fallback(fallbackTravelMinutes);
    }

    if (origin == null) {
      debugPrint(
        'Smart preparation travel fallback: no current location for ${event.id}.',
      );
      return _TravelMinutesResolution.fallback(fallbackTravelMinutes);
    }

    try {
      final estimate = await _travelTimeBuffer.estimateWithMapApis(
        originLat: origin.latitude,
        originLng: origin.longitude,
        destinationLat: destination.latitude,
        destinationLng: destination.longitude,
        mode: _travelModeFromSettings(travelMode),
        locationText: event.location,
      );
      return _TravelMinutesResolution(
        minutes: estimate.minutes,
        isFallback: false,
      );
    } catch (error, stackTrace) {
      debugPrint(
        'Smart preparation travel fallback: route estimate failed for '
        '${event.id}: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      return _TravelMinutesResolution.fallback(fallbackTravelMinutes);
    }
  }

  Future<GeoPoint?> _resolveDestinationForEvent(
    EventModel event, {
    GeoPoint? origin,
  }) async {
    final destinationLat = event.locationLat;
    final destinationLng = event.locationLng;
    if (destinationLat != null && destinationLng != null) {
      return GeoPoint(latitude: destinationLat, longitude: destinationLng);
    }

    for (final query in _buildDestinationSearchQueries(event)) {
      try {
        final searchResult =
            await _locationLookup.searchWithFallback(query, origin: origin);
        if (searchResult.results.isEmpty) {
          continue;
        }
        final selected = searchResult.results.first;
        await _backfillEventLocationCoordinates(
          event: event,
          latitude: selected.latitude,
          longitude: selected.longitude,
          location: selected.bestPlaceLabel,
        );
        return GeoPoint(
          latitude: selected.latitude,
          longitude: selected.longitude,
        );
      } catch (error, stackTrace) {
        debugPrint(
          'Smart preparation travel fallback: location lookup failed for '
          '${event.id}: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    return null;
  }

  Future<void> _backfillEventLocationCoordinates({
    required EventModel event,
    required double latitude,
    required double longitude,
    String? location,
  }) async {
    if (event.id.trim().isEmpty ||
        event.locationLat != null ||
        event.locationLng != null) {
      return;
    }
    try {
      await _events.updateEvent(
        _copyEventWithLocationCoordinates(
          event,
          locationLat: latitude,
          locationLng: longitude,
          location: location,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint(
        'Smart preparation travel fallback: location coordinate backfill '
        'failed for ${event.id}: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<GeoPoint?> _resolveOriginLocation() async {
    final current = await _currentLocationProvider?.call();
    if (current != null) {
      return current;
    }
    if (kIsWeb) {
      return null;
    }
    final permissionService = AppPermissionService();
    return permissionService.getCurrentLocationWithPermission(
      requestIfMissing: false,
    );
  }

  MapTravelMode _travelModeFromSettings(String travelMode) {
    if (travelMode == 'transit') {
      return MapTravelMode.transit;
    }
    return MapTravelMode.car;
  }

  List<String> _buildDestinationSearchQueries(EventModel event) {
    final queries = <String>[];
    void addQuery(String? value) {
      final normalized = value?.trim();
      if (normalized == null || normalized.isEmpty) {
        return;
      }
      if (queries.contains(normalized)) {
        return;
      }
      queries.add(normalized);
    }

    addQuery(event.location);
    addQuery(event.title);
    addQuery(event.memo);
    addQuery([
      event.location,
      event.title,
    ].whereType<String>().join(' '));
    addQuery([
      event.title,
      event.memo,
    ].whereType<String>().join(' '));
    addQuery([
      event.location,
      event.memo,
    ].whereType<String>().join(' '));
    return queries;
  }

  bool _hasPlace(EventModel event) {
    final location = event.location?.trim();
    return (location != null && location.isNotEmpty) ||
        (event.locationLat != null && event.locationLng != null);
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
        payload: 'event:${event.id}',
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
        payload: 'event:${event.id}',
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

class _TravelMinutesResolution {
  const _TravelMinutesResolution({
    required this.minutes,
    required this.isFallback,
  });

  factory _TravelMinutesResolution.fallback(int minutes) {
    return _TravelMinutesResolution(minutes: minutes, isFallback: true);
  }

  final int minutes;
  final bool isFallback;
}

EventModel _copyEventWithLocationCoordinates(
  EventModel event, {
  required double locationLat,
  required double locationLng,
  String? location,
}) {
  final normalizedLocation = location?.trim();
  return EventModel(
    id: event.id,
    userId: event.userId,
    title: event.title,
    startAt: event.startAt,
    endAt: event.endAt,
    location: normalizedLocation == null || normalizedLocation.isEmpty
        ? event.location
        : normalizedLocation,
    locationLat: locationLat,
    locationLng: locationLng,
    memo: event.memo,
    supplies: event.supplies,
    suppliesChecked: event.suppliesChecked,
    participants: event.participants,
    targets: event.targets,
    isCritical: event.isCritical,
    recurrenceRule: event.recurrenceRule,
    isAllDay: event.isAllDay,
    isMultiDay: event.isMultiDay,
    parentEventId: event.parentEventId,
    category: event.category,
    source: event.source,
    externalId: event.externalId,
    externalCalendarId: event.externalCalendarId,
    externalEtag: event.externalEtag,
    externalUpdatedAt: event.externalUpdatedAt,
    lastSyncedAt: event.lastSyncedAt,
    createdAt: event.createdAt,
    updatedAt: event.updatedAt,
  );
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
