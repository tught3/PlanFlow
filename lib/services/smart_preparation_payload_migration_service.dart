import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_event_side_effect_service.dart';

class SmartPreparationPayloadMigrationService {
  const SmartPreparationPayloadMigrationService({
    ManualEventSideEffectService? sideEffectService,
    SharedPreferences? preferences,
    DateTime Function()? now,
  })  : _sideEffectService = sideEffectService,
        _preferences = preferences,
        _now = now;

  final ManualEventSideEffectService? _sideEffectService;
  final SharedPreferences? _preferences;
  final DateTime Function()? _now;

  ManualEventSideEffectService get _sideEffects =>
      _sideEffectService ?? const ManualEventSideEffectService();
  DateTime get _currentTime => (_now ?? DateTime.now)();

  static const String _migrationVersion = 'v1';

  static String _migrationKey(String userId) {
    return 'smart_preparation_payload_migration:$userId:$_migrationVersion';
  }

  Future<bool> migrateIfNeeded(String userId) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return false;
    }

    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final migrationKey = _migrationKey(normalizedUserId);
    if (prefs.getBool(migrationKey) == true) {
      return true;
    }

    try {
      final result = await _sideEffects.recalculateUpcomingAlarmsForUser(
        userId: normalizedUserId,
        now: _currentTime,
      );
      if (result.preparationSucceeded) {
        await prefs.setBool(migrationKey, true);
      }
      return result.preparationSucceeded;
    } catch (error, stackTrace) {
      debugPrint('Smart preparation payload migration failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }
}
