import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';

/// PlanFlow Analytics 이벤트 헬퍼.
///
/// 모든 이벤트는 static 메서드로 호출한다.
class AnalyticsService {
  AnalyticsService._();

  static FirebaseAnalytics? get _analytics {
    if (Firebase.apps.isEmpty) {
      return null;
    }
    return FirebaseAnalytics.instance;
  }

  // ── 음성 입력 퍼널 ──────────────────────────────────────────
  static Future<void> logVoiceInputStarted() =>
      _analytics?.logEvent(name: 'voice_input_started') ?? Future.value();

  static Future<void> logVoiceInputCompleted({required int textLength}) =>
      _analytics?.logEvent(
        name: 'voice_input_completed',
        parameters: <String, Object>{'text_length': textLength},
      ) ??
      Future.value();

  static Future<void> logVoiceInputFailed({required String reason}) =>
      _analytics?.logEvent(
        name: 'voice_input_failed',
        parameters: <String, Object>{'reason': reason},
      ) ??
      Future.value();

  static Future<void> logScheduleParsed({
    required bool hasTime,
    required bool hasLocation,
  }) =>
      _analytics?.logEvent(
        name: 'schedule_parsed',
        parameters: <String, Object>{
          'has_time': hasTime,
          'has_location': hasLocation,
        },
      ) ??
      Future.value();

  static Future<void> logScheduleParseFailed({required String reason}) =>
      _analytics?.logEvent(
        name: 'schedule_parse_failed',
        parameters: <String, Object>{'reason': reason},
      ) ??
      Future.value();

  static Future<void> logScheduleConfirmed() =>
      _analytics?.logEvent(name: 'schedule_confirmed') ?? Future.value();

  static Future<void> logScheduleCancelled() =>
      _analytics?.logEvent(name: 'schedule_cancelled') ?? Future.value();

  // ── 일정 관리 ────────────────────────────────────────────────
  static Future<void> logEventCreated({required String source}) =>
      _analytics?.logEvent(
        name: 'event_created',
        parameters: <String, Object>{'source': source},
      ) ??
      Future.value();

  static Future<void> logEventEdited() =>
      _analytics?.logEvent(name: 'event_edited') ?? Future.value();

  static Future<void> logEventDeleted() =>
      _analytics?.logEvent(name: 'event_deleted') ?? Future.value();

  static Future<void> logConflictDetected() =>
      _analytics?.logEvent(name: 'conflict_detected') ?? Future.value();

  // ── 브리핑 / 알림 ────────────────────────────────────────────
  static Future<void> logBriefingPlayed() =>
      _analytics?.logEvent(name: 'briefing_played') ?? Future.value();

  static Future<void> logBriefingTestPlayed({required bool isMorning}) =>
      _analytics?.logEvent(
        name: 'briefing_test_played',
        parameters: <String, Object>{'is_morning': isMorning},
      ) ??
      Future.value();

  static Future<void> logDepartureAlarmTriggered() =>
      _analytics?.logEvent(name: 'departure_alarm_triggered') ?? Future.value();

  // ── 인증 ─────────────────────────────────────────────────────
  static Future<void> logLogin({required String method}) =>
      _analytics?.logLogin(loginMethod: method) ?? Future.value();

  static Future<void> logSignUp({required String method}) =>
      _analytics?.logSignUp(signUpMethod: method) ?? Future.value();

  // ── 얼리버드 ─────────────────────────────────────────────────
  static Future<void> logEarlyBirdSubmitted() =>
      _analytics?.logEvent(name: 'early_bird_submitted') ?? Future.value();

  // ── 캘린더 동기화 ────────────────────────────────────────────
  static Future<void> logCalendarSyncCompleted({
    required String type,
    required int count,
  }) =>
      _analytics?.logEvent(
        name: 'calendar_sync_completed',
        parameters: <String, Object>{'type': type, 'count': count},
      ) ??
      Future.value();

  static Future<void> logCalendarSyncFailed({
    required String type,
    required String error,
  }) =>
      _analytics?.logEvent(
        name: 'calendar_sync_failed',
        parameters: <String, Object>{'type': type, 'error': error},
      ) ??
      Future.value();

  // ── 홈 위젯 ─────────────────────────────────────────────────
  static Future<void> logWidgetTapped() =>
      _analytics?.logEvent(name: 'widget_tapped') ?? Future.value();

  // ── 사용자 피드백 ───────────────────────────────────────────
  static Future<void> logFeedbackSubmitted({required String type}) =>
      _analytics?.logEvent(
        name: 'feedback_submitted',
        parameters: <String, Object>{'type': type},
      ) ??
      Future.value();
}
