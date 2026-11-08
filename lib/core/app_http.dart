import 'dart:async';

import 'package:http/http.dart' as http;

/// 앱이 직접 만드는 HTTP 클라이언트의 단일 진입점.
///
/// 운영 환경에서는 지금까지와 동일하게 플랫폼 기본 클라이언트를 만든다.
/// 네이티브 QA 하네스는 감시(egress fence) 클라이언트를 여기에 주입해,
/// 위젯 콜백에서 새로 만든 클라이언트도 허용목록·예산·기록을 똑같이
/// 거치게 한다. 주입이 없으면 동작 변화는 없다.
class AppHttp {
  AppHttp._();

  static const Object _zoneFactoryKey = Object();
  static http.Client Function()? _factory;

  /// QA 하네스가 프레임워크 콜백처럼 Zone 경계 밖에서 실행될 수 있는
  /// 호출을 위해 임시로 설정한다. 종료 시 이전 값을 복구해야 한다.
  static http.Client Function()? overrideFactory(
      http.Client Function()? factory) {
    final previous = _factory;
    _factory = factory;
    return previous;
  }

  /// 한 실행의 Zone 안에서만 적용되는 클라이언트 팩토리.
  static T runWithFactory<T>(
      http.Client Function() factory, T Function() body) {
    return runZoned(body, zoneValues: {_zoneFactoryKey: factory});
  }

  static http.Client create() {
    final scoped = Zone.current[_zoneFactoryKey];
    if (scoped is http.Client Function()) return scoped();
    return _factory?.call() ?? http.Client();
  }
}
