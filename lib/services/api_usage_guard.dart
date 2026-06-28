import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diag_logger.dart';

/// 폭주 통보 전송기 시그니처. (api, 일일카운트, 날짜, 폭주 호출 스택)
typedef OverloadAlertSender = Future<void> Function(
  String api,
  int count,
  String date,
  StackTrace stack,
);

/// 외부 API 호출을 날짜별·API별로 카운트하고,
/// 임계 초과 시 호출을 차단하는 circuit breaker.
///
/// - warn 임계: 이상 징후 조기 포착 → SharedPreferences + DiagLogger에 1회 기록
/// - block 임계: 폭주 확정 차단 → tryConsume()이 false 반환
///
/// 차단은 그날만 적용되고 다음 날 자동 리셋된다.
/// SharedPreferences를 영속화 저장소로 사용하므로 백그라운드 isolate와
/// 값을 공유할 수 있다(isolate별로 SharedPreferences.getInstance() 호출).
class ApiUsageGuard {
  ApiUsageGuard({
    Map<String, ApiUsageThreshold>? thresholds,
    Future<SharedPreferences> Function()? prefsFactory,
    DateTime Function()? now,
    OverloadAlertSender? overloadAlertSender,
  })  : _thresholds = thresholds ?? const {},
        _prefsFactory = prefsFactory ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now,
        _overloadAlertSender = overloadAlertSender;

  // --- 기본 임계값 ---
  // 1인 사용자의 정상 외부 API 호출은 하루 수십 회 수준이다. 100회만 넘어도
  // 비정상 신호이므로 warn은 낮게(로그만, 기능 영향 없음), block은 정상 헤비
  // 사용자가 억울하게 막히지 않을 안전 마진만 둔다. (과거 1000/5000 → 폭주를
  // 수천 회까지 허용해 SK 한도/비용 낭비 → 대폭 하향)
  static const int defaultWarnThreshold = 100;
  static const int defaultBlockThreshold = 600;

  // --- SharedPreferences 키 접두사 ---
  static const String _countKeyPrefix = 'api_usage:';
  static const String _warnFlagPrefix = 'api_usage_warned:';
  static const String keyLastWarning = 'api_usage_last_warning';
  static const String keyBlocked = 'api_usage_blocked';

  final Map<String, ApiUsageThreshold> _thresholds;
  final Future<SharedPreferences> Function() _prefsFactory;
  final DateTime Function() _now;

  /// 폭주 통보 전송기. null이면 통보하지 않는다(테스트 기본값).
  /// 운영 싱글톤(instance)만 실제 HTTP 전송기를 주입한다.
  final OverloadAlertSender? _overloadAlertSender;

