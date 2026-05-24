import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/event_repository.dart';
import 'manual_event_side_effect_service.dart';
import 'notification_service.dart';

class CriticalAlarmChannelMigrationService {
  const CriticalAlarmChannelMigrationService({
    EventRepository? eventRepository,
    ManualEventSideEffectService? sideEffectService,
    SharedPreferences? preferences,
    DateTime Function()? now,
  })  : _eventRepository = eventRepository,
        _sideEffectService = sideEffectService,
        _preferences = preferences,
        _now = now;

  final EventRepository? _eventRepository;
  final ManualEventSideEffectService? _sideEffectService;
  final SharedPreferences? _preferences;
  final DateTime Function()? _now;

  EventRepository get _repository =>
      _eventRepository ?? SupabaseEventRepository();
  ManualEventSideEffectService get _sideEffects =>
      _sideEffectService ?? const ManualEventSideEffectService();
  DateTime get _currentTime => (_now ?? DateTime.now)();

  Future<bool> migrateFutureCriticalAlarmsIfNeeded(String userId) async {
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
      final now = _currentTime;
      final criticalEvents = (await _repository.listEvents(
        userId: normalizedUserId,
      ))
          .where(
            (event) =>
                event.isCritical &&
                event.startAt != null &&
                event.startAt!.isAfter(now),
          )
          .toList(growable: false);

      if (criticalEvents.isEmpty) {
        await prefs.setBool(migrationKey, true);
        return true;
      }

      final migrated = await _sideEffects.resyncRemindersForEvents(
        events: criticalEvents,
        userId: normalizedUserId,
      );
      if (migrated) {
        await prefs.setBool(migrationKey, true);
      }
      return migrated;
    } catch (error, stackTrace) {
      debugPrint('Critical alarm channel migration failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  static String _migrationKey(String userId) {
    return 'critical_alarm_channel_migration:$userId:'
        '${NotificationService.criticalAlarmChannelId}';
  }
}
