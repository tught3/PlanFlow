import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../core/analytics_service.dart';
import '../core/diag_logger.dart';
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
  loadTimedOut,
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
      case VoiceConversationAdOutcomeKind.loadTimedOut:
        return 'load_timeout';
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

/// Sanitized state of the most recent voice rewarded-ad attempt.
///
/// This is intentionally metadata-only: it contains no schedule text and no
/// full ad unit ID. It is exposed for QA/Crashlytics adapters so a release
/// build can identify whether an attempt stopped at load, show, or reward.
class RewardedAdAttemptSnapshot {
  const RewardedAdAttemptSnapshot({
    required this.attemptId,
    required this.phase,
    required this.at,
    this.errorCode,
    this.errorDomain,
    this.errorMessage,
    this.responseId,
  });

  final String attemptId;
  final String phase;
  final DateTime at;
  final int? errorCode;
  final String? errorDomain;
  final String? errorMessage;
  final String? responseId;
}

String _safeAdDetail(String value) {
  final sanitized = value
      .replaceAll(RegExp(r'[\r\n]'), ' ')
      .replaceAll(
        RegExp(r'ca-app-pub-\d{16}[~/]\d{1,20}'),
        'ad_unit_redacted',
      )
      .trim();
  return sanitized.length <= 120
      ? sanitized
      : '${sanitized.substring(0, 120)}…';
}

