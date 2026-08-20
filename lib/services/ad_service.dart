import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../core/analytics_service.dart';
import 'ad_consent_service.dart';
import 'ad_reward_state.dart';
import 'remote_config_service.dart';

/// AdMob 공식 광고 단위 ID 형식(`ca-app-pub-XXXXXXXXXXXXXXXX/YYYYYYYYYY`)인지 검증.
/// release 분기가 kDebugMode 때문에 단위 테스트에서 도달 불가하므로,
/// 이 검증 로직을 순수 함수로 분리해 테스트 가능하게 한다.
final RegExp _rewardedAdUnitIdPattern = RegExp(r'^ca-app-pub-\d{16}/\d{1,20}$');

bool isValidRewardedAdUnitId(String value) =>
    _rewardedAdUnitIdPattern.hasMatch(value);

/// Stable outcome categories for a voice-conversation rewarded-ad attempt.
enum VoiceConversationAdOutcomeKind {
  disabled,
  initializationUnavailable,
  unitIdInvalid,
  loadThrottled,
  loadFailed,
  showFailed,
  dismissedWithoutReward,
  rewarded,
}

class VoiceConversationAdOutcome {
  const VoiceConversationAdOutcome(
    this.kind, {
    this.loadErrorCode,
    this.loadErrorDomain,
    this.loadErrorMessage,
  });

  final VoiceConversationAdOutcomeKind kind;
  final int? loadErrorCode;
  final String? loadErrorDomain;
  final String? loadErrorMessage;

  bool get isRewarded => kind == VoiceConversationAdOutcomeKind.rewarded;

  String get analyticsReason {
    switch (kind) {
      case VoiceConversationAdOutcomeKind.disabled:
        return 'disabled';
      case VoiceConversationAdOutcomeKind.initializationUnavailable:
        return 'initialization_unavailable';
      case VoiceConversationAdOutcomeKind.unitIdInvalid:
        return 'unit_id_invalid';
      case VoiceConversationAdOutcomeKind.loadThrottled:
        return 'load_throttled';
      case VoiceConversationAdOutcomeKind.loadFailed:
        return 'load_failed';
      case VoiceConversationAdOutcomeKind.showFailed:
        return 'show_failed';
      case VoiceConversationAdOutcomeKind.dismissedWithoutReward:
        return 'dismissed_without_reward';
      case VoiceConversationAdOutcomeKind.rewarded:
        return 'rewarded';
    }
  }

  String get debugReason {
    final details = <String>['reason=$analyticsReason'];
    if (loadErrorCode != null) details.add('code=$loadErrorCode');
    if (loadErrorDomain != null) {
      details.add('domain=${_safeAdDetail(loadErrorDomain!)}');
    }
    if (loadErrorMessage != null) {
      details.add('message=${_safeAdDetail(loadErrorMessage!)}');
    }
    return details.join(',');
  }
}

/// Full-screen rewarded-ad display terminal state.
///
/// 광고가 닫혔지만 보상이 없었던 경우와 SDK가 전체 화면을 표시하지 못한
/// 경우를 분리해 voice conversation의 진단 UI가 정확한 outcome을 표시한다.
enum RewardedAdShowOutcome {
  rewarded,
  dismissedWithoutReward,
  showFailed,
}

extension on RewardedAdShowOutcome {
  bool get isRewarded => this == RewardedAdShowOutcome.rewarded;
}

String _safeAdDetail(String value) {
  final sanitized = value.replaceAll(RegExp(r'[\r\n]'), ' ').trim();
  return sanitized.length <= 120
      ? sanitized
      : '${sanitized.substring(0, 120)}…';
}

enum _AdLoadOutcomeKind { loaded, throttled, failed }

class _AdLoadOutcome {
  const _AdLoadOutcome(this.kind, {this.code, this.domain, this.message});
  final _AdLoadOutcomeKind kind;
  final int? code;
  final String? domain;
  final String? message;
}

