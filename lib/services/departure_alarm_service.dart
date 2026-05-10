import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'app_permission_service.dart';
import 'map_service.dart';
import 'notification_service.dart';
import 'travel_time_buffer_service.dart';

class DepartureAlarmService {
  const DepartureAlarmService({
    AppPermissionService? permissionService,
    Future<GeoPoint?> Function()? currentLocationProvider,
    TravelTimeBufferService? travelTimeBufferService,
    NotificationService? notificationService,
    EventRepository? eventRepository,
    DateTime Function()? now,
  })  : _permissionService = permissionService,
        _currentLocationProvider = currentLocationProvider,
        _travelTimeBufferService = travelTimeBufferService,
        _notificationService = notificationService,
        _eventRepository = eventRepository,
        _now = now;

  static const String label = '출발 알림';
  static const Duration safetyMargin = Duration(minutes: 30);
  static const Duration monitorInterval = Duration(minutes: 30);
  static const Duration monitorLookAhead = Duration(hours: 24);
  static const String _monitorAlarmId = 'departure_alarm:monitor';
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

  final AppPermissionService? _permissionService;
  final Future<GeoPoint?> Function()? _currentLocationProvider;
  final TravelTimeBufferService? _travelTimeBufferService;
  final NotificationService? _notificationService;
  final EventRepository? _eventRepository;
  final DateTime Function()? _now;

  AppPermissionService get _permissions =>
      _permissionService ?? AppPermissionService();

  TravelTimeBufferService get _travelTime =>
      _travelTimeBufferService ?? TravelTimeBufferService();

  NotificationService get _notifications =>
      _notificationService ?? NotificationService();

  EventRepository get _events => _eventRepository ?? EventRepository.supabase();

  DateTime get _currentTime => (_now ?? DateTime.now)();

  Future<DepartureAlarmScheduleResult> scheduleForEvent(
    EventModel event, {
    bool rescheduleMonitor = true,
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

    final origin = await (_currentLocationProvider?.call() ??
        _permissions.getCurrentLocation());
    if (origin == null) {
      return _recordAndReturnScheduleResult(
        event,
        const DepartureAlarmScheduleResult.skipped('missing_origin'),
      );
    }

    final estimate = await _travelTime.estimateWithMapApis(
      originLat: origin.latitude,
      originLng: origin.longitude,
      destinationLat: destinationLat,
      destinationLng: destinationLng,
      mode: _travelModeFromEvent(event),
      locationText: event.location,
    );
    final departAt = startAt.subtract(estimate.buffer + safetyMargin);
    final notifyAt = _notifyAtFor(departAt);
    if (notifyAt == null) {
      return _recordAndReturnScheduleResult(
        event,
        DepartureAlarmScheduleResult.skipped(
          'departure_time_passed',
          travelMinutes: estimate.minutes,
        ),
      );
    }

    final notificationId = _notifications.notificationIdFor(
      '${event.id}:departure',
    );
    final body = _bodyFor(event, estimate.minutes);
    final criticalResult = await _notifications.scheduleCriticalAlarmWithResult(
      id: notificationId,
      title: '지금 출발해야 해요',
      body: body,
      notifyAt: notifyAt,
    );
    if (!criticalResult.isScheduled) {
      debugPrint(
        'Departure alarm critical channel fallback: '
        '${criticalResult.status.name} ${criticalResult.message ?? ''}',
      );
      await _notifications.scheduleEventReminder(
        id: notificationId,
        title: '지금 출발해야 해요',
        body: body,
        notifyAt: notifyAt,
        payload: 'departure:${event.id}',
      );
    }

    if (rescheduleMonitor) {
      unawaited(scheduleNextMonitor());
    }

    return _recordAndReturnScheduleResult(
      event,
      DepartureAlarmScheduleResult.scheduled(
        notifyAt: notifyAt,
        travelMinutes: estimate.minutes,
      ),
    );
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
    var scheduled = 0;
    var skipped = 0;
    for (final event in events) {
      final startAt = event.startAt;
      if (startAt == null ||
          startAt.isBefore(now) ||
          startAt.isAfter(until) ||
          event.locationLat == null ||
          event.locationLng == null) {
        continue;
      }
      final result = await scheduleForEvent(event, rescheduleMonitor: false);
      if (result.isScheduled) {
        scheduled += 1;
      } else {
        skipped += 1;
      }
    }
    final result = DepartureAlarmMonitorResult(
      scheduled: scheduled,
      skipped: skipped,
    );
    await _recordMonitorStatus(result);
    return result;
  }

  Future<bool> scheduleNextMonitor() async {
    final nextMonitorAt = _currentTime.add(monitorInterval);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      await _recordNextMonitorStatus(nextMonitorAt, scheduled: false);
      return false;
    }
    final initialized = await AndroidAlarmManager.initialize();
    if (!initialized) {
      await _recordNextMonitorStatus(nextMonitorAt, scheduled: false);
      return false;
    }
    final scheduled = await AndroidAlarmManager.oneShotAt(
      nextMonitorAt,
      _monitorAlarmId.hashCode & 0x7fffffff,
      _departureAlarmMonitorCallback,
      exact: false,
      allowWhileIdle: false,
      wakeup: false,
    );
    await _recordNextMonitorStatus(nextMonitorAt, scheduled: scheduled);
    return scheduled;
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

  DateTime? _notifyAtFor(DateTime departAt) {
    final now = _currentTime;
    if (departAt.isAfter(now)) {
      return departAt;
    }
    final grace = now.add(const Duration(minutes: 1));
    return grace;
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

  String _bodyFor(EventModel event, int travelMinutes) {
    final location = event.location?.trim();
    final destination =
        location == null || location.isEmpty ? event.title : location;
    return '$destination까지 이동시간이 약 $travelMinutes분이에요. 여유 $safetyMarginMinutes분을 보고 지금 출발 준비를 해 주세요.';
  }

  int get safetyMarginMinutes => safetyMargin.inMinutes;

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
}

class DepartureAlarmScheduleResult {
  const DepartureAlarmScheduleResult.scheduled({
    required this.notifyAt,
    required this.travelMinutes,
  }) : skippedReason = null;

  const DepartureAlarmScheduleResult.skipped(
    this.skippedReason, {
    this.travelMinutes,
  }) : notifyAt = null;

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
  });

  final int scheduled;
  final int skipped;
  final String? skippedReason;
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

@pragma('vm:entry-point')
Future<void> _departureAlarmMonitorCallback() async {
  try {
    if (!AppEnv.isSupabaseReady && AppEnv.hasValidSupabaseConfig) {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
      );
      AppEnv.markSupabaseInitialized();
    }
    await const DepartureAlarmService().refreshUpcoming();
  } catch (error, stackTrace) {
    debugPrint('Departure alarm monitor skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    await const DepartureAlarmService().scheduleNextMonitor();
  }
}
