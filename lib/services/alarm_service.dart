import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

class AlarmService {
  const AlarmService();

  static Future<bool>? _initializeFuture;

  Future<bool> scheduleMorningBriefing({
    required String id,
    required DateTime scheduledAt,
    String? briefingText,
  }) {
    return scheduleBriefing(
      id: id,
      scheduledAt: scheduledAt,
      briefingType: 'morning',
      briefingText: briefingText,
    );
  }

  Future<bool> scheduleEveningBriefing({
    required String id,
    required DateTime scheduledAt,
    String? briefingText,
  }) {
    return scheduleBriefing(
      id: id,
      scheduledAt: scheduledAt,
      briefingType: 'evening',
      briefingText: briefingText,
    );
  }

  Future<bool> scheduleBriefing({
    required String id,
    required DateTime scheduledAt,
    String briefingType = 'morning',
    String? briefingText,
  }) async {
    if (scheduledAt.isBefore(DateTime.now())) {
      return false;
    }

    final initialized = await _ensureInitialized();
    if (!initialized) {
      return false;
    }

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

  int _alarmIdFrom(String id) => id.hashCode & 0x7fffffff;
}

@pragma('vm:entry-point')
void _briefingAlarmCallback(int id, Map<String, dynamic> params) {
  // Scaffold only: the background isolate wiring will be expanded later.
}
