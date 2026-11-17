import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/diag_logger.dart';
import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'app_permission_service.dart';
import 'critical_alarm_acknowledgement_store.dart';
import 'critical_alarm_preflight_service.dart';
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
    CriticalAlarmAcknowledgementStore? criticalAlarmAcknowledgementStore,
    CriticalAlarmPreflightService? criticalAlarmPreflightService,
  })  : _eventRepository = eventRepository,
        _departureAlarmService = departureAlarmService,
        _notificationService = notificationService,
        _travelTimeBufferService = travelTimeBufferService,
        _locationLookupService = locationLookupService,
        _currentLocationProvider = currentLocationProvider,
        _now = now,
        _criticalAlarmAcknowledgementStore = criticalAlarmAcknowledgementStore,
        _criticalAlarmPreflightService = criticalAlarmPreflightService;

  static const Duration defaultReminderOffset = Duration(minutes: 60);
  static const Duration criticalAlarmOffset = Duration(minutes: 60);

  /// 목적지 후보 쿼리(_buildDestinationSearchQueries) 중 실제로 시도할 최대 개수.
  /// event_preparation_service.dart의 동일 상수와 같은 이유 — 이벤트 1건의
  /// 좌표 미해결 검색이 tmap POI 레이트리밋(60/60s)을 혼자 잡아먹는 폭주를
  /// 막기 위해 location/title/memo 단독 쿼리 3개만 시도한다(2026-07-04 실측).
  static const int _maxDestinationQueries = 3;
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
  final CriticalAlarmAcknowledgementStore? _criticalAlarmAcknowledgementStore;
  final CriticalAlarmPreflightService? _criticalAlarmPreflightService;

  EventRepository get _events => _eventRepository ?? EventRepository.supabase();
  DepartureAlarmService get _departureAlarms =>
      _departureAlarmService ?? const DepartureAlarmService();
  NotificationService get _notifications =>
      _notificationService ?? NotificationService();

  LocalAlarmResyncBatch createLocalAlarmResyncBatch() =>
      LocalAlarmResyncBatch(notificationService: _notifications);

  TravelTimeBufferService get _travelTimeBuffer =>
      _travelTimeBufferService ?? TravelTimeBufferService();
  LocationLookupService get _locationLookup =>
      _locationLookupService ?? LocationLookupService();
  DateTime get _currentTime => (_now ?? DateTime.now)();
  CriticalAlarmAcknowledgementStore get _criticalAcks =>
      _criticalAlarmAcknowledgementStore ??
      const SharedPreferencesCriticalAlarmAcknowledgementStore();

  /// 강한알람 예약은 preflight(트리거 시각 재계산) 통로를 함께 쓴다.
  /// Android+좌표 있는 강한알람만 preflight로 걸고 나머지는 기존 예약 그대로.
  CriticalAlarmPreflightService get _criticalPreflight =>
      _criticalAlarmPreflightService ??
      CriticalAlarmPreflightService(notificationService: _notifications);

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
      await _departureAlarms.clearAcknowledgement(event.id);
      await _notifications.cancelEventNotifications(event.id);
      try {
        await gateway.deleteRemindersForEvent(
            eventId: event.id, userId: userId);
      } catch (error) {
        debugPrint(
            '[PlanFlow] reminder cleanup failed for event ${event.id}: $error');
      }
      return const ManualEventSideEffectResult(
        remindersSynced: false,
        notificationsSynced: false,
        preActionsCleared: false,
      );
    }

    var remindersSynced = false;
    var notificationsSynced = false;
    var preActionsCleared = !clearPreActions;
    var reminderEvent = event;
    final effectiveNow = _currentTime;
    List<EventModel> recurringReminders = const [];
    if (isRecurringAlarmEvent(event)) {
      try {
        final events = await _events.listEvents(userId: userId);
        recurringReminders = upcomingAlarmOccurrences(
          [
            event,
            ...events.where((item) => item.parentEventId == event.id),
          ],
          from: effectiveNow,
          until: effectiveNow.add(recurringAlarmWindow),
        ).where((item) => item.id == event.id).toList();
      } catch (error) {
        debugPrint(
            '[PlanFlow] recurring reminder expansion failed for event ${event.id}: $error');
        return ManualEventSideEffectResult(
          remindersSynced: false,
          notificationsSynced: false,
          preActionsCleared: preActionsCleared,
        );
      }
    }

    final resolvedTravelMinutes = await _resolveTravelMinutesForEvent(
      event,
      fallbackTravelMinutes: travelMinutes,
      travelMode: travelMode,
    );

    await _departureAlarms.clearAcknowledgement(event.id);
    // 사용자가 일정을 직접 저장했다면 시작 시각 불명 ack는 더 이상 신뢰할 수
    // 없으므로 해제한다(시각이 바뀌었는데도 새 알람이 막히는 일 방지).
    try {
      if (await _criticalAcks.hasUnknownStartAcknowledgement(event.id)) {
        await _criticalAcks.clearAcknowledgement(event.id);
      }
    } catch (error) {
      DiagLogger.log(
          'ManualSideEffect', 'critical ack sentinel clear failed: $error');
    }
    await _notifications.cancelEventNotifications(event.id);

    // 편집 경로 진입 로그: 장소 유무와 isFirstExternalEventOfDay 값을 기록해
    // 기기 진단 로그에서 스마트 준비 알람·출발 알람 등록 여부를 추적할 수 있게 한다.
    final hasLocation = (event.location?.trim().isNotEmpty ?? false) ||
        (event.locationLat != null && event.locationLng != null);
    DiagLogger.log(
      'ManualSideEffect',
      'syncAfterSave 시작 eventId=${event.id} '
          'hasLocation=$hasLocation '
          'locationText="${event.location ?? ''}" '
          'hasCoords=${event.locationLat != null && event.locationLng != null} '
          'isFirstExternal=$isFirstExternalEventOfDay',
    );

    Iterable<EventModel> reminderOccurrences() {
      if (!isRecurringAlarmEvent(event)) {
        return [reminderEvent];
      }
      return recurringReminders.map(
        (occurrence) =>
            occurrence.copyWith(isCritical: reminderEvent.isCritical),
      );
    }

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
        includePreparationAlarms: isFirstExternalEventOfDay,
        now: effectiveNow,
      );
      // DB pre_actions 삽입 전: payload 개수 및 준비 알람 포함 여부 기록
      DiagLogger.log(
        'ManualSideEffect',
        'SmartPrep DB payload count=${externalPreparationPayloads.length} '
            'includePrep=$isFirstExternalEventOfDay '
            'travelMin=${resolvedTravelMinutes.minutes} '
            'travelIsFallback=${resolvedTravelMinutes.isFallback}',
      );
      await gateway.insertPreActions(externalPreparationPayloads);
      reminderEvent = await _syncEventCriticalFlagForPreActions(
        event,
        hasPreActions: externalPreparationPayloads.isNotEmpty,
      );
      await gateway.insertReminders(
        _deduplicatePayloads(
          reminderOccurrences().expand(
            (occurrence) => buildReminderPayloads(
              event: occurrence,
              userId: userId,
              reminderOffset: reminderOffset,
              criticalAlarmOffset: criticalAlarmOffset ?? reminderOffset,
            ),
          ),
        ),
      );
      remindersSynced = true;
    } catch (e, st) {
      debugPrint(
          '[PlanFlow] reminder DB sync failed for event ${event.id}: $e\n$st');
      DiagLogger.log(
        'ManualSideEffect',
        'DB 동기화 실패 eventId=${event.id} error=$e',
      );
      remindersSynced = false;
    }

    try {
      for (final occurrence in reminderOccurrences()) {
        await scheduleLocalNotifications(
          occurrence,
          reminderOffset: reminderOffset,
          criticalAlarmOffset: criticalAlarmOffset ?? reminderOffset,
        );
      }
      final localSmartPrepPayloads =
          SmartPreparationAlarmService().buildExternalEventPayloads(
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
        includePreparationAlarms: isFirstExternalEventOfDay,
        now: effectiveNow,
      );
      // 로컬 알람 스케줄 전: payload 개수 기록
      DiagLogger.log(
        'ManualSideEffect',
        'SmartPrep 로컬알람 payload count=${localSmartPrepPayloads.length} '
            'eventId=${event.id}',
      );
      await const SmartPreparationAlarmService().schedulePayloads(
        eventId: event.id,
        eventTitle: event.title,
        eventSource: event.source,
        payloads: localSmartPrepPayloads,
      );
      notificationsSynced = true;
    } catch (e, st) {
      debugPrint(
          '[PlanFlow] local notification sync failed for event ${event.id}: $e\n$st');
      DiagLogger.log(
        'ManualSideEffect',
        '로컬 알람 동기화 실패 eventId=${event.id} error=$e',
      );
      notificationsSynced = false;
    }

    // recalculate가 출발 알람을 등록하므로 진입 전 기록
    DiagLogger.log(
      'ManualSideEffect',
      'recalculate 시작 eventId=${event.id} hasLocation=$hasLocation',
    );
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

  Future<EventModel> _syncEventCriticalFlagForPreActions(
    EventModel event, {
    required bool hasPreActions,
  }) async {
    final nextIsCritical = event.isCritical || hasPreActions;
    if (event.isCritical == nextIsCritical) {
      return event;
    }
    final updatedEvent = event.copyWith(isCritical: nextIsCritical);
    try {
      return await _events.updateEvent(updatedEvent);
    } catch (error, stackTrace) {
      debugPrint('Event critical flag sync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return updatedEvent;
    }
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
    await _departureAlarms.clearAcknowledgement(eventId);
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

  /// Clears per-event state, then recalculates alarms once for the batch.
  Future<void> cleanupAfterBatchDelete(
    Iterable<String> eventIds, {
    String? userId,
    int prepTimeMin = SmartPreparationAlarmService.defaultPrepTimeMin,
    int prepPreAlarmOffset =
        SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
    int departPreAlarmOffset =
        SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
  }) async {
    for (final eventId in eventIds) {
      try {
        await _departureAlarms.clearAcknowledgement(eventId);
      } catch (error) {
        DiagLogger.log(
            'DIAG', 'batch clear acknowledgement failed: ${error.runtimeType}');
      }
      try {
        await _notifications.cancelEventNotifications(eventId);
      } catch (error) {
        DiagLogger.log(
            'DIAG', 'batch cancel notifications failed: ${error.runtimeType}');
      }
    }
    final resolvedUserId = userId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) return;
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
    // 백그라운드 동기화에서 호출하면 true로 설정해 라이브 GPS 조회를 막는다.
    bool cacheOnlyLocation = false,
    LocalAlarmResyncBatch? localAlarmBatch,
  }) async {
    final booking = localAlarmBatch ?? createLocalAlarmResyncBatch();
    final effectiveNow = now ?? _currentTime;
    final effectiveUntil = until ?? effectiveNow.add(recurringAlarmWindow);
    final upcomingEvents = upcomingAlarmOccurrences(
      events,
      from: effectiveNow,
      until: effectiveUntil,
    );

    var preparationDays = 0;
    var preparationFailed = false;
    final dayEvents = <String, List<EventModel>>{};
    // Smart preparation stores one setup per event ID. Keep its existing
    // anchor behavior while departure alarms use individual occurrences.
    for (final event in events) {
      final startAt = event.startAt;
      if (startAt == null ||
          !startAt.isAfter(effectiveNow) ||
          !startAt.isBefore(effectiveUntil)) {
        continue;
      }
      final localDay = planflowLocal(startAt);
      final key = '${localDay.year.toString().padLeft(4, '0')}-'
          '${localDay.month.toString().padLeft(2, '0')}-'
          '${localDay.day.toString().padLeft(2, '0')}';
      dayEvents.putIfAbsent(key, () => <EventModel>[]).add(event);
    }

    var departureScheduled = 0;
    var departureSkipped = 0;
    try {
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
          cacheOnlyLocation: cacheOnlyLocation,
          localAlarmBatch: booking,
        );
        preparationDays += 1;
        preparationFailed = preparationFailed || !ok;
      }

      if (resyncDepartureAlarms) {
        final departureUntil =
            effectiveNow.add(DepartureAlarmService.monitorLookAhead);
        var hasUrgentDepartureMonitorEvent = false;
        final upcomingDepartures = upcomingEvents
            .where((event) => event.startAt!.isBefore(departureUntil))
            .toList();
        final activeDepartureKeys = upcomingDepartures
            .where((event) =>
                event.locationLat != null && event.locationLng != null)
            .map((event) => eventAlarmKey(event, 'departure'))
            .toSet();
        final cancelledDepartureEventIds = {
          ...extraDepartureEventIdsToCancel.where((id) => id.trim().isNotEmpty),
          ...upcomingDepartures.map((event) => event.id),
          ...events.where(isRecurringAlarmEvent).map((event) => event.id),
        };
        for (final eventId in cancelledDepartureEventIds) {
          for (final key in eventAlarmCancellationKeys(
            '$eventId:departure',
            effectiveNow,
          )) {
            if (!activeDepartureKeys.contains(key)) {
              await _notifications.cancelDepartureSlot(key);
            }
          }
        }
        for (final event in upcomingDepartures) {
          if (!_hasPlace(event)) {
            DiagLogger.log(
              'ManualSideEffect',
              'DepartureAlarm 스킵(장소없음) eventId=${event.id} '
                  'title="${event.title}"',
            );
            departureSkipped += 1;
            continue;
          }
          final startAt = event.startAt!;
          if (startAt.isBefore(
            effectiveNow.add(DepartureAlarmService.monitorUrgentWindow),
          )) {
            hasUrgentDepartureMonitorEvent = true;
          }
          booking.add(
            startAt,
            1,
            (_) async {
              final result = await _departureAlarms.scheduleForEvent(
                event,
                rescheduleMonitor: false,
                safetyMarginOverride: departureSafetyMargin,
                cacheOnlyLocation: cacheOnlyLocation,
              );
              DiagLogger.log(
                'ManualSideEffect',
                result.isScheduled
                    ? 'DepartureAlarm 등록 eventId=${event.id} '
                        'title="${event.title}" '
                        'loc="${event.location ?? ''}" '
                        'hasCoords=${event.locationLat != null && event.locationLng != null}'
                    : 'DepartureAlarm 스킵 eventId=${event.id} '
                        'title="${event.title}" '
                        'reason=${result.skippedReason ?? 'unknown'}',
              );
              if (result.isScheduled) {
                departureScheduled += 1;
                return 1;
              }
              departureSkipped += 1;
              return 0;
            },
            departureKey: eventAlarmKey(event, 'departure'),
            validatePending: () =>
                _departureAlarms.validatePendingDeparture(event),
            canReplacePending: () =>
                _departureAlarms.canReplacePendingDeparture(
              event,
              safetyMarginOverride: departureSafetyMargin,
            ),
            onSkip: () => departureSkipped += 1,
          );
        }
        if (upcomingDepartures.isNotEmpty) {
          await _departureAlarms.scheduleNextMonitor(
            interval: hasUrgentDepartureMonitorEvent
                ? DepartureAlarmService.monitorUrgentInterval
                : DepartureAlarmService.monitorInterval,
          );
        }
      }
    } finally {
      if (localAlarmBatch == null) {
        await booking.book();
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
    LocalAlarmResyncBatch? localAlarmBatch,
  }) async {
    final booking = localAlarmBatch ?? createLocalAlarmResyncBatch();
    final now = _currentTime;
    final futureEvents = upcomingAlarmOccurrences(
      events,
      from: now,
      until: now.add(recurringAlarmWindow),
      includeFutureNonRecurring: true,
    );
    final eventIdsToRefresh = {
      ...events.where(isRecurringAlarmEvent).map((event) => event.id),
      ...futureEvents.map((event) => event.id),
    };
    if (eventIdsToRefresh.isEmpty) {
      return true;
    }

    try {
      for (final eventId in eventIdsToRefresh) {
        await gateway.deleteRemindersForEvent(
          eventId: eventId,
          userId: userId,
        );
        for (final kind in ['push', 'critical']) {
          for (final key in eventAlarmCancellationKeys('$eventId:$kind', now)) {
            await _notifications.cancel(_notifications.notificationIdFor(key));
          }
        }
        // 동적 강한알람 체인(이전 generation의 headless/소리 알림)도 함께
        // 무효화한다. 이후 ACK 등으로 재예약하지 않는 일정에 옛 watchdog이
        // 남아 울리지 않게 한다.
        await CriticalAlarmPreflightService.cancelScheduledPreflight(
          eventId,
          notifications: _notifications,
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
        if (!event.isCritical && reminderOffset == null) continue;
        booking.add(
          event.startAt!,
          1,
          (_) async => await _scheduleLocalNotifications(
            event,
            reminderOffset: reminderOffset,
            criticalAlarmOffset: criticalAlarmOffset ?? reminderOffset,
          )
              ? 1
              : 0,
        );
      }
      return localAlarmBatch != null || await booking.book();
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
    // 백그라운드 동기화에서 호출하면 true로 설정해 라이브 GPS 조회를 막는다.
    bool cacheOnlyLocation = false,
    LocalAlarmResyncBatch? localAlarmBatch,
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
      cacheOnlyLocation: cacheOnlyLocation,
      localAlarmBatch: localAlarmBatch,
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
    bool cacheOnlyLocation = false,
    LocalAlarmResyncBatch? localAlarmBatch,
  }) async {
    final booking = localAlarmBatch ?? createLocalAlarmResyncBatch();
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
      DiagLogger.log(
        'ManualSideEffect',
        'resyncExternalPrep 외부일정 없음 day=${dayReference.toIso8601String()}',
      );
      return true;
    }

    final firstExternalEventId = externalEvents.first.id;
    DiagLogger.log(
      'ManualSideEffect',
      'resyncExternalPrep 외부일정 count=${externalEvents.length} '
          'firstId=$firstExternalEventId '
          'day=${dayReference.toIso8601String()}',
    );

    // 위치를 루프 밖에서 1회만 조회해 이벤트마다 중복 LocationManager 호출을 막는다.
    // 백그라운드(cacheOnlyLocation=true)에서는 라이브 GPS 조회 자체를 건너뛴다.
    final sharedOrigin =
        await _resolveOriginLocation(cacheOnly: cacheOnlyLocation);
    DiagLogger.log(
      'ManualSideEffect',
      'resyncExternalPrep origin=${sharedOrigin != null ? '${sharedOrigin.latitude},${sharedOrigin.longitude}' : 'null'} '
          'day=${dayReference.toIso8601String()}',
    );

    final payloadsByEvent = <EventModel, List<Map<String, dynamic>>>{};
    for (final event in externalEvents) {
      final resolvedTravelMinutes = await _resolveTravelMinutesForEvent(
        event,
        fallbackTravelMinutes: travelMinutes,
        travelMode: travelMode,
        preResolvedOrigin: sharedOrigin,
      );
      final isFirst = event.id == firstExternalEventId;
      final payloads = smartService.buildExternalEventPayloads(
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
        isFirstExternalEventOfDay: isFirst,
        includePreparationAlarms: isFirst,
        now: now,
      );
      // 이벤트별 payload 생성 결과: 준비 알람 포함 여부와 payload 수 기록
      DiagLogger.log(
        'ManualSideEffect',
        'resyncExternalPrep payload eventId=${event.id} '
            'isFirst=$isFirst '
            'includePrep=$isFirst '
            'payloadCount=${payloads.length} '
            'travelMin=${resolvedTravelMinutes.minutes} '
            'travelIsFallback=${resolvedTravelMinutes.isFallback}',
      );
      payloadsByEvent[event] = payloads;
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
        booking.add(entry.key.startAt!, entry.value.length, (allowed) async {
          await smartService.schedulePayloads(
            eventId: entry.key.id,
            eventTitle: entry.key.title,
            eventSource: entry.key.source,
            payloads: entry.value.take(allowed).toList(),
          );
          return allowed;
        });
      }
      return localAlarmBatch != null || await booking.book();
    } catch (e, st) {
      debugPrint('[PlanFlow] smart preparation alarm resync failed: $e\n$st');
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

  /// 이벤트별 이동시간 해상도를 계산한다.
  ///
  /// [preResolvedOrigin] 을 전달하면 위치 조회를 건너뛴다.
  /// 여러 이벤트를 루프로 처리할 때 origin 조회를 루프 밖에서 1회 실행하고
  /// 이 파라미터로 전달해야 LocationManager 중복 호출을 막을 수 있다.
  Future<_TravelMinutesResolution> _resolveTravelMinutesForEvent(
    EventModel event, {
    required int fallbackTravelMinutes,
    required String travelMode,
    GeoPoint? preResolvedOrigin,
  }) async {
    if (fallbackTravelMinutes !=
        SmartPreparationAlarmService.defaultTravelBufferMin) {
      return _TravelMinutesResolution(
        minutes: fallbackTravelMinutes,
        isFallback: false,
      );
    }
    // preResolvedOrigin이 있으면 추가 위치 조회 없이 바로 사용한다.
    final origin = preResolvedOrigin ?? await _resolveOriginLocation();
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
        'Smart preparation travel estimate: no current location for '
        '${event.id}; using destination coordinate heuristic.',
      );
      final estimate = _travelTimeBuffer.estimate(
        latitude: destination.latitude,
        longitude: destination.longitude,
        locationText: event.location,
      );
      return _TravelMinutesResolution(
        minutes: estimate.minutes,
        isFallback: estimate.source == TravelTimeBufferSource.defaultFallback,
      );
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

    for (final query
        in _buildDestinationSearchQueries(event).take(_maxDestinationQueries)) {
      try {
        final searchResult =
            await _locationLookup.searchWithFallback(query, origin: origin);
        if (searchResult.results.isEmpty) {
          continue;
        }
        final selected = searchResult.results.first;
        // [PREVENT] 유령 장소 주입 회귀 방지 (2026-07-16).
        // 사용자가 적은 location 원문을 POI 검색 결과의 공식명(bestPlaceLabel)으로
        // 덮어쓰지 않는다. 좌표(lat/lng)만 채운다 — event_preparation_service와 동일
        // 철학. 이 경로는 location 폴백이 있어야 진입하므로 사용자가 실제로 입력한
        // 장소 텍스트가 존재하며, 이를 검색 API 정식명칭으로 바꿔치기하면 사용자가
        // 알아보는 표현이 사라져 혼란을 준다.
        await _backfillEventLocationCoordinates(
          event: event,
          latitude: selected.latitude,
          longitude: selected.longitude,
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
  }) async {
    if (event.id.trim().isEmpty ||
        event.locationLat != null ||
        event.locationLng != null) {
      return;
    }
    try {
      await _events.updateEvent(
        event.copyWith(
          locationLat: latitude,
          locationLng: longitude,
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

  /// [cacheOnly] 가 true이면 라이브 GPS(getCurrentLocationWithPermission) 조회를
  /// 건너뛴다. 백그라운드 알람 재계산 경로에서 호출할 때는 반드시 true로 설정해
  /// LocationManager 폭주와 삼성 강제종료를 막는다.
  /// 이 서비스는 자체 위치 캐시를 두지 않으므로 cacheOnly이면 origin이 없을 때
  /// null을 반환하고, 출발 알람은 fallback travel time을 사용한다.
  Future<GeoPoint?> _resolveOriginLocation({bool cacheOnly = false}) async {
    final current = await _currentLocationProvider?.call();
    if (current != null) {
      return current;
    }
    if (kIsWeb || cacheOnly) {
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

  // [PREVENT] 유령 장소 주입 회귀 방지 (2026-07-16).
  // event.title/event.memo는 더 이상 장소 검색어로 쓰지 않는다. 이 폴백의 정당한
  // 목적은 "사용자가 이름으로 적은 장소"(event.location)에 좌표를 붙이는 것뿐이다.
  // title/memo는 사용자가 장소로 의도하지 않은 자유 텍스트라 검색어로 쓰면 무관한
  // POI가 부분일치로 뽑혀 사용자 장소를 엉뚱한 공식명/좌표로 덮어쓸 수 있다
  // (event_preparation_service.dart와 동일 클래스 결함).
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

    final criticalNotifyAt = event.isCritical
        ? _resolveCriticalNotifyAt(
            startAt,
            criticalAlarmOffset ?? Duration.zero,
          )
        : null;
    if (event.isCritical && criticalNotifyAt != null) {
      payloads.add(
        _reminderPayload(
          eventId: event.id,
          userId: userId,
          type: 'system_alarm',
          notifyAt: criticalNotifyAt,
        ),
      );
    } else if (reminderOffset != null) {
      payloads.add(
        _reminderPayload(
          eventId: event.id,
          userId: userId,
          type: 'push',
          notifyAt: startAt.subtract(reminderOffset),
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
    await _scheduleLocalNotifications(
      event,
      reminderOffset: reminderOffset,
      criticalAlarmOffset: criticalAlarmOffset,
    );
  }

  Future<bool> _scheduleLocalNotifications(
    EventModel event, {
    required Duration? reminderOffset,
    required Duration? criticalAlarmOffset,
  }) async {
    final startAt = event.startAt;
    if (startAt == null) {
      return false;
    }

    final now = _currentTime;
    var reminderNotifyAt =
        reminderOffset == null ? null : startAt.subtract(reminderOffset);
    // 기본 60분 전 알림 시각이 이미 지났지만 일정 시작은 아직 미래라면
    // (= 지금부터 1시간 이내에 시작하는 일정), 알림을 스킵하지 말고
    // 일정 시작 정각에 알린다. (시작 시각마저 과거면 아래 isAfter(now)에서 스킵)
    if (reminderNotifyAt != null &&
        !reminderNotifyAt.isAfter(now) &&
        startAt.isAfter(now)) {
      reminderNotifyAt = startAt;
    }
    final criticalNotifyAt = event.isCritical
        ? _resolveCriticalNotifyAt(
            startAt,
            criticalAlarmOffset ?? Duration.zero,
          )
        : null;
    if (!event.isCritical &&
        reminderNotifyAt != null &&
        reminderNotifyAt.isAfter(now)) {
      await _notifications.scheduleEventReminder(
        id: _notifications.notificationIdFor(eventAlarmKey(event, 'push')),
        title: event.title,
        body: '일정 시작: ${event.title}',
        notifyAt: reminderNotifyAt,
        payload: 'event:${event.id}',
      );
      return true;
    }

    if (event.isCritical && criticalNotifyAt != null) {
      // 사용자가 이미 확인한 일정이면 강한알람을 재예약하지 않는다. 이 한
      // 줄이 채널 마이그레이션/캘린더 재동기화/사용자 편집 후 재예약까지
      // 모두 막는다(모든 경로가 scheduleLocalNotifications를 거친다).
      // sentinel 케이스(startAt을 모른 채로 저장된 ack)도 같은 eventId에
      // 대해 매칭되므로 막는다. 시작 시각이 변경되면 exact 매칭이 풀려
      // 자동으로 다시 울린다.
      final criticalAcks = _criticalAcks;
      final occurrence = isRecurringAlarmEvent(event)
          ? CriticalAlarmOccurrence(startAt)
          : null;
      if (await criticalAcks.hasUnknownStartAcknowledgement(event.id)) {
        // 백그라운드에서 시작 시각 없이 저장된 ack: 지금 확인된 시작 시각으로
        // 고정해 두면 이후 시각 변경은 정상적으로 다시 울린다.
        await criticalAcks.adoptUnknownStart(event.id, startAt);
        return false;
      }
      if (await criticalAcks.isAcknowledged(event.id, startAt) ||
          (occurrence != null &&
              await criticalAcks.isOccurrenceAcknowledged(
                occurrence.acknowledgementKey(event.id),
                startAt,
              ))) {
        return false;
      }
      // Android+좌표 있는 강한알람은 트리거 시각에 조용히 preflight를 돌려
      // 신선한 GPS·경로 API로 출발 시각을 재계산한 뒤 울린다(12:00 트리거가
      // 12:30으로 재무장되는 식). 그 외(iOS/약한알람/무좌표)는 기존처럼
      // 바로 예약한다. 결과 규약(isScheduled/throw)은 기존과 동일하다.
      final id =
          _notifications.notificationIdFor(eventAlarmKey(event, 'critical'));
      const body = '중요 일정이 곧 시작됩니다.';
      final payload = occurrence?.payloadFor(event.id) ?? 'event:${event.id}';
      // The existing preflight owner is keyed by the series ID. Use a direct
      // alarm per occurrence so reserving one does not replace the others.
      final result = occurrence != null
          ? await _notifications.scheduleCriticalAlarmWithResult(
              id: id,
              title: event.title,
              notifyAt: criticalNotifyAt,
              body: body,
              payload: payload,
              useStrongAlarm: event.useStrongAlarm,
            )
          : await _criticalPreflight.scheduleCriticalAlarmWithTravelRecalc(
              event: event,
              id: id,
              title: event.title,
              notifyAt: criticalNotifyAt,
              body: body,
              payload: payload,
              useStrongAlarm: event.useStrongAlarm,
            );
      if (!result.isScheduled) {
        throw StateError(result.message ?? '중요 알람 예약 실패');
      }
      return true;
    }
    return false;
  }

  DateTime? _resolveCriticalNotifyAt(DateTime eventStartAt, Duration offset) {
    final now = _currentTime;
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
