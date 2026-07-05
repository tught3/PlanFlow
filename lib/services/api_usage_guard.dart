import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diag_logger.dart';

/// 폭주 통보 전송기 시그니처. (api, 윈도우카운트, 윈도우길이(초), 폭주 호출 스택)
typedef OverloadAlertSender = Future<void> Function(
  String api,
  int count,
  String date,
  StackTrace stack,
);

/// 외부 API 호출을 **슬라이딩 윈도우 빈도** 기반으로 감시하고,
/// 윈도우 내 호출 수가 rateLimit 이상이면 **자동 차단**,
/// 시간이 흘러 윈도우 내 호출 수가 줄면 **자동 재개**하는 circuit breaker.
///
/// ## 동작 요약
/// - 각 API별로 최근 [windowSeconds]초 동안의 호출 타임스탬프 버킷을
///   SharedPreferences에 영속 저장한다(백그라운드 isolate와 공유 가능).
/// - `tryConsume(api)`: 윈도우 내 카운트 >= rateLimit이면 false(차단),
///   아니면 타임스탬프 기록 후 true(허용).
/// - 차단된 호출은 타임스탬프에 추가하지 않아 폭주를 가속하지 않는다.
/// - 별도 해제 플래그 없이, 시간이 흘러 오래된 타임스탬프가 윈도우 밖으로
///   밀려나면 자연히 다시 허용된다(자동 재개).
/// - 차단이 시작(closed→open 전이)될 때 [overloadAlertSender]로 1회 통보,
///   같은 API는 [alertCooldownMinutes]분 동안 추가 통보 없음(도배 방지).
///
/// ## rateLimit / windowSeconds 기본값 근거
/// - 정상 1인 사용: 60초에 최대 한두 자리 호출 (사용자가 직접 검색해도 수~10회)
/// - 과거 폭주 사례: 좌표 해석 실패 루프 → 하루 16,000회 (초당 수십 회)
/// - 기본값: windowSeconds=60, tmapPoi rateLimit=60 (사용자 검색 포함으로 여유),
///   tmapRoutes=40 (일정 저장·출발 전에만 호출, 정상 비율이 낮음)
///   → 루프 폭주는 60초 40~60회가 넘는 순간 즉시 차단, 정상 사용은 통과.
class ApiUsageGuard {
  ApiUsageGuard({
    Map<String, ApiRateConfig>? configs,
    Future<SharedPreferences> Function()? prefsFactory,
    DateTime Function()? now,
    OverloadAlertSender? overloadAlertSender,
    int alertCooldownMinutes = 5,
  })  : _configs = configs ?? const {},
        _prefsFactory = prefsFactory ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now,
        _overloadAlertSender = overloadAlertSender,
        _alertCooldownMinutes = alertCooldownMinutes;

  // --- 기본 설정 ---
  static const int defaultWindowSeconds = 60;
  static const int defaultRateLimit = 60;

  // --- SharedPreferences 키 ---
  /// 버킷 저장소: `api_rate:{api}` → JSON `List<int>` (epoch 밀리초 버킷)
  static const String _bucketKeyPrefix = 'api_rate:';

  /// 차단 상태 진단 키 (피드백 첨부용)
  static const String keyBlocked = 'api_usage_blocked';

  /// 마지막 경고 진단 키
  static const String keyLastWarning = 'api_usage_last_warning';

  /// 통보 쿨다운 키 접두사: `api_rate_alert_ts:{api}` → int (epoch ms)
  static const String _alertTsPrefix = 'api_rate_alert_ts:';

  final Map<String, ApiRateConfig> _configs;
  final Future<SharedPreferences> Function() _prefsFactory;
  final DateTime Function() _now;
  final OverloadAlertSender? _overloadAlertSender;
  final int _alertCooldownMinutes;

  ApiRateConfig _configFor(String api) {
    return _configs[api] ??
        const ApiRateConfig(
          windowSeconds: ApiUsageGuard.defaultWindowSeconds,
          rateLimit: ApiUsageGuard.defaultRateLimit,
        );
  }

  /// 버킷 키: `api_rate:{api}`
  String _bucketKey(String api) => '$_bucketKeyPrefix$api';

