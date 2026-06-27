import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 배터리 최적화(절전) 예외 권한을 관리하는 서비스.
///
/// Android에서 삼성·샤오미 등의 배터리 최적화는 백그라운드 알람을 막는 주요 원인.
/// `planflow/android_permissions` MethodChannel 의 두 메서드를 통해
/// MainActivity.kt 의 PowerManager / Settings 인텐트를 호출한다.
///
/// 비안드로이드 플랫폼이나 예외 상황에서는 true를 반환해 흐름을 막지 않는다.
class BatteryOptimizationService {
  const BatteryOptimizationService();

  static const MethodChannel _channel =
      MethodChannel('planflow/android_permissions');

  /// 현재 앱이 배터리 최적화 예외로 등록되어 있으면 true.
  ///
  /// Android가 아니거나 PowerManager 접근 실패 시 true(최적화 없음으로 간주).
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } catch (error, stackTrace) {
      debugPrint('Battery optimization check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      // 확인 실패 시 흐름을 막지 않는다.
      return true;
    }
  }

  /// 배터리 최적화 예외 요청 화면을 연다.
  ///
  /// ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS(원탭 다이얼로그)를 우선 시도하고,
  /// 실패 시 ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS(목록 화면)로 폴백.
  /// 화면 전환 여부(true/false)를 반환한다.
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Battery optimization request failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }
}
