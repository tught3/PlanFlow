import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/analytics_service.dart';
import '../core/env.dart';
import '../widgets/voice_conversation_ad_dialog.dart';
import 'ad_service.dart';
import 'remote_config_service.dart';

/// 음성 대화 모드(voice conversation) 진입 게이트.
///
/// 1. 음성 대화 버튼 탭(또는 자동 진입 시도) 시점에 호출된다.
/// 2. 무료 사용 횟수가 남아 있으면 사용 후 즉시 진입을 허용한다.
/// 3. 무료 사용 횟수를 모두 소진한 경우 광고 다이얼로그를 띄우고,
///    사용자가 "광고 보고 시작하기"를 누르면 AdService.showForVoiceConversation을
///    호출해 광고를 표시한다.
/// 4. 광고 실패 시 RemoteConfigService.rewardAdFailurePolicy에 따라
///    - 'free_pass'  : 이 세션 한 번에 한해 무료 진입을 허용.
///    - 'retry'      : 진입 거부 (호출자가 다이얼로그/스낵바 등을 처리).
///    - 'feature_unavailable' : 진입 거부 + 기능 일시 사용 불가 메시지 표시.
///
/// 설계 메모:
/// - 무료 사용 횟수는 user_settings.voice_conversation_free_trial_used에 저장.
/// - 본 게이트는 1인 진입 결정을 책임지며, 실제 화면 전환은 caller가 [onEnterAllowed]
///   콜백으로 처리한다.
/// - 동시 호출 안전: 동일 userId + 같은 진입 흐름에서 두 번 카운트가 차는 것을 막기
///   위해 인플라이트 가드(_inFlight)로 보호한다.
class VoiceConversationAdGate {
  VoiceConversationAdGate._();

  static final VoiceConversationAdGate instance = VoiceConversationAdGate._();

  /// 테스트/QA가 게이트 결정을 주입할 수 있도록 백도어.
  /// - null이면 본 클래스의 정책 로직을 그대로 사용.
  VoiceConversationAdGateDelegate? _delegateForTest;
  set delegateForTest(VoiceConversationAdGateDelegate? value) {
    _delegateForTest = value;
  }

  /// 동일 userId에 대한 tryEnterVoiceConversation의 동시 호출을 거부.
  final Set<String> _inFlight = <String>{};

  /// 무료 사용 한도 (Remote Config). 실패 시 0 반환 (항상 광고).
  int freeTrialLimit() {
    return RemoteConfigService.voiceConversationFreeTrialCount;
  }

  /// 잔여 무료 횟수.
  /// - user_settings.voice_conversation_free_trial_used 컬럼을 읽어 계산.
  /// - Supabase 미준비 / 조회 실패 시 null 반환 (caller가 정책대로 결정).
  Future<int?> getRemainingFreeTrialCount(String userId) async {
    final delegate = _delegateForTest;
    if (delegate != null) {
      return delegate.getRemainingFreeTrialCount(userId);
    }
    return _fetchRemaining(userId);
  }

  /// 무료 횟수 1회 사용.
  /// - 성공 시 잔여 횟수 반환 (실패/미초기화 시 null).
  Future<int?> useFreeTrial(String userId) async {
    final delegate = _delegateForTest;
    if (delegate != null) {
      return delegate.useFreeTrial(userId);
    }
    return _consume(userId);
  }

  /// 잔여값이 0 이하면 광고 필요.
  bool isAdRequired(int remaining) => remaining <= 0;

  /// 실제 진입 게이트. UI 컨텍스트(context)와 진입 허용 시 호출될 콜백을 받는다.
  /// - 광고/실패 정책 분기는 이 메서드 안에서 끝낸다.
  /// - 진입이 최종 거부된 경우에는 onEnterAllowed를 호출하지 않는다.
  Future<void> tryEnterVoiceConversation({
    required BuildContext context,
    required String userId,
    required VoidCallback onEnterAllowed,
  }) async {
    if (_inFlight.contains(userId)) {
      // 이미 진행 중이면 사일런트하게 무시 (사용자 인지 불필요).
      return;
    }
    _inFlight.add(userId);
    try {
      await _runGate(
        context: context,
        userId: userId,
        onEnterAllowed: onEnterAllowed,
      );
    } finally {
      _inFlight.remove(userId);
    }
  }