// Legacy callback-order experiment removed: dismissal is a terminal event;
// reward is granted only when the SDK invokes onUserEarnedReward.
// Coordinates the two callbacks emitted by a rewarded ad.
///
/// Some SDK versions deliver `onAdDismissedFullScreenContent` just before
/// `onUserEarnedReward`.  Dismissal therefore gets a short grace period rather
/// than immediately being treated as a failed reward.  This small, SDK-free
/// coordinator is intentionally public so the ordering contract can be tested
/// deterministically without constructing a platform [RewardedAd].
class RewardedAdLifecycleCoordinator {
  RewardedAdLifecycleCoordinator({
    this.gracePeriod = const Duration(milliseconds: 500),
  });

  final Duration gracePeriod;
  final Completer<bool> _result = Completer<bool>();
  Timer? _graceTimer;
  bool _rewardEarned = false;
  bool _failedToShow = false;

  Future<bool> get result => _result.future;
  bool get isCompleted => _result.isCompleted;

  void onUserEarnedReward() {
    _rewardEarned = true;
    if (_graceTimer != null) {
      _finish(true);
    }
  }

  void onAdDismissed() {
    if (_result.isCompleted) return;
    if (_rewardEarned) {
      _finish(true);
      return;
    }
    _graceTimer ??= Timer(gracePeriod, () => _finish(false));
  }

  void onAdFailedToShow() {
    _failedToShow = true;
    _finish(false);
  }

  bool get failedToShow => _failedToShow;

  /// Completes an abandoned lifecycle and releases its timer.
  void dispose() {
    _graceTimer?.cancel();
    _graceTimer = null;
    if (!_result.isCompleted) {
      _result.complete(false);
    }
  }

  void _finish(bool value) {
    if (_result.isCompleted) return;
    _graceTimer?.cancel();
    _graceTimer = null;
    _result.complete(value);
  }
}

@visibleForTesting
Future<bool> runRewardedAdLifecycle({
  required Future<void> Function({
    required void Function() onUserEarnedReward,
    required void Function() onAdDismissed,
    required void Function() onAdFailedToShow,
  }) drive,
  Duration gracePeriod = const Duration(milliseconds: 500),
}) async {
  return (await runRewardedAdLifecycleWithOutcome(
    drive: drive,
    gracePeriod: gracePeriod,
  ))
      .isRewarded;
}

/// [runRewardedAdLifecycle]과 같은 콜백 순서를 실행하되, SDK 표시 실패와
/// 사용자 닫힘을 구분한다. 플랫폼 SDK 없이 결과 분류를 집중 테스트한다.
@visibleForTesting
Future<RewardedAdShowOutcome> runRewardedAdLifecycleWithOutcome({
  required Future<void> Function({
    required void Function() onUserEarnedReward,
    required void Function() onAdDismissed,
    required void Function() onAdFailedToShow,
  }) drive,
  Duration gracePeriod = const Duration(milliseconds: 500),
}) async {
  final lifecycle = RewardedAdLifecycleCoordinator(gracePeriod: gracePeriod);
  try {
    await drive(
      onUserEarnedReward: lifecycle.onUserEarnedReward,
      onAdDismissed: lifecycle.onAdDismissed,
      onAdFailedToShow: lifecycle.onAdFailedToShow,
    );
    final rewarded = await lifecycle.result;
    if (rewarded) return RewardedAdShowOutcome.rewarded;
    return lifecycle.failedToShow
        ? RewardedAdShowOutcome.showFailed
        : RewardedAdShowOutcome.dismissedWithoutReward;
  } finally {
    lifecycle.dispose();
  }
}

/// [useTestUnit]을 파라미터로 주입받아 kDebugMode에 직접 의존하지 않는
/// 순수 버전의 광고 단위 ID 해석 함수. 단위 테스트가 release 분기를
/// 검증할 수 있도록 [AdService._resolveAdUnitId]에서 위임 호출한다.
String resolveRewardedAdUnitIdFor({
  required bool useTestUnit,
  required String configured,
}) {
  if (useTestUnit) {
    return 'ca-app-pub-3940256099942544/5224354917'; // Google test rewarded ad unit
  }
  final trimmed = configured.trim();
  if (!isValidRewardedAdUnitId(trimmed)) return '';
  return trimmed;
}

