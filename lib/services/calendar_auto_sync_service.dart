import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/models/event_model.dart';
import '../providers/auth_provider.dart';
import 'calendar_sync_service.dart';
import 'device_calendar_service.dart';
import 'event_refresh_bus.dart';
import 'naver_caldav_service.dart';

class CalendarAutoSyncService {
  CalendarAutoSyncService({
    CalendarSyncService? calendarSyncService,
    NaverCalDavService? naverCalDavService,
    DeviceCalendarService? deviceCalendarService,
    Duration throttle = const Duration(minutes: 15),
    DateTime Function()? now,
  })  : _calendarSyncService = calendarSyncService,
        _naverCalDavService = naverCalDavService,
        _deviceCalendarService = deviceCalendarService,
        _throttle = throttle,
        _now = now ?? DateTime.now;

  final CalendarSyncService? _calendarSyncService;
  final NaverCalDavService? _naverCalDavService;
  final DeviceCalendarService? _deviceCalendarService;
  final Duration _throttle;
  final DateTime Function() _now;

  DateTime? _lastAttemptAt;
  bool _isSyncing = false;

  CalendarSyncService get _calendarSync =>
      _calendarSyncService ??
      CalendarSyncService(
        googleClientId: kIsWeb ? AppEnv.googleWebClientId : null,
        googleServerClientId: kIsWeb ? null : AppEnv.googleServerClientId,
      );

  NaverCalDavService get _naverCalDav =>
      _naverCalDavService ?? NaverCalDavService();

  DeviceCalendarService get _deviceCalendar =>
      _deviceCalendarService ?? DeviceCalendarService();

  Future<CalendarAutoSyncResult> syncAfterEventSave(EventModel event) async {
    if (!_canSync) {
      return CalendarAutoSyncResult.skipped('not_signed_in');
    }

    final result = CalendarAutoSyncResult();
    await _runStep(result, 'google_export', () async {
      final google = await _calendarSync.syncGoogleCalendar(interactive: false);
      return google.status == CalendarIntegrationStatus.synced ||
          google.status == CalendarIntegrationStatus.ready ||
          google.status == CalendarIntegrationStatus.signedOut;
    });
    await _runStep(result, 'naver_api_export', () async {
      final naver = await _calendarSync.syncNaverCalendar();
      return naver.status == CalendarIntegrationStatus.synced ||
          naver.status == CalendarIntegrationStatus.ready ||
          naver.status == CalendarIntegrationStatus.signedOut;
    });
    await _runStep(result, 'naver_caldav_export', () {
      return _naverCalDav.exportEvent(event);
    });
    await _runStep(result, 'device_calendar_export', () {
      return _deviceCalendar.exportEvent(event);
    });

    EventRefreshBus.instance.notifyChanged(
      reason: 'calendar_fan_out_after_save',
      eventId: event.id,
      startAt: event.startAt,
    );
    return result;
  }

  Future<CalendarAutoSyncResult> syncConnectedCalendars({
    String reason = 'app_lifecycle',
    bool force = false,
  }) async {
    if (!_canSync || _isSyncing) {
      return CalendarAutoSyncResult.skipped('not_ready');
    }

    final now = _now();
    final lastAttemptAt = _lastAttemptAt;
    if (!force &&
        lastAttemptAt != null &&
        now.difference(lastAttemptAt) < _throttle) {
      return CalendarAutoSyncResult.skipped('throttled');
    }

    _lastAttemptAt = now;
    _isSyncing = true;
    final result = CalendarAutoSyncResult();
    try {
      await _runStep(result, 'google_auto_sync', () async {
        final google = await _calendarSync.syncGoogleCalendar(
          interactive: false,
        );
        return google.status == CalendarIntegrationStatus.synced ||
            google.status == CalendarIntegrationStatus.ready ||
            google.status == CalendarIntegrationStatus.signedOut;
      });
      await _runStep(result, 'naver_api_auto_export', () async {
        final naver = await _calendarSync.syncNaverCalendar();
        return naver.status == CalendarIntegrationStatus.synced ||
            naver.status == CalendarIntegrationStatus.ready ||
            naver.status == CalendarIntegrationStatus.signedOut;
      });
      await _runStep(result, 'naver_caldav_auto_import', () async {
        if (!await _naverCalDav.hasCredentials()) {
          return true;
        }
        final naver = await _naverCalDav.syncAll(
          mode: NaverCalDavSyncMode.quick,
          skipUnchanged: true,
        );
        return naver.success;
      });
      await _runStep(result, 'device_calendar_auto_import', () async {
        final hasPermission = await _deviceCalendar.checkCalendarPermission();
        if (!hasPermission) {
          return true;
        }
        final imported = await _deviceCalendar.importNaverEvents();
        return imported.status != DeviceCalendarImportStatus.failed;
      });
      EventRefreshBus.instance.notifyChanged(
        reason: 'calendar_auto_sync:$reason',
      );
      return result;
    } finally {
      _isSyncing = false;
    }
  }

  bool get _canSync {
    final supabaseUserId = _currentSupabaseUserId();
    return AppEnv.isSupabaseReady &&
        (authProvider.isSignedIn ||
            (supabaseUserId != null && supabaseUserId.isNotEmpty));
  }

  String? _currentSupabaseUserId() {
    try {
      final auth = Supabase.instance.client.auth;
      return auth.currentSession?.user.id ?? auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<void> _runStep(
    CalendarAutoSyncResult result,
    String name,
    Future<bool> Function() step,
  ) async {
    try {
      final success = await step();
      if (success) {
        result.completed.add(name);
      } else {
        result.failed.add(name);
      }
    } catch (error, stackTrace) {
      result.failed.add(name);
      debugPrint('Calendar auto sync step failed: $name $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
}

class CalendarAutoSyncResult {
  CalendarAutoSyncResult() : skippedReason = null;

  CalendarAutoSyncResult.skipped(this.skippedReason);

  final String? skippedReason;
  final List<String> completed = <String>[];
  final List<String> failed = <String>[];

  bool get didRun => skippedReason == null;
  bool get hasFailures => failed.isNotEmpty;
}

class DailyCalendarSyncSchedulerService {
  const DailyCalendarSyncSchedulerService();

  static const String _alarmId = 'calendar_sync:daily:0330';

  Future<bool> scheduleDaily() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final initialized = await AndroidAlarmManager.initialize();
    if (!initialized) {
      return false;
    }
    return AndroidAlarmManager.oneShotAt(
      _next330Am(),
      _alarmId.hashCode & 0x7fffffff,
      _dailyCalendarSyncCallback,
      exact: false,
      allowWhileIdle: false,
      wakeup: false,
    );
  }

  DateTime _next330Am() {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, 3, 30);
    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
  }
}

@pragma('vm:entry-point')
Future<void> _dailyCalendarSyncCallback() async {
  try {
    await dotenv.load(fileName: '.env');
    if (!AppEnv.isSupabaseReady && AppEnv.hasValidSupabaseConfig) {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
      );
      AppEnv.markSupabaseInitialized();
    }
    await CalendarAutoSyncService().syncConnectedCalendars(
      reason: 'daily_alarm',
      force: true,
    );
  } catch (error, stackTrace) {
    debugPrint('Daily calendar sync callback skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    await const DailyCalendarSyncSchedulerService().scheduleDaily();
  }
}
