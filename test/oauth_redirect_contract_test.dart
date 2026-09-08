import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P4 재발방지 계약테스트: 최근 소셜 로그인(OAuth) 딥링크 리다이렉트 장애의
/// 근본 원인은 Supabase 대시보드 설정이었지 코드는 아니었지만, 코드 쪽에서
/// `lib/core/env.dart`의 `authRedirectUrl`(scheme/host)과
/// `AndroidManifest.xml`의 auth-callback intent-filter, `Info.plist`의
/// `CFBundleURLSchemes`가 서로 어긋나는 회귀를 조기에 잡기 위한 것이다.
void main() {
  final root = Directory.current;
  File file(String path) => File('${root.path}${Platform.pathSeparator}$path');

  /// `lib/core/env.dart`의 `authRedirectUrl` getter가 반환하는 리터럴에서
  /// scheme과 host를 파싱한다. compile-time override가 없는 고정 상수이므로
  /// 정규식으로 직접 뽑아낸다.
  ({String scheme, String host}) parseAuthRedirectUrl(String envSource) {
    final match = RegExp(
      r"authRedirectUrl\s*=>\s*'([a-zA-Z][a-zA-Z0-9+.\-]*)://([^/'\s]+)'",
    ).firstMatch(envSource);
    if (match == null) {
      throw StateError(
          'authRedirectUrl literal not found in lib/core/env.dart');
    }
    return (scheme: match.group(1)!, host: match.group(2)!);
  }

  test('env.dart authRedirectUrl parses to a non-empty scheme and host', () {
    final envSource = file('lib/core/env.dart').readAsStringSync();
    final parsed = parseAuthRedirectUrl(envSource);
    expect(parsed.scheme, isNotEmpty);
    expect(parsed.host, isNotEmpty);
    // 계획서 기준 값 고정: 회귀 시 아래 두 테스트가 잡아내지만, 현재 값도
    // 명시적으로 확인해 둔다.
    expect(parsed.scheme, 'planflow');
    expect(parsed.host, 'auth-callback');
  });

  test(
      'AndroidManifest auth-callback intent-filter matches env.dart authRedirectUrl',
      () {
    final envSource = file('lib/core/env.dart').readAsStringSync();
    final parsed = parseAuthRedirectUrl(envSource);
    final manifest =
        file('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    // auth-callback host를 가진 <data> 태그를 감싸는 intent-filter 블록을
    // 통째로 찾아, 그 안에서 scheme도 함께 확인한다 (host/scheme이 서로
    // 다른 <data> 태그에 흩어져 있어도 매칭되는 것을 방지).
    final escapedHost = RegExp.escape(parsed.host);
    final authCallbackFilter = RegExp(
      '<intent-filter>(?:(?!</intent-filter>)[\\s\\S])*?'
      'android:host="$escapedHost"'
      '(?:(?!</intent-filter>)[\\s\\S])*?</intent-filter>',
    ).firstMatch(manifest);
    expect(authCallbackFilter, isNotNull,
        reason:
            'AndroidManifest.xml에 host="${parsed.host}"를 가진 intent-filter가 없다');
    final block = authCallbackFilter!.group(0)!;
    expect(block, contains('android:scheme="${parsed.scheme}"'),
        reason:
            'host="${parsed.host}" intent-filter의 scheme이 env.dart(${parsed.scheme})와 다르다');
  });

  test('iOS Info.plist CFBundleURLSchemes includes env.dart auth scheme', () {
    final envSource = file('lib/core/env.dart').readAsStringSync();
    final parsed = parseAuthRedirectUrl(envSource);
    final plist = file('ios/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<string>${parsed.scheme}</string>'),
        reason:
            'Info.plist CFBundleURLSchemes에 env.dart scheme(${parsed.scheme})이 없다');
  });
}
