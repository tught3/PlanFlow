import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/models/event_model.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/event_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'alarm_service.dart';
import 'gpt_service.dart';
import 'notification_service.dart';
import 'tts_service.dart';

class BriefingSchedulerService {
  BriefingSchedulerService({
    AlarmService? alarmService,
    GptService? gptService,
    TtsService? ttsService,
    NotificationService? notificationService,
    SettingsRepository? settingsRepository,
  })  : _alarmService = alarmService ?? const AlarmService(),
        _gptService = gptService ?? GptService(),
        _ttsService = ttsService ?? const TtsService(),
        _notificationService = notificationService ?? NotificationService(),
        _settingsRepository = settingsRepository;

  final AlarmService _alarmService;
  final GptService _gptService;
  final TtsService _ttsService;
  final NotificationService _notificationService;
  final SettingsRepository? _settingsRepository;

  static const String _morningAlarmId = 'briefing:morning';
  static const String _eveningAlarmId = 'briefing:evening';

  Future<void> scheduleDaily({
    required String morningTime,
    required String eveningTime,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);

    await _alarmService.scheduleMorningBriefing(
      id: _morningAlarmId,
      scheduledAt: _nextOccurrence(morningTime),
      userId: resolvedUserId,
    );

    await _alarmService.scheduleEveningBriefing(
      id: _eveningAlarmId,
      scheduledAt: _nextOccurrence(eveningTime),
      userId: resolvedUserId,
    );
  }

  Future<void> executeBriefing({
    required bool isMorning,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);

    try {
      if (!AppEnv.isSupabaseReady) {
        await _deliverBriefing(
          'PlanFlow 브리핑을 실행하려면 서버 설정이 필요합니다. 앱을 열어 설정을 확인해 주세요.',
          isMorning: isMorning,
        );
        return;
      }

      if (resolvedUserId == null) {
        await _deliverBriefing(
          'PlanFlow 브리핑을 위해 로그인 상태 확인이 필요합니다. 앱을 한 번 열어 주세요.',
          isMorning: isMorning,
        );
        return;
      }

      final events = await _fetchRelevantEvents(
        userId: resolvedUserId,
        isMorning: isMorning,
      );

      if (events.isEmpty) {
        await _deliverBriefing(
          isMorning
              ? '좋은 아침이에요. 오늘은 예정된 일정이 없어요. 여유로운 하루 보내세요.'
              : '오늘 하루도 고생하셨어요. 내일은 예정된 일정이 없어요. 편안한 저녁 보내세요.',
          isMorning: isMorning,
        );
        return;
      }

      final briefingText = await _gptService.generateBriefing(
        rawText: _buildEventSummary(events),
        isMorning: isMorning,
      );
      await _deliverBriefing(briefingText, isMorning: isMorning);
    } catch (_) {
      // Background alarm callbacks must never crash the isolate.
    } finally {
      await _rescheduleForTomorrow(
        isMorning: isMorning,
        userId: resolvedUserId,
      );
    }
  }

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

  String _buildEventSummary(List<EventModel> events) {
    return events.map((event) {
      final time = event.startAt == null
          ? '시간 미정'
          : '${event.startAt!.hour.toString().padLeft(2, '0')}:${event.startAt!.minute.toString().padLeft(2, '0')}';
      final location = event.location == null ? '' : ' (${event.location})';
      final critical = event.isCritical ? ' 중요' : '';
      final supplies =
          event.supplies.isEmpty ? '' : ' 준비물: ${event.supplies.join(', ')}';
      return '- $time ${event.title}$location$critical$supplies';
    }).join('\n');
  }

  Future<void> _deliverBriefing(
    String text, {
    required bool isMorning,
  }) async {
    final title = isMorning ? '모닝 브리핑' : '이브닝 브리핑';

    try {
      await _notificationService.scheduleEventReminder(
        id: isMorning ? 90001 : 90002,
        title: title,
        body: text.length > 100 ? '${text.substring(0, 100)}...' : text,
        notifyAt: DateTime.now().add(const Duration(seconds: 1)),
      );
    } catch (_) {}

    try {
      await _ttsService.speak(text);
    } catch (_) {}
  }

  Future<void> _rescheduleForTomorrow({
    required bool isMorning,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final settings = await _loadSettings(resolvedUserId);
    final nextTime =
        isMorning ? settings.morningBriefingAt : settings.eveningBriefingAt;

    if (isMorning) {
      await _alarmService.scheduleMorningBriefing(
        id: _morningAlarmId,
        scheduledAt: _nextOccurrence(nextTime),
        userId: resolvedUserId,
      );
    } else {
      await _alarmService.scheduleEveningBriefing(
        id: _eveningAlarmId,
        scheduledAt: _nextOccurrence(nextTime),
        userId: resolvedUserId,
      );
    }
  }

  Future<UserSettingsModel> _loadSettings(String? userId) async {
    if (userId == null || !AppEnv.isSupabaseReady) {
      return UserSettingsModel.defaults(userId: userId ?? '');
    }

    try {
      final repository = _settingsRepository ?? SettingsRepository.supabase();
      final settings = await repository.fetchSettings(userId);
      return settings ?? UserSettingsModel.defaults(userId: userId);
    } catch (_) {
      return UserSettingsModel.defaults(userId: userId);
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
    } catch (_) {}

    return null;
  }

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
