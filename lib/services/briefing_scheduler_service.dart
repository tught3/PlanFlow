import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/diag_logger.dart';
import '../core/env.dart';
import '../core/local_time.dart';
import '../data/models/event_model.dart';
import '../data/models/user_settings_model.dart';
import '../data/repositories/event_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'alarm_service.dart';
import 'gpt_service.dart';
import 'notification_service.dart';
import 'remote_config_service.dart';
import 'smart_preparation_alarm_service.dart';
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
    this.events = const [],
  });

  final bool delivered;
  final bool usedFallback;
  final String message;
  final String? failureReason;
  /// 브리핑에 사용된 일정 목록. 캐시 히트 시 캐시에서 복원된 일정을 포함한다.
  final List<EventModel> events;
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
    EventRepository? eventRepository,
    DateTime Function()? now,
    FutureOr<bool> Function()? isAppInForeground,
  })  : _alarmService = alarmService ?? const AlarmService(),
        _gptService = gptService ?? GptService(),
        _ttsService = ttsService ?? const TtsService(),
        _notificationService = notificationService ?? NotificationService(),
        _settingsRepository = settingsRepository,
        _eventRepository = eventRepository,
        _now = now ?? DateTime.now,
        _isAppInForeground = isAppInForeground;

  final AlarmService _alarmService;
  final GptService _gptService;
  final TtsService _ttsService;
  final NotificationService _notificationService;
  final SettingsRepository? _settingsRepository;
  final EventRepository? _eventRepository;
  final DateTime Function() _now;
  final FutureOr<bool> Function()? _isAppInForeground;

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
  // 사전 로드(preload) 캐시 키: 알람 발생 ~ 사용자 재생 버튼 사이에 미리 생성한 텍스트를 저장한다.
  static const String _preloadCacheMorningKey =
      'briefing:preload_cache:morning';
  static const String _preloadCacheEveningKey =
      'briefing:preload_cache:evening';
  // alarm callback(별도 Dart VM)이 포그라운드 앱에게 모달 신호를 전달하는 키.
  // IsolateNameServer는 같은 VM 내에서만 작동하므로 SharedPreferences를 사용한다.
  static const String appForegroundKey = 'briefing:app_foreground';
  static const String pendingModalKey = 'briefing:pending_modal';
  static const Duration _briefingLeadBeforePrepStart = Duration(minutes: 30);

  static final StreamController<bool> _foregroundBriefingController =
      StreamController<bool>.broadcast();

  /// 앱이 포그라운드일 때 브리핑 알람이 도착하면 true(모닝)/false(이브닝) 이벤트를 발행한다.
  static Stream<bool> get foregroundBriefingStream =>
      _foregroundBriefingController.stream;

  /// 알람 콜백이 [pendingModalKey]에 남긴 트리거를 확인해 모달 스트림으로 전달한다.
  /// 앱이 포그라운드일 때 주기적으로 호출한다.
  static Future<void> checkPendingModalTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString(pendingModalKey);
    if (pending == null) {
      return;
    }

    if (prefs.getBool(appForegroundKey) != true) {
      return;
    }

    await prefs.remove(pendingModalKey);
    if (!_foregroundBriefingController.isClosed) {
      _foregroundBriefingController.add(pending == 'morning');
    }
  }

  // 포그라운드 heartbeat 타임스탬프 키. appForegroundKey(bool)만으로는 앱이
  // 백그라운드로 가거나 종료될 때 false 쓰기가 flush되지 않거나 onPause가
  // 안 불려 true로 고착돼, 알람 콜백이 포그라운드로 오판(알림 대신 모달만)하는
  // 문제가 있었다. 포그라운드일 때만 주기적으로 이 타임스탬프를 갱신하고,
  // 콜백은 "플래그 true + heartbeat 최근"일 때만 포그라운드로 본다.
  static const String appForegroundAtKey = 'briefing:app_foreground_at';

  /// heartbeat 신선도 창. 앱이 이 시간 내에 heartbeat를 갱신했을 때만
  /// 포그라운드로 간주한다(백그라운드/종료 시 갱신이 멈춰 낡으면 백그라운드).
  static const Duration foregroundHeartbeatFreshness = Duration(seconds: 10);

  static Future<void> recordAppForegroundState(bool isForeground) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(appForegroundKey, isForeground);
    if (isForeground) {
      await preferences.setInt(
        appForegroundAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      await preferences.remove(appForegroundAtKey);
    }
  }

  /// 포그라운드 유지 중 주기적으로(앱의 lifecycle 타이머에서) 호출해 heartbeat를
  /// 갱신한다. 앱이 백그라운드/종료되면 타이머가 멈춰 갱신이 자연히 중단된다.
  static Future<void> refreshForegroundHeartbeat() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(appForegroundKey, true);
    await preferences.setInt(
      appForegroundAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 알람 콜백(별도 Dart VM)에서 앱이 실제로 포그라운드인지 heartbeat 신선도로
  /// 판정한다. 플래그가 true여도 heartbeat가 낡았으면(갱신 중단=백그라운드/종료)
  /// false를 반환해, 콜백이 알림을 정상 발화하도록 한다.
  static bool isAppForegroundFresh(SharedPreferences preferences) {
    if (!(preferences.getBool(appForegroundKey) ?? false)) {
      return false;
    }
    final at = preferences.getInt(appForegroundAtKey);
    if (at == null) {
      return false;
    }
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(at));
    return !age.isNegative && age < foregroundHeartbeatFreshness;
  }

  Future<BriefingDailyScheduleResult> scheduleDaily({
    required String morningTime,
    required String eveningTime,
    String? userId,
    bool briefingEnabled = true,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final settings = await _loadSettings(resolvedUserId);
    final morningAt = await _resolveMorningScheduleTime(
      baseMorningAt: _nextOccurrence(morningTime),
      userId: resolvedUserId,
      settings: settings.copyWith(morningBriefingAt: morningTime),
    );
    final eveningAt = _nextOccurrence(eveningTime);

    if (!RemoteConfigService.briefingEnabled) {
      debugPrint(
        'Briefing schedule skipped: remote config disabled, '
        'userId=${resolvedUserId ?? 'none'}',
      );
      return BriefingDailyScheduleResult(
        morning: BriefingScheduleEntry(
          scheduledAt: morningAt,
          scheduled: false,
        ),
        evening: BriefingScheduleEntry(
          scheduledAt: eveningAt,
          scheduled: false,
        ),
      );
    }

    if (!briefingEnabled) {
      DiagLogger.log(
        'Briefing',
        'schedule_cancelled: user disabled briefing alarms',
      );
      await _alarmService.cancelBriefing(id: _morningAlarmId);
      await _alarmService.cancelBriefing(id: _eveningAlarmId);
      return BriefingDailyScheduleResult(
        morning: BriefingScheduleEntry(
          scheduledAt: morningAt,
          scheduled: false,
        ),
        evening: BriefingScheduleEntry(
          scheduledAt: eveningAt,
          scheduled: false,
        ),
      );
    }

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
    bool isManualTrigger = false,
    // 일정 목록이 확정되는 즉시(TTS 재생 완료를 기다리지 않고) 호출된다.
    // 화면이 "브리핑 중..." 로딩 문구만 보여주지 않고, 읽어줄 목록을 바로
    // 화면에 띄운 채로 음성 재생을 진행할 수 있게 하기 위함.
    void Function(List<EventModel> events)? onEventsResolved,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final type = isMorning ? 'morning' : 'evening';
    debugPrint(
        'Briefing execute: type=$type userId=${resolvedUserId ?? 'none'}');

    try {
      if (!RemoteConfigService.briefingEnabled) {
        const result = BriefingExecutionResult(
          delivered: false,
          usedFallback: false,
          message: '브리핑 기능이 현재 비활성화되어 있습니다.',
          failureReason: 'briefing_disabled',
        );
        await _recordExecutionStatus(isMorning: isMorning, result: result);
        return result;
      }

      if (!AppEnv.isSupabaseReady) {
        const message = 'PlanFlow 브리핑을 실행하려면 서버 설정이 필요합니다. 앱을 열어 설정을 확인해 주세요.';
        await _deliverBriefing(
          message,
          isMorning: isMorning,
          suppressNotification: isManualTrigger,
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

      if (resolvedUserId == null || !_hasActiveSessionForServerQueries()) {
        const message = '일정을 확인하려면 로그인 세션을 다시 확인해 주세요.';
        await _deliverBriefing(
          message,
          isMorning: isMorning,
          suppressNotification: isManualTrigger,
        );
        const result = BriefingExecutionResult(
          delivered: true,
          usedFallback: true,
          message: '로그인 세션 재확인이 필요하다는 안내를 재생했습니다.',
          failureReason: 'session_reauth_required',
        );
        await _recordExecutionStatus(isMorning: isMorning, result: result);
        return result;
      }

      // 캐시 히트: 알람 발생 시 미리 생성해 둔 텍스트가 2시간 이내에 있으면 바로 재생.
      final cachedResult = await _consumePreloadCache(isMorning: isMorning);
      if (cachedResult != null) {
        onEventsResolved?.call(cachedResult.events);
        await _deliverBriefing(
          cachedResult.text,
          isMorning: isMorning,
          suppressNotification: isManualTrigger,
        );
        final result = BriefingExecutionResult(
          delivered: true,
          usedFallback: cachedResult.usedFallback,
          message: cachedResult.usedFallback
              ? '캐시(OpenAI 폴백)에서 브리핑을 재생했습니다.'
              : (isMorning
                  ? '캐시에서 모닝 브리핑을 재생했습니다.'
                  : '캐시에서 이브닝 브리핑을 재생했습니다.'),
          events: cachedResult.events,
        );
        await _recordExecutionStatus(isMorning: isMorning, result: result);
        return result;
      }

      final events = await _fetchRelevantEvents(
        userId: resolvedUserId,
        isMorning: isMorning,
      );

      if (events.isEmpty) {
        onEventsResolved?.call(const []);
        final message = isMorning
            ? '좋은 아침이에요. 오늘은 예정된 일정이 없어요. 여유로운 하루 보내세요.'
            : '오늘 하루도 고생하셨어요. 내일은 예정된 일정이 없어요. 편안한 저녁 보내세요.';
        await _deliverBriefing(
          message,
          isMorning: isMorning,
          suppressNotification: isManualTrigger,
        );
        final result = BriefingExecutionResult(
          delivered: true,
          usedFallback: false,
          message: isMorning
              ? '오늘 일정이 없어 모닝 브리핑을 재생했습니다.'
              : '내일 일정이 없어 이브닝 브리핑을 재생했습니다.',
          events: const [],
        );
        await _recordExecutionStatus(isMorning: isMorning, result: result);
        return result;
      }

      onEventsResolved?.call(events);
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
      await _deliverBriefing(
        briefingText,
        isMorning: isMorning,
        suppressNotification: isManualTrigger,
      );
      final result = BriefingExecutionResult(
        delivered: true,
        usedFallback: usedFallback,
        message: usedFallback
            ? 'OpenAI 응답 실패로 로컬 브리핑을 재생했습니다.'
            : (isMorning ? '모닝 브리핑을 재생했습니다.' : '이브닝 브리핑을 재생했습니다.'),
        failureReason: failureReason,
        events: events,
      );
      await _recordExecutionStatus(isMorning: isMorning, result: result);
      return result;
    } catch (error, stackTrace) {
      // Background alarm callbacks must never crash the isolate.
      DiagLogger.log(
        'BriefingAlarm',
        'execute failed type=$type error=$error',
      );
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
        // 여기가 조용히 실패하면 다음 브리핑이 영구히 안 걸린다(재발 5회
        // 원인). shell_screen.dart의 resume 재예약 백스톱과 이 로그가
        // 함께 재발을 막는다.
        DiagLogger.log(
          'BriefingAlarm',
          'reschedule failed type=$type error=$error',
        );
        debugPrint('Briefing reschedule failed: type=$type error=$error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  Future<void> showBriefingStartNotification({
    required bool isMorning,
  }) async {
    final title = isMorning ? '모닝 브리핑' : '이브닝 브리핑';
    final body = isMorning
        ? '오늘 모닝 브리핑 알람이 도착했습니다. 오늘 일정을 시간순으로 알려드릴까요?'
        : '이브닝 브리핑 알람이 도착했습니다. 내일 일정을 시간순으로 알려드릴까요?';
    if (await _shouldSuppressNotification(false)) {
      DiagLogger.log(
        'Briefing',
        'notification_suppressed type=${isMorning ? 'morning' : 'evening'} '
            'reason=app_foreground',
      );
      debugPrint(
        'Briefing start notification suppressed: '
        'type=${isMorning ? 'morning' : 'evening'} app_foreground=true',
      );
      return;
    }

    final result = await _notificationService.scheduleEventReminderWithResult(
      id: isMorning ? 91001 : 91002,
      title: title,
      body: body,
      notifyAt: DateTime.now().add(const Duration(seconds: 1)),
      payload: isMorning ? 'briefing:morning' : 'briefing:evening',
    );
    DiagLogger.log(
      'Briefing',
      'notification_schedule_result type=${isMorning ? 'morning' : 'evening'} '
          'status=${result.status.name} '
          'message=${result.message ?? 'none'}',
    );

    // 알림 예약과 동시에 best-effort 사전 로드 시작.
    // 사용자가 알림을 눌러 재생 화면에 진입할 때 캐시가 준비되어 있으면 즉시 재생 가능.
    unawaited(preloadBriefing(isMorning: isMorning));
  }

  Future<bool> rescheduleNextBriefing({
    required bool isMorning,
    String? userId,
  }) {
    return _rescheduleForTomorrow(isMorning: isMorning, userId: userId);
  }

  /// 일정 조회 → 요약 → GPT(또는 로컬 폴백) 텍스트 생성. TTS는 호출하지 않는다.
  /// [resolvedUserId]가 null이거나 세션이 없으면 null 반환.
  Future<({String text, bool usedFallback, List<EventModel> events})?>
      _resolveBriefingContent({
    required bool isMorning,
    required String? resolvedUserId,
  }) async {
    if (resolvedUserId == null || !_hasActiveSessionForServerQueries()) {
      return null;
    }
    final events = await _fetchRelevantEvents(
      userId: resolvedUserId,
      isMorning: isMorning,
    );
    if (events.isEmpty) {
      final text = isMorning
          ? '좋은 아침이에요. 오늘은 예정된 일정이 없어요. 여유로운 하루 보내세요.'
          : '오늘 하루도 고생하셨어요. 내일은 예정된 일정이 없어요. 편안한 저녁 보내세요.';
      return (text: text, usedFallback: false, events: <EventModel>[]);
    }
    final eventSummary = _buildEventSummary(events);
    var usedFallback = false;
    late final String text;
    try {
      text = await _gptService.generateBriefing(
        rawText: eventSummary,
        isMorning: isMorning,
      );
    } catch (error, stackTrace) {
      debugPrint(
        'Briefing preload GPT failed: type=${isMorning ? 'morning' : 'evening'} '
        'error=$error',
      );
      debugPrintStack(stackTrace: stackTrace);
      text = await _buildLocalBriefing(events, isMorning: isMorning);
      usedFallback = true;
    }
    return (text: text, usedFallback: usedFallback, events: events);
  }

  /// 알람 알림 예약 직후 또는 포그라운드 다이얼로그 표시와 동시에 호출.
  /// 브리핑 텍스트를 미리 생성해 SharedPreferences에 캐시한다(TTS 없음).
  /// 모든 예외를 흡수해 절대 throw하지 않는다(백그라운드 isolate 안전).
  Future<void> preloadBriefing({
    required bool isMorning,
    String? userId,
  }) async {
    try {
      if (!RemoteConfigService.briefingEnabled) {
        return;
      }
      if (!AppEnv.isSupabaseReady) {
        return;
      }
      final resolvedUserId = _resolveUserId(userId);
      final content = await _resolveBriefingContent(
        isMorning: isMorning,
        resolvedUserId: resolvedUserId,
      );
      if (content == null) {
        return;
      }
      final cacheKey =
          isMorning ? _preloadCacheMorningKey : _preloadCacheEveningKey;
      final cacheJson = jsonEncode({
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'type': isMorning ? 'morning' : 'evening',
        'text': content.text,
        'used_fallback': content.usedFallback,
        'events': content.events.map((e) => e.toJson()).toList(),
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(cacheKey, cacheJson);
      debugPrint(
        'Briefing preload cached: type=${isMorning ? 'morning' : 'evening'} '
        'events=${content.events.length}',
      );
    } catch (error, stackTrace) {
      // best-effort: 실패해도 정상 executeBriefing 라이브 경로로 폴백.
      debugPrint(
        'Briefing preload skipped: '
        'type=${isMorning ? 'morning' : 'evening'} error=$error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// 캐시된 사전 로드 결과를 읽고 삭제한다(소비 후 제거).
  /// 캐시가 없거나 만료(2시간 초과)·파싱 오류이면 null 반환.
  Future<({String text, bool usedFallback, List<EventModel> events})?>
      _consumePreloadCache({required bool isMorning}) async {
    try {
      final cacheKey =
          isMorning ? _preloadCacheMorningKey : _preloadCacheEveningKey;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey);
      if (raw == null) {
        return null;
      }
      // 파싱 즉시 삭제(1회성 캐시)
      await prefs.remove(cacheKey);
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final generatedAt =
          DateTime.tryParse(map['generated_at'] as String? ?? '');
      if (generatedAt == null) {
        return null;
      }
      // 2시간 이내의 캐시만 유효
      final age = DateTime.now().toUtc().difference(generatedAt.toUtc());
      if (age > const Duration(hours: 2)) {
        debugPrint(
          'Briefing preload cache expired: '
          'type=${isMorning ? 'morning' : 'evening'} age=${age.inMinutes}m',
        );
        return null;
      }
      final text = map['text'] as String? ?? '';
      if (text.isEmpty) {
        return null;
      }
      final usedFallback = (map['used_fallback'] as bool?) ?? false;
      final rawEvents = map['events'];
      final events = <EventModel>[];
      if (rawEvents is List) {
        for (final item in rawEvents) {
          try {
            if (item is Map<String, dynamic>) {
              events.add(EventModel.fromJson(item));
            }
          } catch (_) {
            // 일정 하나 파싱 실패 시 나머지는 계속 진행
          }
        }
      }
      debugPrint(
        'Briefing preload cache hit: '
        'type=${isMorning ? 'morning' : 'evening'} '
        'age=${age.inMinutes}m events=${events.length}',
      );
      return (text: text, usedFallback: usedFallback, events: events);
    } catch (error, stackTrace) {
      debugPrint('Briefing preload cache read failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<List<EventModel>> _fetchRelevantEvents({
    required String userId,
    required bool isMorning,
  }) async {
    final repository = _eventRepository ?? EventRepository.supabase();
    final allEvents = await repository.listEvents(userId: userId);
    final targetDate = isMorning ? _now() : _tomorrow();

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
          : '${planflowLocal(event.startAt!).hour.toString().padLeft(2, '0')}:${planflowLocal(event.startAt!).minute.toString().padLeft(2, '0')}';
      final location = event.location == null ? '' : ' 장소: ${event.location}';
      final critical = event.isCritical ? ' 중요 일정' : '';
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
        ? '좋은 아침입니다. 오늘 일정은 ${events.length}개입니다.'
        : '오늘 하루도 고생하셨어요. 내일 일정은 ${events.length}개입니다.';
    final briefingEvents = events.take(6).toList(growable: false);
    final highlights = briefingEvents
        .asMap()
        .entries
        .map((entry) => _buildSecretaryEventSentence(
              entry.value,
              index: entry.key,
            ))
        .join(' ');
    final remainingCount = events.length - briefingEvents.length;
    final remainingSummary =
        remainingCount > 0 ? '이후 일정이 $remainingCount개 더 있습니다.' : '';
    final tightGapWarning = await _buildTightGapWarning(events);
    return [
      prefix,
      highlights,
      if (remainingSummary.isNotEmpty) remainingSummary,
      if (tightGapWarning != null) tightGapWarning,
    ].where((part) => part.trim().isNotEmpty).join(' ');
  }

  String _buildSecretaryEventSentence(
    EventModel event, {
    required int index,
  }) {
    final lead = switch (index) {
      0 when event.isCritical => '중요한 일정입니다.',
      0 => '첫 일정은',
      1 when event.isCritical => '다음은 중요한 일정입니다.',
      1 => '다음 일정은',
      _ when event.isCritical => '그다음은 중요한 일정입니다.',
      _ => '그다음 일정은',
    };
    final time =
        event.startAt == null ? '시간 미정' : _spokenLocalTime(event.startAt!);
    final location = event.location?.trim();
    final locationPhrase =
        location == null || location.isEmpty ? '' : ', $location에서';
    final detail = '$time$locationPhrase ${event.title}이 있습니다.';
    return '$lead $detail';
  }

  String _spokenLocalTime(DateTime value) {
    final local = planflowLocal(value);
    final period = local.hour < 12 ? '오전' : '오후';
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    if (local.minute == 0) {
      return '$period $hour12시';
    }
    return '$period $hour12시 ${local.minute}분';
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

      final previousHasLocation = _hasUsableLocation(previous);
      final currentHasLocation = _hasUsableLocation(current);
      final hasMovementContext = previousHasLocation && currentHasLocation;
      var requiredMinutes = hasMovementContext ? 45 : 15;
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
        if (hasMovementContext) {
          return '${previous.title} 다음 ${current.title}까지 시간이 빠듯하니 이동을 서둘러 주세요.';
        }
        return '${previous.title} 다음 ${current.title}까지 일정 간격이 짧으니 앞 일정 마무리 시간을 확인해 주세요.';
      }
    }
    return null;
  }

  bool _hasUsableLocation(EventModel event) {
    final location = event.location?.trim();
    return location != null && location.isNotEmpty;
  }

  Future<void> _deliverBriefing(
    String text, {
    required bool isMorning,
    bool suppressNotification = false,
  }) async {
    final title = isMorning ? '모닝 브리핑' : '이브닝 브리핑';
    final type = isMorning ? 'morning' : 'evening';

    if (!await _shouldSuppressNotification(suppressNotification)) {
      try {
        await _notificationService.scheduleEventReminder(
          id: isMorning ? 90001 : 90002,
          title: title,
          body: text.length > 100 ? '${text.substring(0, 100)}...' : text,
          notifyAt: DateTime.now().add(const Duration(seconds: 1)),
        );
      } catch (error, stackTrace) {
        DiagLogger.log(
          'BriefingAlarm',
          'notification failed type=$type error=$error',
        );
        debugPrint('Briefing notification failed: type=$type error=$error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    try {
      await _ttsService.speak(text);
    } catch (error, stackTrace) {
      DiagLogger.log('BriefingAlarm', 'TTS failed type=$type error=$error');
      debugPrint('Briefing TTS failed: type=$type error=$error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool> _shouldSuppressNotification(bool explicitSuppress) async {
    if (explicitSuppress) {
      return true;
    }

    final injected = _isAppInForeground;
    if (injected != null) {
      return await injected();
    }

    final preferences = await SharedPreferences.getInstance();
    // AlarmService's background callback uses the same freshness check. Using
    // only appForegroundKey here can suppress the notification immediately
    // after that callback correctly classified a stale app as background.
    return isAppForegroundFresh(preferences);
  }

  Future<bool> _rescheduleForTomorrow({
    required bool isMorning,
    String? userId,
  }) async {
    final resolvedUserId = _resolveUserId(userId);
    final settings = await _loadSettings(resolvedUserId);
    final nextTime =
        isMorning ? settings.morningBriefingAt : settings.eveningBriefingAt;

    final scheduledAt = isMorning
        ? await _resolveMorningScheduleTime(
            baseMorningAt: _nextOccurrence(nextTime),
            userId: resolvedUserId,
            settings: settings,
          )
        : _nextOccurrence(nextTime);
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

  Future<DateTime> _resolveMorningScheduleTime({
    required DateTime baseMorningAt,
    required String? userId,
    required UserSettingsModel settings,
  }) async {
    if (userId == null || userId.isEmpty) {
      return baseMorningAt;
    }

    try {
      final firstExternalEvent = await _firstExternalEventOn(
        userId: userId,
        targetDate: baseMorningAt,
      );
      if (firstExternalEvent == null || firstExternalEvent.startAt == null) {
        return baseMorningAt;
      }

      final prepStartAt = _prepStartAtFor(
        firstExternalEvent,
        settings: settings,
      );
      final adjusted = prepStartAt.subtract(_briefingLeadBeforePrepStart);
      if (adjusted.isAfter(_now()) && adjusted.isBefore(baseMorningAt)) {
        return adjusted;
      }
    } catch (error, stackTrace) {
      debugPrint('Morning briefing smart schedule skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    return baseMorningAt;
  }

  Future<EventModel?> _firstExternalEventOn({
    required String userId,
    required DateTime targetDate,
  }) async {
    final repository = _eventRepository ?? EventRepository.supabase();
    final events = await repository.listEvents(userId: userId);
    final smartPreparation = const SmartPreparationAlarmService();
    final externalEvents = events.where((event) {
      final startAt = event.startAt;
      if (startAt == null || !planflowIsSameLocalDay(startAt, targetDate)) {
        return false;
      }
      return smartPreparation.isExternalEvent(
        title: event.title,
        location: event.location,
      );
    }).toList(growable: false)
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    return externalEvents.isEmpty ? null : externalEvents.first;
  }

  DateTime _prepStartAtFor(
    EventModel event, {
    required UserSettingsModel settings,
  }) {
    final startAt = planflowLocal(event.startAt!);
    final prepMinutes = settings.prepTimeMin.clamp(5, 240).toInt();
    final travelMinutes = SmartPreparationAlarmService.defaultTravelBufferMin
        .clamp(0, 360)
        .toInt();
    final departureAt = startAt.subtract(
      Duration(
        minutes: travelMinutes +
            SmartPreparationAlarmService.externalScheduleSlackMin,
      ),
    );
    return departureAt.subtract(Duration(minutes: prepMinutes));
  }

  String? _resolveUserId(String? userId) {
    final explicitUserId = userId?.trim();
    if (explicitUserId != null && explicitUserId.isNotEmpty) {
      return explicitUserId;
    }

    try {
      final currentUserId =
          Supabase.instance.client.auth.currentSession?.user.id.trim();
      if (currentUserId != null && currentUserId.isNotEmpty) {
        return currentUserId;
      }
    } catch (e) {
      debugPrint('BriefingScheduler 사용자ID 조회 무시: $e');
    }

    return null;
  }

  bool _hasActiveSessionForServerQueries() {
    if (_eventRepository != null) {
      return true;
    }
    try {
      return Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      return false;
    }
  }

  DateTime _nextOccurrence(String timeString) {
    final parts = timeString.split(':');
    final hour = int.tryParse(parts.firstOrNull ?? '') ?? 7;
    final minute = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 30;

    final now = _now();
    var target = DateTime(now.year, now.month, now.day, hour, minute);

    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }

    return target;
  }

  DateTime _tomorrow() {
    final now = _now();
    return DateTime(now.year, now.month, now.day + 1);
  }

  DateTime? _parseDateTime(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }
}
