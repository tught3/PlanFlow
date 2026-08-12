import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/ad_service.dart';
import 'package:planflow/services/remote_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AdService.initialize 마스터 스위치 OFF 분기', () {
    // 단위 테스트 환경에서는 Firebase.initializeApp()이 호출되지 않으므로
    // RemoteConfigService.rewardedAdEnabled는 항상 실제(mock 아님) 코드
    // 경로를 타고 false를 반환한다(remote_config_service.dart의
    // `_remoteConfig` getter가 `Firebase.apps.isEmpty`일 때 null을 반환 →
    // `?? false` 폴백). 즉 이 테스트는 그 실제 분기(ad_service.dart
    // initialize()의 `if (!RemoteConfigService.rewardedAdEnabled)` 블록)를
    // 그대로 실행해 검증한다 — 별도 mock 인프라를 새로 만들지 않는다.
    test('RemoteConfig 미확정(false) 상태에서는 _initialized를 영구 true로 잠그지 않는다',
        () async {
      // 테스트 환경 전제 확인: Firebase 미초기화 상태에서 rewardedAdEnabled는
      // false여야 이 테스트가 실제로 회귀 대상 분기를 타는지 보장된다.
      expect(RemoteConfigService.rewardedAdEnabled, isFalse);

      final service = AdService();
      expect(service.isInitialized, isFalse);

      await service.initialize();

      // 수정 전 버그: 이 분기에서 _initialized = true를 세팅해 버그가
      // 재현됐다(main.dart 경쟁 상태로 rewardedAdEnabled가 아직 fetch 전
      // 기본값을 읽었을 뿐인데도, 이후 RemoteConfig가 fetch를 마쳐 실제
      // 값이 true가 되더라도 이 세션 동안 다시는 재평가되지 않았다).
      // 수정 후: 이 분기를 타면 _initialized는 여전히 false로 남아
      // 다음 initialize() 호출에서 재평가할 수 있어야 한다.
      expect(
        service.isInitialized,
        isFalse,
        reason:
            'rewardedAdEnabled=false 분기는 _initialized를 영구 잠그면 안 된다 '
            '(RemoteConfig fetch가 나중에 true로 바뀌어도 재평가가 막히는 회귀 방지)',
      );

      // 재호출해도 동일하게 동작해야 한다(멱등, 영구 잠금 없음).
      await service.initialize();
      expect(service.isInitialized, isFalse);
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
}
