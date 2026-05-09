import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/event_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'alarm_service.dart';
import 'gpt_service.dart';
import 'notification_service.dart';
import 'travel_time_buffer_service.dart';
import 'tts_service.dart';

class BriefingScheduleEntry {
  const BriefingScheduleEntry({
    required this.scheduledAt,
    required this.scheduled,
  });

  final DateTime scheduledAt;
  final bool scheduled;
}

class BriefingDailyScheduleResult {
  const BriefingDailyScheduleResult({
    required this.morning,
    required this.evening,
  });

  final BriefingScheduleEntry morning;
  final BriefingScheduleEntry evening;

  bool get allScheduled => morning.scheduled && evening.scheduled;
}

class BriefingNextTimes {
  const BriefingNextTimes({
    required this.morning,
    required this.evening,
  });

  final DateTime morning;
  final DateTime evening;
}

class BriefingExecutionResult {
  const BriefingExecutionResult({
    required this.delivered,
    required this.usedFallback,
    required this.message,
    this.failureReason,
  });

  final bool delivered;
  final bool usedFallback;
  final String message;
  final String? failureReason;
}

class BriefingRuntimeStatus {
  const BriefingRuntimeStatus({
    this.nextMorningAt,
    this.nextEveningAt,
    this.morningScheduled,
    this.eveningScheduled,
    this.lastExecutedType,
    this.lastExecutedAt,
    this.lastExecutionDelivered,
    this.lastExecutionMessage,
    this.lastExecutionFailureReason,
  });

