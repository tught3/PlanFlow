import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import 'manual_event_side_effect_service.dart';

class SmartPreparationMonitorService {
  const SmartPreparationMonitorService({
    ManualEventSideEffectService? sideEffectService,
    DateTime Function()? now,
  })  : _sideEffectService = sideEffectService,
        _now = now;

  static const Duration monitorInterval = Duration(minutes: 30);
  static const String _monitorAlarmId = 'smart_preparation:monitor';

  final ManualEventSideEffectService? _sideEffectService;
  final DateTime Function()? _now;

  ManualEventSideEffectService get _sideEffects =>
      _sideEffectService ?? const ManualEventSideEffectService();

  DateTime get _currentTime => (_now ?? DateTime.now)();

  Future<bool> scheduleNextMonitor() async {
    final nextMonitorAt = _currentTime.add(monitorInterval);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final initialized = await AndroidAlarmManager.initialize();
    if (!initialized) {
      return false;
    }
    return AndroidAlarmManager.oneShotAt(
      nextMonitorAt,
      _monitorAlarmId.hashCode & 0x7fffffff,
      _smartPreparationMonitorCallback,
      exact: false,
      allowWhileIdle: false,
      wakeup: false,
    );
  }

  Future<void> refreshUpcoming({String? userId}) async {
    final resolvedUserId = userId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return;
    }
    if (!AppEnv.isSupabaseReady) {
      return;
    }
    await _sideEffects.recalculateUpcomingAlarmsForUser(
      userId: resolvedUserId,
    );
  }

  String? _currentSupabaseUserId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id.trim();
    } catch (_) {
      return null;
    }
  }
}

@pragma('vm:entry-point')
Future<void> _smartPreparationMonitorCallback() async {
  try {
    if (!AppEnv.isSupabaseReady && AppEnv.hasValidSupabaseConfig) {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
      );
      AppEnv.markSupabaseInitialized();
    }
    await const SmartPreparationMonitorService().refreshUpcoming();
  } catch (error, stackTrace) {
    debugPrint('Smart preparation monitor skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    await const SmartPreparationMonitorService().scheduleNextMonitor();
  }
}
