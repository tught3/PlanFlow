import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import 'backup_service.dart';

class DailyBackupSchedulerService {
  const DailyBackupSchedulerService();

  static const String _alarmId = 'backup:daily:03';

  Future<bool> scheduleDaily() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    final initialized = await AndroidAlarmManager.initialize();
    if (!initialized) {
      return false;
    }

    return AndroidAlarmManager.oneShotAt(
      _next3Am(),
      _alarmId.hashCode & 0x7fffffff,
      _dailyBackupCallback,
      exact: true,
      allowWhileIdle: true,
      wakeup: false,
    );
  }

  Future<BackupSnapshot?> runCatchUpIfDue(BackupService backupService) {
    return backupService.createAutomaticBackupIfDue();
  }

  DateTime _next3Am() {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, 3);
    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
  }
}

@pragma('vm:entry-point')
Future<void> _dailyBackupCallback() async {
  try {
    if (!AppEnv.isSupabaseReady && AppEnv.hasValidSupabaseConfig) {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
      );
      AppEnv.markSupabaseInitialized();
    }

    await BackupService().createAutomaticBackupIfDue();
  } catch (error, stackTrace) {
    debugPrint('Daily backup callback skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    await const DailyBackupSchedulerService().scheduleDaily();
  }
}