/// 리워드 광고(AdMob) 서비스.
///
/// 정책:
/// - 배너·네이티브·인터스티셜·자동재생 강제 광고는 사용하지 않는다.
/// - 사용자가 [showForParseSchedule]/[showForVoiceConversation]를 명시적으로 호출했을 때만
///   광고를 띄운다.
/// - 광고 미완료(로드 실패, 재고 없음, 백그라운드 이동)는 보상 미부여.
/// - 보상 부여(grant)는 [AdRewardState]에 영속 저장 → 앱 종료 후 복구 가능.
/// - 마스터 스위치 OFF면 어떤 호출에서도 광고를 띄우지 않고 즉시 false 반환.
class AdService {
  AdService({
    AdRewardState? rewardState,
    AdConsentService? consentService,
    Future<Object?> Function()? dynamicAdsInitializer,
  })  : _rewardState = rewardState ?? AdRewardState.instance,
        _consentService = consentService ?? AdConsentService.instance,
        _dynamicAdsInitializer = dynamicAdsInitializer;

  // 기본 ID는 테스트 ID(공식 제공). 운영 ID는 Remote Config.

  // RewardedAd 로드 throttle. 너무 잦은 load 호출 방지 (AdMob quota 보호).
  static const Duration _kReloadThrottle = Duration(seconds: 30);

  static final AdService instance = AdService();

  bool _initialized = false;
  bool _showingAd = false;
  int _promptShown = 0;
  int _optIn = 0;

  // RewardedAd SDK 호출에 필요한 상태.
  RewardedAd? _rewardedAd;
  bool _loadingAd = false;
  DateTime? _lastLoadAt;
  int? _lastLoadErrorCode;
  String? _lastLoadErrorDomain;
  String? _lastLoadErrorMessage;

  final AdRewardState _rewardState;
  final AdConsentService _consentService;
  final Future<Object?> Function()? _dynamicAdsInitializer;

  bool get isInitialized => _initialized;
  bool get isShowing => _showingAd;

  /// 사용량 추적 (옵션 전환율 진단).
  int get promptShownCount => _promptShown;
  int get optInCount => _optIn;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    if (!RemoteConfigService.rewardedAdEnabled) {
      // 진단 신호 (M1, 이슈 A). lastFetchSucceeded로 OFF 사유를 구분한다:
      //  - false: RC fetch 실패 → 컴파일타임 기본값(false)을 읽은 것으로
      //    추정. RC fetch가 정착한 뒤 initialize()가 다시 호출될 수 있도록
      //    _initialized는 false로 남긴다.
      //  - true:  콘솔에서 명시적으로 OFF (운영자 의도). 정상 비활성 경로.
      if (!RemoteConfigService.lastFetchSucceeded) {
        unawaited(
          AnalyticsService.logAdLoadFailed(
            reason: 'rc_fetch_failed',
            requestId: 'ad_init',
          ),
        );
      } else {
        unawaited(
          AnalyticsService.logAdLoadFailed(
            reason: 'disabled_in_rc',
            requestId: 'ad_init',
          ),
        );
      }
      // 마스터 OFF면 AdMob 자체를 띄우지 않는다 (리소스 절약 + 광고 절대 비활성).
      //
      // 주의: 여기서 _initialized = true를 설정하지 않는다. 이 값이
      // RemoteConfig의 "진짜 OFF" 설정이 아니라 fetch가 아직 끝나지 않은
      // 시점에 컴파일타임 기본값(false)을 읽은 것일 수 있기 때문이다
      // (main.dart의 병렬 초기화 경쟁 상태, 2026-08-12 확인된 근본원인 —
      // 이 경쟁이 걸리면 rewardedAdEnabled가 이후 fetch로 true가 되어도
      // _initialized가 영구 true로 잠겨 있어 그 세션 내내 광고가 다시는
      // 초기화되지 않았다). _initialized를 false로 남겨두면 initialize()가
      // 다시 호출될 때(RemoteConfig 값이 정상 반영된 뒤) 재평가할 수 있다.
      return;
    }
    await _consentService.initialize();
    if (!_consentService.isAvailable) {
      // 진단 신호 + 잠금 버그 교정 (M1, 이슈 A). UMP가 EEA/동의 추정에
      // 실패하면 MobileAds 호출 없이 조기 종료한다. 단, 잠금 버그를 막기
      // 위해 _initialized는 false로 남긴다(이전 코드는 _initialized=true로
      // 잠가 다음 initialize() 호출이 즉시 return되어 광고가 영구 비활성).
      // UMP가 부재/타임아웃이면 여기서 멈춘다. 과거의 자동 재시도는
      // 부팅을 길게 만들고, 5초 상한을 넘긴 뒤에도 다시 UMP를 띄우는
      // 부작용이 있어 제거했다.
      unawaited(
        AnalyticsService.logAdLoadFailed(
          reason: 'ump_unavailable',
          requestId: 'ad_init',
        ),
      );
      return;
    }

