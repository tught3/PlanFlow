import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/analytics_service.dart';
import 'ad_consent_service.dart';
import 'ad_reward_state.dart';
import 'remote_config_service.dart';

/// 리워드 광고(AdMob) 서비스.
///
/// 정책:
/// - 배너·네이티브·인터스티셜·자동재생 강제 광고는 사용하지 않는다.
/// - 사용자가 [showForParseSchedule]를 명시적으로 호출했을 때만 광고를 띄운다.
/// - 광고 미완료(로드 실패, 재고 없음, 백그라운드 이동)는 보상 미부여.
/// - 보상 부여(grant)는 [AdRewardState]에 영속 저장 → 앱 종료 후 복구 가능.
/// - 마스터 스위치 OFF면 어떤 호출에서도 광고를 띄우지 않고 즉시 false 반환.
///
/// flutter pub run 시 의존성(google_mobile_ads: ^5.2.0)이 없으면 컴파일 실패하기
/// 때문에 실제 API 호출은 동적(dynamic) 호출로 격리하고, 광고 패키지가 빌드에
/// 포함되지 않는 환경(테스트, mock)에서도 코드가 컴파일만은 되도록 작성한다.
class AdService {
  AdService({
    AdRewardState? rewardState,
    AdConsentService? consentService,
    Future<Object?> Function()? dynamicAdsInitializer,
  })  : _rewardState = rewardState ?? AdRewardState.instance,
        _consentService = consentService ?? AdConsentService.instance,
        _dynamicAdsInitializer = dynamicAdsInitializer;

  // 기본 ID는 테스트 ID(공식 제공). 운영 ID는 Remote Config.
  static const String _kTestRewardedAdUnitIdAndroid =
      'ca-app-pub-3940256099942544/5224354917';

  static final AdService instance = AdService();

  bool _initialized = false;
  bool _showingAd = false;
  int _promptShown = 0;
  int _optIn = 0;

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
      // 마스터 OFF면 AdMob 자체를 띄우지 않는다 (리소스 절약 + 광고 절대 비활성).
      _initialized = true;
      return;
    }
    await _consentService.initialize();
    if (!_consentService.isAvailable) {
      _initialized = true;
      return;
    }

    try {
      final initializer = _dynamicAdsInitializer;
      if (initializer != null) {
        await initializer();
      }
      // 동적 호출이 없으면 compile-time에 google_mobile_ads를 import 해야 한다.
      // 그 import는 initialize() 호출자(main.dart)에서 await로 수행하고,
      // 그 결과로 MobileAds.instance.initialize()가 완료되었다고 가정한다.
      _initialized = true;
    } catch (error, stackTrace) {
      debugPrint('AdService.initialize failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _initialized = false;
    }
  }

  /// 운영 단위 ID (Remote Config). 비어 있으면 테스트 ID로 폴백.
  String _resolveAdUnitId() {
    final configured = RemoteConfigService.rewardedAdUnitIdAndroid.trim();
    if (configured.isEmpty) {
      return _kTestRewardedAdUnitIdAndroid;
    }
    return configured;
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
  ///
  /// [onProgress] 호출은 비동기 안전(thread-safe). 발화 후 즉시 다음 단계로 진행.
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
      final loaded = await _loadRewardedAd();
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

  Future<bool> _loadRewardedAd() async {
    // 실제 호출은 동적. 광고 SDK가 init되지 않은 환경에선 false.
    if (!_initialized) {
      return false;
    }
    final adUnitId = _resolveAdUnitId();
    try {
      debugPrint('AdService._loadRewardedAd($adUnitId)');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _showRewardedAd() async {
    // 실제 호출은 동적. (RewardAd.show) → onUserEarnedReward / onAdFailedToShowFullScreenContent
    // Toggle here when google_mobile_ads is wired in.
    try {
      return false;
    } catch (_) {
      return false;
    }
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
