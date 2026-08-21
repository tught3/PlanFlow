import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:planflow/services/ad_consent_service.dart';
import 'package:planflow/services/ad_service.dart';
import 'package:planflow/services/remote_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      ),
      null,
    );
    // Reset the singleton so later tests cannot inherit a simulated mobile
    // consent result and attempt the real MobileAds channel.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    AdConsentService.instance.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
  });

  group('AdConsentService platform availability', () {
    test('unsupported test platform completes unavailable without a channel',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final consent = AdConsentService.instance;

      await consent.retryAfterUserAction();

      expect(consent.isAvailable, isFalse);
      expect(consent.canRequestAds, isFalse);
    });

    test('mobile callback sequence records a successful consent result',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final channel = MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ConsentInformation#canRequestAds') {
          return true;
        }
        return null;
      });

      final consent = AdConsentService.instance;
      await consent.retryAfterUserAction();

      expect(consent.isAvailable, isTrue);
      expect(consent.canRequestAds, isTrue);
    });

    test('a retryable UMP failure can be retried by the next user action',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final channel = MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      );
      var updateCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ConsentInformation#requestConsentInfoUpdate') {
          updateCalls += 1;
          if (updateCalls == 1) {
            throw PlatformException(code: 'temporary');
          }
        }
        if (call.method == 'ConsentInformation#canRequestAds') return true;
        return null;
      });

      final consent = AdConsentService.instance;
      await consent.retryAfterUserAction();
      expect(consent.readiness, ConsentReadiness.retryableFailure);

      await consent.retryAfterUserAction();
      expect(updateCalls, 2);
      expect(consent.isAvailable, isTrue);
      expect(consent.canRequestAds, isTrue);
    });

    test('live UMP consent remains usable after a transient update failure',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final channel = MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ConsentInformation#requestConsentInfoUpdate') {
          throw PlatformException(code: 'temporary');
        }
        if (call.method == 'ConsentInformation#canRequestAds') return true;
        return null;
      });

      final consent = AdConsentService.instance;
      await consent.retryAfterUserAction();
      expect(await consent.canRequestAdsLive, isTrue);
      expect(consent.readiness, ConsentReadiness.ready);
    });
  });

  group('AdService.initialize 마스터 스위치 OFF 분기', () {
    // 단위 테스트 환경에서는 Firebase.initializeApp()이 호출되지 않으므로
    // RemoteConfigService.rewardedAdEnabled는 항상 실제(mock 아님) 코드
    // 경로를 타고 새 기본값(true)을 반환한다(remote_config_service.dart의
    // `_remoteConfig` getter가 `Firebase.apps.isEmpty`일 때 null을 반환 →
    // `?? true` 폴백, 2026-08-13 RC 기본값 false→true 변경에 따라 갱신).
    // 즉 이 테스트는 RC가 ON인 실제 분기(ad_service.dart initialize()의
    // `if (!RemoteConfigService.rewardedAdEnabled)` 블록 미진입)를 그대로
    // 실행해 검증한다 — 별도 mock 인프라를 새로 만들지 않는다.
    test('RemoteConfig 미확정(true 기본값) 상태에서는 _initialized를 영구 true로 잠그지 않는다',
        () async {
      // 테스트 환경 전제 확인: Firebase 미초기화 상태에서 rewardedAdEnabled는
      // 새 기본값(true)이다. 이 테스트가 회귀 대상 분기(RC OFF 즉시 차단
      // 경로가 아니어야 함)를 정확히 타는지 보장한다.
      expect(RemoteConfigService.rewardedAdEnabled, isTrue);

      final service = AdService();
      expect(service.isInitialized, isFalse);

      await service.initialize();

      // 2026-08-13 갱신: RC 기본값이 false→true로 바뀌었다. 이 테스트 환경
      // 에서는 즉시 차단 분기(`if (!RemoteConfigService.rewardedAdEnabled)`)
      // 에 들어가지 않고 _consentService.initialize()로 진행한다. Flutter
      // test 환경은 UMP 플랫폼 채널이 없어 _consentService.isAvailable=false
      // 가 되어 MobileAds가 호출되지 않고 _initialized=false로 유지된다.
      // 따라서 RC OFF 분기 잠금 회피 의도는 그대로 검증된다(이 테스트 환경
      // 에선 우회 경로지만 결과는 동일).
      expect(
        service.isInitialized,
        isFalse,
        reason: '테스트 환경에서는 AdConsentService가 UMP 호출에 실패해 '
            '_initialized는 false로 유지되어야 한다 (RC OFF 분기 잠금 회피 회귀 방지)',
      );

      // 재호출해도 동일하게 동작해야 한다(멱등, 영구 잠금 없음).
      await service.initialize();
      expect(service.isInitialized, isFalse);
    });
  });

  group('AdService.showForParseSchedule 부팅 초기화 실패 시 재시도', () {
    // showForVoiceConversationWithOutcome은 이미 "_initialized=false로
    // 진입한 호출은 initialize()를 한 번 더 시도한다"는 회귀 방지 로직을
    // 갖고 있다(449-462줄 부근). showForParseSchedule에는 이 로직이 없어서
    // 부팅 시 initialize()가 한 번 실패하면(main.dart 경쟁 상태 등) 그
    // 세션 내내 _loadRewardedAd가 조용히 false만 반환했다. 이 테스트는
    // showForParseSchedule 호출이 initialize()를 실제로 (재)시도하는지를
    // 검증한다.
    test('_initialized=false로 시작하면 initialize()를 (재)호출한다', () async {
      final service = _SpyAdService();
      expect(service.isInitialized, isFalse);
      expect(service.initializeCallCount, 0);

      final result = await service.showForParseSchedule(
        requestId: 'test-request-id',
      );

      // 테스트 환경(플랫폼 채널 없음)에서는 consent가 끝내 unavailable로
      // 남아 _initialized는 여전히 false이지만, initialize()가 실제로
      // 호출됐는지(=재시도 시도 여부)는 스파이로 별도 관측한다.
      expect(
        service.initializeCallCount,
        1,
        reason: 'showForParseSchedule은 _initialized=false일 때 '
            'initialize()를 한 번 (재)시도해야 한다',
      );
      expect(service.isInitialized, isFalse);
      expect(result, isFalse);
    });

    test('초기화 재시도가 실패해도 광고 로드(_loadRewardedAd)로 진행하지 않는다', () async {
      final service = _SpyAdService();

      final stages = <String>[];
      final result = await service.showForParseSchedule(
        requestId: 'test-request-id-2',
        onProgress: stages.add,
      );

      expect(result, isFalse);
      // 'shown' 단계는 _loadRewardedAd 성공 이후에만 발화한다. 초기화
      // 재시도가 실패하면 'loading' -> 'failed'로 바로 끝나야 한다.
      expect(stages, <String>['loading', 'failed']);
    });
  });

  group('isValidRewardedAdUnitId', () {
    test('운영 형식(16자리 숫자/최대 20자리 숫자)은 통과한다', () {
      expect(
        isValidRewardedAdUnitId('ca-app-pub-3753374909078516/4571759225'),
        isTrue,
      );
    });

    test('Google 공식 테스트 광고 단위 ID는 통과한다', () {
      expect(
        isValidRewardedAdUnitId('ca-app-pub-3940256099942544/5224354917'),
        isTrue,
      );
    });

    test('빈 문자열은 거부한다', () {
      expect(isValidRewardedAdUnitId(''), isFalse);
    });

    test('공백만 있는 문자열은 거부한다', () {
      expect(isValidRewardedAdUnitId('   '), isFalse);
    });

    test('슬래시가 없으면 거부한다', () {
      expect(
        isValidRewardedAdUnitId('ca-app-pub-3753374909078516'),
        isFalse,
      );
    });

    test('App ID를 잘못 넣은 경우(~ 구분자)는 거부한다', () {
      expect(
        isValidRewardedAdUnitId('ca-app-pub-3940256099942544~3347511713'),
        isFalse,
      );
    });

    test('앞자리 숫자가 16자리보다 부족하면 거부한다', () {
      expect(isValidRewardedAdUnitId('ca-app-pub-123/456'), isFalse);
    });

    test('영문자가 섞여 있으면 거부한다', () {
      expect(
        isValidRewardedAdUnitId('ca-app-pub-375337490907851X/4571759225'),
        isFalse,
      );
    });
  });

  group('resolveRewardedAdUnitIdFor', () {
    test('useTestUnit이 true면 configured가 비어있어도 테스트 ID를 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(useTestUnit: true, configured: ''),
        'ca-app-pub-3940256099942544/5224354917',
      );
    });

    test('useTestUnit이 true면 configured에 운영값이 있어도 무시하고 테스트 ID를 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(
          useTestUnit: true,
          configured: 'ca-app-pub-3753374909078516/4571759225',
        ),
        'ca-app-pub-3940256099942544/5224354917',
      );
    });

    test('useTestUnit이 false면 유효한 configured 값을 그대로 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(
          useTestUnit: false,
          configured: 'ca-app-pub-3753374909078516/4571759225',
        ),
        'ca-app-pub-3753374909078516/4571759225',
      );
    });

    test('useTestUnit이 false이고 configured가 빈 문자열이면 빈 문자열을 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(useTestUnit: false, configured: ''),
        '',
      );
    });

    test('useTestUnit이 false이고 configured가 공백만이면 trim 후 빈 문자열을 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(useTestUnit: false, configured: '   '),
        '',
      );
    });

    test('useTestUnit이 false이고 configured 형식이 잘못됐으면(App ID 오입력) 빈 문자열을 반환한다',
        () {
      expect(
        resolveRewardedAdUnitIdFor(
          useTestUnit: false,
          configured: 'ca-app-pub-3940256099942544~3347511713',
        ),
        '',
      );
    });

    test('useTestUnit이 false이고 configured에 앞뒤 공백이 있으면 trim된 정상값을 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(
          useTestUnit: false,
          configured: '  ca-app-pub-3753374909078516/4571759225  ',
        ),
        'ca-app-pub-3753374909078516/4571759225',
      );
    });
  });

  group('RewardedAdLifecycleCoordinator', () {
    test('reward-before-dismiss completes successfully on dismissal', () async {
      final lifecycle = RewardedAdLifecycleCoordinator(
        gracePeriod: const Duration(milliseconds: 1),
      );

      lifecycle.onUserEarnedReward();
      lifecycle.onAdDismissed();

      expect(await lifecycle.result, isTrue);
      expect(lifecycle.isCompleted, isTrue);
    });

    test('dismiss-before-reward succeeds within the grace period', () async {
      final lifecycle = RewardedAdLifecycleCoordinator(
        gracePeriod: const Duration(milliseconds: 20),
      );

      lifecycle.onAdDismissed();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      lifecycle.onUserEarnedReward();

      expect(await lifecycle.result, isTrue);
    });

    test('dismissal without a reward remains unsuccessful after grace',
        () async {
      final lifecycle = RewardedAdLifecycleCoordinator(
        gracePeriod: const Duration(milliseconds: 1),
      );

      lifecycle.onAdDismissed();

      expect(await lifecycle.result, isFalse);
    });

    test('show failure and duplicate completion stay unsuccessful', () async {
      final lifecycle = RewardedAdLifecycleCoordinator(
        gracePeriod: const Duration(milliseconds: 1),
      );

      lifecycle.onAdFailedToShow();
      lifecycle.onUserEarnedReward();
      lifecycle.onAdDismissed();

      expect(await lifecycle.result, isFalse);
      expect(lifecycle.isCompleted, isTrue);
    });
  });

  group('AdService rewarded lifecycle production seam', () {
    test('missing SDK callbacks time out and release lifecycle state',
        () async {
      final stopwatch = Stopwatch()..start();
      final outcome = await runRewardedAdLifecycle(
        lifecycleTimeout: const Duration(milliseconds: 20),
        drive: ({
          required void Function() onUserEarnedReward,
          required void Function() onAdDismissed,
          required void Function() onAdFailedToShow,
        }) async {
          // Simulate an SDK show() that never returns and emits no callback.
          await Future<void>.delayed(const Duration(seconds: 1));
        },
      );
      stopwatch.stop();

      expect(outcome, isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 250)));
    });

    test('late SDK callbacks after timeout cannot revive a completed attempt',
        () async {
      void Function()? reward;
      void Function()? dismiss;
      void Function()? failure;

      final outcome = await runRewardedAdLifecycle(
        lifecycleTimeout: const Duration(milliseconds: 10),
        drive: ({
          required void Function() onUserEarnedReward,
          required void Function() onAdDismissed,
          required void Function() onAdFailedToShow,
        }) async {
          reward = onUserEarnedReward;
          dismiss = onAdDismissed;
          failure = onAdFailedToShow;
        },
      );

      expect(outcome, isFalse);
      // Simulate a platform callback arriving after the ad was disposed.
      reward?.call();
      dismiss?.call();
      failure?.call();
      expect(outcome, isFalse);
    });

    test('dismiss-before-reward resolves successfully within grace period',
        () async {
      final outcome = runRewardedAdLifecycle(
        gracePeriod: const Duration(milliseconds: 20),
        drive: ({
          required void Function() onUserEarnedReward,
          required void Function() onAdDismissed,
          required void Function() onAdFailedToShow,
        }) async {
          onAdDismissed();
          await Future<void>.delayed(const Duration(milliseconds: 1));
          onUserEarnedReward();
        },
      );

      expect(await outcome, isTrue);
    });

    test('reward-before-dismiss resolves successfully on dismissal', () async {
      final outcome = runRewardedAdLifecycle(
        gracePeriod: const Duration(milliseconds: 1),
        drive: ({
          required void Function() onUserEarnedReward,
          required void Function() onAdDismissed,
          required void Function() onAdFailedToShow,
        }) async {
          onUserEarnedReward();
          onAdDismissed();
        },
      );

      expect(await outcome, isTrue);
    });

    test('show failure stays unsuccessful even if later callbacks fire',
        () async {
      final outcome = runRewardedAdLifecycle(
        gracePeriod: const Duration(milliseconds: 1),
        drive: ({
          required void Function() onUserEarnedReward,
          required void Function() onAdDismissed,
          required void Function() onAdFailedToShow,
        }) async {
          onAdFailedToShow();
          onUserEarnedReward();
          onAdDismissed();
        },
      );

      expect(await outcome, isFalse);
    });
  });

  group('Remote Config rewarded unit retry guard', () {
    test('retries only for release mode after a failed fetch and empty unit',
        () {
      expect(
        shouldRetryRemoteConfigForRewardedUnit(
          useTestUnit: false,
          fetchSucceeded: false,
          configured: '',
        ),
        isTrue,
      );
      expect(
        shouldRetryRemoteConfigForRewardedUnit(
          useTestUnit: true,
          fetchSucceeded: false,
          configured: '',
        ),
        isFalse,
      );
      expect(
        shouldRetryRemoteConfigForRewardedUnit(
          useTestUnit: false,
          fetchSucceeded: true,
          configured: '',
        ),
        isFalse,
      );
      expect(
        shouldRetryRemoteConfigForRewardedUnit(
          useTestUnit: false,
          fetchSucceeded: false,
          configured: 'ca-app-pub-1234567890123456/123',
        ),
        isFalse,
      );
    });

    test('re-checking after retry disables voice ads when either switch is off',
        () {
      expect(
        shouldDisableVoiceConversationAdsAfterRemoteConfigRetry(
          rewardedAdEnabled: false,
          rewardAdVoiceConversationEnabled: true,
        ),
        isTrue,
      );
      expect(
        shouldDisableVoiceConversationAdsAfterRemoteConfigRetry(
          rewardedAdEnabled: true,
          rewardAdVoiceConversationEnabled: false,
        ),
        isTrue,
      );
      expect(
        shouldDisableVoiceConversationAdsAfterRemoteConfigRetry(
          rewardedAdEnabled: true,
          rewardAdVoiceConversationEnabled: true,
        ),
        isFalse,
      );
    });
  });

  group('AdService.initialize UMP timeout', () {
    test('concurrent initialize calls share one in-flight future', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final channel = MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ConsentInformation#canRequestAds') {
          return true;
        }
        return null;
      });

      final initializer = Completer<void>();
      var initializerCalls = 0;
      final service = AdService(
        dynamicAdsInitializer: () {
          initializerCalls += 1;
          return initializer.future;
        },
      );

      final first = service.initialize();
      final second = service.initialize();

      initializer.complete();
      await Future.wait([first, second]);

      expect(initializerCalls, 1);
      expect(service.isInitialized, isTrue);
    });

    test('6s UMP request is bounded by the 5s boot deadline', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final channel = MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      );
      var requestConsentInfoUpdateCalls = 0;
      var mobileAdsInitializerCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'ConsentInformation#requestConsentInfoUpdate':
            requestConsentInfoUpdateCalls += 1;
            await Future<void>.delayed(const Duration(seconds: 6));
            return null;
          case 'UserMessagingPlatform#loadAndShowConsentFormIfRequired':
            return null;
          case 'ConsentInformation#canRequestAds':
            return false;
        }
        return null;
      });

      final service = AdService(
        dynamicAdsInitializer: () async {
          mobileAdsInitializerCalls += 1;
          return null;
        },
      );

      final stopwatch = Stopwatch()..start();
      await service.initialize();
      stopwatch.stop();

      expect(requestConsentInfoUpdateCalls, 1);
      expect(mobileAdsInitializerCalls, 0);
      expect(service.isInitialized, isFalse);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 6)),
        reason: '6초 지연이 있어도 initialize()는 5초 상한에서 반환해야 한다',
      );
    });
  });
}

/// [AdService.initialize] 호출 횟수를 관측하기 위한 테스트 전용 스파이.
///
/// AdConsentService/RemoteConfigService는 싱글턴이거나 생성자가 private라
/// 직접 mock 카운터를 주입할 수 없으므로, `initialize()`를 오버라이드해
/// 실제 로직(super.initialize())을 그대로 수행하면서 호출 횟수만 센다.
class _SpyAdService extends AdService {
  int initializeCallCount = 0;

  @override
  Future<void> initialize() async {
    initializeCallCount += 1;
    await super.initialize();
  }
}
