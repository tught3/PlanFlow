import 'package:flutter/foundation.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/diag_logger.dart';
import '../core/env.dart';
import '../core/supabase_auth_options.dart';
import 'briefing_scheduler_service.dart';

class AlarmService {
  const AlarmService();

  static Future<bool>? _initializeFuture;

  Future<bool> scheduleMorningBriefing({
    required String id,
    required DateTime scheduledAt,
    String? userId,
    String? briefingText,
  }) {
    return scheduleBriefing(
      id: id,
      scheduledAt: scheduledAt,
      briefingType: 'morning',
      userId: userId,
      briefingText: briefingText,
    );
  }

  Future<bool> scheduleEveningBriefing({
    required String id,
    required DateTime scheduledAt,
    String? userId,
    String? briefingText,
  }) {
    return scheduleBriefing(
      id: id,
      scheduledAt: scheduledAt,
      briefingType: 'evening',
      userId: userId,
      briefingText: briefingText,
    );
  }

  Future<bool> scheduleBriefing({
    required String id,
    required DateTime scheduledAt,
    String briefingType = 'morning',
    String? userId,
    String? briefingText,
  }) async {
    if (scheduledAt.isBefore(DateTime.now())) {
      DiagLogger.log(
        'AlarmService',
        'scheduleBriefing skip: past time id=$id scheduledAt=$scheduledAt',
      );
      return false;
    }

    final initialized = await _ensureInitialized();
    if (!initialized) {
      DiagLogger.log(
        'AlarmService',
        'scheduleBriefing skip: AndroidAlarmManager init failed id=$id',
      );
      return false;
    }

    final resolvedUserId = _resolveCurrentUserId(userId);
    return AndroidAlarmManager.oneShotAt(
      scheduledAt,
      _alarmIdFrom(id),
      _briefingAlarmCallback,
      exact: true,
      allowWhileIdle: true,
      wakeup: true,
      params: <String, dynamic>{
        'id': id,
        'briefing_type': briefingType,
        if (resolvedUserId != null) 'user_id': resolvedUserId,
        if (briefingText != null && briefingText.trim().isNotEmpty)
          'briefing_text': briefingText.trim(),
        'scheduled_at': scheduledAt.toIso8601String(),
      },
    );
  }

  Future<bool> _ensureInitialized() {
    _initializeFuture ??= AndroidAlarmManager.initialize();
    return _initializeFuture!;
  }

  String? _resolveCurrentUserId(String? userId) {
    final explicitUserId = userId?.trim();
    if (explicitUserId != null && explicitUserId.isNotEmpty) {
      return explicitUserId;
    }

    try {
      final currentUserId =
          Supabase.instance.client.auth.currentUser?.id.trim();
      if (currentUserId != null && currentUserId.isNotEmpty) {
        return currentUserId;
      }
    } catch (_) {
      // Scheduling can be attempted before Supabase is initialized.
    }

    return null;
  }

  Future<void> cancelBriefing({required String id}) async {
    await AndroidAlarmManager.cancel(_alarmIdFrom(id));
    DiagLogger.log('AlarmService', 'briefing alarm cancelled id=$id');
  }

  int _alarmIdFrom(String id) => id.hashCode & 0x7fffffff;
}

/// Background isolate callback for briefing alarms.
///
/// Because this runs in a separate isolate, we need to re-initialize
/// Supabase before doing any work.
@pragma('vm:entry-point')
Future<void> _briefingAlarmCallback(
  int id,
  Map<String, dynamic> params,
) async {
  final briefingType = params['briefing_type'] as String? ?? 'morning';
  final isMorning = briefingType == 'morning';
  final userId = params['user_id'] as String?;

  DiagLogger.log(
    'BriefingAlarm',
    'briefingCallback 시작 type=$briefingType '
        'at=${DateTime.now().toIso8601String()}',
  );

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

    // IsolateNameServer는 같은 Dart VM 내에서만 동작한다.
    // android_alarm_manager_plus는 별도 FlutterEngine(별도 VM)을 생성하므로
    // SharedPreferences 기반 pending key로 포그라운드 신호를 전달한다.
    final prefs = await SharedPreferences.getInstance();
    // 단순 bool 플래그는 백그라운드 전환/앱 종료 시 true로 고착돼 알림이 안
    // 울리던 문제가 있었다. heartbeat 신선도로 실제 포그라운드 여부를 판정한다.
    final isForeground = BriefingSchedulerService.isAppForegroundFresh(prefs);
    if (isForeground) {
      await prefs.setString(
        BriefingSchedulerService.pendingModalKey,
        briefingType,
      );
      DiagLogger.log(
        'BriefingAlarm',
        'foreground_modal_pending type=$briefingType',
      );
    } else {
      final scheduler = BriefingSchedulerService();
      await scheduler.showBriefingStartNotification(isMorning: isMorning);
    }
  } catch (error, stackTrace) {
    // Background isolate must never crash, but failures must stay visible.
    DiagLogger.log(
      'BriefingAlarm',
      'callback failed type=$briefingType error=$error',
    );
    debugPrint('Briefing alarm callback failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    // Supabase 초기화 실패 여부와 무관하게 항상 다음 알람 등록
    try {
      final scheduler = BriefingSchedulerService();
      await scheduler.rescheduleNextBriefing(
        isMorning: isMorning,
        userId: userId,
      );
    } catch (e) {
      // 이 재예약이 조용히 실패하면(과거 재발 원인) 콜드스타트/설정 재저장
      // 전까지 다음 브리핑이 영구히 예약 안 되므로 반드시 진단로그에 남긴다.
      // shell_screen.dart의 resume 훅이 이 실패를 앱을 여는 것만으로도
      // 복구하는 백스톱 역할을 한다.
      DiagLogger.log(
        'BriefingAlarm',
        'reschedule failed type=$briefingType error=$e',
      );
      debugPrint('AlarmService 무시된 예외: $e');
    }
  }
}