  Future<void> _runGate({
    required BuildContext context,
    required String userId,
    required VoidCallback onEnterAllowed,
  }) async {
    final delegate = _delegateForTest;
    if (delegate != null) {
      await delegate.tryEnter(
        context: context,
        userId: userId,
        onEnterAllowed: onEnterAllowed,
        gate: this,
      );
      return;
    }

    // 1. 마스터 스위치 OFF → 그냥 진입.
    if (!RemoteConfigService.rewardedAdEnabled) {
      onEnterAllowed();
      return;
    }
    // 2. 음성 대화 모드 광고 비활성 → 그냥 진입.
    if (!RemoteConfigService.rewardAdVoiceConversationEnabled) {
      await AnalyticsService.logVoiceConvGateBlocked(reason: 'remote_disabled');
      onEnterAllowed();
      return;
    }

    // 3. 무료 사용 횟수 확인.
    final remaining = await getRemainingFreeTrialCount(userId);
    if (remaining != null && !isAdRequired(remaining)) {
      final used = await useFreeTrial(userId);
      final remainingAfter = used ?? (remaining - 1);
      await AnalyticsService.logVoiceConvFreeTrialUsed(
        remainingAfter: remainingAfter,
      );
      await AnalyticsService.logVoiceConvEntered(source: 'free_trial');
      onEnterAllowed();
      return;
    }

    // 4. 무료 사용 소진 → 광고 다이얼로그.
    if (!context.mounted) {
      return;
    }
    final confirmed = await showVoiceConversationAdDialog(context);
    if (!confirmed) {
      await AnalyticsService.logVoiceConvGateBlocked(reason: 'user_canceled');
      return;
    }

    // 5. 광고 표시.
    final requestId = _requestId();
    final watched = await AdService.instance.showForVoiceConversation(
      requestId: requestId,
    );
    if (watched) {
      await AnalyticsService.logVoiceConvEntered(source: 'ad_rewarded');
      onEnterAllowed();
      return;
    }

    // 6. 광고 실패 → 정책 분기.
    final policy = RemoteConfigService.rewardAdFailurePolicy;
    if (policy == 'free_pass') {
      await AnalyticsService.logVoiceConvGateBlocked(
        reason: 'ad_failed_free_pass',
      );
      await AnalyticsService.logVoiceConvEntered(source: 'ad_failed_free_pass');
      onEnterAllowed();
      return;
    }
    if (policy == 'retry') {
      await AnalyticsService.logVoiceConvGateBlocked(reason: 'ad_failed_retry');
      return;
    }
    // 'feature_unavailable' (default 폴백 포함).
    await AnalyticsService.logVoiceConvGateBlocked(
      reason: 'ad_failed_feature_unavailable',
    );
  }

  // ── Data Access (Supabase) ─────────────────────────────────────

  Future<int?> _fetchRemaining(String userId) async {
    if (!AppEnv.isSupabaseReady || !AppEnv.hasValidSupabaseConfig) {
      return null;
    }
    try {
      final client = Supabase.instance.client;
      final response = await client
          .from('user_settings')
          .select('voice_conversation_free_trial_used')
          .eq('user_id', userId)
          .maybeSingle();
      if (response == null) {
        // 신규 사용자: row 자체가 없으면 사용 0회로 간주.
        return freeTrialLimit();
      }
      final row = Map<String, dynamic>.from(response as Map);
      final used = _readUsed(row);
      final limit = freeTrialLimit();
      final remaining = limit - used;
      return remaining < 0 ? 0 : remaining;
    } catch (error, stackTrace) {
      debugPrint(
        'VoiceConversationAdGate._fetchRemaining failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<int?> _consume(String userId) async {
    if (!AppEnv.isSupabaseReady || !AppEnv.hasValidSupabaseConfig) {
      return null;
    }
    try {
      final client = Supabase.instance.client;
      final limit = freeTrialLimit();
      // 1) 현재 사용 횟수 + 잔여 한도 조회.
      final response = await client
          .from('user_settings')
          .select('voice_conversation_free_trial_used')
          .eq('user_id', userId)
          .maybeSingle();
      if (response == null) {
        // row 없음 → 1회 사용으로 신규 row 생성.
        await client.from('user_settings').upsert(
              <String, dynamic>{
                'user_id': userId,
                'voice_conversation_free_trial_used': 1,
              },
              onConflict: 'user_id',
            );
        return limit - 1 < 0 ? 0 : limit - 1;
      }
      final row = Map<String, dynamic>.from(response as Map);
      final currentUsed = _readUsed(row);
      final nextUsed = currentUsed + 1;
      // 2) 증가 반영.
      await client
          .from('user_settings')
          .update({'voice_conversation_free_trial_used': nextUsed})
          .eq('user_id', userId);
      final remaining = limit - nextUsed;
      return remaining < 0 ? 0 : remaining;
    } catch (error, stackTrace) {
      debugPrint('VoiceConversationAdGate._consume failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  int _readUsed(Map<String, dynamic> row) {
    final raw = row['voice_conversation_free_trial_used'];
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  String _requestId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = now.toRadixString(36);
    return 'voice_conv_$now-$random';
  }
}

/// 게이트 로직을 테스트/QA가 주입할 수 있도록 하는 인터페이스.
abstract class VoiceConversationAdGateDelegate {
  Future<int?> getRemainingFreeTrialCount(String userId);
  Future<int?> useFreeTrial(String userId);
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required VoidCallback onEnterAllowed,
    required VoiceConversationAdGate gate,
  });
}