  /// 오늘의 날짜 문자열 (yyyy-MM-dd)
  String _todayKey() {
    final d = _now();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  /// count 영속 키: `api_usage:{date}:{api}`
  String _countKey(String api) => '$_countKeyPrefix${_todayKey()}:$api';

  /// warn 1회성 플래그 키: `api_usage_warned:{date}:{api}`
  String _warnFlagKey(String api) => '$_warnFlagPrefix${_todayKey()}:$api';

  ApiUsageThreshold _thresholdFor(String api) {
    return _thresholds[api] ??
        const ApiUsageThreshold(
          warn: ApiUsageGuard.defaultWarnThreshold,
          block: ApiUsageGuard.defaultBlockThreshold,
        );
  }

  /// 해당 API의 오늘 사용 횟수를 반환한다.
  Future<int> todayCount(String api) async {
    final prefs = await _prefsFactory();
    return prefs.getInt(_countKey(api)) ?? 0;
  }

  /// API 호출 시도를 소비한다.
  ///
  /// - block 임계 초과 → `false` 반환 (호출 차단)
  /// - 그 외 → 카운트 증가 후 `true` 반환
  /// - warn 임계 첫 도달 시 진단 기록 (중복 방지)
  Future<bool> tryConsume(String api) async {
    final prefs = await _prefsFactory();
    final key = _countKey(api);
    final threshold = _thresholdFor(api);

    // 현재 카운트 읽기 (과거 날짜 키는 오늘 키와 다르므로 자동 무시)
    final current = prefs.getInt(key) ?? 0;

    // 이미 block 임계 초과 상태이면 즉시 차단
    if (current >= threshold.block) {
      await _recordBlocked(prefs, api, current, StackTrace.current);
      return false;
    }

    // 카운트 +1
    final next = current + 1;
    await prefs.setInt(key, next);

    // warn 임계 도달 시 1회성 경고 기록
    if (next >= threshold.warn) {
      final warnFlag = _warnFlagKey(api);
      final alreadyWarned = prefs.getBool(warnFlag) ?? false;
      if (!alreadyWarned) {
        await prefs.setBool(warnFlag, true);
        await _recordWarning(prefs, api, next);
      }
    }

    // block 임계 도달(이번 호출로 처음 초과)하면 차단
    if (next >= threshold.block) {
      await _recordBlocked(prefs, api, next, StackTrace.current);
      return false;
    }

    return true;
  }

  /// 경고 수준 진단 기록.
  Future<void> _recordWarning(
      SharedPreferences prefs, String api, int count) async {
    final date = _todayKey();
    final message = 'WARN api=$api count=$count date=$date';
    await prefs.setString(keyLastWarning, message);
    DiagLogger.log('ApiUsageGuard', message);
  }

  /// 차단 수준 진단 기록 + 폭주 원인 자동 통보(1일 1회).
  Future<void> _recordBlocked(
    SharedPreferences prefs,
    String api,
    int count,
    StackTrace stack,
  ) async {
    final date = _todayKey();
    final message = 'BLOCKED api=$api count=$count date=$date';
    await prefs.setString(keyBlocked, message);
    DiagLogger.log('ApiUsageGuard', message);

    // 단순 차단에 그치지 않고, 폭주를 일으킨 호출 스택(원인 코드 위치)과
    // 최근 진단을 서버 경유로 텔레그램/디스코드에 자동 통보한다.
    // 알림 자체가 폭주하지 않도록 같은 API는 하루 1회만 전송한다.
    final alertFlag = 'api_usage_alert_sent:$date:$api';
    if (prefs.getBool(alertFlag) ?? false) {
      return;
    }
    await prefs.setBool(alertFlag, true);
    final sender = _overloadAlertSender;
    if (sender != null) {
      unawaited(sender(api, count, date, stack));
    }
  }

  /// 폭주 진단(호출 스택 + 최근 로그)을 서버 알림 엔드포인트로 전송한다.
  /// 텔레그램 토큰 등은 서버에만 있으므로 앱은 진단만 보낸다. 실패는 무시한다.
  static Future<void> _defaultHttpOverloadAlert(
    String api,
    int count,
    String date,
    StackTrace stack,
  ) async {
    try {
      final stackStr = stack.toString();
      final trimmedStack =
          stackStr.length > 2000 ? stackStr.substring(0, 2000) : stackStr;
      final diag = DiagLogger.dump();
      final recentDiag =
          diag.length > 1500 ? diag.substring(diag.length - 1500) : diag;
      await http
          .post(
            Uri.parse('https://fluxstudio.co.kr/api/feedback/notify'),
            headers: const <String, String>{
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'type': 'bug',
              'source': 'android-app',
              'message': '[API 폭주 차단] api=$api count=$count date=$date\n'
                  '— 폭주를 일으킨 호출 스택(원인 위치) —\n$trimmedStack\n'
                  '— 최근 진단 로그 —\n$recentDiag',
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      DiagLogger.log('ApiUsageGuard', 'overload alert send failed: $error');
    }
  }

  /// 과거 날짜 키를 정리한다 (선택적 유지보수 — 앱이 장기 설치될 때).
  /// [today]를 주입하지 않으면 _todayKey()를 사용한다.
  Future<void> cleanupOldKeys({String? today}) async {
    final prefs = await _prefsFactory();
    final todayPrefix = '$_countKeyPrefix${today ?? _todayKey()}:';
    final warnTodayPrefix = '$_warnFlagPrefix${today ?? _todayKey()}:';
    final toRemove = prefs
        .getKeys()
        .where((key) =>
            (key.startsWith(_countKeyPrefix) &&
                !key.startsWith(todayPrefix)) ||
            (key.startsWith(_warnFlagPrefix) &&
                !key.startsWith(warnTodayPrefix)))
        .toList();
    for (final key in toRemove) {
      await prefs.remove(key);
    }
  }

  // --- 싱글톤 ---
  static ApiUsageGuard? _instance;

  /// 기본 임계값을 사용하는 싱글톤 인스턴스.
  /// 테스트에서는 생성자로 직접 주입하고 이 getter는 사용하지 않는다.
  ///
  /// API 성격별 차등: routes(이동시간)는 일정 저장/출발 직전에만 쓰여 정상량이
  /// 가장 적으므로 가장 낮게, POI(장소 검색)는 사용자 직접 검색도 포함하므로
  /// 약간 높게 둔다. warn은 모두 100(조기 진단 로그), block은 정상 상한 위.
  static ApiUsageGuard get instance {
    _instance ??= ApiUsageGuard(
      thresholds: const <String, ApiUsageThreshold>{
        // warn은 낮게(100) 유지 → 하루 100회만 넘어도 진단 로그로 조기 인지.
        // block(실제 차단)은 정상·개발 사용을 막지 않고 확실한 폭주(과거 16,000회)
        // 만 끊도록 상향. (이전 routes 300은 하루 종일 개발 테스트 누적에 걸려
        // 지도 좌표 해석이 막히는 부작용이 있었음)
        ApiName.tmapPoi: ApiUsageThreshold(warn: 100, block: 2000),
        ApiName.tmapRoutes: ApiUsageThreshold(warn: 100, block: 2000),
        ApiName.naverGeocode: ApiUsageThreshold(warn: 100, block: 2000),
        ApiName.googleGeocode: ApiUsageThreshold(warn: 100, block: 2000),
      },
      overloadAlertSender: _defaultHttpOverloadAlert,
    );
    return _instance!;
  }

  /// 테스트에서 싱글톤을 초기화할 때 사용.
  static void resetForTesting() {
    _instance = null;
  }
}

/// API별 임계값 설정.
class ApiUsageThreshold {
  const ApiUsageThreshold({
    required this.warn,
    required this.block,
  }) : assert(warn < block, 'warn must be less than block');

  final int warn;
  final int block;
}

/// 애플리케이션에서 사용하는 API 이름 상수.
class ApiName {
  ApiName._();

  static const String tmapPoi = 'tmap_poi';
  static const String tmapRoutes = 'tmap_routes';
  static const String naverGeocode = 'naver_geocode';
  static const String googleGeocode = 'google_geocode';
}