    try {
      final initializer = _dynamicAdsInitializer;
      if (initializer != null) {
        // 테스트 등에서 주입된 대체 초기화 경로. 이 경우 실제 SDK를
        // 직접 호출하지 않고 주입된 콜백만 수행한다(테스트 seam 보존).
        await initializer();
      } else {
        // 운영 경로: google_mobile_ads는 compile-time에 import되어 있으므로
        // (파일 상단 import) 여기서 실제로 AdMob SDK 초기화를 호출해야 한다.
        // 과거에는 이 호출이 누락된 채 _initialized = true만 설정해,
        // MobileAds.instance.initialize()가 한 번도 실행되지 않아도 초기화
        // 완료로 오판하는 버그가 있었다(2026-08-12 확인).
        await MobileAds.instance.initialize();
      }
      _initialized = true;
    } catch (error, stackTrace) {
      debugPrint('AdService.initialize failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _initialized = false;
    }
  }

  /// 보유 중인 RewardedAd 자원 해제 (앱 종료 / 위젯 정리 시).
  void dispose() {
    _rewardedAd?.dispose();
    _rewardedAd = null;
    _loadingAd = false;
  }

  /// Debug/Profile 모드에서는 테스트 ID, Release에서는 Remote Config ID 사용.
  String _resolveAdUnitId() {
    return resolveRewardedAdUnitIdFor(
      useTestUnit: kDebugMode || kProfileMode,
      configured: RemoteConfigService.rewardedAdUnitIdAndroid,
    );
  }

  /// 단일 사용 흐름: 사용자가 '광고 보고 분석하기'를 눌렀을 때 호출.
  /// 광고 완료 → 보상 grant → true 반환.
  /// 광고 실패 / 사용자 취소 / kill-switch / 마스터 OFF → false 반환.
  ///
  /// [onProgress]는 UI 상태를 외부에서 그릴 수 있도록 단계 알림을 보낸다.
  ///   - 'loading'    : 광고 요청 시작
  ///   - 'shown'      : 광고 표시 시작
  ///   - 'completed'  : 광고 표시 완료 (보상 부여 직전)
  ///   - 'failed'     : 실패 (로드 실패, 재고 없음, 백그라운드 이동, 네트워크 등)
  ///   - 'cancelled'  : 사용자가 광고 닫음 (보상 미부여)
  Future<bool> showForParseSchedule({
    required String requestId,
    void Function(String stage)? onProgress,
  }) async {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (_showingAd) {
      // 둘 이상의 동시 호출 방지 (멱등 가드).
      await AnalyticsService.logAdLoadFailed(
        reason: 'already_showing',
        requestId: requestId,
      );
      return false;
    }
    _showingAd = true;
    _promptShown += 1;
    await AnalyticsService.logAdPromptShown();
    try {
      onProgress?.call('loading');
      // A caller may arrive before app-start priming has completed. Await one
      // initialization attempt here; initialize() is idempotent. Without this,
      // a failed startup init leaves _initialized permanently false for the
      // rest of the session and _loadRewardedAd short-circuits silently.
      if (!_initialized) {
        await initialize();
      }
      if (!_initialized) {
        await AnalyticsService.logAdLoadFailed(
          reason: 'initialization_unavailable',
          requestId: requestId,
        );
        onProgress?.call('failed');
        return false;
      }
      final loaded = await _loadRewardedAd(requestId: requestId);
      if (!loaded) {
        await AnalyticsService.logAdLoadFailed(
          reason: 'load_failed',
          requestId: requestId,
        );
        onProgress?.call('failed');
        return false;
      }
      await AnalyticsService.logAdLoadSuccess(requestId: requestId);

      onProgress?.call('shown');
      await AnalyticsService.logAdStarted(requestId: requestId);
      final completed = await _showRewardedAd();
      if (!completed) {
        await AnalyticsService.logAdLoadFailed(
          reason: 'cancelled_or_backgrounded',
          requestId: requestId,
        );
        onProgress?.call('cancelled');
        return false;
      }
      await AnalyticsService.logAdCompleted(requestId: requestId);

      // 보상 부여
      await _rewardState.grant(requestId: requestId);
      await AnalyticsService.logAdRewardGranted(requestId: requestId);
      _optIn += 1;
      await AnalyticsService.logAdConversionRate(
        promptsShown: _promptShown,
        optedIn: _optIn,
      );
      onProgress?.call('completed');
      return true;
    } catch (error, stackTrace) {
      debugPrint('AdService.showForParseSchedule failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      await AnalyticsService.logAdLoadFailed(
        reason: 'exception',
        requestId: requestId,
      );
      onProgress?.call('failed');
      return false;
    } finally {
      _showingAd = false;
    }
  }

