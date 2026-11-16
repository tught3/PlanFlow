import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/diag_logger.dart';
import '../core/env.dart';
import '../core/local_time.dart';
import '../core/recurrence_expansion.dart';
import '../core/supabase_auth_options.dart';
import '../data/models/event_model.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/event_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'app_permission_service.dart';
import 'alarm_service.dart';
import 'departure_acknowledgement_store.dart';
import 'map_service.dart';
import 'notification_service.dart';
import 'pending_departure_store.dart';
import 'travel_time_buffer_service.dart';

const recurringAlarmWindow = Duration(days: 7);

bool isRecurringAlarmEvent(EventModel event) =>
    event.recurrenceRule?.trim().isNotEmpty ?? false;

String eventAlarmKey(EventModel event, String kind) {
  final key = '${event.id}:$kind';
  final startAt = event.startAt;
  if (startAt == null || !isRecurringAlarmEvent(event)) {
    return key;
  }
  return '$key:${eventAlarmDateSuffix(startAt)}';
}

/// Expands in the PlanFlow calendar zone, then returns absolute alarm times.
List<EventModel> upcomingAlarmOccurrences(
  Iterable<EventModel> events, {
  required DateTime from,
  required DateTime until,
  bool includeFutureNonRecurring = false,
  bool includeNonRecurringBoundaries = false,
}) {
  final localFrom = planflowLocal(from);
  final localUntil = planflowLocal(until);
  final candidates = <EventModel>[];
  final overrides = <EventModel>[];

  for (final event in events) {
    if (event.parentEventId != null && event.overriddenOccurrenceDate != null) {
      overrides.add(event.copyWith(clearStartAt: true));
    }
    final startAt = event.startAt;
    if (startAt == null) {
      continue;
    }
    if (!isRecurringAlarmEvent(event)) {
      final startsAfterBoundary = startAt.isAfter(from) ||
          (includeNonRecurringBoundaries && startAt.isAtSameMomentAs(from));
      final startsBeforeBoundary = startAt.isBefore(until) ||
          (includeNonRecurringBoundaries && startAt.isAtSameMomentAs(until));
      if (startsAfterBoundary &&
          (includeFutureNonRecurring || startsBeforeBoundary)) {
        candidates.add(event);
      }
      continue;
    }
    for (final occurrence in expandRecurringEvent(
      event: event,
      rangeStart: localFrom,
      rangeEnd: localUntil,
      includeOccurrence: (occurrence, from, until) {
        final startAt = occurrence.startAt!;
        return !startAt.isBefore(from) && startAt.isBefore(until);
      },
    )) {
      // Invalid or unsupported rules can return the unchanged anchor.
      final startAt = identical(occurrence, event)
          ? event.startAt!
          : planflowLocalDateTimeToUtc(occurrence.startAt!);
      if (startAt.isBefore(from) || !startAt.isBefore(until)) {
        continue;
      }
      final duration = event.endAt?.difference(event.startAt!);
      candidates.add(event.copyWith(
        startAt: startAt,
        endAt: duration == null ? null : startAt.add(duration),
      ));
    }
  }
  final upcoming = overrides.isEmpty
      ? candidates
      : hideOverriddenRecurringOccurrences([...candidates, ...overrides])
          .where((event) => event.startAt != null)
          .toList();
  return upcoming..sort((a, b) => a.startAt!.compareTo(b.startAt!));
}

typedef DepartureAlarmPreflightScheduler = Future<bool> Function({
  required EventModel event,
  required DateTime preflightAt,
  required Duration safetyMargin,
  required MapTravelMode travelMode,
});

class DepartureAlarmService {
  const DepartureAlarmService({
    AppPermissionService? permissionService,
    Future<GeoPoint?> Function()? currentLocationProvider,
    TravelTimeBufferService? travelTimeBufferService,
    NotificationService? notificationService,
    EventRepository? eventRepository,
    SettingsRepository? settingsRepository,
    DepartureAlarmPreflightScheduler? preflightScheduler,
    Future<bool> Function(int alarmId)? preflightCanceller,
    DepartureAcknowledgementStore? acknowledgementStore,
    PendingDepartureStore? pendingDepartureStore,
    CriticalAlarmOccurrence? confirmationOccurrence,
    DateTime Function()? now,
  })  : _permissionService = permissionService,
        _currentLocationProvider = currentLocationProvider,
        _travelTimeBufferService = travelTimeBufferService,
        _notificationService = notificationService,
        _eventRepository = eventRepository,
        _settingsRepository = settingsRepository,
        _preflightScheduler = preflightScheduler,
        _preflightCanceller = preflightCanceller,
        _acknowledgementStore = acknowledgementStore,
        _pendingDepartureStore = pendingDepartureStore,
        _confirmationOccurrence = confirmationOccurrence,
        _now = now;

  static const String label = '출발 알림';
  static const int defaultSafetyMarginMin = 20;
  static const Duration safetyMargin = Duration(
    minutes: defaultSafetyMarginMin,
  );
  static const Duration monitorInterval = Duration(minutes: 30);
  static const Duration monitorUrgentInterval = Duration(minutes: 15);
  static const int defaultRepeatIntervalMin = 10;
  static const List<int> allowedRepeatIntervalMinutes = <int>[
    0,
    5,
    10,
    15,
    30,
    60,
  ];
  static const Duration monitorUrgentWindow = Duration(hours: 6);
  static const Duration monitorLookAhead = Duration(hours: 24);
  static const String _monitorAlarmId = 'departure_alarm:monitor';
  static const Duration _immediateNotificationDelay = Duration(seconds: 3);
  // Start the recalculation before the visible fallback is due so they cannot
  // both post an alarm at the same time.
  static const Duration _preflightLeadTime = Duration(seconds: 30);
  static const String _lastEventIdKey = 'departure_alarm:last_event_id';
  static const String _lastEventTitleKey = 'departure_alarm:last_event_title';
  static const String _lastStatusKey = 'departure_alarm:last_status';
  static const String _lastSkippedReasonKey =
      'departure_alarm:last_skipped_reason';
  static const String _lastCheckedAtKey = 'departure_alarm:last_checked_at';
  static const String _lastNotifyAtKey = 'departure_alarm:last_notify_at';
  static const String _lastTravelMinutesKey =
      'departure_alarm:last_travel_minutes';
  static const String _lastMonitorAtKey = 'departure_alarm:last_monitor_at';
  static const String _nextMonitorAtKey = 'departure_alarm:next_monitor_at';
  static const String _lastMonitorScheduledKey =
      'departure_alarm:last_monitor_scheduled';
  static const String _lastMonitorSkippedKey =
      'departure_alarm:last_monitor_skipped';
  static const String _lastMonitorSkippedReasonKey =
      'departure_alarm:last_monitor_skipped_reason';
  static const String _monitorScheduledKey =
      'departure_alarm:monitor_scheduled';
  static const String _repeatIntervalMinKey =
      'departure_alarm:repeat_interval_min';
  static const String _lastVisibleNotifyPrefix =
      'departure_alarm:last_visible_notify_at:';
  static const String cachedOriginLatKey = 'departure_alarm:cached_origin_lat';
  static const String cachedOriginLngKey = 'departure_alarm:cached_origin_lng';
  static const String cachedOriginAtKey = 'departure_alarm:cached_origin_at';

