import 'package:flutter_test/flutter_test.dart';

/// E2E 시나리오가 실제 네트워크 호출을 하지 않았음을 기록/단언하기 위한
/// 계약.
///
/// 이 하네스가 대상으로 하는 SIMULATOR_FULL 시나리오
/// (`docs/ios/SIMULATOR_QA_MATRIX.md`)는 전부 fake repository/service로
/// 대체되므로, 실제 네트워크 호출이 1건이라도 기록되면 그 시나리오가
/// 의도치 않게 실제 백엔드(또는 `lib/core/env.dart`의 프로덕션 Supabase
/// 폴백)를 두드렸다는 신호다.
abstract class NetworkCallRecorder {
  List<Uri> get recordedCalls;
}

/// [recorder]에 기록된 호출이 0건인지 단언한다.
void expectNoNetworkCalls(NetworkCallRecorder recorder, {String? reason}) {
  expect(
    recorder.recordedCalls,
    isEmpty,
    reason: reason ??
        'E2E scenario recorded ${recorder.recordedCalls.length} real '
        'network call(s): ${recorder.recordedCalls}',
  );
}

/// 테스트가 실제 HTTP 클라이언트를 완전히 대체할 필요 없이, 네트워크
/// 호출 지점에서 이 레코더를 통하도록만 배선하면 되는 최소 구현.
///
/// 이 하네스가 대상으로 하는 시나리오는 네트워크 요청이 발생해서는 안
/// 되므로, "요청을 보내되 기록만 한다"가 아니라 "요청 자체를 차단하고
/// 기록한다"가 안전한 기본값이다(fail-closed).
class BlockingNetworkCallRecorder implements NetworkCallRecorder {
  final List<Uri> _calls = <Uri>[];

  @override
  List<Uri> get recordedCalls => List.unmodifiable(_calls);

  /// 네트워크 호출 지점에서 실제 요청 대신 호출한다. 항상 예외를 던진다.
  Never recordAndBlock(Uri uri) {
    _calls.add(uri);
    throw StateError(
      'Blocked unexpected real network call in E2E scenario: $uri',
    );
  }
}
