import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences.getInstance()를 안전하게 호출한다.
///
/// 앱 시작 직후, 백그라운드 전환, 엔진 detach 시점에는 플랫폼 채널
/// (`shared_preferences_android.SharedPreferencesApi.getAll`)이 일시적으로
/// 끊겨 `PlatformException(channel-error)` 또는 `MissingPluginException`이
/// 발생할 수 있다. 이는 앱 버그가 아니라 일시적 환경 문제이므로 fatal 크래시로
/// 올리지 않고 null을 반환해 호출부가 조용히 skip 하도록 한다.
Future<SharedPreferences?> tryGetPrefs() async {
  try {
    return await SharedPreferences.getInstance();
  } on MissingPluginException catch (error) {
    debugPrint('SharedPreferences unavailable (missing plugin): $error');
    return null;
  } on PlatformException catch (error) {
    debugPrint('SharedPreferences unavailable (channel error): $error');
    return null;
  }
}
