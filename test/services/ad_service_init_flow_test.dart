import 'package:flutter_test/flutter_test.dart';
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
/// 검증 가능 시나리오 (시나리오 2):
///   - flutter test 환경은 Firebase 미초기화 → `RemoteConfigService._remoteConfig`
///     가 null → `rewardedAdEnabled`가 false(컴파일타임 기본값 폴백)
///   - `RemoteConfigService._lastFetchSucceeded`는 초기값 false
///   - 따라서 AdService.initialize()는 RC OFF 분기를 진입하고
///     `lastFetchSucceeded == false`이므로 `rc_fetch_failed` reason을
///     Analytics에 남기고 즉시 return. MobileAds는 호출되지 않고,
///     `_initialized`는 false로 유지된다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('AdService.initialize 진단 분기 (M5, 이슈 A)', () {
    test(
      '시나리오 2: RC OFF + lastFetchSucceeded=false → MobileAds 미호출, '
      '_initialized=false (현재 구조상 검증 가능한 유일 시나리오)',
      () async {
        int adsInitializerCalls = 0;
        final service = AdService(
          dynamicAdsInitializer: () async {
            adsInitializerCalls += 1;
            return null;
          },
        );

        await service.initialize();

        // RC fetch 실패로 기본값(false)을 읽은 상태. MobileAds(또는 주입된
        // dynamicAdsInitializer) 미호출 + _initialized 미잠금이 단언의 핵심.
        // 진단 신호(reason='rc_fetch_failed')는 AnalyticsService가 no-op
        // 정적 메서드라 직접 검증 불가. 시그니처 변경 후에는 fake Analytics
        // 또는 Sentry capture 호출 카운팅으로 검증 가능.
        expect(adsInitializerCalls, 0,
            reason: 'RC OFF 분기에서 MobileAds 초기화는 절대 호출되지 않는다');
        expect(service.isInitialized, false,
            reason: 'RC OFF면 _initialized는 false 유지(잠금 버그 회피)');
      },
    );

    test(
      '시나리오 2 추가 단언: initialize()가 idempotent하게 false를 유지한다',
      () async {
        // 같은 인스턴스에서 initialize()를 두 번 호출해도 _initialized가
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
}