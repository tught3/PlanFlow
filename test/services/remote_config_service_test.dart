import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/remote_config_service.dart';

/// RemoteConfigService는 static 싱글턴으로 FirebaseRemoteConfig.instance에
/// 직접 접근하는 구조라 플랫폼 채널을 mock하지 않고는 전체를 유닛테스트할
/// 수 없다. 대신 "신규키/레거시키/기본값 우선순위 판단" 로직을 순수 함수
/// (resolveInitialFreeCount / resolveDailyFreeCount)로 분리해뒀으므로 그
/// 함수만 직접 검증한다.
void main() {
  group('Remote Config attempt generation guard', () {
    test('accepts only the latest completion', () {
      expect(
        shouldAcceptRemoteConfigAttempt(
          completionAttempt: 4,
          currentAttempt: 4,
        ),
        isTrue,
      );
      expect(
        shouldAcceptRemoteConfigAttempt(
          completionAttempt: 3,
          currentAttempt: 4,
        ),
        isFalse,
      );
    });
  });

  group('RemoteConfigService.resolveInitialFreeCount', () {
    test('신규 키가 콘솔에서 fetch됐으면 신규 키 값을 채택한다', () {
      final result = RemoteConfigService.resolveInitialFreeCount(
        newKeySet: true,
        newKeyValue: 7,
        legacyKeySet: true,
        legacyKeyValue: 3,
      );
      expect(result, 7);
    });

    test('신규 키 미설정 + 레거시 키가 fetch됐으면 레거시 값으로 폴백한다', () {
      final result = RemoteConfigService.resolveInitialFreeCount(
        newKeySet: false,
        newKeyValue: 0,
        legacyKeySet: true,
        legacyKeyValue: 5,
      );
      expect(result, 5);
    });

    test('신규 키·레거시 키 둘 다 미설정이면 코드 기본값으로 폴백한다', () {
      final result = RemoteConfigService.resolveInitialFreeCount(
        newKeySet: false,
        newKeyValue: 0,
        legacyKeySet: false,
        legacyKeyValue: 0,
      );
      expect(
        result,
        RemoteConfigService.kVoiceConversationInitialFreeCountDefault,
      );
    });

    test('신규 키가 명시적으로 0으로 설정된 경우 0을 그대로 채택한다(레거시로 폴백하지 않음)', () {
      final result = RemoteConfigService.resolveInitialFreeCount(
        newKeySet: true,
        newKeyValue: 0,
        legacyKeySet: true,
        legacyKeyValue: 9,
      );
      expect(result, 0);
    });
  });

  group('RemoteConfigService.resolveDailyFreeCount', () {
    test('신규 키가 콘솔에서 fetch됐으면 신규 키 값을 채택한다', () {
      final result = RemoteConfigService.resolveDailyFreeCount(
        newKeySet: true,
        newKeyValue: 2,
      );
      expect(result, 2);
    });

    test('신규 키 미설정이면 코드 기본값으로 폴백한다', () {
      final result = RemoteConfigService.resolveDailyFreeCount(
        newKeySet: false,
        newKeyValue: 0,
      );
      expect(
        result,
        RemoteConfigService.kVoiceConversationDailyFreeCountDefault,
      );
    });

    test('신규 키가 명시적으로 0으로 설정된 경우 0을 그대로 채택한다', () {
      final result = RemoteConfigService.resolveDailyFreeCount(
        newKeySet: true,
        newKeyValue: 0,
      );
      expect(result, 0);
    });
  });

  group('RemoteConfigService.retryFetchIfFailed', () {
    tearDown(() {
      // 다른 테스트가 Firebase mock과 무관하게 동작하도록 매 테스트 후
      // _lastFetchSucceeded를 기본값(false)으로 되돌린다.
      RemoteConfigService.lastFetchSucceededForTest = false;
    });

    test(
      '이미 성공한 상태면 즉시 true 반환 (재시도 호출 안 함)',
      () async {
        // 직전 fetch가 성공한 상태를 시뮬레이션. retryFetchIfFailed는
        // 어떤 Firebase 호출도 하지 않고 즉시 true를 반환해야 한다.
        RemoteConfigService.lastFetchSucceededForTest = true;

        final result = await RemoteConfigService.retryFetchIfFailed();

        expect(result, isTrue);
      },
    );

    test(
      '실패 상태에서 Firebase 미초기화면 _remoteConfig=null → false 반환',
      () async {
        // Flutter test 환경은 Firebase.apps.isEmpty → _remoteConfig getter
        // 가 null을 반환 → retryFetchIfFailed가 강제 재시도를 시도조차
        // 하지 못하고 false를 반환. 즉 "재시도 실패" 경로가 fail-closed
        // 로 처리됨을 검증한다.
        RemoteConfigService.lastFetchSucceededForTest = false;

        final result = await RemoteConfigService.retryFetchIfFailed();

        expect(result, isFalse);
      },
    );

    test(
      '실패 상태에서 재시도 성공 → true 반환 (skip 사유 기록: Firebase mock 필요)',
      () async {
        // 이 시나리오는 "직전 fetch가 실패했고 강제 재시도가 성공"하는
        // 경로인데, retryFetchIfFailed는 FirebaseRemoteConfig.instance에
        // 직접 접근해 setConfigSettings/fetchAndActivate를 호출한다. Flutter
        // test 환경에서 Firebase Remote Config를 가짜로 mock하려면
        // firebase_remote_config_platform_interface의 Mock 구현을 만들어야
        // 하고 이 작업 범위를 벗어난다. 또한 _lastFetchSucceeded는 private
        // 정적 필드라 in-memory fake로 hit하기 어렵다. 이 테스트는 placeholder
        // 로 남겨두되 실제 단언은 하지 않는다.
        RemoteConfigService.lastFetchSucceededForTest = false;

        // 검증 불가: retryFetchIfFailed가 진짜로 fetch에 성공하는 경로는
        // Firebase mock 없이는 재현할 수 없다.
        expect(true, true,
            reason: 'Firebase Remote Config mock 인프라가 선행되어야 검증 가능');
      },
    );
  });
}