  /// 음성 대화 모드 진입 흐름: [VoiceConversationAdGate]가 광고가 필요하다고
  /// 판정한 후 호출. 광고 완료 → true, 실패/취소 → false.
  ///
  /// 기존 [showForParseSchedule]과 동일한 단계 전이(loading/shown/completed/failed/cancelled)와
  /// 보상 grant 로직을 따르되, 음성 대화 모드 전용 analytics 이벤트를 발행한다.
  Future<bool> showForVoiceConversation({
    required String requestId,
    void Function(String stage)? onProgress,
  }) async =>
      (await showForVoiceConversationWithOutcome(
        requestId: requestId,
        onProgress: onProgress,
      ))
          .isRewarded;

  Future<VoiceConversationAdOutcome> showForVoiceConversationWithOutcome({
    required String requestId,
    void Function(String stage)? onProgress,
  }) async {
    if (!RemoteConfigService.rewardedAdEnabled ||
        !RemoteConfigService.rewardAdVoiceConversationEnabled) {
      return const VoiceConversationAdOutcome(
        VoiceConversationAdOutcomeKind.disabled,
      );
    }
    if (_showingAd) {
      await AnalyticsService.logVoiceConvAdFailed(
        reason: 'already_showing',
        requestId: requestId,
      );
      return const VoiceConversationAdOutcome(
        VoiceConversationAdOutcomeKind.loadThrottled,
      );
    }
    _showingAd = true;
    _promptShown += 1;
    await AnalyticsService.logVoiceConvButtonTap();
    try {
      // A caller may arrive before app-start priming has completed. Await one
      // initialization attempt here; initialize() is idempotent.
      if (!_initialized) {
        await initialize();
      }
      if (!_initialized) {
        final outcome = const VoiceConversationAdOutcome(
          VoiceConversationAdOutcomeKind.initializationUnavailable,
        );
        await AnalyticsService.logVoiceConvAdFailed(
          reason: outcome.analyticsReason,
          requestId: requestId,
        );
        return outcome;
      }
      if (_resolveAdUnitId().isEmpty) {
        final outcome = const VoiceConversationAdOutcome(
          VoiceConversationAdOutcomeKind.unitIdInvalid,
        );
        await AnalyticsService.logVoiceConvAdFailed(
          reason: outcome.analyticsReason,
          requestId: requestId,
        );
        return outcome;
      }
      onProgress?.call('loading');
      final load = await _loadRewardedAdDetailed();
      if (load.kind != _AdLoadOutcomeKind.loaded) {
        final outcome = VoiceConversationAdOutcome(
          load.kind == _AdLoadOutcomeKind.throttled
              ? VoiceConversationAdOutcomeKind.loadThrottled
              : VoiceConversationAdOutcomeKind.loadFailed,
          loadErrorCode: load.code,
          loadErrorDomain: load.domain,
          loadErrorMessage: load.message,
        );
        await AnalyticsService.logVoiceConvAdFailed(
          reason: outcome.analyticsReason,
          requestId: requestId,
        );
        onProgress?.call('failed');
        return outcome;
      }
      await AnalyticsService.logVoiceConvAdShown(requestId: requestId);

      onProgress?.call('shown');
      final showOutcome = await _showRewardedAdWithOutcome();
      if (!showOutcome.isRewarded) {
        final outcome = VoiceConversationAdOutcome(
          showOutcome == RewardedAdShowOutcome.showFailed
              ? VoiceConversationAdOutcomeKind.showFailed
              : VoiceConversationAdOutcomeKind.dismissedWithoutReward,
        );
        await AnalyticsService.logVoiceConvAdFailed(
          reason: outcome.analyticsReason,
          requestId: requestId,
        );
        onProgress?.call(
          showOutcome == RewardedAdShowOutcome.showFailed
              ? 'failed'
              : 'cancelled',
        );
        return outcome;
      }

      // 보상 부여 (다음 대화 모드 진입에 사용하지는 않지만, 일관된 grant 패턴 유지).
      await _rewardState.grant(requestId: requestId);
      await AnalyticsService.logVoiceConvAdRewardEarned(requestId: requestId);
      _optIn += 1;
      await AnalyticsService.logAdConversionRate(
        promptsShown: _promptShown,
        optedIn: _optIn,
      );
      onProgress?.call('completed');
      return const VoiceConversationAdOutcome(
        VoiceConversationAdOutcomeKind.rewarded,
      );
    } catch (error, stackTrace) {
      debugPrint('AdService.showForVoiceConversation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      await AnalyticsService.logVoiceConvAdFailed(
        reason: 'exception',
        requestId: requestId,
      );
      onProgress?.call('failed');
      return const VoiceConversationAdOutcome(
        VoiceConversationAdOutcomeKind.showFailed,
      );
    } finally {
      _showingAd = false;
    }
  }

