import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
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
      return const DepartureAlarmScheduleResult.skipped('past_or_no_time');
    }
    if (destinationLat == null || destinationLng == null) {
      return const DepartureAlarmScheduleResult.skipped('missing_destination');
    }

    final origin = await (_currentLocationProvider?.call() ??
        _permissions.getCurrentLocation());
    if (origin == null) {
      return const DepartureAlarmScheduleResult.skipped('missing_origin');
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
      return DepartureAlarmScheduleResult.skipped(
        'departure_time_passed',
        travelMinutes: estimate.minutes,
      );
    }

    await _notifications.scheduleEventReminder(
      id: _notifications.notificationIdFor('${event.id}:departure'),
      title: '지금 출발 준비',
      body: _bodyFor(event, estimate.minutes),
      notifyAt: notifyAt,
      payload: 'departure:${event.id}',
    );

    if (rescheduleMonitor) {
      unawaited(scheduleNextMonitor());
    }

    return DepartureAlarmScheduleResult.scheduled(
      notifyAt: notifyAt,
      travelMinutes: estimate.minutes,
    );
  }

  Future<DepartureAlarmMonitorResult> refreshUpcoming({
    String? userId,
  }) async {
    final resolvedUserId = userId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return const DepartureAlarmMonitorResult(skippedReason: 'signed_out');
    }
    if (!AppEnv.isSupabaseReady) {
      return const DepartureAlarmMonitorResult(skippedReason: 'supabase');
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
    return DepartureAlarmMonitorResult(
      scheduled: scheduled,
      skipped: skipped,
    );
  }

  Future<bool> scheduleNextMonitor() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final initialized = await AndroidAlarmManager.initialize();
    if (!initialized) {
      return false;
    }
    return AndroidAlarmManager.oneShotAt(
      _currentTime.add(monitorInterval),
      _monitorAlarmId.hashCode & 0x7fffffff,
      _departureAlarmMonitorCallback,
      exact: false,
      allowWhileIdle: false,
      wakeup: false,
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

@pragma('vm:entry-point')
Future<void> _departureAlarmMonitorCallback() async {
  try {
    await dotenv.load(fileName: '.env');
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
