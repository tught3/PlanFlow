import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/analytics_service.dart';
import '../core/env.dart';
import '../widgets/voice_conversation_ad_dialog.dart';
import 'ad_consent_service.dart';
import 'ad_service.dart';
import 'remote_config_service.dart';
import 'voice_conversation_entitlement.dart';

/// 음성 대화 모드(voice conversation) 진입 게이트.
///
/// 1. 음성 대화 버튼 탭(또는 자동 진입 시도) 시점에 호출된다.
/// 2. 최초 누적 무료 3회가 남아 있으면 즉시 진입을 허용한다.
/// 3. 무료 사용 횟수를 모두 소진한 경우 광고 다이얼로그를 띄우고,
///    사용자가 "광고 보고 시작하기"를 누르면 AdService.showForVoiceConversation을
///    호출해 광고를 표시한다.
/// 4. 광고 취소·실패·요청 불가·기능 비활성은 모두 진입을 거부한다.
///
/// 설계 메모(2026-08 개편):
/// - 이 게이트는 더 이상 진입 시점에 무료 사용 횟수를 **소비하지 않는다**
///   (부작용 없는 [VoiceConversationEntitlementService.peek]만 사용).
///   실제 소비는 화면에서 첫 명령이 처리되기 시작할 때
///   [VoiceConversationEntitlementService.consume]으로 이관됐다.
/// - 진입이 허용되면 [VoiceConversationEntryGrant]를 만들어
///   [onEnterAllowed]로 전달한다. grant에는 이 진입을 유일하게 식별하는
///   `sessionId`(추후 consume 호출 시 멱등 키로 사용)와 승인 근거([EntitlementSource])가
///   담긴다.
/// - peek() 실패(RPC 오류 등)는 "무료 잔여를 알 수 없음"이므로,
///   광고 우회도 허용하지 않고 재시도 안내와 함께 fail-closed 처리한다.
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

  /// 테스트에서 재시도 순서를 관측하기 위한 제한된 seam이다. null이면
  /// 항상 실제 UMP 서비스를 호출하므로 운영 계약에는 영향을 주지 않는다.
  @visibleForTesting
  Future<void> Function()? retryAfterUserActionForTest;

  /// 테스트에서 live consent 재평가 결과를 주입하기 위한 제한된 seam이다.
  @visibleForTesting
  Future<bool> Function()? canRequestAdsLiveForTest;

  /// 동일 userId에 대한 tryEnterVoiceConversation의 동시 호출을 거부.
  final Set<String> _inFlight = <String>{};

  @visibleForTesting
  VoiceConversationGateDenialReason? lastDenialReason;

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
  /// - onEnterAllowed는 이 진입을 승인한 [VoiceConversationEntryGrant]를
  ///   받는다. 이 게이트 자체는 무료 횟수를 소비하지 않는다(peek만 사용) —
  ///   실제 소비는 grant.sessionId로 [VoiceConversationEntitlementService.consume]을
  ///   호출하는 화면 쪽 책임이다.
  Future<void> tryEnterVoiceConversation({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    void Function(VoiceConversationGateDenialReason reason)? onDenied,
  }) async {
    lastDenialReason = null;
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
        onDenied: onDenied,
      );
    } finally {
      _inFlight.remove(userId);
    }
  }

  Future<void> _runGate({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    void Function(VoiceConversationGateDenialReason reason)? onDenied,
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

    // 1. 무료 잔여 횟수 조회(부작용 없음). 최초 3회는 광고 SDK 상태와
    // 관계없이 사용할 수 있어야 하므로 광고 요청 가능 여부보다 먼저 확인한다.
    final peek = await VoiceConversationEntitlementService.instance.peek();
    if (peek == null) {
      // 잔여를 확인하지 못한 상태에서는 광고로 우회하지 않는다.
      // 서버 상태를 확인할 수 있을 때만 무료/광고 분기를 결정한다.
      await AnalyticsService.logVoiceConvAdRequired();
      await AnalyticsService.logVoiceConvGateBlocked(
        reason: 'entitlement_unavailable',
      );
      _deny(
        VoiceConversationGateDenialReason.entitlementUnavailable,
        onDenied,
      );
      return;
    } else if (!peek.requiresAd) {
      // 무료 잔여 있음 → 즉시 진입(소비는 화면 쪽에서 처리).
      final source = EntitlementSource.initialFree;
      await AnalyticsService.logVoiceConvEntered(source: 'initial_free');
      onEnterAllowed(
        _grant(
          source,
          initialRemainingAtGate: peek.initialRemaining,
          dailyRemainingAtGate: peek.dailyRemaining,
        ),
      );
      return;
    } else {
      await AnalyticsService.logVoiceConvAdRequired();
    }

    // 2. 무료 사용 소진 후의 광고 진단/재시도는 한 상태형 다이얼로그에서
    // 진행한다. 재시도는 이 클로저를 다시 호출하므로 매번 새 requestId와
    // AdService outcome API를 사용하며, AdService의 single-flight/30초
    // throttle은 그대로 보존된다.
    if (!context.mounted) {
      _deny(VoiceConversationGateDenialReason.userCanceled, onDenied);
      return;
    }
    VoiceConversationGateDenialReason? latestDenial;
    VoiceConversationEntryGrant? freePassGrant;
    final dialogResult = await showVoiceConversationAdDialog(
      context,
      initialCompletedStages: const <VoiceConversationAdDialogStage>{
        VoiceConversationAdDialogStage.entitlement,
      },
      onStartAttempt: (reportProgress, attemptNumber) => _runAdAttempt(
        peek: peek,
        reportProgress: reportProgress,
        isUserRetry: attemptNumber > 1,
        onDenied: (reason) => latestDenial = reason,
        onFreePass: (grant) => freePassGrant = grant,
      ),
    );
    if (dialogResult.isRewarded) {
      await AnalyticsService.logVoiceConvAdCompleted();
      await AnalyticsService.logVoiceConvEntered(source: 'ad_rewarded');
      onEnterAllowed(
        _grant(
          EntitlementSource.adRewarded,
          initialRemainingAtGate: peek.initialRemaining,
          dailyRemainingAtGate: peek.dailyRemaining,
        ),
      );
      return;
    }
    if (dialogResult.isAllowed && freePassGrant != null) {
      await AnalyticsService.logVoiceConvEntered(
        source: 'ad_failed_free_pass',
      );
      onEnterAllowed(freePassGrant!);
      return;
    }
    final denial =
        latestDenial ?? VoiceConversationGateDenialReason.userCanceled;
    if (latestDenial == null) {
      await AnalyticsService.logVoiceConvGateBlocked(reason: 'user_canceled');
    }
    _deny(denial, onDenied);
  }

  Future<VoiceConversationAdDialogAttemptResult> _runAdAttempt({
    required VoiceConversationEntitlementPeek peek,
    required VoiceConversationAdDialogProgress reportProgress,
    required bool isUserRetry,
    required void Function(VoiceConversationGateDenialReason reason) onDenied,
    required void Function(VoiceConversationEntryGrant grant) onFreePass,
  }) async {
    reportProgress(VoiceConversationAdDialogStage.remoteConfig);
    if (!RemoteConfigService.rewardedAdEnabled) {
      if (!RemoteConfigService.lastFetchSucceeded) {
        final retrySucceeded = await RemoteConfigService.retryFetchIfFailed();
        if (retrySucceeded && !RemoteConfigService.rewardedAdEnabled) {
          await AnalyticsService.logVoiceConvGateBlocked(
            reason: 'rewarded_disabled_after_retry',
          );
          return _attemptDenied(
            VoiceConversationGateDenialReason.rewardedDisabled,
            onDenied,
          );
        }
      } else {
        await AnalyticsService.logVoiceConvGateBlocked(
          reason: 'rewarded_disabled',
        );
        return _attemptDenied(
          VoiceConversationGateDenialReason.rewardedDisabled,
          onDenied,
        );
      }
    }
    if (!RemoteConfigService.rewardAdVoiceConversationEnabled) {
      await AnalyticsService.logVoiceConvGateBlocked(reason: 'remote_disabled');
      return _attemptDenied(
        VoiceConversationGateDenialReason.remoteDisabled,
        onDenied,
      );
    }

    reportProgress(VoiceConversationAdDialogStage.consent);
    if (isUserRetry) {
      // 재시도 버튼은 명시적 사용자 액션이다. UMP 상태를 새로 초기화한 뒤
      // live consent를 다시 읽어야 이전 거부/플랫폼 오류 캐시를 우회하지
      // 않으면서도 정책을 fail-closed로 재평가할 수 있다.
      final retry = retryAfterUserActionForTest ??
          AdConsentService.instance.retryAfterUserAction;
      await retry();
    }
    final canRequestAds = canRequestAdsLiveForTest ??
        (() => AdConsentService.instance.canRequestAdsLive);
    final adsOk = await canRequestAds();
    if (!adsOk) {
      await AnalyticsService.logVoiceConvGateBlocked(reason: 'ads_unavailable');
      return _attemptDenied(
        VoiceConversationGateDenialReason.adsUnavailable,
        onDenied,
      );
    }

    reportProgress(VoiceConversationAdDialogStage.initializing);
    final outcome =
        await AdService.instance.showForVoiceConversationWithOutcome(
      requestId: _requestId(),
      onProgress: (stage) {
        switch (stage) {
          case 'loading':
            reportProgress(VoiceConversationAdDialogStage.loading);
          case 'shown':
            reportProgress(VoiceConversationAdDialogStage.showing);
          case 'completed':
            reportProgress(VoiceConversationAdDialogStage.rewardVerified);
          case 'failed':
          case 'cancelled':
            break;
        }
      },
    );
    if (outcome.isRewarded) {
      return const VoiceConversationAdDialogAttemptResult.rewarded();
    }

    // 기존의 명시적 RC 예외만 그대로 보존한다. 이것은 다이얼로그/재시도가
    // 새 우회 경로를 만든 것이 아니라 기존 gate 정책을 그대로 적용한 것이다.
    final freePassGrant = maybeFreePassGrant(
      initialRemainingAtGate: peek.initialRemaining,
      dailyRemainingAtGate: peek.dailyRemaining,
    );
    if (freePassGrant != null) {
      onFreePass(freePassGrant);
      return const VoiceConversationAdDialogAttemptResult.freePass();
    }

    await AnalyticsService.logVoiceConvGateBlocked(reason: 'ad_failed_retry');
    onDenied(VoiceConversationGateDenialReason.adFailed);
    return VoiceConversationAdDialogAttemptResult.failure(
      diagnosticCode: voiceConversationGateDenialCode(
        VoiceConversationGateDenialReason.adFailed,
      ),
      diagnosticDetail: outcome.debugReason,
      terminalStage: voiceConversationAdTerminalStageForOutcome(outcome.kind),
    );
  }

  VoiceConversationAdDialogAttemptResult _attemptDenied(
    VoiceConversationGateDenialReason reason,
    void Function(VoiceConversationGateDenialReason reason) onDenied,
  ) {
    onDenied(reason);
    return VoiceConversationAdDialogAttemptResult.failure(
      diagnosticCode: voiceConversationGateDenialCode(reason),
      diagnosticDetail: voiceConversationGateDenialMessage(reason),
    );
  }

  /// UMP/광고 SDK 없이 재시도 순서와 fail-closed consent 거부를 검증한다.
  @visibleForTesting
  Future<VoiceConversationAdDialogAttemptResult> runAdAttemptForTest({
    required VoiceConversationEntitlementPeek peek,
    required int attemptNumber,
  }) {
    return _runAdAttempt(
      peek: peek,
      reportProgress: (_) {},
      isUserRetry: attemptNumber > 1,
      onDenied: (_) {},
      onFreePass: (_) {},
    );
  }

  /// RemoteConfigService.rewardAdFailurePolicy가 명시적으로 'free_pass'로
  /// 설정된 경우에만 무료 진입 grant를 만들어 반환한다(그 외에는 null).
  ///
  /// `_runGate`의 광고 실패 분기가 실제로 사용하는 로직을 그대로 노출한
  /// 것이다 — Firebase/AdService 의존 없이 정책 분기를 직접 단위 테스트할
  /// 수 있도록 `@visibleForTesting`으로 공개한다.
  @visibleForTesting
  VoiceConversationEntryGrant? maybeFreePassGrant({
    required int initialRemainingAtGate,
    required int dailyRemainingAtGate,
  }) {
    if (!_isFreePassPolicy()) {
      return null;
    }
    return _grant(
      EntitlementSource.adFailedFreePass,
      initialRemainingAtGate: initialRemainingAtGate,
      dailyRemainingAtGate: dailyRemainingAtGate,
    );
  }

  /// RemoteConfigService.rewardAdFailurePolicy가 명시적으로 'free_pass'로
  /// 설정됐는지 확인한다(대소문자 무관). 기본값('retry') 또는 그 외 값은
  /// false — fail-closed 유지.
  bool _isFreePassPolicy() {
    return RemoteConfigService.rewardAdFailurePolicy.trim().toLowerCase() ==
        'free_pass';
  }

  void _deny(
    VoiceConversationGateDenialReason reason,
    void Function(VoiceConversationGateDenialReason reason)? callback,
  ) {
    lastDenialReason = reason;
    callback?.call(reason);
  }

  VoiceConversationEntryGrant _grant(
    EntitlementSource source, {
    int initialRemainingAtGate = 0,
    int dailyRemainingAtGate = 0,
  }) {
    return VoiceConversationEntryGrant(
      sessionId: VoiceConversationSessionIdGenerator.next(),
      source: source,
      initialRemainingAtGate: initialRemainingAtGate,
      dailyRemainingAtGate: dailyRemainingAtGate,
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
      debugPrint('VoiceConversationAdGate._fetchRemaining failed: $error');
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
        await client.from('user_settings').upsert(<String, dynamic>{
          'user_id': userId,
          'voice_conversation_free_trial_used': 1,
        }, onConflict: 'user_id');
        return limit - 1 < 0 ? 0 : limit - 1;
      }
      final row = Map<String, dynamic>.from(response as Map);
      final currentUsed = _readUsed(row);
      final nextUsed = currentUsed + 1;
      // 2) 증가 반영.
      await client
          .from('user_settings')
          .update({'voice_conversation_free_trial_used': nextUsed}).eq(
              'user_id', userId);
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

enum VoiceConversationGateDenialReason {
  inFlight,
  entitlementUnavailable,
  rewardedDisabled,
  remoteDisabled,
  adsUnavailable,
  userCanceled,
  adFailed,
}

/// 광고 outcome이 다이얼로그에 남겨야 할 terminal 단계.
@visibleForTesting
VoiceConversationAdDialogStage voiceConversationAdTerminalStageForOutcome(
  VoiceConversationAdOutcomeKind kind,
) =>
    kind == VoiceConversationAdOutcomeKind.dismissedWithoutReward
        ? VoiceConversationAdDialogStage.cancelled
        : VoiceConversationAdDialogStage.failed;

String voiceConversationGateDenialMessage(
    VoiceConversationGateDenialReason reason) {
  switch (reason) {
    case VoiceConversationGateDenialReason.inFlight:
      return 'AI일정대화를 여는 중이에요. 잠시만 기다려 주세요.';
    case VoiceConversationGateDenialReason.entitlementUnavailable:
      return '무료 사용 횟수를 확인하지 못했어요. 잠시 후 다시 시도해 주세요. (E-GATE0)';
    case VoiceConversationGateDenialReason.rewardedDisabled:
      return 'AI일정대화 광고 설정이 꺼져 있어요. 운영자에게 문의해 주세요. (E-RC1)';
    case VoiceConversationGateDenialReason.remoteDisabled:
      return 'AI일정대화 광고 설정이 꺼져 있어요. 운영자에게 문의해 주세요. (E-RC2)';
    case VoiceConversationGateDenialReason.adsUnavailable:
      return '광고를 불러올 수 없어 AI일정대화를 시작하지 못했어요. 잠시 후 다시 시도해 주세요. (E-ADS0)';
    case VoiceConversationGateDenialReason.userCanceled:
      return '광고를 취소해 AI일정대화를 시작하지 않았어요.';
    case VoiceConversationGateDenialReason.adFailed:
      return '광고가 완료되지 않아 AI일정대화를 시작하지 못했어요. 다시 시도해 주세요.';
  }
}

/// [VoiceConversationGateDenialReason]별 진단 코드를 반환한다.
///
/// 운영자가 문의 접수 시 어떤 원인으로 진입이 거부됐는지 즉시 파악할 수
/// 있도록, analytics 로그 부착용으로 사용된다. 코드는 [voiceConversationGateDenialMessage]에
/// 표시되는 suffix(일부 reason)와 항상 일치해야 한다.
@visibleForTesting
String voiceConversationGateDenialCode(
    VoiceConversationGateDenialReason reason) {
  switch (reason) {
    case VoiceConversationGateDenialReason.inFlight:
      return 'E-GATE1';
    case VoiceConversationGateDenialReason.entitlementUnavailable:
      return 'E-GATE0';
    case VoiceConversationGateDenialReason.rewardedDisabled:
      return 'E-RC1';
    case VoiceConversationGateDenialReason.remoteDisabled:
      return 'E-RC2';
    case VoiceConversationGateDenialReason.adsUnavailable:
      return 'E-ADS0';
    case VoiceConversationGateDenialReason.userCanceled:
      return 'E-CANCEL';
    case VoiceConversationGateDenialReason.adFailed:
      return 'E-ADFAIL';
  }
}

/// 게이트 로직을 테스트/QA가 주입할 수 있도록 하는 인터페이스.
abstract class VoiceConversationAdGateDelegate {
  Future<int?> getRemainingFreeTrialCount(String userId);
  Future<int?> useFreeTrial(String userId);
  Future<void> tryEnter({
    required BuildContext context,
    required String userId,
    required void Function(VoiceConversationEntryGrant grant) onEnterAllowed,
    required VoiceConversationAdGate gate,
  });
}
