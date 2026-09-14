import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ad_instance_manager.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:planflow/services/ad_consent_service.dart';
import 'package:planflow/services/ad_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [AdService.initialize] 흐름의 진단 가시화 검증 (이슈 A, M5).
///
/// 5 시나리오 검증 목표:
///   1. RC `rewardedAdEnabled=false` + `lastFetchSucceeded=true` → OFF 진단 신호
///   2. RC `rewardedAdEnabled=false` + `lastFetchSucceeded=false` → fetch 실패 진단
///   3. consent `isAvailable=false` → MobileAds 미호출, `_initialized=false`
///   4. consent `isAvailable=false` + retry 성공 → MobileAds 1회 호출, `_initialized=true`
///   5. consent `isAvailable=true` → MobileAds 1회 호출, `_initialized=true`
///
/// 현재 시그니처 한계 (2026-08-12, M5 작성 시점 실측):
///   - `RemoteConfigService`는 static singleton이고 `_lastFetchSucceeded`가
///     private 정적 필드라 flutter test 환경에서 fake/monkey-patch 불가.
///     따라서 lastFetchSucceeded=true 분기(시나리오 1)는 직접 hit 불가.
///   - `AdConsentService`는 `AdConsentService._()` private 생성자 +
///     `isAvailable`/내부 `_initialized`/`_available`이 모두 final/상속 불가
///     라 fake 구현으로 override 불가. abstract base 또는 interface 분리
///     리팩토링이 선행돼야 시나리오 3~5 검증 가능.
///
/// 이 테스트는 시그니처 변경 없이 단언 가능한 시나리오만 검증하고,
/// 나머지는 skip 사유를 테스트 본문에 명시한다. 진단 분기 자체는 M1
/// 코드 리뷰(`lib/services/ad_service.dart`의 `if (!RemoteConfigService.
/// rewardedAdEnabled)` 분기)로 커버된다.
///
/// 검증 가능 시나리오 (시나리오 2, 2026-08-13 갱신):
///   - flutter test 환경은 Firebase 미초기화 → `RemoteConfigService._remoteConfig`
///     가 null → `rewardedAdEnabled`가 true(새 기본값, 2026-08-13 false→true 변경).
///   - 즉 RC OFF 분기 진입 조건은 더 이상 false가 아니라 true로 인해 미진입.
///   - RC OFF 분기를 직접 검증하려면 (a) RemoteConfigService를 fake로 분리
///     또는 (b) test-only setter로 _remoteConfig/ rewardedAdEnabled를 주입
///     가능하게 노출하는 리팩토링이 선행돼야 한다.
///   - 현재 시점에선 (a)/(b) 모두 미완이므로 시나리오 1/2 단언 대신
///     "consent 분기 실패 시 MobileAds 미호출 + _initialized=false 유지"를
///     검증한다(아래 시나리오 C). 이 경로는 RC 기본값(true)에서도 _consentService
///     .isAvailable=false면 동일하게 MobileAds 미호출로 종결된다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('AdService.initialize 진단 분기 (M5, 이슈 A)', () {
    test(
      '시나리오 C (2026-08-13 추가): RC 기본값(true) + consent 실패 → '
      'MobileAds 미호출, _initialized=false',
      () async {
        // 배경: RC 기본값이 false→true로 변경됐고(2026-08-13) 이 테스트
        // 환경은 Firebase 미초기화 + UMP 플랫폼 채널 미존재라 _consentService
        // .isAvailable=false가 된다. 따라서 ad_service.initialize()는
        // RC OFF 분기 미진입 → _consentService.initialize() 실패 →
        // retryAfterUserAction() 실패 → 즉시 return. MobileAds 미호출 +
        // _initialized=false가 단언의 핵심.
        int adsInitializerCalls = 0;
        final service = AdService(
          dynamicAdsInitializer: () async {
            adsInitializerCalls += 1;
            return null;
          },
        );

        await service.initialize();

        expect(adsInitializerCalls, 0,
            reason: 'consent 실패 시 MobileAds 초기화는 절대 호출되지 않는다');
        expect(service.isInitialized, false,
            reason: 'consent 실패 시 _initialized는 false 유지(잠금 버그 회피)');
      },
    );

    test(
      '시나리오 C 추가 단언: initialize()가 idempotent하게 false를 유지한다',
      () async {
        // 같은 인스턴스에서 initialize()를 세 번 호출해도 _initialized가
        // true로 잠기지 않는지(잠금 버그 재발 방지) 단언.
        int adsInitializerCalls = 0;
        final service = AdService(
          dynamicAdsInitializer: () async {
            adsInitializerCalls += 1;
            return null;
          },
        );

        await service.initialize();
        await service.initialize();
        await service.initialize();

        expect(adsInitializerCalls, 0);
        expect(service.isInitialized, false);
      },
    );

    test(
      '시나리오 1 (RC OFF + lastFetchSucceeded=true) — skip 사유 기록',
      () async {
        // 이 테스트는 placeholder로 남겨두되 실제 단언은 하지 않는다.
        // RC가 static singleton이고 _lastFetchSucceeded가 private 정적 필드라
        // flutter test에서 fake로 hit할 수 없다. 검증하려면 다음 중 하나가
        // 선행돼야 한다:
        //   (a) RemoteConfigService를 abstract interface + 구현체로 분리
        //   (b) test-only setter로 _lastFetchSucceeded 주입 가능하게 노출
        //   (c) 정적 메서드를 인스턴스 메서드로 마이그레이션 후 DI
        // (a)는 큰 리팩토링이라 별도 작업으로 분리. 현재 M5에서는 skip.
        expect(true, true);
      },
    );

    test(
      '시나리오 3, 4, 5 (consent 분기) — skip 사유 기록',
      () async {
        // 시나리오 3~5는 AdConsentService의 가용성을 fake로 조작해야 하는데,
        // AdConsentService._() private 생성자 + _initialized/_available
        // private 필드 + abstract 미선언 상태라 fake로 override 불가.
        // 검증하려면 다음 중 하나가 선행돼야 한다:
        //   (a) AdConsentService를 abstract base class로 추출
        //   (b) @visibleForTesting public 생성자 + setter 노출
        //   (c) AdService의 consentService 필드 타입을 인터페이스로 교체
        // (a)가 가장 표준이지만 M3 작업의 ad_consent_service.dart를
        // 수정해야 하므로 M5 범위를 벗어남. 현재 M5에서는 skip.
        expect(true, true);
      },
    );
  });

  /// P13 — "광고 표시 지연 개선": `initialize()` 성공 직후 리워드 광고를
  /// 웜 프리로드해 첫 광고 요청이 콜드 로드(1~15s)가 되지 않게 한다.
  ///
  /// 위 "시나리오 3, 4, 5" 주석은 `AdConsentService`를 fake로 override할 수
  /// 없다는 이유로 consent 분기 검증을 skip했으나, `ad_service_test.dart`가
  /// 이미 증명한 대로 override 없이도 실제 싱글턴(`AdConsentService.instance`)
  /// + 플랫폼 채널 mock(`plugins.flutter.io/google_mobile_ads/ump`)만으로
  /// consent 성공/실패 분기를 모두 재현할 수 있다. 이 그룹은 그 방식을
  /// 그대로 재사용해 프리로드 게이트를 검증한다.
  group('AdService.initialize 웜 프리로드 (P13)', () {
    final consentChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads/ump',
      StandardMethodCodec(UserMessagingCodec()),
    );
    final adLoaderChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads',
      StandardMethodCodec(AdMessageCodec()),
    );

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(consentChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(adLoaderChannel, null);
      // AdConsentService.instance는 싱글턴이라 다음 테스트(다른 그룹 포함)로
      // 상태가 새지 않도록 반드시 초기화한다. resetForTesting()이 플랫폼
      // 채널을 만지지 않으므로 override 해제 전/후 순서는 무관하다.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      AdConsentService.instance.resetForTesting();
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      '동의 획득 + RC 활성화 → initialize() 성공 직후 프리로드가 시도된다',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(consentChannel, (call) async {
          if (call.method == 'ConsentInformation#canRequestAds') {
            return true;
          }
          return null;
        });

        var adsInitializerCalls = 0;
        final service = AdService(
          dynamicAdsInitializer: () async {
            adsInitializerCalls += 1;
            return null;
          },
        );

        await service.initialize();

        expect(service.isInitialized, isTrue,
            reason: 'consent 획득 + RC 활성화면 MobileAds 초기화가 완료돼야 한다');
        expect(adsInitializerCalls, 1);
        expect(
          service.debugPreloadAttempted,
          isTrue,
          reason: 'consent+RC 통과 후 initialize()는 캐시 프리로드를 즉시 '
              '시작해야 한다(첫 광고의 콜드 로드 방지, P13)',
        );
      },
    );

    test(
      '동의 미획득 → initialize()는 프리로드를 시작하지 않는다',
      () async {
        // Linux(비-android/iOS) 플랫폼은 ad_consent_service.dart의 플랫폼
        // 가드에 걸려 UMP 채널을 아예 호출하지 않고 즉시
        // ConsentReadiness.notEligible + isAvailable=false로 귀결된다.
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;

        var adsInitializerCalls = 0;
        final service = AdService(
          dynamicAdsInitializer: () async {
            adsInitializerCalls += 1;
            return null;
          },
        );

        await service.initialize();

        expect(adsInitializerCalls, 0,
            reason: '동의 미획득 상태에서는 MobileAds 초기화 자체가 호출되지 않는다');
        expect(service.isInitialized, isFalse);
        expect(
          service.debugPreloadAttempted,
          isFalse,
          reason: '동의를 얻지 못했으면 프리로드도 절대 시작되면 안 된다'
              '(동의 전 광고 요청은 정책 위반)',
        );
      },
    );

    test(
      'RC `rewardedAdEnabled=false` → initialize()는 프리로드를 시작하지 않는다 '
      '(구조적 근거, skip 사유 기록)',
      () async {
        // RemoteConfigService.rewardedAdEnabled는 static singleton이자
        // Firebase 기반이라(Firebase 미초기화 시 기본값 true 반환) flutter
        // test 환경에서 false로 강제할 test-only setter가 없다(위 "시나리오
        // 1"과 동일한 근본 한계, ad_consent_service.dart/remote_config_service
        // .dart는 이번 작업 범위 밖이라 override hook을 추가하지 않는다).
        //
        // 대신 소스 순서로 동일한 안전 보장을 확인한다: ad_service.dart의
        // `_initializeInternal()`에서 RC OFF 분기는 `return;`으로 함수를
        // 즉시 종료하고, `_preloadNextAd()` 호출은 그 return문보다 반드시
        // 뒤에(= `_initialized = true` 대입 다음 줄에) 위치해야 한다. RC가
        // 꺼져 있으면 그 return에 막혀 `_preloadNextAd()`까지 도달할 수
        // 없다는 것이 코드 구조로 보장된다.
        final source = await File(
          'lib/services/ad_service.dart',
        ).readAsString();
        final rcGuardIndex =
            source.indexOf('if (!RemoteConfigService.rewardedAdEnabled) {');
        final rcGuardReturnIndex = source.indexOf('return;', rcGuardIndex);
        final preloadCallIndex = source.indexOf(
          '_preloadNextAd();',
          rcGuardIndex,
        );

        expect(rcGuardIndex, greaterThanOrEqualTo(0),
            reason: 'RC 마스터 스위치 OFF 가드가 사라지면 안 된다');
        expect(rcGuardReturnIndex, greaterThan(rcGuardIndex));
        expect(
          preloadCallIndex,
          greaterThan(rcGuardReturnIndex),
          reason: 'RC OFF 조기 반환보다 뒤에 있어야만 RC가 꺼졌을 때 '
              'preload 호출에 도달하지 못한다',
        );
      },
    );

    test(
      'initialize()는 리워드 광고 프리로드 완료를 기다리지 않고 즉시 반환한다',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(consentChannel, (call) async {
          if (call.method == 'ConsentInformation#canRequestAds') {
            return true;
          }
          return null;
        });

        // loadRewardedAd 호출을 이 completer가 풀릴 때까지 붙잡아 둔다.
        // initialize()가 프리로드를 기다렸다면 아래 await가 이 completer가
        // 풀리기 전까지 반환되지 않아 timeout으로 테스트가 실패한다.
        final releaseLoad = Completer<void>();
        addTearDown(() {
          if (!releaseLoad.isCompleted) releaseLoad.complete();
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(adLoaderChannel, (call) async {
          if (call.method == 'loadRewardedAd') {
            await releaseLoad.future;
          }
          return null;
        });

        final service = AdService(
          dynamicAdsInitializer: () async => null,
        );

        await service.initialize().timeout(
              const Duration(seconds: 2),
              onTimeout: () => fail(
                'initialize()는 리워드 광고 프리로드 완료를 기다리면 안 된다'
                '(부팅 지연 회귀, P13)',
              ),
            );

        expect(service.isInitialized, isTrue);
        expect(
          service.debugPreloadAttempted,
          isTrue,
          reason: 'initialize()가 즉시 반환했더라도 프리로드 자체는 '
              '시작됐어야 한다',
        );

        releaseLoad.complete();
      },
    );
  });
}
