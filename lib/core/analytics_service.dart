import 'package:flutter/foundation.dart';

/// PlanFlow Analytics 이벤트 헬퍼.
///
/// 1차 배포에서는 광고 ID 선언과 충돌하지 않도록 외부 Analytics SDK를
/// 포함하지 않는다. 호출부 호환을 위해 이벤트 메서드는 유지하되 no-op 처리한다.
class AnalyticsService {
  AnalyticsService._();

  static Future<void> _logEvent(
    String name, {
    Map<String, Object?>? parameters,
  }) {
    if (kDebugMode) {
      debugPrint('Analytics event skipped ($name): analytics disabled');
    }
    return Future.value();
  }

  // ── 음성 입력 퍼널 ──────────────────────────────────────────
  static Future<void> logVoiceInputStarted() =>
      _logEvent('voice_input_started');

  static Future<void> logVoiceInputCompleted({required int textLength}) =>
      _logEvent(
        'voice_input_completed',
        parameters: <String, Object>{'text_length': textLength},
      );

  static Future<void> logVoiceInputFailed({required String reason}) =>
      _logEvent(
        'voice_input_failed',
        parameters: <String, Object>{'reason': reason},
      );

  static Future<void> logScheduleParsed({
    required bool hasTime,
    required bool hasLocation,
  }) =>
      _logEvent(
        'schedule_parsed',
        parameters: <String, Object>{
          'has_time': hasTime,
          'has_location': hasLocation,
        },
      );

  static Future<void> logScheduleParseFailed({required String reason}) =>
      _logEvent(
        'schedule_parse_failed',
        parameters: <String, Object>{'reason': reason},
      );

  static Future<void> logScheduleConfirmed() => _logEvent('schedule_confirmed');

  static Future<void> logScheduleCancelled() => _logEvent('schedule_cancelled');

  // ── 일정 관리 ────────────────────────────────────────────────
  static Future<void> logEventCreated({required String source}) => _logEvent(
        'event_created',
        parameters: <String, Object>{'source': source},
      );

  static Future<void> logEventEdited() => _logEvent('event_edited');

  static Future<void> logEventDeleted() => _logEvent('event_deleted');

  static Future<void> logConflictDetected() => _logEvent('conflict_detected');

  // ── 브리핑 / 알림 ────────────────────────────────────────────
  static Future<void> logBriefingPlayed() => _logEvent('briefing_played');

  static Future<void> logBriefingTestPlayed({required bool isMorning}) =>
      _logEvent(
        'briefing_test_played',
        parameters: <String, Object>{'is_morning': isMorning},
      );

  static Future<void> logDepartureAlarmTriggered() =>
      _logEvent('departure_alarm_triggered');

  // ── 인증 ─────────────────────────────────────────────────────
  static Future<void> logLogin({required String method}) => _logEvent(
        'login',
        parameters: <String, Object>{'method': method},
      );

  static Future<void> logSignUp({required String method}) => _logEvent(
        'sign_up',
        parameters: <String, Object>{'method': method},
      );

  // ── 얼리버드 ─────────────────────────────────────────────────
  static Future<void> logEarlyBirdSubmitted() =>
      _logEvent('early_bird_submitted');

  // ── 캘린더 동기화 ────────────────────────────────────────────
  static Future<void> logCalendarSyncCompleted({
    required String type,
    required int count,
  }) =>
      _logEvent(
        'calendar_sync_completed',
        parameters: <String, Object>{'type': type, 'count': count},
      );

  static Future<void> logCalendarSyncFailed({
    required String type,
    required String error,
  }) =>
      _logEvent(
        'calendar_sync_failed',
        parameters: <String, Object>{'type': type, 'error': error},
      );

  // ── 홈 위젯 ─────────────────────────────────────────────────
  static Future<void> logWidgetTapped() => _logEvent('widget_tapped');

  // ── 사용자 피드백 ───────────────────────────────────────────
  static Future<void> logFeedbackSubmitted({required String type}) => _logEvent(
        'feedback_submitted',
        parameters: <String, Object>{'type': type},
      );
}
