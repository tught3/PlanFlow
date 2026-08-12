import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/ad_service.dart';

/// [ad_service.dart]의 광고 단위 ID 순수 함수 단위 테스트 (이슈 A, F1).
///
/// 대상 함수 (본문 수정 금지 — 다른 워커와 병렬 작업 중):
/// - [isValidRewardedAdUnitId]: AdMob 단위 ID 형식(`ca-app-pub-\d{16}/\d{1,20}`) 검증
/// - [resolveRewardedAdUnitIdFor]: useTestUnit이면 Google 테스트 ID,
///   아니면 configured를 트림해 형식이 유효하면 그대로, 아니면 빈 문자열 반환
///
/// 배경: release 분기에서 kDebugMode 때문에 도달 불가한 검증 로직을
/// 순수 함수로 분리해 테스트 가능하게 한 것(ad_service.dart 주석 동일).
/// 실제 SDK/플랫폼 채널을 띄우지 않고 순수 함수의 반환값만 검증한다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const googleTestRewardedUnitId = 'ca-app-pub-3940256099942544/5224354917';
  const validOperationalUnitId = 'ca-app-pub-3753374909078516/4571759225';

  group('isValidRewardedAdUnitId', () {
    test('유효한 AdMob 형식(퍼블리셔 16자리/단위 1~20자리)은 true를 반환한다', () {
      expect(
        isValidRewardedAdUnitId('ca-app-pub-3940256099942544/5224354917'),
        isTrue,
        reason: 'Google 공식 테스트 광고 단위 ID',
      );
      expect(
        isValidRewardedAdUnitId('ca-app-pub-3753374909078516/4571759225'),
        isTrue,
        reason: '운영 형식 단위 ID',
      );
    });

    test('빈 문자열은 false를 반환한다', () {
      expect(isValidRewardedAdUnitId(''), isFalse);
    });

    test('형식이 전혀 아닌 문자열은 false를 반환한다', () {
      expect(isValidRewardedAdUnitId('invalid'), isFalse);
    });

    test('숫자가 아닌 자리(XXX/YYY)는 false를 반환한다', () {
      // ca-app-pub-XXX/YYY는 정규식(`\d{16}/\d{1,20}`)에 매칭되지 않는다.
      expect(isValidRewardedAdUnitId('ca-app-pub-XXX/YYY'), isFalse);
    });

    test('퍼블리셔 자릿수가 16이 아니면 false를 반환한다', () {
      expect(isValidRewardedAdUnitId('ca-app-pub-123/456'), isFalse);
    });
  });

  group('resolveRewardedAdUnitIdFor', () {
    test('useTestUnit=true면 configured 무관하게 Google 테스트 ID를 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(useTestUnit: true, configured: ''),
        googleTestRewardedUnitId,
      );
      expect(
        resolveRewardedAdUnitIdFor(useTestUnit: true, configured: 'invalid'),
        googleTestRewardedUnitId,
      );
    });

    test('useTestUnit=false, configured가 빈 문자열이면 빈 문자열을 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(useTestUnit: false, configured: ''),
        '',
      );
    });

    test('useTestUnit=false, configured 형식이 잘못되면 빈 문자열을 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(useTestUnit: false, configured: 'invalid'),
        '',
      );
      // 자리만 채워도 숫자가 아니면 형식 오류로 판정한다(실제 동작 반영).
      expect(
        resolveRewardedAdUnitIdFor(
          useTestUnit: false,
          configured: 'ca-app-pub-XXX/YYY',
        ),
        '',
      );
    });

    test('useTestUnit=false, configured가 유효하면 그대로 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(
          useTestUnit: false,
          configured: validOperationalUnitId,
        ),
        validOperationalUnitId,
      );
    });

    test('useTestUnit=false, configured 앞뒤 공백은 트림 후 반환한다', () {
      expect(
        resolveRewardedAdUnitIdFor(
          useTestUnit: false,
          configured: '  $validOperationalUnitId  ',
        ),
        validOperationalUnitId,
      );
    });
  });
}
