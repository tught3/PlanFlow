import 'package:http/http.dart' as http;

/// I/O 를 하지 않는 지연 생성 HTTP 클라이언트.
///
/// 생성/종료 시점에는 내부 클라이언트를 만들지 않고, 첫 [send] 호출 시에만
/// [factory] 로 실제 클라이언트를 만든다. 덕분에 메타데이터 조회나 화면
/// 렌더링처럼 네트워크가 필요 없는 경로에서 `http.Client()` 생성이 유발하는
/// I/O(예: `HttpOverrides` 기반 격리 정책) 를 건드리지 않는다.
///
/// - 생성자와 [close] 는 어떤 네트워크 I/O 도 수행하지 않는다.
/// - [close] 는 이미 만들어진 내부 클라이언트만 닫고, 새로 만들지 않는다.
/// - 닫힌 뒤의 [send] 는 `http.ClientException` 으로 실패하며 되살아나지 않는다.
class DeferredHttpClient extends http.BaseClient {
  DeferredHttpClient({http.Client Function()? factory})
      : _factory = factory ?? _defaultFactory;

  static http.Client _defaultFactory() => http.Client();

  final http.Client Function() _factory;
  http.Client? _inner;
  bool _closed = false;

  /// 이미 닫힌 상태인지 여부.
  bool get isClosed => _closed;

  http.Client get _client {
    if (_closed) {
      throw http.ClientException('DeferredHttpClient is already closed.');
    }
    final existing = _inner;
    if (existing != null) {
      return existing;
    }
    final created = _factory();
    _inner = created;
    return created;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('DeferredHttpClient is already closed.');
    }
    return _client.send(request);
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _inner?.close();
  }
}
