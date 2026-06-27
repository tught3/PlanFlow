import 'package:flutter/foundation.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
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
      return false;
    }

    final initialized = await _ensureInitialized();
    if (!initialized) {
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

    final scheduler = BriefingSchedulerService();
    await scheduler.showBriefingStartNotification(isMorning: isMorning);
  } catch (_) {
    // Background isolate must never crash
  } finally {
    // Supabase 초기화 실패 여부와 무관하게 항상 다음 알람 등록
    try {
      final scheduler = BriefingSchedulerService();
      await scheduler.rescheduleNextBriefing(
        isMorning: isMorning,
        userId: userId,
      );
    } catch (e) { debugPrint('AlarmService 무시된 예외: $e'); }
  }
}