enum _AdLoadOutcomeKind { loaded, throttled, failed, timedOut }

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

  void onAdFailedToShow() => _finish(false);

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
  Duration lifecycleTimeout = const Duration(minutes: 2),
}) async {
  // The SDK must never keep an ad attempt alive longer than this, even when
  // a caller supplies a longer test/configuration timeout.  A missing
  // dismiss/reward/failure callback is a failed attempt, not an indefinitely
  // pending UI state.
  const hardMaximum = Duration(minutes: 2);
  final boundedTimeout =
      lifecycleTimeout < hardMaximum ? lifecycleTimeout : hardMaximum;
  final lifecycle = RewardedAdLifecycleCoordinator(gracePeriod: gracePeriod);
  try {
    final driveAndAwaitResult = drive(
      onUserEarnedReward: lifecycle.onUserEarnedReward,
      onAdDismissed: lifecycle.onAdDismissed,
      onAdFailedToShow: lifecycle.onAdFailedToShow,
    ).then((_) => lifecycle.result);
    final timeout = Future<void>.delayed(boundedTimeout).then((_) {
      lifecycle.dispose();
      return false;
    });
    return await Future.any<bool>(<Future<bool>>[
      driveAndAwaitResult,
      timeout,
    ]);
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

/// Release에서 Remote Config fetch 실패로 광고 단위 ID가 비어 있을 때만
/// 사용자 요청 경로의 1회 재시도를 허용한다. Debug/Profile은 항상 공식
/// 테스트 단위 ID를 사용하므로 이 조건에 들어오지 않는다.
@visibleForTesting
bool shouldRetryRemoteConfigForRewardedUnit({
  required bool useTestUnit,
  required bool fetchSucceeded,
  required String configured,
}) =>
    !useTestUnit && !fetchSucceeded && configured.trim().isEmpty;

/// Release용 빈 rewarded unit 보강 재시도 뒤, 광고 관련 스위치가 꺼졌으면
/// 즉시 광고 경로를 중단해야 하는지 판단한다.
@visibleForTesting
bool shouldDisableVoiceConversationAdsAfterRemoteConfigRetry({
  required bool rewardedAdEnabled,
  required bool rewardAdVoiceConversationEnabled,
}) =>
    !rewardedAdEnabled || !rewardAdVoiceConversationEnabled;

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
  Future<bool>? _loadFuture;
  int _loadGeneration = 0;
  DateTime? _lastLoadAt;
  int? _lastLoadErrorCode;
  String? _lastLoadErrorDomain;
  String? _lastLoadErrorMessage;
  int? _lastShowErrorCode;
  String? _lastShowErrorDomain;
  String? _lastShowErrorMessage;
  bool _lastShowFailed = false;
  void Function()? _cancelActiveLoad;
  String? _lastAdResponseId;
  RewardedAdAttemptSnapshot? _lastVoiceAttempt;

  final AdRewardState _rewardState;
  final AdConsentService _consentService;
  final Future<Object?> Function()? _dynamicAdsInitializer;

  bool get isInitialized => _initialized;
  bool get isShowing => _showingAd;
  RewardedAdAttemptSnapshot? get lastVoiceAttempt => _lastVoiceAttempt;

  void _recordVoiceAttempt(
    String attemptId,
    String phase, {
    int? errorCode,
    String? errorDomain,
    String? errorMessage,
    String? responseId,
  }) {
    _lastVoiceAttempt = RewardedAdAttemptSnapshot(
      attemptId: attemptId,
      phase: phase,
      at: DateTime.now(),
      errorCode: errorCode,
      errorDomain: errorDomain == null ? null : _safeAdDetail(errorDomain),
      errorMessage: errorMessage == null ? null : _safeAdDetail(errorMessage),
      responseId: responseId ?? _lastAdResponseId,
    );
    // 앱 내부의 "진단 로그"에도 광고 시도 단계를 남긴다. 기존에는
    // Crashlytics breadcrumb에만 기록되어 실기기에서 광고 실패 원인을
    // 확인할 수 없었다. 일정 내용·전체 광고 ID·원본 requestId는 기록하지
    // 않고 시도 ID의 해시와 단계/안전한 오류 메타데이터만 저장한다.
    final fingerprint = attemptId.hashCode.toRadixString(16);
    final diagnostic = <String>[
      'attempt=$fingerprint',
      'phase=${_safeAdDetail(phase)}',
      'consent=${_consentService.readiness.name}',
      'rcFetch=${RemoteConfigService.lastFetchSucceeded}',
      'rcSource=${RemoteConfigService.rewardedAdConfigSource}',
      'rcEnabled=${RemoteConfigService.rewardedAdEnabled}',
      'voiceEnabled=${RemoteConfigService.rewardAdVoiceConversationEnabled}',
    ];
    if (errorCode != null) diagnostic.add('code=$errorCode');
    if (errorDomain != null) {
      diagnostic.add('domain=${_safeAdDetail(errorDomain)}');
    }
    if (errorMessage != null) {
      diagnostic.add('message=${_safeAdDetail(errorMessage)}');
    }
    final safeResponseId = responseId ?? _lastAdResponseId;
    if (safeResponseId != null && safeResponseId.isNotEmpty) {
      diagnostic.add('responseId=${_safeAdDetail(safeResponseId)}');
    }
    DiagLogger.log('RewardedAd', diagnostic.join(' '));
    // Keep a release-visible breadcrumb without sending request IDs, schedule
    // text, or the full ad-unit ID. Firebase may not be initialized in tests
    // or during early startup, so this path must remain best-effort.
    if (Firebase.apps.isEmpty) return;
    final details = <String>[
      'rewarded_ad_attempt id=$fingerprint phase=${_safeAdDetail(phase)}',
    ];
    if (errorCode != null) details.add('code=$errorCode');
    if (errorDomain != null) {
      details.add('domain=${_safeAdDetail(errorDomain)}');
    }
    if (errorMessage != null) {
      details.add('message=${_safeAdDetail(errorMessage)}');
    }
    unawaited(_writeCrashlyticsBreadcrumb(details.join(' ')));
  }

  Future<void> _writeCrashlyticsBreadcrumb(String message) async {
    try {
      await FirebaseCrashlytics.instance.log(message);
    } catch (_) {
      // Crashlytics is optional during startup and in local/test builds.
    }
  }

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
    await _consentService.ensureReady(userInitiated: false);
    // UMP documents that a previous consent decision can remain usable when
    // the latest requestConsentInfoUpdate failed. Query the live state before
    // abandoning initialization so a transient network/platform failure does
    // not permanently suppress rewarded ads for this process.
    if (!_consentService.isAvailable &&
        !(await _consentService.canRequestAdsLive)) {
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
    // Invalidate and complete an SDK load that may never call either callback.
    // Without this, callers awaiting the shared Future remain blocked forever
    // after a lifecycle/generation reset.
    _cancelActiveLoad?.call();
    _cancelActiveLoad = null;
    _loadGeneration++;
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
    _lastAdResponseId = null;
    _recordVoiceAttempt(requestId, 'started');
    if (!RemoteConfigService.rewardedAdEnabled ||
        !RemoteConfigService.rewardAdVoiceConversationEnabled) {
      _recordVoiceAttempt(requestId, 'disabled');
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
        _recordVoiceAttempt(requestId, 'initialization_failed');
        final outcome = const VoiceConversationAdOutcome(
          VoiceConversationAdOutcomeKind.initializationUnavailable,
        );
        await AnalyticsService.logVoiceConvAdFailed(
          reason: outcome.analyticsReason,
          requestId: requestId,
        );
        return outcome;
      }
      var adUnitId = _resolveAdUnitId();
      if (adUnitId.isEmpty &&
          shouldRetryRemoteConfigForRewardedUnit(
            useTestUnit: kDebugMode || kProfileMode,
            fetchSucceeded: RemoteConfigService.lastFetchSucceeded,
            configured: RemoteConfigService.rewardedAdUnitIdAndroid,
          )) {
        // A failed startup fetch can leave the fail-safe enabled default true
        // while the unit ID default remains empty. Retry only for this explicit
        // user request; never invent or fall back to an operational unit ID.
        await RemoteConfigService.retryFetchIfFailed();
        if (shouldDisableVoiceConversationAdsAfterRemoteConfigRetry(
          rewardedAdEnabled: RemoteConfigService.rewardedAdEnabled,
          rewardAdVoiceConversationEnabled:
              RemoteConfigService.rewardAdVoiceConversationEnabled,
        )) {
          _recordVoiceAttempt(requestId, 'disabled_after_rc_retry');
          final outcome = const VoiceConversationAdOutcome(
            VoiceConversationAdOutcomeKind.disabled,
          );
          await AnalyticsService.logVoiceConvAdFailed(
            reason: outcome.analyticsReason,
            requestId: requestId,
          );
          return outcome;
        }
        adUnitId = _resolveAdUnitId();
      }
      if (adUnitId.isEmpty) {
        _recordVoiceAttempt(requestId, 'unit_id_invalid_after_rc_retry');
        final outcome = VoiceConversationAdOutcome(
          VoiceConversationAdOutcomeKind.unitIdInvalid,
          loadErrorMessage: 'remote_config_unit_id_missing',
        );
        await AnalyticsService.logVoiceConvAdFailed(
          reason: outcome.analyticsReason,
          requestId: requestId,
        );
        return outcome;
      }
      onProgress?.call('loading');
      final load = await _loadRewardedAdDetailed(userInitiated: true);
      if (load.kind != _AdLoadOutcomeKind.loaded) {
        _recordVoiceAttempt(
          requestId,
          load.kind == _AdLoadOutcomeKind.timedOut
              ? 'load_timeout'
              : 'load_failed',
          errorCode: load.code,
          errorDomain: load.domain,
          errorMessage: load.message,
        );
        final outcome = VoiceConversationAdOutcome(
          load.kind == _AdLoadOutcomeKind.throttled
              ? VoiceConversationAdOutcomeKind.loadThrottled
              : load.kind == _AdLoadOutcomeKind.timedOut
                  ? VoiceConversationAdOutcomeKind.loadTimedOut
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
      _recordVoiceAttempt(requestId, 'shown');

      onProgress?.call('shown');
      final completed = await _showRewardedAd();
      if (!completed) {
        final showFailed = _lastShowFailed;
        _recordVoiceAttempt(
          requestId,
          showFailed ? 'show_failed' : 'dismissed_without_reward',
          errorCode: _lastShowErrorCode,
          errorDomain: _lastShowErrorDomain,
          errorMessage: _lastShowErrorMessage,
        );
        final outcome = VoiceConversationAdOutcome(
          showFailed
              ? VoiceConversationAdOutcomeKind.showFailed
              : VoiceConversationAdOutcomeKind.dismissedWithoutReward,
          loadErrorCode: _lastShowErrorCode,
          loadErrorDomain: _lastShowErrorDomain,
          loadErrorMessage: _lastShowErrorMessage,
        );
        await AnalyticsService.logVoiceConvAdFailed(
          reason: outcome.analyticsReason,
          requestId: requestId,
        );
        onProgress?.call('cancelled');
        return outcome;
      }

      // 보상 부여 (다음 대화 모드 진입에 사용하지는 않지만, 일관된 grant 패턴 유지).
      await _rewardState.grant(requestId: requestId);
      await AnalyticsService.logVoiceConvAdRewardEarned(requestId: requestId);
      _recordVoiceAttempt(requestId, 'rewarded');
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
      _recordVoiceAttempt(requestId, 'show_failed',
          errorMessage: error.toString());
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
    return _loadRewardedAdInternal(userInitiated: true, requestId: requestId);
  }

  Future<bool> _loadRewardedAdInternal({
    bool userInitiated = false,
    String? requestId,
  }) async {
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
    if (!userInitiated &&
        last != null &&
        DateTime.now().difference(last) < _kReloadThrottle &&
        _rewardedAd == null) {
      return false;
    }
    final inFlight = _loadFuture;
    if (inFlight != null) {
      return await inFlight;
    }
    final future = _doLoad();
    _loadFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_loadFuture, future)) _loadFuture = null;
    }
  }

  Future<_AdLoadOutcome> _loadRewardedAdDetailed(
      {bool userInitiated = false}) async {
    _lastLoadErrorCode = null;
    _lastLoadErrorDomain = null;
    _lastLoadErrorMessage = null;
    final last = _lastLoadAt;
    final throttled = !userInitiated &&
        last != null &&
        DateTime.now().difference(last) < _kReloadThrottle &&
        _rewardedAd == null;
    final loaded = await _loadRewardedAdInternal(userInitiated: userInitiated);
    if (loaded) return const _AdLoadOutcome(_AdLoadOutcomeKind.loaded);
    return _AdLoadOutcome(
      throttled
          ? _AdLoadOutcomeKind.throttled
          : (_lastLoadErrorMessage == 'load_timeout'
              ? _AdLoadOutcomeKind.timedOut
              : _AdLoadOutcomeKind.failed),
      code: _lastLoadErrorCode,
      domain: _lastLoadErrorDomain,
      message: _lastLoadErrorMessage,
    );
  }

  Future<bool> _doLoad() async {
    _loadingAd = true;
    final generation = ++_loadGeneration;
    _lastLoadAt = DateTime.now();
    final adUnitId = _resolveAdUnitId();
    void Function()? cancelActiveLoad;
    try {
      final completer = Completer<bool>();
      Timer? timeoutTimer;
      void finish(bool value) {
        timeoutTimer?.cancel();
        if (!completer.isCompleted) completer.complete(value);
      }

      cancelActiveLoad = () {
        if (generation != _loadGeneration || completer.isCompleted) return;
        _loadingAd = false;
        _lastLoadErrorMessage = 'load_cancelled';
        finish(false);
      };
      _cancelActiveLoad = cancelActiveLoad;

      RewardedAd.load(
        adUnitId: adUnitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (RewardedAd ad) {
            if (generation != _loadGeneration || completer.isCompleted) {
              ad.dispose();
              return;
            }
            _rewardedAd = ad;
            _lastAdResponseId = _readAdResponseId(ad);
            _loadingAd = false;
            finish(true);
          },
          onAdFailedToLoad: (LoadAdError error) {
            if (generation != _loadGeneration || completer.isCompleted) return;
            _rewardedAd = null;
            _loadingAd = false;
            debugPrint(
              'AdService._loadRewardedAd failed: code=${error.code} '
              'domain=${error.domain} message=${error.message}',
            );
            _lastLoadErrorCode = error.code;
            _lastLoadErrorDomain = error.domain;
            _lastLoadErrorMessage = _safeAdDetail(error.message);
            finish(false);
          },
        ),
      );
      timeoutTimer = Timer(const Duration(seconds: 15), () {
        if (generation != _loadGeneration || completer.isCompleted) return;
        _loadingAd = false;
        _lastLoadErrorMessage = 'load_timeout';
        finish(false);
      });
      return await completer.future;
    } catch (error, stackTrace) {
      debugPrint('AdService._loadRewardedAd exception: $error');
      debugPrintStack(stackTrace: stackTrace);
      _loadingAd = false;
      _rewardedAd = null;
      return false;
    } finally {
      if (identical(_cancelActiveLoad, cancelActiveLoad)) {
        _cancelActiveLoad = null;
      }
      if (generation == _loadGeneration) _loadingAd = false;
    }
  }

  String? _readAdResponseId(RewardedAd ad) {
    try {
      final dynamic dynamicAd = ad;
      final dynamic responseInfo = dynamicAd.responseInfo;
      final dynamic responseId = responseInfo?.responseId;
      if (responseId is String && responseId.trim().isNotEmpty) {
        return _safeAdDetail(responseId);
      }
    } catch (_) {
      // Older SDKs may not expose responseInfo; diagnostics remain valid.
    }
    return null;
  }

  /// 캐시된 _rewardedAd를 표시하고, 보상 획득 여부를 반환.
  Future<bool> _showRewardedAd() async {
    final ad = _rewardedAd;
    if (ad == null) {
      return false;
    }
    _lastShowFailed = false;
    _lastShowErrorCode = null;
    _lastShowErrorDomain = null;
    _lastShowErrorMessage = null;
    try {
      return await runRewardedAdLifecycle(
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
              _lastShowFailed = true;
              _lastShowErrorCode = error.code;
              _lastShowErrorDomain = _safeAdDetail(error.domain);
              _lastShowErrorMessage = _safeAdDetail(error.message);
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
      _lastShowFailed = true;
      _lastShowErrorMessage = _safeAdDetail(error.toString());
      debugPrint('AdService._showRewardedAd exception: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
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
    if (_rewardedAd != null || _loadFuture != null || _loadingAd) return;
    final future = _loadRewardedAdInternal(userInitiated: false);
    unawaited(future);
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
