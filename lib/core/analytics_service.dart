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

  // ── 리워드 광고 (GPT 일정 파싱) ───────────────────────────────
  // 개인정보/일정 본문은 절대 포함하지 않음. 오류 사유도 카테고리화된 값만.
  static Future<void> logAdPromptShown() => _logEvent('ad_prompt_shown');

  static Future<void> logAdOptedIn() => _logEvent('ad_opted_in');

  static Future<void> logAdCancelled() => _logEvent('ad_cancelled');

  static Future<void> logAdLoadSuccess({required String requestId}) => _logEvent(
        'ad_load_success',
        parameters: <String, Object>{'request_id': requestId},
      );

  static Future<void> logAdLoadFailed({
    required String reason,
    required String requestId,
  }) =>
      _logEvent(
        'ad_load_failed',
        parameters: <String, Object>{
          'reason': reason,
          'request_id': requestId,
        },
      );

  static Future<void> logAdStarted({required String requestId}) => _logEvent(
        'ad_started',
        parameters: <String, Object>{'request_id': requestId},
      );

  static Future<void> logAdCompleted({required String requestId}) => _logEvent(
        'ad_completed',
        parameters: <String, Object>{'request_id': requestId},
      );

  static Future<void> logAdRewardGranted({required String requestId}) =>
      _logEvent(
        'ad_reward_granted',
        parameters: <String, Object>{'request_id': requestId},
      );

  static Future<void> logAdFeatureSuccess({required String requestId}) =>
      _logEvent(
        'ad_feature_success',
        parameters: <String, Object>{'request_id': requestId},
      );

  static Future<void> logAdFeatureFailed({
    required String reason,
    required String requestId,
  }) =>
      _logEvent(
        'ad_feature_failed',
        parameters: <String, Object>{
          'reason': reason,
          'request_id': requestId,
        },
      );

  static Future<void> logAdConversionRate({
    required int promptsShown,
    required int optedIn,
  }) =>
      _logEvent(
        'ad_conversion_rate',
        parameters: <String, Object>{
          'prompts': promptsShown,
          'opt_ins': optedIn,
        },
      );

  // ── 음성 대화 모드 (Reward Ad) ─────────────────────────────────
  // 개인정보/일정 본문/음성 텍스트는 절대 포함하지 않는다.
  // 파라미터는 count/int/request_id/reason(카테고리화된 문자열)만 허용.
  static Future<void> logVoiceConvButtonTap() =>
      _logEvent('voice_conv_button_tap');

  static Future<void> logVoiceConvFreeTrialUsed({required int remainingAfter}) =>
      _logEvent(
        'voice_conv_free_trial_used',
        parameters: <String, Object>{'remaining_after': remainingAfter},
      );

  static Future<void> logVoiceConvAdShown({required String requestId}) =>
      _logEvent(
        'voice_conv_ad_shown',
        parameters: <String, Object>{'request_id': requestId},
      );

  static Future<void> logVoiceConvAdRewardEarned({required String requestId}) =>
      _logEvent(
        'voice_conv_ad_reward_earned',
        parameters: <String, Object>{'request_id': requestId},
      );

  static Future<void> logVoiceConvAdFailed({
    required String reason,
    required String requestId,
  }) =>
      _logEvent(
        'voice_conv_ad_failed',
        parameters: <String, Object>{
          'reason': reason,
          'request_id': requestId,
        },
      );

  static Future<void> logVoiceConvGateBlocked({required String reason}) =>
      _logEvent(
        'voice_conv_gate_blocked',
        parameters: <String, Object>{'reason': reason},
      );

  static Future<void> logVoiceConvEntered({required String source}) =>
      _logEvent(
        'voice_conv_entered',
        parameters: <String, Object>{'source': source},
      );

  // ── 음성 대화 모드 진입/소비 퍼널 (신규) ─────────────────────────
  // 자유텍스트(발화 전문/STT/일정 제목/장소/메모/query 원문/이메일/그룹명)는
  // 절대 파라미터로 받지 않는다. int 또는 제한된 enum만 허용한다.
  static Future<void> logVoiceConvEntryDirect() =>
      _logEvent('voice_conversation_entry_direct');

  static Future<void> logVoiceConvEntryQuery() =>
      _logEvent('voice_conversation_entry_query');

  static Future<void> logVoiceConvEntryDeeplink() =>
      _logEvent('voice_conversation_entry_deeplink');

  static Future<void> logVoiceConvInitialFreeUsed({
    required int remainingAfter,
  }) =>
      _logEvent(
        'voice_conversation_initial_free_used',
        parameters: <String, Object>{'remaining_after': remainingAfter},
      );

  static Future<void> logVoiceConvDailyFreeUsed({
    required int remainingAfter,
  }) =>
      _logEvent(
        'voice_conversation_daily_free_used',
        parameters: <String, Object>{'remaining_after': remainingAfter},
      );

  static Future<void> logVoiceConvAdRequired() =>
      _logEvent('voice_conversation_ad_required');

  static Future<void> logVoiceConvAdCompleted() =>
      _logEvent('voice_conversation_ad_completed');

  static Future<void> logVoiceConvSessionStarted({
    required VoiceConvSessionSource source,
  }) =>
      _logEvent(
        'voice_conversation_session_started',
        parameters: <String, Object>{'source': source.wireValue},
      );

  static Future<void> logVoiceConvSessionAbandonedBeforeUse() =>
      _logEvent('voice_conversation_session_abandoned_before_use');
}

/// [AnalyticsService.logVoiceConvSessionStarted]의 소비 출처를 제한된
/// 값으로만 표현하기 위한 enum. 자유텍스트 문자열을 막기 위해 도입.
enum VoiceConvSessionSource {
  initialFree('initial_free'),
  dailyFree('daily_free'),
  adRewarded('ad_rewarded');

  const VoiceConvSessionSource(this.wireValue);

  /// Analytics 이벤트 파라미터로 전송되는 고정 문자열 값.
  final String wireValue;
}