  final DateTime? nextMorningAt;
  final DateTime? nextEveningAt;
  final bool? morningScheduled;
  final bool? eveningScheduled;
  final String? lastExecutedType;
  final DateTime? lastExecutedAt;
  final bool? lastExecutionDelivered;
  final String? lastExecutionMessage;
  final String? lastExecutionFailureReason;
}

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
  static const String _nextMorningAtKey = 'briefing:next_morning_at';
  static const String _nextEveningAtKey = 'briefing:next_evening_at';
  static const String _morningScheduledKey = 'briefing:morning_scheduled';
  static const String _eveningScheduledKey = 'briefing:evening_scheduled';
  static const String _lastExecutedTypeKey = 'briefing:last_executed_type';
  static const String _lastExecutedAtKey = 'briefing:last_executed_at';
  static const String _lastExecutionDeliveredKey =
      'briefing:last_execution_delivered';
  static const String _lastExecutionMessageKey =
      'briefing:last_execution_message';
  static const String _lastExecutionFailureReasonKey =
      'briefing:last_execution_failure_reason';

  Future<BriefingDailyScheduleResult> scheduleDaily({
    required String morningTime,
    required String eveningTime,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final morningAt = _nextOccurrence(morningTime);
    final eveningAt = _nextOccurrence(eveningTime);

    final morningScheduled = await _alarmService.scheduleMorningBriefing(
      id: _morningAlarmId,
      scheduledAt: morningAt,
      userId: resolvedUserId,
    );

    final eveningScheduled = await _alarmService.scheduleEveningBriefing(
      id: _eveningAlarmId,
      scheduledAt: eveningAt,
      userId: resolvedUserId,
    );

    await _recordScheduleStatus(
      morningAt: morningAt,
      morningScheduled: morningScheduled,
      eveningAt: eveningAt,
      eveningScheduled: eveningScheduled,
    );

    return BriefingDailyScheduleResult(
      morning: BriefingScheduleEntry(
        scheduledAt: morningAt,
        scheduled: morningScheduled,
      ),
      evening: BriefingScheduleEntry(
        scheduledAt: eveningAt,
        scheduled: eveningScheduled,
      ),
    );
  }

  Future<BriefingRuntimeStatus> loadRuntimeStatus() async {
    final preferences = await SharedPreferences.getInstance();
    return BriefingRuntimeStatus(
      nextMorningAt: _parseDateTime(preferences.getString(_nextMorningAtKey)),
      nextEveningAt: _parseDateTime(preferences.getString(_nextEveningAtKey)),
      morningScheduled: preferences.getBool(_morningScheduledKey),
      eveningScheduled: preferences.getBool(_eveningScheduledKey),
      lastExecutedType: preferences.getString(_lastExecutedTypeKey),
      lastExecutedAt: _parseDateTime(preferences.getString(_lastExecutedAtKey)),
      lastExecutionDelivered: preferences.getBool(_lastExecutionDeliveredKey),
      lastExecutionMessage: preferences.getString(_lastExecutionMessageKey),
      lastExecutionFailureReason:
          preferences.getString(_lastExecutionFailureReasonKey),
    );
  }

  BriefingNextTimes nextDailyTimes({
    required String morningTime,
    required String eveningTime,
  }) {
    return BriefingNextTimes(
      morning: _nextOccurrence(morningTime),
      evening: _nextOccurrence(eveningTime),
    );
  }

  Future<BriefingExecutionResult> executeBriefing({
    required bool isMorning,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final type = isMorning ? 'morning' : 'evening';
    debugPrint(
        'Briefing execute: type=$type userId=${resolvedUserId ?? 'none'}');

    try {
      if (!AppEnv.isSupabaseReady) {
        const message = 'PlanFlow 브리핑을 실행하려면 서버 설정이 필요합니다. 앱을 열어 설정을 확인해 주세요.';
        await _deliverBriefing(
          message,
          isMorning: isMorning,
        );
        const result = BriefingExecutionResult(
          delivered: true,
          usedFallback: true,
          message: 'Supabase 설정이 없어 로컬 안내를 재생했습니다.',
          failureReason: 'supabase_missing',
        );
        await _recordExecutionStatus(isMorning: isMorning, result: result);
        return result;
      }

      if (resolvedUserId == null) {
        const message = 'PlanFlow 브리핑을 위해 로그인 상태 확인이 필요합니다. 앱을 한 번 열어 주세요.';
        await _deliverBriefing(
          message,
          isMorning: isMorning,
        );
        const result = BriefingExecutionResult(
          delivered: true,
          usedFallback: true,
          message: '로그인이 필요하다는 안내를 재생했습니다.',
          failureReason: 'signed_out',
        );
        await _recordExecutionStatus(isMorning: isMorning, result: result);
        return result;
      }

      final events = await _fetchRelevantEvents(
        userId: resolvedUserId,
        isMorning: isMorning,
      );

      if (events.isEmpty) {
        final message = isMorning
            ? '좋은 아침이에요. 오늘은 예정된 일정이 없어요. 여유로운 하루 보내세요.'
            : '오늘 하루도 고생하셨어요. 내일은 예정된 일정이 없어요. 편안한 저녁 보내세요.';
        await _deliverBriefing(
          message,
          isMorning: isMorning,
        );
        final result = BriefingExecutionResult(
          delivered: true,
          usedFallback: false,
          message: isMorning
              ? '오늘 일정이 없어 모닝 브리핑을 재생했습니다.'
              : '내일 일정이 없어 이브닝 브리핑을 재생했습니다.',
        );
        await _recordExecutionStatus(isMorning: isMorning, result: result);
        return result;
      }

      final eventSummary = _buildEventSummary(events);
      var usedFallback = false;
      String? failureReason;
      late final String briefingText;
      try {
        briefingText = await _gptService.generateBriefing(
          rawText: eventSummary,
          isMorning: isMorning,
        );
      } catch (error, stackTrace) {
        failureReason = error is GptCompletionException
            ? error.reason
            : 'unknown_gpt_error';
        debugPrint('Briefing GPT failed: type=$type error=$error');
        debugPrintStack(stackTrace: stackTrace);
        briefingText = await _buildLocalBriefing(
          events,
          isMorning: isMorning,
        );
        usedFallback = true;
        debugPrint(
          'Briefing fallback used: type=$type events=${events.length} reason=$failureReason',
        );
      }
      await _deliverBriefing(briefingText, isMorning: isMorning);
      final result = BriefingExecutionResult(
        delivered: true,
        usedFallback: usedFallback,
        message: usedFallback
            ? 'OpenAI 응답 실패로 로컬 브리핑을 재생했습니다.'
            : (isMorning ? '모닝 브리핑을 재생했습니다.' : '이브닝 브리핑을 재생했습니다.'),
        failureReason: failureReason,
      );
      await _recordExecutionStatus(isMorning: isMorning, result: result);
      return result;
    } catch (error, stackTrace) {
      // Background alarm callbacks must never crash the isolate.
      debugPrint('Briefing execute failed: type=$type error=$error');
      debugPrintStack(stackTrace: stackTrace);
      const result = BriefingExecutionResult(
        delivered: false,
        usedFallback: false,
        message: '브리핑 실행에 실패했습니다. 로그인 상태와 일정 조회를 확인해 주세요.',
        failureReason: 'execute_failed',
      );
      await _recordExecutionStatus(isMorning: isMorning, result: result);
      return result;
    } finally {
      try {
        await _rescheduleForTomorrow(
          isMorning: isMorning,
          userId: resolvedUserId,
        );
      } catch (error, stackTrace) {
        debugPrint('Briefing reschedule failed: type=$type error=$error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  Future<void> showBriefingStartNotification({
    required bool isMorning,
  }) {
    final title = isMorning ? '모닝 브리핑' : '이브닝 브리핑';
    final body = isMorning
        ? '알림을 누르면 오늘 일정을 시간순으로 정리해 드릴게요.'
        : '알림을 누르면 내일 일정을 시간순으로 정리해 드릴게요.';
    return _notificationService.scheduleEventReminder(
      id: isMorning ? 91001 : 91002,
      title: title,
      body: body,
      notifyAt: DateTime.now().add(const Duration(seconds: 1)),
      payload: isMorning ? 'briefing:morning' : 'briefing:evening',
    );
  }

  Future<bool> rescheduleNextBriefing({
    required bool isMorning,
    String? userId,
  }) {
    return _rescheduleForTomorrow(isMorning: isMorning, userId: userId);
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
      return planflowIsSameLocalDay(startAt, targetDate);
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
  }

  String _buildEventSummary(List<EventModel> events) {
    return events.map((event) {
      final time = event.startAt == null
          ? '시간 미정'
          : '${event.startAt!.toLocal().hour.toString().padLeft(2, '0')}:${event.startAt!.toLocal().minute.toString().padLeft(2, '0')}';
      final location = event.location == null ? '' : ' (${event.location})';
      final critical = event.isCritical ? ' 중요' : '';
      final supplies =
          event.supplies.isEmpty ? '' : ' 준비물: ${event.supplies.join(', ')}';
      return '- $time ${event.title}$location$critical$supplies';
    }).join('\n');
  }

  Future<String> _buildLocalBriefing(
    List<EventModel> events, {
    required bool isMorning,
  }) async {
    final prefix = isMorning
        ? '좋은 아침이에요. 오늘 일정은 ${events.length}개입니다.'
        : '오늘 하루도 고생하셨어요. 내일 일정은 ${events.length}개입니다.';
    final highlights = events.take(3).map((event) {
      final time = event.startAt == null
          ? '시간 미정'
          : '${event.startAt!.hour.toString().padLeft(2, '0')}:${event.startAt!.minute.toString().padLeft(2, '0')}';
      final location = event.location == null ? '' : ' ${event.location}';
      final critical = event.isCritical ? ' 중요한 일정입니다' : '';
      return '$time ${event.title}$location$critical';
    }).join(', ');
    final tightGapWarning = await _buildTightGapWarning(events);
    return '$prefix $highlights.${tightGapWarning == null ? '' : ' $tightGapWarning'}';
  }

  Future<String?> _buildTightGapWarning(List<EventModel> events) async {
    if (events.length < 2) {
      return null;
    }
    for (var index = 1; index < events.length; index += 1) {
      final previous = events[index - 1];
      final current = events[index];
      final previousStart = previous.startAt;
      final currentStart = current.startAt;
      if (previousStart == null || currentStart == null) {
        continue;
      }
      final gapMinutes = currentStart.difference(previousStart).inMinutes;
      if (gapMinutes <= 0) {
        continue;
      }

      var requiredMinutes = 45;
      final previousLat = previous.locationLat;
      final previousLng = previous.locationLng;
      final currentLat = current.locationLat;
      final currentLng = current.locationLng;
      if (previousLat != null &&
          previousLng != null &&
          currentLat != null &&
          currentLng != null) {
        try {
          final estimate = await TravelTimeBufferService().estimateWithMapApis(
            originLat: previousLat,
            originLng: previousLng,
            destinationLat: currentLat,
            destinationLng: currentLng,
            locationText: current.location,
          );
          requiredMinutes = estimate.minutes + 30;
        } catch (error) {
          debugPrint('Briefing travel estimate skipped: $error');
        }
      }

      if (gapMinutes < requiredMinutes) {
        return '${previous.title} 다음 ${current.title}까지 시간이 빠듯하니 이동을 서둘러 주세요.';
      }
    }
    return null;
  }

  Future<void> _deliverBriefing(
    String text, {
    required bool isMorning,
  }) async {
    final title = isMorning ? '모닝 브리핑' : '이브닝 브리핑';
    final type = isMorning ? 'morning' : 'evening';

    try {
      await _notificationService.scheduleEventReminder(
        id: isMorning ? 90001 : 90002,
        title: title,
        body: text.length > 100 ? '${text.substring(0, 100)}...' : text,
        notifyAt: DateTime.now().add(const Duration(seconds: 1)),
      );
    } catch (error, stackTrace) {
      debugPrint('Briefing notification failed: type=$type error=$error');
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      await _ttsService.speak(text);
    } catch (error, stackTrace) {
      debugPrint('Briefing TTS failed: type=$type error=$error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool> _rescheduleForTomorrow({
    required bool isMorning,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final settings = await _loadSettings(resolvedUserId);
    final nextTime =
        isMorning ? settings.morningBriefingAt : settings.eveningBriefingAt;

    final scheduledAt = _nextOccurrence(nextTime);
    if (isMorning) {
      final scheduled = await _alarmService.scheduleMorningBriefing(
        id: _morningAlarmId,
        scheduledAt: scheduledAt,
        userId: resolvedUserId,
      );
      await _recordSingleScheduleStatus(
        isMorning: true,
        scheduledAt: scheduledAt,
        scheduled: scheduled,
      );
      return scheduled;
    }
    final scheduled = await _alarmService.scheduleEveningBriefing(
      id: _eveningAlarmId,
      scheduledAt: scheduledAt,
      userId: resolvedUserId,
    );
    await _recordSingleScheduleStatus(
      isMorning: false,
      scheduledAt: scheduledAt,
      scheduled: scheduled,
    );
    return scheduled;
  }

  Future<void> _recordScheduleStatus({
    required DateTime morningAt,
    required bool morningScheduled,
    required DateTime eveningAt,
    required bool eveningScheduled,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_nextMorningAtKey, morningAt.toIso8601String());
    await preferences.setBool(_morningScheduledKey, morningScheduled);
    await preferences.setString(_nextEveningAtKey, eveningAt.toIso8601String());
    await preferences.setBool(_eveningScheduledKey, eveningScheduled);
  }

  Future<void> _recordSingleScheduleStatus({
    required bool isMorning,
    required DateTime scheduledAt,
    required bool scheduled,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      isMorning ? _nextMorningAtKey : _nextEveningAtKey,
      scheduledAt.toIso8601String(),
    );
    await preferences.setBool(
      isMorning ? _morningScheduledKey : _eveningScheduledKey,
      scheduled,
    );
  }

  Future<void> _recordExecutionStatus({
    required bool isMorning,
    required BriefingExecutionResult result,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _lastExecutedTypeKey,
      isMorning ? 'morning' : 'evening',
    );
    await preferences.setString(
      _lastExecutedAtKey,
      DateTime.now().toIso8601String(),
    );
    await preferences.setBool(_lastExecutionDeliveredKey, result.delivered);
    await preferences.setString(_lastExecutionMessageKey, result.message);
    final failureReason = result.failureReason;
    if (failureReason == null || failureReason.isEmpty) {
      await preferences.remove(_lastExecutionFailureReasonKey);
    } else {
      await preferences.setString(
        _lastExecutionFailureReasonKey,
        failureReason,
      );
    }
  }

  Future<UserSettingsModel> _loadSettings(String? userId) async {
    if (userId == null) {
      return UserSettingsModel.defaults(userId: userId ?? '');
    }

    if (_settingsRepository == null && !AppEnv.isSupabaseReady) {
      return UserSettingsModel.defaults(userId: userId);
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

  DateTime? _parseDateTime(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }
}