  /// 보상이 유효한지(만료 안 됐는지) 확인. 사용 직전 호출.
  Future<bool> hasActiveReward({required String requestId}) async {
    final active = await _rewardState.consumeActiveRequestId();
    return active == requestId;
  }

  /// 보상 소비 (성공 후 또는 폐기 후).
  Future<void> clearReward() async {
    await _rewardState.clear();
  }

  // ── Private ──────────────────────────────────────────────────

  /// RewardedAd 인스턴스를 비동기로 로드.
  /// - throttle: 직전 호출로부터 30초 이내면 캐시된 _rewardedAd를 재사용.
  /// - dedup: 동시에 진행 중인 _loadRewardedAd가 있으면 합류.
  ///
  /// [requestId]가 제공되면 empty_unit_id 같은 조기 실패 분기에서
  /// Analytics에 구체적 reason을 남긴다(2026-08-12 M1 진단 강화).
  Future<bool> _loadRewardedAd({String? requestId}) async {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (!_initialized) {
      return false;
    }
    final adUnitId = _resolveAdUnitId();
    if (adUnitId.isEmpty) {
      // 진단 신호 (M1, 이슈 A). RC 미설정 + debug/profile 모드 아님이면
      // adUnitId가 비어 load가 시도조차 안 됨. 호출부에서 load_failed로
      // 집계되지만 더 구체적 reason을 Analytics에 남긴다.
      if (requestId != null) {
        unawaited(
          AnalyticsService.logAdLoadFailed(
            reason: 'empty_unit_id',
            requestId: requestId,
          ),
        );
      }
      return false;
    }
    // 이미 캐시된 광고가 있으면 그대로 사용.
    if (_rewardedAd != null) {
      return true;
    }
    // throttle: 30초 이내 재요청은 스킵 (없으면 false).
    final last = _lastLoadAt;
    if (last != null &&
        DateTime.now().difference(last) < _kReloadThrottle &&
        _rewardedAd == null) {
      return false;
    }
    if (_loadingAd) {
      // dedup: 이미 로드 중이면 캐시될 때까지 대기.
      return await _awaitLoad();
    }
    return await _doLoad();
  }

  Future<_AdLoadOutcome> _loadRewardedAdDetailed() async {
    _lastLoadErrorCode = null;
    _lastLoadErrorDomain = null;
    _lastLoadErrorMessage = null;
    final last = _lastLoadAt;
    final throttled = last != null &&
        DateTime.now().difference(last) < _kReloadThrottle &&
        _rewardedAd == null;
    final loaded = await _loadRewardedAd();
    if (loaded) return const _AdLoadOutcome(_AdLoadOutcomeKind.loaded);
    return _AdLoadOutcome(
      throttled ? _AdLoadOutcomeKind.throttled : _AdLoadOutcomeKind.failed,
      code: _lastLoadErrorCode,
      domain: _lastLoadErrorDomain,
      message: _lastLoadErrorMessage,
    );
  }

