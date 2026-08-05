import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/ad_service.dart';

void main() {
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
