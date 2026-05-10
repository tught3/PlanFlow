import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
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
        status: 'attention',
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
      return _calendarOutcome(google);
    });
    await _runStep(result, 'naver_caldav_export', () {
      return _boolOutcome(
        _naverCalDav.exportEvent(event),
        skippedMessage: 'Naver CalDAV가 연결되지 않았거나 내보내기를 건너뛰었습니다.',
      );
    });
    await _runStep(result, 'device_calendar_export', () {
      return _boolOutcome(
        _deviceCalendar.exportEvent(event),
        skippedMessage: '휴대폰 캘린더 내보내기를 건너뛰었습니다.',
      );
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
        status: 'attention',
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
        return _calendarOutcome(google);
      });
      await _runStep(result, 'naver_api_auto_export', () async {
        final naver = await _calendarSync.syncNaverCalendar();
        return _calendarOutcome(naver);
      });
      await _runStep(result, 'naver_caldav_auto_import', () async {
        if (!await _naverCalDav.hasCredentials()) {
          return CalendarAutoSyncStepOutcome.skipped(
            'Naver CalDAV가 아직 연결되지 않아 자동 가져오기를 건너뜁니다.',
          );
        }
        final naver = await _naverCalDav.syncAll(
          mode: NaverCalDavSyncMode.quick,
          skipUnchanged: true,
        );
        if (naver.success) {
          return CalendarAutoSyncStepOutcome.completed(naver.message);
        }
        return CalendarAutoSyncStepOutcome.attention(naver.message);
      });
      await _runStep(result, 'device_calendar_auto_import', () async {
        final hasPermission = await _deviceCalendar.checkCalendarPermission();
        if (!hasPermission) {
          return CalendarAutoSyncStepOutcome.skipped(
            '휴대폰 캘린더 권한이 없어 자동 가져오기를 건너뜁니다.',
          );
        }
        final imported = await _deviceCalendar.importNaverEvents();
        if (imported.status == DeviceCalendarImportStatus.failed ||
            imported.status == DeviceCalendarImportStatus.permissionDenied) {
          return CalendarAutoSyncStepOutcome.attention(imported.message);
        }
        return CalendarAutoSyncStepOutcome.completed(imported.message);
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
    Future<CalendarAutoSyncStepOutcome> Function() step,
  ) async {
    try {
      final outcome = await step();
      if (outcome.status == CalendarAutoSyncStepStatus.completed) {
        result.completed.add(name);
        await _recordProviderStatus(
          name,
          status: 'connected',
          message: outcome.message,
        );
      } else if (outcome.status == CalendarAutoSyncStepStatus.skipped) {
        result.skipped.add(name);
        await _recordProviderStatus(
          name,
          status: 'skipped',
          message: outcome.message,
        );
      } else {
        result.failed.add(name);
        await _recordProviderStatus(
          name,
          status: 'attention',
          message: outcome.message,
        );
      }
    } catch (error, stackTrace) {
      result.failed.add(name);
      await _recordProviderStatus(
        name,
        status: 'attention',
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
    await prefs.setStringList(
      'calendar_sync:last_skipped',
      result.skipped,
    );
  }

  Future<void> _recordProviderStatus(
    String provider, {
    required String status,
    required String message,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'calendar_sync:provider:$provider';
    await prefs.setString('$key:status', status);
    await prefs.setString('$key:message', message);
    await prefs.setString('$key:checked_at', _now().toIso8601String());
    if (status == 'connected') {
      await prefs.setString('$key:last_success_at', _now().toIso8601String());
    }
  }

  CalendarAutoSyncStepOutcome _calendarOutcome(
    CalendarIntegrationResult result,
  ) {
    return switch (result.status) {
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.synced =>
        CalendarAutoSyncStepOutcome.completed(result.message),
      CalendarIntegrationStatus.signedOut ||
      CalendarIntegrationStatus.notConfigured ||
      CalendarIntegrationStatus.unsupported =>
        CalendarAutoSyncStepOutcome.skipped(result.message),
      CalendarIntegrationStatus.reauthRequired ||
      CalendarIntegrationStatus.failed =>
        CalendarAutoSyncStepOutcome.attention(result.message),
      CalendarIntegrationStatus.syncing =>
        CalendarAutoSyncStepOutcome.skipped(result.message),
    };
  }

  Future<CalendarAutoSyncStepOutcome> _boolOutcome(
    Future<bool> future, {
    required String skippedMessage,
  }) async {
    final success = await future;
    if (success) {
      return const CalendarAutoSyncStepOutcome.completed('정상 동기화됨');
    }
    return CalendarAutoSyncStepOutcome.skipped(skippedMessage);
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
      skipped:
          prefs.getStringList('calendar_sync:last_skipped') ?? const <String>[],
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
  final List<String> skipped = <String>[];

  bool get didRun => skippedReason == null;
  bool get hasFailures => failed.isNotEmpty;
}

enum CalendarAutoSyncStepStatus { completed, attention, skipped }

class CalendarAutoSyncStepOutcome {
  const CalendarAutoSyncStepOutcome._({
    required this.status,
    required this.message,
  });

  const CalendarAutoSyncStepOutcome.completed(String message)
      : this._(
          status: CalendarAutoSyncStepStatus.completed,
          message: message,
        );

  const CalendarAutoSyncStepOutcome.attention(String message)
      : this._(
          status: CalendarAutoSyncStepStatus.attention,
          message: message,
        );

  const CalendarAutoSyncStepOutcome.skipped(String message)
      : this._(
          status: CalendarAutoSyncStepStatus.skipped,
          message: message,
        );

  final CalendarAutoSyncStepStatus status;
  final String message;
}

class CalendarAutoSyncSnapshot {
  const CalendarAutoSyncSnapshot({
    required this.lastReason,
    required this.lastAttemptAt,
    required this.completed,
    required this.failed,
    required this.skipped,
    required this.providers,
  });

  final String? lastReason;
  final DateTime? lastAttemptAt;
  final List<String> completed;
  final List<String> failed;
  final List<String> skipped;
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
  bool get isSkipped => status == 'skipped';
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