  /// SharedPreferences에서 해당 API의 타임스탬프 버킷(epoch ms 리스트)을 읽는다.
  List<int> _readBuckets(SharedPreferences prefs, String api) {
    final raw = prefs.getString(_bucketKey(api));
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.cast<int>();
      }
    } catch (_) {}
    return [];
  }

  /// 슬라이딩 윈도우 내 타임스탬프만 남기고 저장.
  Future<List<int>> _prunedBuckets(
    SharedPreferences prefs,
    String api,
    int windowMs,
    int nowMs,
  ) async {
    final all = _readBuckets(prefs, api);
    final cutoff = nowMs - windowMs;
    final pruned = all.where((ts) => ts > cutoff).toList();
    await prefs.setString(_bucketKey(api), jsonEncode(pruned));
    return pruned;
  }

  /// 해당 API의 현재 윈도우 내 호출 수를 반환한다.
  Future<int> windowCount(String api) async {
    final prefs = await _prefsFactory();
    final config = _configFor(api);
    final windowMs = config.windowSeconds * 1000;
    final nowMs = _now().millisecondsSinceEpoch;
    final pruned = await _prunedBuckets(prefs, api, windowMs, nowMs);
    return pruned.length;
  }

  /// 하위 호환성: 기존 적용처가 todayCount를 사용하는 경우를 위해 유지.
  /// 슬라이딩 윈도우 카운트를 반환한다.
  Future<int> todayCount(String api) => windowCount(api);

  /// 해당 API의 [ApiRateConfig.rateLimit]를 반환한다.
  /// 호출처가 "한 번에 소비할 수 있는 최대 호출 수"와 비교해 예산을 계산할 때 쓴다.
  int rateLimitFor(String api) => _configFor(api).rateLimit;

  /// 윈도우 내 남은 호출 예산을 반환한다 (`rateLimit - windowCount`).
  /// 음수가 되지 않게 0으로 클램프한다.
  /// 호출처가 "이번 패스/이번 검색이 안전하게 진행 가능한지"를 tryConsume
  /// 전에 미리 알고 싶을 때 사용한다 — 예산이 부족하면 시도조차 하지 않고
  /// 다음 기회로 미룰 수 있다. 이로써 폭주(차단 임계 도달)를 원천 예방한다.
  Future<int> remainingBudget(String api) async {
    final limit = _configFor(api).rateLimit;
    final used = await windowCount(api);
    final remaining = limit - used;
    return remaining < 0 ? 0 : remaining;
  }

  /// API 호출 시도를 소비한다.
  ///
  /// - 윈도우 내 호출수 >= rateLimit → `false` 반환 (자동 차단)
  /// - 그 외 → 타임스탬프 기록 후 `true` 반환
  /// - 차단된 호출은 타임스탬프에 추가하지 않는다(폭주 가속 방지).
  /// - 시간이 흘러 윈도우 내 카운트가 줄면 자연히 `true`로 복구(자동 재개).
  Future<bool> tryConsume(String api) async {
    final prefs = await _prefsFactory();
    final config = _configFor(api);
    final windowMs = config.windowSeconds * 1000;
    final now = _now();
    final nowMs = now.millisecondsSinceEpoch;

    // 오래된 타임스탬프를 제거하고 현재 윈도우 내 카운트를 얻는다
    final current = await _prunedBuckets(prefs, api, windowMs, nowMs);
    final count = current.length;

    if (count >= config.rateLimit) {
      // 폭주 감지 — 차단
      await _recordBlocked(prefs, api, count, StackTrace.current, now);
      return false;
    }

    // 허용 — 타임스탬프 추가 후 저장
    final updated = [...current, nowMs];
    await prefs.setString(_bucketKey(api), jsonEncode(updated));
    return true;
  }

  /// 차단 수준 진단 기록 + 폭주 자동 통보(쿨다운 내 중복 방지).
  Future<void> _recordBlocked(
    SharedPreferences prefs,
    String api,
    int count,
    StackTrace stack,
    DateTime now,
  ) async {
    final config = _configFor(api);
    final message =
        'BLOCKED api=$api window_count=$count limit=${config.rateLimit} window=${config.windowSeconds}s';
    await prefs.setString(keyBlocked, message);
    DiagLogger.log('ApiUsageGuard', message);

    // 통보 쿨다운 확인: 같은 api는 [_alertCooldownMinutes]분에 1회만 전송
    final alertTsKey = '$_alertTsPrefix$api';
    final lastAlertMs = prefs.getInt(alertTsKey) ?? 0;
    final cooldownMs = _alertCooldownMinutes * 60 * 1000;
    final nowMs = now.millisecondsSinceEpoch;

    if (nowMs - lastAlertMs < cooldownMs) {
      // 쿨다운 중 — 전송 스킵
      return;
    }

    // 쿨다운 타임스탬프 갱신
    await prefs.setInt(alertTsKey, nowMs);

    final sender = _overloadAlertSender;
    if (sender != null) {
      final date = _dateStr(now);
      unawaited(sender(api, count, date, stack));
    }
  }

  String _dateStr(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
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
              'message': '[API 폭주 차단] api=$api window_count=$count date=$date\n'
                  '— 폭주를 일으킨 호출 스택(원인 위치) —\n$trimmedStack\n'
                  '— 최근 진단 로그 —\n$recentDiag',
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      DiagLogger.log('ApiUsageGuard', 'overload alert send failed: $error');
    }
  }

  /// 해당 API의 버킷 데이터를 지운다 (선택적 유지보수).
  Future<void> cleanupOldKeys({String? today}) async {
    // 슬라이딩 윈도우 방식에서는 날짜별 키가 없으므로
    // 오래된 타임스탬프는 tryConsume/windowCount 호출 때 자동 프루닝된다.
    // 이 메서드는 하위 호환성을 위해 유지하되 실질 동작은 없다.
    // 필요 시 버킷 전체를 초기화하려면 clearAll()을 사용한다.
    final prefs = await _prefsFactory();
    // 경고/차단 진단 키 중 날짜 기반 구 형식 키 제거 (마이그레이션 지원)
    const oldCountPrefix = 'api_usage:';
    const oldWarnPrefix = 'api_usage_warned:';
    final toRemove = prefs
        .getKeys()
        .where((k) =>
            k.startsWith(oldCountPrefix) || k.startsWith(oldWarnPrefix))
        .toList();
    for (final k in toRemove) {
      await prefs.remove(k);
    }
  }

  // --- 싱글톤 ---
  static ApiUsageGuard? _instance;

  /// 기본 설정을 사용하는 싱글톤 인스턴스.
  /// 테스트에서는 생성자로 직접 주입하고 이 getter는 사용하지 않는다.
  ///
  /// ## rateLimit 선택 근거
  /// - tmapPoi: 사용자 직접 검색 포함 → 60초당 60회 (정상 인터랙션은 수~10회)
  /// - tmapRoutes: 일정 저장·출발 직전에만 호출 → 60초당 40회
  /// - 나머지 geocode: routes와 유사한 빈도 → 60초당 40회
  /// - 과거 폭주: 60초 수백~수천 → 위 기준값으로 즉시 감지.
  static ApiUsageGuard get instance {
    _instance ??= ApiUsageGuard(
      configs: const <String, ApiRateConfig>{
        ApiName.tmapPoi: ApiRateConfig(
          windowSeconds: 60,
          rateLimit: 60,
        ),
        ApiName.tmapRoutes: ApiRateConfig(
          windowSeconds: 60,
          rateLimit: 40,
        ),
        ApiName.naverGeocode: ApiRateConfig(
          windowSeconds: 60,
          rateLimit: 40,
        ),
        ApiName.googleGeocode: ApiRateConfig(
          windowSeconds: 60,
          rateLimit: 40,
        ),
        // GPT: 음성 1회 처리에 수 회 호출(정리+파싱+검증). 비용이 크므로 보수적.
        ApiName.gpt: ApiRateConfig(
          windowSeconds: 60,
          rateLimit: 20,
        ),
        // 캘린더 일괄 내보내기: 저장·동기화 시 루프 POST. 버스트 차단.
        ApiName.naverCalendar: ApiRateConfig(
          windowSeconds: 60,
          rateLimit: 30,
        ),
        ApiName.googleCalendar: ApiRateConfig(
          windowSeconds: 60,
          rateLimit: 30,
        ),
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

/// API별 슬라이딩 윈도우 설정 기반 클래스.
///
/// - [windowSeconds]: 빈도를 측정할 시간 윈도우 (초 단위). 기본 60.
/// - [rateLimit]: 윈도우 내 최대 허용 호출 수. 이 수 이상이면 즉시 차단.
class ApiRateConfig {
  const ApiRateConfig({
    this.windowSeconds = ApiUsageGuard.defaultWindowSeconds,
    required this.rateLimit,
  });

  final int windowSeconds;
  final int rateLimit;
}

/// 하위 호환성을 위한 구 임계값 설정 클래스.
/// 신규 코드는 [ApiRateConfig]를 사용한다.
///
/// [block]이 [ApiRateConfig.rateLimit]으로 매핑된다. [warn]은 현재 무시된다.
class ApiUsageThreshold extends ApiRateConfig {
  const ApiUsageThreshold({required this.warn, required int block})
      : super(
          windowSeconds: ApiUsageGuard.defaultWindowSeconds,
          rateLimit: block,
        );

  /// 조기 경고 임계 (현재 슬라이딩 윈도우 방식에서는 사용되지 않음).
  final int warn;

  /// 구 block 임계 (rateLimit과 동일).
  int get block => rateLimit;
}

/// 애플리케이션에서 사용하는 API 이름 상수.
class ApiName {
  ApiName._();

  static const String tmapPoi = 'tmap_poi';
  static const String tmapRoutes = 'tmap_routes';
  static const String naverGeocode = 'naver_geocode';
  static const String googleGeocode = 'google_geocode';

  /// OpenAI(GPT) 호출. 음성 파싱/정리/브리핑 생성 등. 비용 보호용.
  static const String gpt = 'gpt';

  /// Naver 캘린더 일정 일괄 내보내기(POST 루프).
  static const String naverCalendar = 'naver_calendar';

  /// Google 캘린더 일정 일괄 내보내기(POST 루프).
  static const String googleCalendar = 'google_calendar';
}
