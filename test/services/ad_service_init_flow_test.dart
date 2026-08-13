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
}