  final AppPermissionService? _permissionService;
  final Future<GeoPoint?> Function()? _currentLocationProvider;
  final TravelTimeBufferService? _travelTimeBufferService;
  final NotificationService? _notificationService;
  final EventRepository? _eventRepository;
  final SettingsRepository? _settingsRepository;
  final DepartureAlarmPreflightScheduler? _preflightScheduler;
  final Future<bool> Function(int alarmId)? _preflightCanceller;
  final DepartureAcknowledgementStore? _acknowledgementStore;
  final PendingDepartureStore? _pendingDepartureStore;
  final CriticalAlarmOccurrence? _confirmationOccurrence;
  final DateTime Function()? _now;

  AppPermissionService get _permissions =>
      _permissionService ?? AppPermissionService();

  TravelTimeBufferService get _travelTime =>
      _travelTimeBufferService ?? TravelTimeBufferService();

  NotificationService get _notifications =>
      _notificationService ?? NotificationService();

  EventRepository get _events => _eventRepository ?? EventRepository.supabase();

  SettingsRepository get _settings {
    final injected = _settingsRepository;
    if (injected != null) {
      return injected;
    }
    try {
      return SettingsRepository.supabase();
    } catch (error, stackTrace) {
      debugPrint('Departure alarm settings fallback: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const _FallbackSettingsRepository();
    }
  }

  DepartureAcknowledgementStore get _acknowledgements =>
      _acknowledgementStore ??
      const SharedPreferencesDepartureAcknowledgementStore();

  PendingDepartureStore get _pendingDepartures =>
      _pendingDepartureStore ?? const SharedPreferencesPendingDepartureStore();

  DateTime get _currentTime => (_now ?? DateTime.now)();

  static Future<int> loadRepeatIntervalMinutes() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getInt(_repeatIntervalMinKey);
    if (value != null && allowedRepeatIntervalMinutes.contains(value)) {
      return value;
    }
    return defaultRepeatIntervalMin;
  }

