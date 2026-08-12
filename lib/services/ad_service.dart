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

  /// 음성 대화 모드 진입 흐름: [VoiceConversationAdGate]가 광고가 필요하다고
  /// 판정한 후 호출. 광고 완료 → true, 실패/취소 → false.
  ///
  /// 기존 [showForParseSchedule]과 동일한 단계 전이(loading/shown/completed/failed/cancelled)와
  /// 보상 grant 로직을 따르되, 음성 대화 모드 전용 analytics 이벤트를 발행한다.
  Future<bool> showForVoiceConversation({
    required String requestId,
    void Function(String stage)? onProgress,
  }) async {
    if (!RemoteConfigService.rewardedAdEnabled ||
        !RemoteConfigService.rewardAdVoiceConversationEnabled) {
      return false;
    }
    if (_showingAd) {
      await AnalyticsService.logVoiceConvAdFailed(
        reason: 'already_showing',
        requestId: requestId,
      );
      return false;
    }
    _showingAd = true;
    _promptShown += 1;
    await AnalyticsService.logVoiceConvButtonTap();
    try {
      onProgress?.call('loading');
      final loaded = await _loadRewardedAd();
      if (!loaded) {
        await AnalyticsService.logVoiceConvAdFailed(
          reason: 'load_failed',
          requestId: requestId,
        );
        onProgress?.call('failed');
        return false;
      }
      await AnalyticsService.logVoiceConvAdShown(requestId: requestId);

      onProgress?.call('shown');
      final completed = await _showRewardedAd();
      if (!completed) {
        await AnalyticsService.logVoiceConvAdFailed(
          reason: 'cancelled_or_backgrounded',
          requestId: requestId,
        );
        onProgress?.call('cancelled');
        return false;
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
      return true;
    } catch (error, stackTrace) {
      debugPrint('AdService.showForVoiceConversation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      await AnalyticsService.logVoiceConvAdFailed(
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

  /// RewardedAd 인스턴스를 비동기로 로드.
  /// - throttle: 직전 호출로부터 30초 이내면 캐시된 _rewardedAd를 재사용.
  /// - dedup: 동시에 진행 중인 _loadRewardedAd가 있으면 합류.
  Future<bool> _loadRewardedAd() async {
    if (!RemoteConfigService.rewardedAdEnabled) {
      return false;
    }
    if (!_initialized) {
      return false;
    }
    final adUnitId = _resolveAdUnitId();
    if (adUnitId.isEmpty) return false;
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
  Future<bool> _showRewardedAd() async {
    final ad = _rewardedAd;
    if (ad == null) {
      return false;
    }
    bool rewardEarned = false;
    final completer = Completer<bool>();
    try {
      ad.fullScreenContentCallback = FullScreenContentCallback<RewardedAd>(
        onAdDismissedFullScreenContent: (RewardedAd closedAd) {
          if (!completer.isCompleted) {
            completer.complete(rewardEarned);
          }
        },
        onAdFailedToShowFullScreenContent:
            (RewardedAd failedAd, AdError error) {
          debugPrint(
            'AdService._showRewardedAd failed: code=${error.code} '
            'message=${error.message}',
          );
          if (!completer.isCompleted) {
            completer.complete(false);
          }
        },
      );
      await ad.show(
        onUserEarnedReward: (AdWithoutView rewardedAd, RewardItem reward) {
          rewardEarned = true;
        },
      );
      final result = await completer.future;
      _rewardedAd?.dispose();
      _rewardedAd = null;
      _preloadNextAd();
      return result;
    } catch (error, stackTrace) {
      debugPrint('AdService._showRewardedAd exception: $error');
      debugPrintStack(stackTrace: stackTrace);
      _rewardedAd?.dispose();
      _rewardedAd = null;
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return false;
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