  Future<bool> _awaitLoad() async {
    // 단순 폴링으로 캐시 생성 대기 (로드 대기 시간은 보통 수 초).
    const pollInterval = Duration(milliseconds: 200);
    const timeout = Duration(seconds: 8);
    final start = DateTime.now();
    while (_loadingAd && DateTime.now().difference(start) < timeout) {
      await Future<void>.delayed(pollInterval);
    }
    return _rewardedAd != null;
  }

  Future<bool> _doLoad() async {
    _loadingAd = true;
    _lastLoadAt = DateTime.now();
    final adUnitId = _resolveAdUnitId();
    try {
      final completer = Completer<bool>();
      RewardedAd.load(
        adUnitId: adUnitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (RewardedAd ad) {
            _rewardedAd = ad;
            _loadingAd = false;
            if (!completer.isCompleted) {
              completer.complete(true);
            }
          },
          onAdFailedToLoad: (LoadAdError error) {
            _rewardedAd = null;
            _loadingAd = false;
            debugPrint(
              'AdService._loadRewardedAd failed: code=${error.code} '
              'domain=${error.domain} message=${error.message}',
            );
            _lastLoadErrorCode = error.code;
            _lastLoadErrorDomain = error.domain;
            _lastLoadErrorMessage = _safeAdDetail(error.message);
            if (!completer.isCompleted) {
              completer.complete(false);
            }
          },
        ),
      );
      return await completer.future;
    } catch (error, stackTrace) {
      debugPrint('AdService._loadRewardedAd exception: $error');
      debugPrintStack(stackTrace: stackTrace);
      _loadingAd = false;
      _rewardedAd = null;
      return false;
    }
  }

  /// 캐시된 _rewardedAd를 표시하고, 보상 획득 여부를 반환.
  Future<bool> _showRewardedAd() async =>
      (await _showRewardedAdWithOutcome()).isRewarded;

  /// 캐시된 광고 표시의 실패 원인을 SDK 실패/사용자 닫힘으로 구분한다.
  Future<RewardedAdShowOutcome> _showRewardedAdWithOutcome() async {
    final ad = _rewardedAd;
    if (ad == null) {
      return RewardedAdShowOutcome.showFailed;
    }
    try {
      return await runRewardedAdLifecycleWithOutcome(
        drive: ({
          required void Function() onUserEarnedReward,
          required void Function() onAdDismissed,
          required void Function() onAdFailedToShow,
        }) async {
          ad.fullScreenContentCallback = FullScreenContentCallback<RewardedAd>(
            onAdDismissedFullScreenContent: (RewardedAd closedAd) {
              onAdDismissed();
            },
            onAdFailedToShowFullScreenContent:
                (RewardedAd failedAd, AdError error) {
              debugPrint(
                'AdService._showRewardedAd failed: code=${error.code} '
                'message=${error.message}',
              );
              onAdFailedToShow();
            },
          );
          await ad.show(
            onUserEarnedReward: (AdWithoutView rewardedAd, RewardItem reward) {
              onUserEarnedReward();
            },
          );
        },
      );
    } catch (error, stackTrace) {
      debugPrint('AdService._showRewardedAd exception: $error');
      debugPrintStack(stackTrace: stackTrace);
      return RewardedAdShowOutcome.showFailed;
    } finally {
      // There is one ownership/cleanup path for both success and failure.
      // This prevents duplicate disposal when SDK callbacks and show() errors
      // race each other.
      ad.dispose();
      if (identical(_rewardedAd, ad)) {
        _rewardedAd = null;
      }
      _preloadNextAd();
    }
  }

  void _preloadNextAd() {
    _doLoad();
  }
}

/// AdService.defaultWithAds()는 google_mobile_ads가 의존성에 추가됐을 때
/// 사용 가능한 별도 진입점. 그땐 ad_service.loader.dart에서 dynamic import bridge를
/// 거쳐 실제 호출을 위임한다.
extension AdServiceFactory on AdService {
  static AdService create() {
    return AdService.instance;
  }
}