  static Future<void> saveRepeatIntervalMinutes(int minutes) async {
    final normalized = allowedRepeatIntervalMinutes.contains(minutes)
        ? minutes
        : defaultRepeatIntervalMin;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_repeatIntervalMinKey, normalized);
  }

  Future<DepartureAlarmScheduleResult> scheduleForEvent(
    EventModel event, {
    bool rescheduleMonitor = true,
    Duration? safetyMarginOverride,
    MapTravelMode? travelModeOverride,
    bool fireDueDeparture = false,

    /// 백그라운드 isolate(모니터·preflight 콜백)에서 호출할 때 true로 설정한다.
    /// 라이브 GPS 조회를 건너뛰고 캐시된 위치만 사용해 LocationManager 폭주를 막는다.
    bool cacheOnlyLocation = false,
  }) =>
      _scheduleForEvent(
        event,
        rescheduleMonitor: rescheduleMonitor,
        safetyMarginOverride: safetyMarginOverride,
        travelModeOverride: travelModeOverride,
        fireDueDeparture: fireDueDeparture,
        cacheOnlyLocation: cacheOnlyLocation,
      );

  /// A pending alert can be displaced only when the cached route still places
  /// the departure time in the future. Preserve the fallback if timing is unknown.
  Future<bool> canReplacePendingDeparture(
    EventModel event, {
    Duration? safetyMarginOverride,
    MapTravelMode? travelModeOverride,
  }) async {
    final startAt = event.startAt;
    final destinationLat = event.locationLat;
    final destinationLng = event.locationLng;
    if (startAt == null || destinationLat == null || destinationLng == null) {
      return false;
    }
    final origin = await _resolveOriginLocation(cacheOnly: true);
    if (origin == null) return false;

    final estimate = await _estimateDepartureTravelTime(
      event,
      origin: origin,
      destinationLat: destinationLat,
      destinationLng: destinationLng,
      travelModeOverride: travelModeOverride,
      cacheOnlyLocation: true,
    );
    final margin =
        safetyMarginOverride ?? const Duration(minutes: defaultSafetyMarginMin);
    return startAt.subtract(estimate.buffer + margin).isAfter(_currentTime);
  }

  Future<TravelTimeBufferEstimate> _estimateDepartureTravelTime(
    EventModel event, {
    required GeoPoint origin,
    required double destinationLat,
    required double destinationLng,
    required MapTravelMode? travelModeOverride,
    required bool cacheOnlyLocation,
  }) =>
      _travelTime.estimateWithMapApis(
        originLat: origin.latitude,
        originLng: origin.longitude,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        mode: travelModeOverride ?? _travelModeFromEvent(event),
        locationText: event.location,
        skipRemote: cacheOnlyLocation,
      );

  Future<DepartureAlarmScheduleResult> _scheduleForEvent(
    EventModel event, {
    required bool rescheduleMonitor,
    Duration? safetyMarginOverride,
    MapTravelMode? travelModeOverride,
    bool fireDueDeparture = false,
    bool cacheOnlyLocation = false,
    DateTime? fallbackAt,
  }) async {
    final startAt = event.startAt;
    final destinationLat = event.locationLat;
    final destinationLng = event.locationLng;
    if (startAt == null || !startAt.isAfter(_currentTime)) {
      return _recordAndReturnScheduleResult(
        event,
        const DepartureAlarmScheduleResult.skipped('past_or_no_time'),
      );
    }
    if (destinationLat == null || destinationLng == null) {
      return _recordAndReturnScheduleResult(
        event,
        const DepartureAlarmScheduleResult.skipped('missing_destination'),
      );
    }
    if (await _isDepartureAcknowledged(event)) {
      return _recordAndReturnScheduleResult(
        event,
        const DepartureAlarmScheduleResult.skipped(
          'departure_acknowledged',
        ),
      );
    }
    final departureKey = isRecurringAlarmEvent(event)
        ? eventAlarmKey(event, 'departure')
        : event.id;

    final origin = await _resolveOriginLocation(cacheOnly: cacheOnlyLocation);
    if (origin == null) {
      if (fallbackAt != null) {
        return const DepartureAlarmScheduleResult.skipped('fallback_retained');
      }
      if (fireDueDeparture) {
        if (!await _canFireDueDeparture(departureKey)) {
          return _recordAndReturnScheduleResult(
            event,
            const DepartureAlarmScheduleResult.skipped(
              'departure_repeat_throttled',
            ),
          );
        }
        final notifyAt = _currentTime.add(_immediateNotificationDelay);
        final scheduled = await _scheduleVisibleDepartureNotification(
          event: event,
          notifyAt: notifyAt,
          travelMinutes: null,
          safetyMargin: safetyMarginOverride ??
              const Duration(minutes: defaultSafetyMarginMin),
          isDueNow: true,
        );
        if (!scheduled) {
          return _recordAndReturnScheduleResult(
            event,
            const DepartureAlarmScheduleResult.skipped(
              'notification_schedule_failed',
            ),
          );
        }
        await _recordDueDepartureFired(departureKey);
        return _recordAndReturnScheduleResult(
          event,
          DepartureAlarmScheduleResult.scheduled(
            notifyAt: notifyAt,
            travelMinutes: null,
          ),
        );
      }
      await _cancelInvalidPendingDeparture(event, startAt);
      return _recordAndReturnScheduleResult(
        event,
        const DepartureAlarmScheduleResult.skipped('missing_origin'),
      );
    }

    final estimate = await _estimateDepartureTravelTime(
      event,
      origin: origin,
      destinationLat: destinationLat,
      destinationLng: destinationLng,
      // 백그라운드(모니터/동기화)에선 routes API 대신 로컬 추정만 사용해 폭주 방지.
      travelModeOverride: travelModeOverride,
      cacheOnlyLocation: cacheOnlyLocation,
    );
    final resolvedSafetyMargin =
        safetyMarginOverride ?? const Duration(minutes: defaultSafetyMarginMin);
    final departAt = startAt.subtract(estimate.buffer + resolvedSafetyMargin);
    final now = _currentTime;
    final shouldFireNow = !departAt.isAfter(now);
    if (shouldFireNow && !fireDueDeparture) {
      await _cancelInvalidPendingDeparture(event, startAt);
      return _recordAndReturnScheduleResult(
        event,
        DepartureAlarmScheduleResult.skipped(
          'departure_time_passed',
          travelMinutes: estimate.minutes,
        ),
      );
    }

    if (fallbackAt != null && !fallbackAt.isAfter(_currentTime)) {
      return const DepartureAlarmScheduleResult.skipped('fallback_already_due');
    }
    if (shouldFireNow && !await _canFireDueDeparture(departureKey)) {
      return _recordAndReturnScheduleResult(
        event,
        const DepartureAlarmScheduleResult.skipped(
          'departure_repeat_throttled',
        ),
      );
    }
    final notifyAt = shouldFireNow
        ? _currentTime.add(_immediateNotificationDelay)
        : departAt;
    final visibleScheduled = await _scheduleVisibleDepartureNotification(
      event: event,
      notifyAt: notifyAt,
      travelMinutes: estimate.minutes,
      safetyMargin: resolvedSafetyMargin,
      isDueNow: shouldFireNow,
    );
    int? rearmedPreflightId;
    if (!shouldFireNow) {
      final rearmed = await _scheduleDeparturePreflight(
        event: event,
        notifyAt: notifyAt,
        fallbackAt: visibleScheduled ? notifyAt : null,
        safetyMargin: resolvedSafetyMargin,
        travelMode: travelModeOverride ?? _travelModeFromEvent(event),
      );
      if (rearmed) {
        rearmedPreflightId =
            _stableAlarmId(eventAlarmKey(event, 'departure_preflight'));
      }
    } else if (visibleScheduled) {
      await _recordDueDepartureFired(departureKey);
    }
    if (!visibleScheduled && rearmedPreflightId == null) {
      return _recordAndReturnScheduleResult(
        event,
        const DepartureAlarmScheduleResult.skipped(
          'notification_schedule_failed',
        ),
      );
    }

    if (rescheduleMonitor) {
      unawaited(scheduleNextMonitor(interval: _monitorIntervalForEvent(event)));
    }

    return _recordAndReturnScheduleResult(
      event,
      DepartureAlarmScheduleResult.scheduled(
        notifyAt: notifyAt,
        travelMinutes: estimate.minutes,
        rearmedPreflightId: rearmedPreflightId,
      ),
    );
  }

  /// Checks an existing fallback without booking or replacing an alarm.
  Future<void> validatePendingDeparture(EventModel event) async {
    final startAt = event.startAt;
    if (startAt == null) return;
    await _cancelInvalidPendingDeparture(event, startAt);
  }

  Future<void> _cancelInvalidPendingDeparture(
    EventModel event,
    DateTime startAt,
  ) async {
    final slot = await _notifications.pendingDepartureSlot(
      eventAlarmKey(event, 'departure'),
    );
    if (slot == null) return;
    final notifyAt = slot.notifyAt;
    if (notifyAt != null &&
        notifyAt.isAfter(_currentTime) &&
        notifyAt.isBefore(startAt)) {
      return;
    }
    await _cancelDepartureArtifacts(
      event.id,
      dateSuffix:
          isRecurringAlarmEvent(event) ? eventAlarmDateSuffix(startAt) : null,
    );
  }

  Future<DepartureAlarmScheduleResult> runPreflightForEvent(
    String eventId, {
    String? userId,
    DateTime? occurrenceStartAt,
    DateTime? fallbackAt,
    int? alarmId,
  }) async {
    final suffix = occurrenceStartAt == null
        ? ''
        : ':${eventAlarmDateSuffix(occurrenceStartAt)}';
    final firedId = alarmId ??
        _stableAlarmId('${eventId.trim()}:departure_preflight$suffix');
    DepartureAlarmScheduleResult? result;
    try {
      result = await _runPreflightForEvent(
        eventId,
        userId: userId,
        occurrenceStartAt: occurrenceStartAt,
        fallbackAt: fallbackAt,
      );
      return result;
    } finally {
      if (result?._rearmedPreflightId != firedId) {
        await _cancelDeparturePreflightById(firedId);
      }
    }
  }

  Future<DepartureAlarmScheduleResult> _runPreflightForEvent(
    String eventId, {
    String? userId,
    DateTime? occurrenceStartAt,
    DateTime? fallbackAt,
  }) async {
    final resolvedEventId = eventId.trim();
    if (resolvedEventId.isEmpty) {
      return const DepartureAlarmScheduleResult.skipped('missing_event_id');
    }
    if (fallbackAt != null && !fallbackAt.isAfter(_currentTime)) {
      return const DepartureAlarmScheduleResult.skipped('fallback_already_due');
    }

    final resolvedUserId = userId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return const DepartureAlarmScheduleResult.skipped('signed_out');
    }
    if (!AppEnv.isSupabaseReady) {
      return const DepartureAlarmScheduleResult.skipped('supabase');
    }

    final anchor =
        await _events.fetchEvent(resolvedEventId, userId: resolvedUserId);
    final dateSuffix = occurrenceStartAt == null
        ? null
        : eventAlarmDateSuffix(occurrenceStartAt);
    if (anchor == null) {
      // The isolated client can see no row under RLS. Leave the fallback booked.
      return const DepartureAlarmScheduleResult.skipped('event_not_found');
    }
    var event = anchor;
    if (occurrenceStartAt != null) {
      final related = await _events.listEvents(userId: resolvedUserId);
      final candidates = upcomingAlarmOccurrences(
        [anchor, ...related.where((item) => item.parentEventId == anchor.id)],
        from: occurrenceStartAt.subtract(const Duration(seconds: 1)),
        until: occurrenceStartAt.add(const Duration(seconds: 1)),
      );
      if (!isRecurringAlarmEvent(anchor) ||
          !candidates.any((item) =>
              item.id == anchor.id &&
              item.startAt!.isAtSameMomentAs(occurrenceStartAt))) {
        await _notifications.cancel(
          _notifications.notificationIdFor(
            '$resolvedEventId:departure:$dateSuffix',
          ),
        );
        return const DepartureAlarmScheduleResult.skipped('occurrence_changed');
      }
      event = candidates.firstWhere((item) => item.id == anchor.id);
    } else if (isRecurringAlarmEvent(anchor)) {
      // A pre-WAVE2 callback has no occurrence identity. The rolling monitor
      // handles subsequent occurrences.
      return const DepartureAlarmScheduleResult.skipped('missing_occurrence');
    }
    if (await _isDepartureAcknowledged(event)) {
      return const DepartureAlarmScheduleResult.skipped(
        'departure_acknowledged',
      );
    }

    final settings = await _loadSettings(resolvedUserId);
    final safetyMargin = Duration(
      minutes: _settingsSafetyMarginMinutes(settings?.departureSafetyMarginMin),
    );
    final travelMode = _travelModeFromSettings(settings?.travelMode);
    return _scheduleForEvent(
      event,
      rescheduleMonitor: false,
      safetyMarginOverride: safetyMargin,
      travelModeOverride: travelMode,
      fireDueDeparture: true,
      fallbackAt: fallbackAt,
    );
  }

  Future<bool> _isDepartureAcknowledged(EventModel event) async {
    if (!isRecurringAlarmEvent(event)) {
      return _acknowledgements.isAcknowledged(event.id);
    }
    if (_acknowledgementStore == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
      } catch (error) {
        debugPrint('Departure acknowledgement reload failed: $error');
      }
    }
    return _acknowledgements.isAcknowledged(
      NotificationService.departureAcknowledgementKey(
        event.id,
        CriticalAlarmOccurrence(event.startAt!),
      ),
    );
  }

  Future<void> acknowledgeDeparture(String eventId) async {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) {
      return;
    }
    final confirmedAt = _currentTime;
    final occurrence = _confirmationOccurrence ??
        await _resolveDepartureAcknowledgement(normalizedEventId, confirmedAt);
    final ackKey = occurrence == null
        ? normalizedEventId
        : NotificationService.departureAcknowledgementKey(
            normalizedEventId,
            occurrence,
          );
    await _acknowledgements.markAcknowledged(ackKey);
    if (_confirmationOccurrence == null) {
      await _cancelDepartureArtifacts(normalizedEventId);
    }
    if (occurrence != null) {
      await _cancelDepartureArtifacts(
        normalizedEventId,
        dateSuffix: occurrence.dateSuffix,
      );
    }
    await _pendingDepartures.clear();
    if (_acknowledgementStore == null) {
      await NotificationService.pruneDepartureOccurrenceAcknowledgements(
        acknowledgedKey: ackKey,
        now: confirmedAt,
      );
    }
  }

  Future<CriticalAlarmOccurrence?> _resolveDepartureAcknowledgement(
    String eventId,
    DateTime confirmedAt,
  ) async {
    final userId = _currentSupabaseUserId();
    if (userId == null && _eventRepository == null) return null;
    try {
      final anchor = await _events.fetchEvent(eventId, userId: userId);
      if (anchor == null || !isRecurringAlarmEvent(anchor)) return null;
      final related = await _events.listEvents(userId: anchor.userId);
      final settings = await _loadSettings(anchor.userId);
      final margin = Duration(
        minutes:
            _settingsSafetyMarginMinutes(settings?.departureSafetyMarginMin),
      );
      final travelBuffer = _travelTime
          .estimate(
            latitude: anchor.locationLat,
            longitude: anchor.locationLng,
            locationText: anchor.location,
          )
          .buffer;
      final occurrences = upcomingAlarmOccurrences(
        [anchor, ...related.where((item) => item.parentEventId == eventId)],
        // A notice without occurrence metadata may be confirmed after it starts.
        from: confirmedAt.subtract(margin + travelBuffer),
        until: confirmedAt.add(recurringAlarmWindow),
      );
      for (final event in occurrences) {
        if (event.id == eventId) {
          final startAt = event.startAt!;
          // A legacy tap can arrive long after its occurrence. Do not infer
          // the next occurrence until its own departure window has opened.
          if (startAt.isAfter(confirmedAt)) {
            // The booked instant is authoritative when route estimates have
            // since changed. A failed queue read leaves the future slot alone.
            final slot = await _notifications.pendingDepartureSlot(
              eventAlarmKey(event, 'departure'),
            );
            final notifyAt =
                slot?.notifyAt ?? startAt.subtract(margin + travelBuffer);
            if (confirmedAt.isBefore(notifyAt)) continue;
          }
          return CriticalAlarmOccurrence(startAt);
        }
      }
    } catch (error) {
      debugPrint('Departure acknowledgement occurrence lookup failed: $error');
    }
    return null;
  }

  Future<void> clearAcknowledgement(String eventId) async {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) {
      return;
    }
    final suffixes = _departureCancellationDateSuffixes(_currentTime);
    try {
      await _acknowledgements.clearAcknowledged(normalizedEventId);
      if (_acknowledgementStore == null) {
        const prefix =
            NotificationService.departureAcknowledgementPreferencePrefix;
        final prefs = await SharedPreferences.getInstance();
        for (final key in prefs.getKeys()) {
          if (key.startsWith('$prefix$normalizedEventId:departure:')) {
            await prefs.remove(key);
          }
        }
      } else {
        for (final suffix in suffixes) {
          await _acknowledgements.clearAcknowledged(
            '$normalizedEventId:departure:$suffix',
          );
        }
      }
    } catch (error) {
      debugPrint(
          'Departure acknowledgement cleanup failed: ${error.runtimeType}');
    }
    await _cancelDepartureArtifacts(normalizedEventId);
    for (final suffix in suffixes) {
      await _cancelDepartureArtifacts(normalizedEventId, dateSuffix: suffix);
    }
    try {
      await _pendingDepartures.clear();
    } catch (error) {
      debugPrint('Pending departure cleanup failed: ${error.runtimeType}');
    }
  }

  /// 그룹에 속한 모든 일정에 예약된 출발 알람(preflight + pending + 표시 알림)
  /// 을 일괄 취소한다. 그룹 archive/restore cleanup에서 사용한다.
  /// fire-and-forget: 호출자는 unawaited로 호출해도 안전하다.
  /// 그룹 이벤트의 id(group_events.id)를 출발알람 키로 그대로 사용해
  /// _cancelDepartureArtifacts가 notification + preflight alarm을 정리한다.
  Future<void> cancelAlarmsForGroup(String groupId) async {
    final normalizedGroupId = groupId.trim();
    if (normalizedGroupId.isEmpty) {
      return;
    }
    try {
      final auth = _currentSupabaseUserId();
      if (auth == null || auth.isEmpty) {
        debugPrint(
          'DepartureAlarmService.cancelAlarmsForGroup: signed out, skipping',
        );
        return;
      }
      final client = Supabase.instance.client;
      final response = await client
          .from('group_events')
          .select('id')
          .eq('group_id', normalizedGroupId);
      final rows = response as List<dynamic>;
      for (final row in rows) {
        if (row is! Map) continue;
        final id = (row['id'] as String?)?.trim();
        if (id == null || id.isEmpty) continue;
        try {
          await _cancelDepartureArtifacts(id);
          for (final suffix
              in _departureCancellationDateSuffixes(_currentTime)) {
            await _cancelDepartureArtifacts(id, dateSuffix: suffix);
          }
        } catch (e, st) {
          debugPrint(
            'DepartureAlarmService.cancelAlarmsForGroup: cancelArtifacts($id) failed: $e',
          );
          debugPrintStack(stackTrace: st);
        }
      }
    } catch (e, st) {
      debugPrint(
        'DepartureAlarmService.cancelAlarmsForGroup failed: $e',
      );
      debugPrintStack(stackTrace: st, maxFrames: 8);
    }
  }

  Future<DepartureAlarmMonitorResult> refreshUpcoming({
    String? userId,
  }) async {
    final resolvedUserId = userId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      const result = DepartureAlarmMonitorResult(skippedReason: 'signed_out');
      await _recordMonitorStatus(result);
      return result;
    }
    if (!AppEnv.isSupabaseReady) {
      const result = DepartureAlarmMonitorResult(skippedReason: 'supabase');
      await _recordMonitorStatus(result);
      return result;
    }

    final now = _currentTime;
    final until = now.add(monitorLookAhead);
    final events = await _events.listEvents(userId: resolvedUserId);
    final settings = await _loadSettings(resolvedUserId);
    final safetyMargin = Duration(
      minutes: _settingsSafetyMarginMinutes(settings?.departureSafetyMarginMin),
    );
    final travelMode = _travelModeFromSettings(settings?.travelMode);
    var scheduled = 0;
    var skipped = 0;
    var hasUrgentEvent = false;
    final batch = LocalAlarmResyncBatch(notificationService: _notifications);
    final upcoming = upcomingAlarmOccurrences(
      events,
      from: now,
      until: until,
      includeNonRecurringBoundaries: true,
    );
    for (final event in upcoming) {
      final startAt = event.startAt!;
      if (await _isDepartureAcknowledged(event)) {
        skipped += 1;
        continue;
      }
      if (startAt.isBefore(now.add(monitorUrgentWindow))) {
        hasUrgentEvent = true;
      }
      if (event.locationLat == null || event.locationLng == null) {
        continue;
      }
      batch.add(
        startAt,
        1,
        (_) async {
          final result = await scheduleForEvent(
            event,
            rescheduleMonitor: false,
            safetyMarginOverride: safetyMargin,
            travelModeOverride: travelMode,
            // 모니터는 백그라운드에서 라이브 GPS 대신 캐시만 사용한다.
            cacheOnlyLocation: true,
          );
          if (result.isScheduled) {
            scheduled += 1;
            return 1;
          }
          skipped += 1;
          return 0;
        },
        departureKey: eventAlarmKey(event, 'departure'),
        validatePending: () => validatePendingDeparture(event),
        canReplacePending: () => canReplacePendingDeparture(
          event,
          safetyMarginOverride: safetyMargin,
          travelModeOverride: travelMode,
        ),
        onSkip: () => skipped += 1,
      );
    }
    await batch.book();
    final urgentInterval = await _urgentMonitorInterval();
    final result = DepartureAlarmMonitorResult(
      scheduled: scheduled,
      skipped: skipped,
      nextMonitorInterval: hasUrgentEvent ? urgentInterval : monitorInterval,
    );
    await _recordMonitorStatus(result);
    return result;
  }

  Future<bool> scheduleNextMonitor({
    Duration? interval,
  }) async {
    final nextMonitorInterval = _resolveMonitorInterval(interval);
    final nextMonitorAt = _currentTime.add(nextMonitorInterval);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      await _recordNextMonitorStatus(nextMonitorAt, scheduled: false);
      return false;
    }
    final initialized = await AlarmService.ensureInitialized();
    if (!initialized) {
      await _recordNextMonitorStatus(nextMonitorAt, scheduled: false);
      return false;
    }
    final scheduled = await AndroidAlarmManager.oneShotAt(
      nextMonitorAt,
      _monitorAlarmId.hashCode & 0x7fffffff,
      _departureAlarmMonitorCallback,
      rescheduleOnReboot: true,
      exact: false,
      allowWhileIdle: false,
      wakeup: false,
    );
    await _recordNextMonitorStatus(nextMonitorAt, scheduled: scheduled);
    return scheduled;
  }

  Future<bool> _scheduleDeparturePreflight({
    required EventModel event,
    required DateTime notifyAt,
    required DateTime? fallbackAt,
    required Duration safetyMargin,
    required MapTravelMode travelMode,
  }) async {
    final preflightAt =
        fallbackAt == null ? notifyAt : notifyAt.subtract(_preflightLeadTime);
    if (!preflightAt.isAfter(_currentTime)) {
      return false;
    }

    final injectedScheduler = _preflightScheduler;
    if (injectedScheduler != null) {
      return injectedScheduler(
        event: event,
        preflightAt: preflightAt,
        safetyMargin: safetyMargin,
        travelMode: travelMode,
      );
    }

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    try {
      final initialized = await AlarmService.ensureInitialized();
      if (!initialized) {
        return false;
      }
      return await AndroidAlarmManager.oneShotAt(
        preflightAt,
        _stableAlarmId(eventAlarmKey(event, 'departure_preflight')),
        _departureAlarmPreflightCallback,
        rescheduleOnReboot: true,
        exact: true,
        allowWhileIdle: true,
        wakeup: true,
        params: <String, dynamic>{
          'event_id': event.id,
          'user_id': event.userId,
          if (fallbackAt != null) 'fallback_at': fallbackAt.toIso8601String(),
          if (isRecurringAlarmEvent(event))
            'occurrence_start_at': event.startAt!.toIso8601String(),
        },
      );
    } catch (error, stackTrace) {
      debugPrint('Departure alarm preflight scheduling failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _scheduleVisibleDepartureNotification({
    required EventModel event,
    required DateTime notifyAt,
    required int? travelMinutes,
    required Duration safetyMargin,
    required bool isDueNow,
  }) async {
    final notificationId = _notifications.notificationIdFor(
      eventAlarmKey(event, 'departure'),
    );
    final body = _bodyFor(
      event,
      travelMinutes,
      safetyMargin: safetyMargin,
    );
    final payload = NotificationService.departurePayloadFor(
      event.id,
      occurrence: isRecurringAlarmEvent(event)
          ? CriticalAlarmOccurrence(event.startAt!)
          : null,
      notifyAt: notifyAt,
    );
    final criticalResult =
        await _notifications.scheduleDepartureAlarmWithResult(
      id: notificationId,
      title: '지금 출발해야 해요',
      body: body,
      notifyAt: notifyAt,
      payload: payload,
    );
    var scheduled = criticalResult.isScheduled;
    if (!scheduled) {
      debugPrint(
        'Departure alarm critical channel fallback: '
        '${criticalResult.status.name} ${criticalResult.message ?? ''}',
      );
      final fallback = await _notifications.scheduleDepartureFallbackWithResult(
        id: notificationId,
        title: '지금 출발해야 해요',
        body: body,
        notifyAt: notifyAt,
        payload: payload,
      );
      scheduled = fallback.isScheduled;
    }

    // 알람이 지금(±즉시) 발동하는 경우에만, 앱이 알림 대신 백그라운드/포그라운드
    // 상태에서 곧바로 출발 알람 화면을 띄울 수 있도록 보류 상태를 기록한다.
    // A future alarm does not open the departure screen yet.
    if (isDueNow && scheduled) {
      await _pendingDepartures.write(PendingDeparture(
        eventId: event.id,
        title: event.title,
        fireAt: _currentTime,
      ));
    }
    return scheduled;
  }

  Iterable<String> _departureCancellationDateSuffixes(DateTime now) =>
      eventAlarmCancellationKeys('departure', now)
          .skip(1)
          .map((key) => key.substring('departure:'.length));

  Future<void> _cancelDepartureArtifacts(
    String eventId, {
    String? dateSuffix,
  }) async {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) {
      return;
    }
    final suffix = dateSuffix == null ? '' : ':$dateSuffix';
    await _notifications.cancel(
      _notifications.notificationIdFor('$normalizedEventId:departure$suffix'),
    );
    await _cancelDeparturePreflight(
      '$normalizedEventId:departure_preflight$suffix',
    );
  }

  Future<bool> _cancelDeparturePreflight(String key) =>
      _cancelDeparturePreflightById(_stableAlarmId(key));

  Future<bool> _cancelDeparturePreflightById(int alarmId) async {
    final injectedCanceller = _preflightCanceller;
    if (injectedCanceller != null) {
      try {
        return await injectedCanceller(alarmId);
      } catch (error, stackTrace) {
        debugPrint('Departure preflight cancel failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return false;
      }
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      final initialized = await AlarmService.ensureInitialized();
      if (!initialized) {
        return false;
      }
      return await AndroidAlarmManager.cancel(alarmId);
    } catch (error, stackTrace) {
      debugPrint('Departure preflight cancel failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Duration _monitorIntervalForEvent(EventModel event) {
    final startAt = event.startAt;
    if (startAt == null) {
      return monitorInterval;
    }
    final now = _currentTime;
    if (startAt.isAfter(now) &&
        startAt.isBefore(now.add(monitorUrgentWindow))) {
      return monitorUrgentInterval;
    }
    return monitorInterval;
  }

  Future<DepartureAlarmRuntimeStatus> loadRuntimeStatus() async {
    final preferences = await SharedPreferences.getInstance();
    return DepartureAlarmRuntimeStatus(
      lastEventId: preferences.getString(_lastEventIdKey),
      lastEventTitle: preferences.getString(_lastEventTitleKey),
      lastStatus: preferences.getString(_lastStatusKey),
      lastSkippedReason: preferences.getString(_lastSkippedReasonKey),
      lastCheckedAt: _parseDateTime(preferences.getString(_lastCheckedAtKey)),
      lastNotifyAt: _parseDateTime(preferences.getString(_lastNotifyAtKey)),
      lastTravelMinutes: preferences.getInt(_lastTravelMinutesKey),
      lastMonitorAt: _parseDateTime(preferences.getString(_lastMonitorAtKey)),
      nextMonitorAt: _parseDateTime(preferences.getString(_nextMonitorAtKey)),
      lastMonitorScheduled: preferences.getInt(_lastMonitorScheduledKey),
      lastMonitorSkipped: preferences.getInt(_lastMonitorSkippedKey),
      lastMonitorSkippedReason:
          preferences.getString(_lastMonitorSkippedReasonKey),
      monitorScheduled: preferences.getBool(_monitorScheduledKey),
    );
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

  String _bodyFor(
    EventModel event,
    int? travelMinutes, {
    required Duration safetyMargin,
  }) {
    final location = event.location?.trim();
    final destination =
        location == null || location.isEmpty ? event.title : location;
    // 알림 축소 상태에서도 '출발' 버튼이 함께 보이도록 본문을 짧게 유지하고,
    // 버튼이 가려지는 기기를 위해 펼침 안내를 덧붙인다. (safetyMargin은 호환을 위해 유지)
    const guide = "아래 '출발' 버튼을 눌러주세요 (안 보이면 알림을 ▼ 펼치세요)";
    if (travelMinutes == null) {
      return '$destination · $guide';
    }
    return '$destination까지 약 $travelMinutes분 · $guide';
  }

  MapTravelMode _travelModeFromSettings(String? travelMode) {
    return travelMode == 'transit' ? MapTravelMode.transit : MapTravelMode.car;
  }

  Future<UserSettingsModel?> _loadSettings(String userId) async {
    try {
      return await _settings.fetchSettings(userId);
    } catch (error, stackTrace) {
      debugPrint('Departure alarm settings fallback: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  int _settingsSafetyMarginMinutes(int? value) {
    if (value == 10 || value == 20 || value == 30) {
      return value!;
    }
    return defaultSafetyMarginMin;
  }

  Duration _resolveMonitorInterval(Duration? interval) {
    if (interval == null || interval <= Duration.zero) {
      return monitorInterval;
    }
    return interval;
  }

  Future<Duration> _urgentMonitorInterval() async {
    final minutes = await loadRepeatIntervalMinutes();
    if (minutes <= 0) {
      return monitorInterval;
    }
    return Duration(minutes: minutes);
  }

  Future<bool> _canFireDueDeparture(String eventId) async {
    final minutes = await loadRepeatIntervalMinutes();
    if (minutes <= 0) {
      final previous = await _lastDueDepartureFiredAt(eventId);
      return previous == null;
    }
    final previous = await _lastDueDepartureFiredAt(eventId);
    if (previous == null) {
      return true;
    }
    return _currentTime.difference(previous) >= Duration(minutes: minutes);
  }

  Future<DateTime?> _lastDueDepartureFiredAt(String eventId) async {
    final preferences = await SharedPreferences.getInstance();
    return _parseDateTime(
      preferences.getString('$_lastVisibleNotifyPrefix$eventId'),
    );
  }

  Future<void> _recordDueDepartureFired(String eventId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      '$_lastVisibleNotifyPrefix$eventId',
      _currentTime.toIso8601String(),
    );
  }

  /// 출발지 위치를 확인한다.
  ///
  /// [cacheOnly] 가 true이면 라이브 GPS/네이티브 위치 조회를 건너뛰고
  /// SharedPreferences에 저장된 캐시만 반환한다. 백그라운드 isolate(모니터·
  /// preflight 콜백) 에서 호출할 때는 반드시 true로 설정해야 한다.
  /// 라이브 위치 요청은 백그라운드에서 LocationManager 폭주와 CPU 과다 사용을
  /// 일으키며 삼성 계열 기기에서 앱 강제 종료의 직접 원인이 된다.
  Future<GeoPoint?> _resolveOriginLocation({bool cacheOnly = false}) async {
    final provider = _currentLocationProvider;
    if (provider != null) {
      final origin = await provider();
      if (origin != null) {
        await _cacheLastOrigin(origin);
        return origin;
      }
    }
    // cacheOnly 모드: 라이브 위치 조회 없이 캐시만 사용
    if (cacheOnly) {
      return _loadCachedOrigin();
    }
    try {
      final permissionGranted = await _permissions.checkLocationPermission();
      if (permissionGranted) {
        final lastKnownOrigin = await _permissions.getLastKnownLocation();
        if (lastKnownOrigin != null) {
          await _cacheLastOrigin(lastKnownOrigin);
          return lastKnownOrigin;
        }
        final fallbackOrigin = await _permissions
            .getCurrentLocation()
            .timeout(const Duration(seconds: 5));
        if (fallbackOrigin != null) {
          await _cacheLastOrigin(fallbackOrigin);
          return fallbackOrigin;
        }
      }
    } catch (error) {
      debugPrint('Departure origin live lookup failed: $error');
    }
    return _loadCachedOrigin();
  }

  Future<void> _cacheLastOrigin(GeoPoint origin) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(cachedOriginLatKey, origin.latitude);
    await preferences.setDouble(cachedOriginLngKey, origin.longitude);
    await preferences.setString(
      cachedOriginAtKey,
      _currentTime.toIso8601String(),
    );
  }

  Future<GeoPoint?> _loadCachedOrigin() async {
    final preferences = await SharedPreferences.getInstance();
    final lat = preferences.getDouble(cachedOriginLatKey);
    final lng = preferences.getDouble(cachedOriginLngKey);
    if (lat == null || lng == null) {
      return null;
    }
    // 캐시가 있으면 만료 여부와 무관하게 반환한다.
    // 오래된 캐시라도 위치 확인 불가보다는 낫다.
    // (백그라운드가 아닌 경우 라이브 조회로 캐시를 업데이트한다)
    return GeoPoint(latitude: lat, longitude: lng);
  }

  String? _currentSupabaseUserId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id.trim();
    } catch (_) {
      return null;
    }
  }

  Future<DepartureAlarmScheduleResult> _recordAndReturnScheduleResult(
    EventModel event,
    DepartureAlarmScheduleResult result,
  ) async {
    await _recordScheduleStatus(event: event, result: result);
    return result;
  }

  Future<void> _recordScheduleStatus({
    required EventModel event,
    required DepartureAlarmScheduleResult result,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_lastEventIdKey, event.id);
    await preferences.setString(_lastEventTitleKey, event.title);
    await preferences.setString(
      _lastStatusKey,
      result.isScheduled ? 'scheduled' : 'skipped',
    );
    await preferences.setString(
      _lastCheckedAtKey,
      _currentTime.toIso8601String(),
    );

    final skippedReason = result.skippedReason;
    if (skippedReason == null || skippedReason.isEmpty) {
      await preferences.remove(_lastSkippedReasonKey);
    } else {
      await preferences.setString(_lastSkippedReasonKey, skippedReason);
    }

    final notifyAt = result.notifyAt;
    if (notifyAt == null) {
      await preferences.remove(_lastNotifyAtKey);
    } else {
      await preferences.setString(_lastNotifyAtKey, notifyAt.toIso8601String());
    }

    final travelMinutes = result.travelMinutes;
    if (travelMinutes == null) {
      await preferences.remove(_lastTravelMinutesKey);
    } else {
      await preferences.setInt(_lastTravelMinutesKey, travelMinutes);
    }
  }

  Future<void> _recordMonitorStatus(
    DepartureAlarmMonitorResult result,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _lastMonitorAtKey,
      _currentTime.toIso8601String(),
    );
    await preferences.setInt(_lastMonitorScheduledKey, result.scheduled);
    await preferences.setInt(_lastMonitorSkippedKey, result.skipped);
    final skippedReason = result.skippedReason;
    if (skippedReason == null || skippedReason.isEmpty) {
      await preferences.remove(_lastMonitorSkippedReasonKey);
    } else {
      await preferences.setString(
        _lastMonitorSkippedReasonKey,
        skippedReason,
      );
    }
  }

  Future<void> _recordNextMonitorStatus(
    DateTime nextMonitorAt, {
    required bool scheduled,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _nextMonitorAtKey,
      nextMonitorAt.toIso8601String(),
    );
    await preferences.setBool(_monitorScheduledKey, scheduled);
  }

  DateTime? _parseDateTime(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  int _stableAlarmId(String id) {
    var hash = 0x811c9dc5;
    for (final codeUnit in id.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}

class DepartureAlarmScheduleResult {
  const DepartureAlarmScheduleResult.scheduled({
    required this.notifyAt,
    required this.travelMinutes,
    int? rearmedPreflightId,
  })  : skippedReason = null,
        _rearmedPreflightId = rearmedPreflightId;

  const DepartureAlarmScheduleResult.skipped(
    this.skippedReason, {
    this.travelMinutes,
  })  : notifyAt = null,
        _rearmedPreflightId = null;

  final int? _rearmedPreflightId;
  final DateTime? notifyAt;
  final int? travelMinutes;
  final String? skippedReason;

  bool get isScheduled => notifyAt != null && skippedReason == null;
}

class DepartureAlarmMonitorResult {
  const DepartureAlarmMonitorResult({
    this.scheduled = 0,
    this.skipped = 0,
    this.skippedReason,
    this.nextMonitorInterval,
  });

  final int scheduled;
  final int skipped;
  final String? skippedReason;
  final Duration? nextMonitorInterval;
}

class DepartureAlarmRuntimeStatus {
  const DepartureAlarmRuntimeStatus({
    this.lastEventId,
    this.lastEventTitle,
    this.lastStatus,
    this.lastSkippedReason,
    this.lastCheckedAt,
    this.lastNotifyAt,
    this.lastTravelMinutes,
    this.lastMonitorAt,
    this.nextMonitorAt,
    this.lastMonitorScheduled,
    this.lastMonitorSkipped,
    this.lastMonitorSkippedReason,
    this.monitorScheduled,
  });

  final String? lastEventId;
  final String? lastEventTitle;
  final String? lastStatus;
  final String? lastSkippedReason;
  final DateTime? lastCheckedAt;
  final DateTime? lastNotifyAt;
  final int? lastTravelMinutes;
  final DateTime? lastMonitorAt;
  final DateTime? nextMonitorAt;
  final int? lastMonitorScheduled;
  final int? lastMonitorSkipped;
  final String? lastMonitorSkippedReason;
  final bool? monitorScheduled;
}

class _FallbackSettingsRepository extends SettingsRepository {
  const _FallbackSettingsRepository();

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    return UserSettingsModel.defaults(userId: userId);
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    return settings;
  }
}

@pragma('vm:entry-point')
Future<void> _departureAlarmMonitorCallback() async {
  // 백그라운드 isolate: 진단 로그로 실행 시각과 cacheOnly 전략 추적
  DiagLogger.log(
    'DepartureMonitor',
    'monitorCallback 시작 at=${DateTime.now().toIso8601String()} '
        'cacheOnlyLocation=true (라이브 GPS 조회 금지)',
  );
  Duration? scheduledInterval;
  try {
    if (!AppEnv.isSupabaseReady && AppEnv.hasValidSupabaseConfig) {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
        authOptions: buildPlanFlowAuthOptions(
          supabaseUrl: AppEnv.supabaseUrl,
          detectSessionInUri: false,
          autoRefreshToken: false,
          isolateMode: true,
        ),
      );
      AppEnv.markSupabaseInitialized();
    }
    final refreshResult = await const DepartureAlarmService().refreshUpcoming();
    scheduledInterval = refreshResult.nextMonitorInterval;
    DiagLogger.log(
      'DepartureMonitor',
      'monitorCallback 완료 scheduled=${refreshResult.scheduled} '
          'skipped=${refreshResult.skipped} '
          'nextInterval=${scheduledInterval?.inMinutes ?? 30}min',
    );
  } catch (error, stackTrace) {
    debugPrint('Departure alarm monitor skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
    DiagLogger.log('DepartureMonitor', 'monitorCallback 예외 error=$error');
  } finally {
    await const DepartureAlarmService()
        .scheduleNextMonitor(interval: scheduledInterval);
  }
}

@pragma('vm:entry-point')
Future<void> _departureAlarmPreflightCallback(
  int id,
  Map<String, dynamic> params,
) async {
  const service = DepartureAlarmService();
  var delegatedCleanup = false;
  try {
    if (!AppEnv.isSupabaseReady && AppEnv.hasValidSupabaseConfig) {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
        authOptions: buildPlanFlowAuthOptions(
          supabaseUrl: AppEnv.supabaseUrl,
          detectSessionInUri: false,
          autoRefreshToken: false,
          isolateMode: true,
        ),
      );
      AppEnv.markSupabaseInitialized();
    }

    final eventId = params['event_id'] as String?;
    final userId = params['user_id'] as String?;
    if (eventId == null || eventId.trim().isEmpty) {
      await const DepartureAlarmService().refreshUpcoming(userId: userId);
      return;
    }
    final occurrenceStartAt =
        DateTime.tryParse(params['occurrence_start_at'] as String? ?? '');
    final fallbackAt =
        DateTime.tryParse(params['fallback_at'] as String? ?? '');
    delegatedCleanup = true;
    final result = await service.runPreflightForEvent(
      eventId,
      userId: userId,
      occurrenceStartAt: occurrenceStartAt,
      fallbackAt: fallbackAt,
      alarmId: id,
    );
    await _recordPreflightRun(eventId: eventId, result: result);
  } catch (error, stackTrace) {
    debugPrint('Departure alarm preflight skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    if (!delegatedCleanup) {
      await service._cancelDeparturePreflightById(id);
    }
    await service.scheduleNextMonitor(
      interval: await service._urgentMonitorInterval(),
    );
  }
}

/// 출발 알람 preflight(출발 직전 위치 재조회·이동시간 재계산)의 실행 결과를
/// 영속 저장한다. 백그라운드 isolate라 메모리 DiagLogger에 안 남으므로,
/// SharedPreferences에 기록해 메인 isolate(진단 로그 화면)에서 읽게 한다.
const String departurePreflightLastRunKey = 'departure_preflight_last_run';

Future<void> _recordPreflightRun({
  required String eventId,
  required DepartureAlarmScheduleResult result,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final summary = result.isScheduled
        ? 'OK travelMin=${result.travelMinutes ?? '-'} '
            'notifyAt=${result.notifyAt?.toIso8601String() ?? '-'}'
        : 'SKIP reason=${result.skippedReason ?? 'unknown'}';
    await prefs.setString(
      departurePreflightLastRunKey,
      '${DateTime.now().toIso8601String()} | event=$eventId | $summary',
    );
  } catch (error) {
    debugPrint('preflight record failed: $error');
  }
}
