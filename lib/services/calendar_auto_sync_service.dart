import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      await _recordProviderStatus(
        'all',
        success: false,
        message: '로그인 또는 Supabase 설정이 필요합니다.',
      );
      return CalendarAutoSyncResult.skipped('not_signed_in');
    }

    final result = CalendarAutoSyncResult();
    await _runStep(result, 'google_export', () async {
      final google = await _calendarSync.exportEventToGoogle(
        event,
        interactive: false,
      );
      return google.status == CalendarIntegrationStatus.synced ||
          google.status == CalendarIntegrationStatus.ready ||
          google.status == CalendarIntegrationStatus.signedOut;
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
    await _recordSummary(result, reason: 'event_save');
    return result;
  }

  Future<CalendarAutoSyncResult> syncConnectedCalendars({
    String reason = 'app_lifecycle',
    bool force = false,
  }) async {
    if (!_canSync || _isSyncing) {
      await _recordProviderStatus(
        'all',
        success: false,
        message: '로그인 또는 Supabase 설정이 필요합니다.',
      );
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
      await _recordSummary(result, reason: reason);
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
        await _recordProviderStatus(
          name,
          success: true,
          message: '정상 동기화됨',
        );
      } else {
        result.failed.add(name);
        await _recordProviderStatus(
          name,
          success: false,
          message: _failureMessageFor(name),
        );
      }
    } catch (error, stackTrace) {
      result.failed.add(name);
      await _recordProviderStatus(
        name,
        success: false,
        message: '$name 동기화 중 오류가 발생했습니다.',
      );
      debugPrint('Calendar auto sync step failed: $name $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _recordSummary(
    CalendarAutoSyncResult result, {
    required String reason,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'calendar_sync:last_reason',
      reason,
    );
    await prefs.setString(
      'calendar_sync:last_attempt_at',
      _now().toIso8601String(),
    );
    await prefs.setStringList(
      'calendar_sync:last_completed',
      result.completed,
    );
    await prefs.setStringList(
      'calendar_sync:last_failed',
      result.failed,
    );
  }

  Future<void> _recordProviderStatus(
    String provider, {
    required bool success,
    required String message,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'calendar_sync:provider:$provider';
    await prefs.setString('$key:status', success ? 'connected' : 'attention');
    await prefs.setString('$key:message', message);
    await prefs.setString('$key:checked_at', _now().toIso8601String());
    if (success) {
      await prefs.setString('$key:last_success_at', _now().toIso8601String());
    }
  }

  String _failureMessageFor(String name) {
    if (name.contains('google')) {
      return 'Google 로그인이 끊겼거나 Calendar 권한 동의가 필요합니다.';
    }
    if (name.contains('naver_caldav')) {
      return 'Naver CalDAV 아이디 또는 앱 비밀번호를 확인해 주세요.';
    }
    if (name.contains('device_calendar')) {
      return '휴대폰 캘린더 권한이 필요하거나 기기 캘린더에 노출된 일정이 없습니다.';
    }
    if (name.contains('naver_api')) {
      return 'Naver 캘린더 직접 연동 상태를 확인해 주세요.';
    }
    return '$name 동기화가 완료되지 않았습니다.';
  }

  Future<CalendarAutoSyncSnapshot> loadSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    return CalendarAutoSyncSnapshot(
      lastReason: prefs.getString('calendar_sync:last_reason'),
      lastAttemptAt: _parseDateTime(
        prefs.getString('calendar_sync:last_attempt_at'),
      ),
      completed: prefs.getStringList('calendar_sync:last_completed') ??
          const <String>[],
      failed:
          prefs.getStringList('calendar_sync:last_failed') ?? const <String>[],
      providers: _knownProviderLabels.entries.map((entry) {
        final key = 'calendar_sync:provider:${entry.key}';
        return CalendarAutoSyncProviderSnapshot(
          key: entry.key,
          label: entry.value,
          status: prefs.getString('$key:status') ?? 'unknown',
          message: prefs.getString('$key:message') ?? '아직 자동 동기화 기록이 없습니다.',
          checkedAt: _parseDateTime(prefs.getString('$key:checked_at')),
          lastSuccessAt:
              _parseDateTime(prefs.getString('$key:last_success_at')),
        );
      }).toList(growable: false),
    );
  }

  DateTime? _parseDateTime(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  static const Map<String, String> _knownProviderLabels = <String, String>{
    'google_auto_sync': 'Google Calendar',
    'naver_api_auto_export': 'Naver 직접 연동',
    'naver_caldav_auto_import': 'Naver CalDAV',
    'device_calendar_auto_import': '휴대폰 내부 캘린더',
  };
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

class CalendarAutoSyncSnapshot {
  const CalendarAutoSyncSnapshot({
    required this.lastReason,
    required this.lastAttemptAt,
    required this.completed,
    required this.failed,
    required this.providers,
  });

  final String? lastReason;
  final DateTime? lastAttemptAt;
  final List<String> completed;
  final List<String> failed;
  final List<CalendarAutoSyncProviderSnapshot> providers;

  bool get hasHistory =>
      lastAttemptAt != null ||
      providers.any((provider) {
        return provider.checkedAt != null || provider.lastSuccessAt != null;
      });
}

class CalendarAutoSyncProviderSnapshot {
  const CalendarAutoSyncProviderSnapshot({
    required this.key,
    required this.label,
    required this.status,
    required this.message,
    required this.checkedAt,
    required this.lastSuccessAt,
  });

  final String key;
  final String label;
  final String status;
  final String message;
  final DateTime? checkedAt;
  final DateTime? lastSuccessAt;

  bool get isHealthy => status == 'connected';
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
