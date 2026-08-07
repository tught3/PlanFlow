import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/remote_config_service.dart';

/// RemoteConfigService는 static 싱글턴으로 FirebaseRemoteConfig.instance에
/// 직접 접근하는 구조라 플랫폼 채널을 mock하지 않고는 전체를 유닛테스트할
/// 수 없다. 대신 "신규키/레거시키/기본값 우선순위 판단" 로직을 순수 함수
/// (resolveInitialFreeCount / resolveDailyFreeCount)로 분리해뒀으므로 그
/// 함수만 직접 검증한다.
void main() {
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
}
