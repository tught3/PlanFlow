import 'package:integration_test/integration_test.dart';

/// 시뮬레이터/실기기에서 스크린샷을 캡처하는 얇은 헬퍼.
///
/// Windows 로컬 개발 환경에는 iOS 시뮬레이터가 없어 실제 캡처 동작은
/// 여기서 검증할 수 없다(컴파일만 확인 가능). CI(P8, macOS 러너) 1차
/// 실행에서 실제 캡처를 실측한다.
class E2eScreenshotHelper {
  const E2eScreenshotHelper(this._binding);

  final IntegrationTestWidgetsFlutterBinding _binding;

  /// `[name]`으로 스크린샷을 캡처한다.
  ///
  /// Android는 캡처 전 `convertFlutterSurfaceToImage()`가 선행되어야
  /// 하지만(package:integration_test 문서 참고), 이 하네스는 iOS 전용이라
  /// 생략한다. iOS/macOS에서 필요해지면 플랫폼 분기를 추가한다.
  Future<List<int>> capture(String name, [Map<String, Object?>? args]) {
    return _binding.takeScreenshot(name, args);
  }
}
