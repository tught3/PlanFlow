import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';
import 'alarm_service.dart';
import 'gpt_service.dart';
import 'notification_service.dart';
import 'tts_service.dart';

/// Orchestrates morning and evening briefings:
/// 1. Fetches today/tomorrow events from Supabase
/// 2. Generates a GPT summary
/// 3. Speaks the briefing via TTS
/// 4. Schedules the next daily alarm
class BriefingSchedulerService {
  BriefingSchedulerService({
    AlarmService? alarmService,
    GptService? gptService,
    TtsService? ttsService,
    NotificationService? notificationService,
  })  : _alarmService = alarmService ?? const AlarmService(),
        _gptService = gptService ?? GptService(),
        _ttsService = ttsService ?? const TtsService(),
        _notificationService = notificationService ?? NotificationService();

  final AlarmService _alarmService;
  final GptService _gptService;
  final TtsService _ttsService;
  final NotificationService _notificationService;

  static const String _morningAlarmId = 'briefing:morning';
  static const String _eveningAlarmId = 'briefing:evening';

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Schedule both morning and evening briefings based on user settings.
  Future<void> scheduleDaily({
    required String morningTime,
    required String eveningTime,
    String? userId,
  }) async {
    final morningAt = _nextOccurrence(morningTime);
    final eveningAt = _nextOccurrence(eveningTime);
    final resolvedUserId = _resolveUserId(userId);

    await _alarmService.scheduleMorningBriefing(
      id: _morningAlarmId,
      scheduledAt: morningAt,
      userId: resolvedUserId,
    );

    await _alarmService.scheduleEveningBriefing(
      id: _eveningAlarmId,
      scheduledAt: eveningAt,
      userId: resolvedUserId,
    );
  }

  /// Execute a briefing right now (called from alarm callback or manually).
  Future<void> executeBriefing({
    required bool isMorning,
    String? userId,
  }) async {
    if (!AppEnv.isSupabaseReady) {
      await _deliverBriefing(
        'PlanFlow 브리핑을 실행하려면 Supabase 설정이 필요해요. 앱을 열어 설정을 확인해 주세요.',
        isMorning: isMorning,
      );
      return;
    }

    final resolvedUserId = _resolveUserId(userId);
    if (resolvedUserId == null) {
      await _deliverBriefing(
        'PlanFlow 브리핑 사용자 확인이 필요해요. 앱을 한 번 열어 로그인 상태와 브리핑 알람을 새로고침해 주세요.',
        isMorning: isMorning,
      );
      return;
    }

    try {
      // 1. Fetch relevant events
      final events = await _fetchRelevantEvents(
        userId: resolvedUserId,
        isMorning: isMorning,
      );

      if (events.isEmpty) {
        final emptyMessage = isMorning
            ? '좋은 아침이에요! 오늘은 예정된 일정이 없어요. 여유로운 하루 보내세요 😊'
            : '오늘 하루도 수고하셨어요! 내일은 예정된 일정이 없네요. 편안한 저녁 보내세요 🌙';
        await _deliverBriefing(emptyMessage, isMorning: isMorning);
        return;
      }

      // 2. Build event summary for GPT
      final eventSummary = events.map((e) {
        final time = e.startAt != null
            ? '${e.startAt!.hour.toString().padLeft(2, '0')}:${e.startAt!.minute.toString().padLeft(2, '0')}'
            : '시간 미정';
        final location = e.location != null ? ' (${e.location})' : '';
        final critical = e.isCritical ? ' ⚠️중요' : '';
        final supplies =
            e.supplies.isNotEmpty ? ' 준비물: ${e.supplies.join(', ')}' : '';
        return '- $time ${e.title}$location$critical$supplies';
      }).join('\n');

      // 3. Generate GPT briefing
      final briefingText = await _gptService.generateBriefing(
        rawText: eventSummary,
        isMorning: isMorning,
      );

      // 4. Deliver
      await _deliverBriefing(briefingText, isMorning: isMorning);
    } catch (_) {
      // Fail silently; don't crash background isolate
    }

    // 5. Re-schedule for tomorrow
    await _rescheduleForTomorrow(
      isMorning: isMorning,
      userId: resolvedUserId,
    );
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<List<EventModel>> _fetchRelevantEvents({
    required String userId,
    required bool isMorning,
  }) async {
    final repository = EventRepository.supabase();
    final allEvents = await repository.listEvents(userId: userId);

    final targetDate = isMorning ? DateTime.now() : _tomorrow();

    return allEvents.where((event) {
      final startAt = event.startAt;
      if (startAt == null) {
        return false;
      }
      return startAt.year == targetDate.year &&
          startAt.month == targetDate.month &&
          startAt.day == targetDate.day;
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
  }

  Future<void> _deliverBriefing(
    String text, {
    required bool isMorning,
  }) async {
    // Push notification
    final notificationId = isMorning ? 90001 : 90002;
    final title = isMorning ? '☀️ 모닝 브리핑' : '🌙 이브닝 브리핑';

    try {
      await _notificationService.scheduleEventReminder(
        id: notificationId,
        title: title,
        body: text.length > 100 ? '${text.substring(0, 100)}...' : text,
        notifyAt: DateTime.now().add(const Duration(seconds: 1)),
      );
    } catch (_) {}

    // TTS
    try {
      await _ttsService.speak(text);
    } catch (_) {}
  }

  Future<void> _rescheduleForTomorrow({
    required bool isMorning,
    String? userId,
  }) async {
    // Default times; in production these would come from user_settings
    final defaultTime = isMorning ? '07:30' : '21:00';
    final nextAt = _nextOccurrence(defaultTime);

    if (isMorning) {
      await _alarmService.scheduleMorningBriefing(
        id: _morningAlarmId,
        scheduledAt: nextAt,
        userId: _resolveUserId(userId),
      );
    } else {
      await _alarmService.scheduleEveningBriefing(
        id: _eveningAlarmId,
        scheduledAt: nextAt,
        userId: _resolveUserId(userId),
      );
    }
  }

  String? _resolveUserId(String? userId) {
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
      // Background isolates can run without a hydrated Supabase auth session.
    }

    return null;
  }

  /// Parse "HH:mm" and return the next occurrence (today if future, else tomorrow).
  DateTime _nextOccurrence(String timeString) {
    final parts = timeString.split(':');
    final hour = int.tryParse(parts.firstOrNull ?? '') ?? 7;
    final minute = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 30;

    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, hour, minute);

    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }

    return target;
  }

  DateTime _tomorrow() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1);
  }
}
