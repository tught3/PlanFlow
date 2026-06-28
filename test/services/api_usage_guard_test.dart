import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiUsageGuard.resetForTesting();
  });

  // ------------------------------------------------------------------ //
  // 1. rateLimit 미만에서 계속 true
  //
  // 동작: 윈도우 내 누적 카운트가 rateLimit 미만이면 허용.
  // rateLimit=5 → 5개가 쌓이기 전까지(0..4개 저장된 상태) 허용.
  // 즉 1~5번째 호출은 모두 true, 6번째부터 false.
  // ------------------------------------------------------------------ //
  test('윈도우 내 호출이 rateLimit 미만이면 계속 true를 반환한다', () async {
    // rateLimit=5: 5개까지 허용(카운트 5개 쌓이면 다음 호출이 차단)
    final guard = ApiUsageGuard(
      configs: {
        'test_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 5),
      },
    );

    // 5번 호출 — 모두 허용 (각 호출 후 카운트 1→2→3→4→5)
    for (var i = 0; i < 5; i++) {
      expect(await guard.tryConsume('test_api'), isTrue,
          reason: '${i + 1}번째 호출은 허용되어야 함 (카운트 ${i + 1}/rateLimit=5)');
    }
    expect(await guard.windowCount('test_api'), 5);
  });

  // ------------------------------------------------------------------ //
  // 2. rateLimit 도달(이미 rateLimit개 존재) 시 false (자동 차단)
  // ------------------------------------------------------------------ //
  test('윈도우에 rateLimit개가 쌓인 이후 호출은 false를 반환한다', () async {
    // rateLimit=3: 3개 쌓이면 이후 호출 차단
    final guard = ApiUsageGuard(
      configs: {
        'test_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 3),
      },
    );

    // 3번 허용 → 카운트=3
    for (var i = 0; i < 3; i++) {
      expect(await guard.tryConsume('test_api'), isTrue,
          reason: '${i + 1}번째(rateLimit=3): 허용');
    }
    // 이후 호출은 차단 (카운트=3 >= rateLimit=3)
    expect(await guard.tryConsume('test_api'), isFalse,
        reason: '4번째: 카운트가 rateLimit에 도달했으므로 차단');
    expect(await guard.tryConsume('test_api'), isFalse,
        reason: '5번째: 여전히 차단');
  });

  // ------------------------------------------------------------------ //
  // 3. [핵심 회귀] 시간 경과 후 자동 재개
  // ------------------------------------------------------------------ //
  test('윈도우(60초)를 초과하는 시간이 지나면 자동으로 재개(true)된다', () async {
    var fakeNow = DateTime(2026, 6, 28, 10, 0, 0);
    final guard = ApiUsageGuard(
      configs: {
        'test_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 3),
      },
      now: () => fakeNow,
    );

    // T=0: 3번 허용 → 카운트=3 (다음 호출부터 차단)
    await guard.tryConsume('test_api');
    await guard.tryConsume('test_api');
    await guard.tryConsume('test_api');
    expect(await guard.tryConsume('test_api'), isFalse,
        reason: 'T=0: 카운트=3, 이미 rateLimit 도달 → 차단');

    // T=+30초: 윈도우(60초) 내에 있으므로 여전히 차단
    fakeNow = DateTime(2026, 6, 28, 10, 0, 30);
    expect(await guard.tryConsume('test_api'), isFalse,
        reason: '+30초: 윈도우 내 타임스탬프 3개 유효 → 차단');

    // T=+61초: 모든 타임스탬프가 윈도우(60초) 밖으로 → 카운트=0 → 자동 재개
    fakeNow = DateTime(2026, 6, 28, 10, 1, 1);
    expect(await guard.tryConsume('test_api'), isTrue,
        reason: '+61초: 윈도우 내 타임스탬프 없음 → 자동 재개');
  });

  // ------------------------------------------------------------------ //
  // 4. 차단된 호출은 윈도우 카운트에 추가되지 않는다
  // ------------------------------------------------------------------ //
  test('차단된 호출은 타임스탬프에 추가되지 않아 카운트가 늘지 않는다', () async {
    final guard = ApiUsageGuard(
      configs: {
        'test_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 3),
      },
    );

    // 3번 허용 → 카운트=3
    await guard.tryConsume('test_api');
    await guard.tryConsume('test_api');
    await guard.tryConsume('test_api');

    // 이후 10번 더 호출해도 모두 차단되어 카운트는 3 그대로
    for (var i = 0; i < 10; i++) {
      await guard.tryConsume('test_api');
    }
    final count = await guard.windowCount('test_api');
    expect(count, 3,
        reason: '차단된 호출은 카운트에 추가되지 않아 rateLimit(3)에서 멈춰야 함');
  });

  // ------------------------------------------------------------------ //
  // 5. 차단 시작 시 통보 sender가 1회 호출된다
  // ------------------------------------------------------------------ //
  test('차단이 시작될 때 overloadAlertSender가 1회 호출된다', () async {
    var senderCallCount = 0;
    String? lastApi;

    final guard = ApiUsageGuard(
      configs: {
        'alert_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 2),
      },
      overloadAlertSender: (api, count, date, stack) async {
        senderCallCount++;
        lastApi = api;
      },
      alertCooldownMinutes: 999, // 쿨다운 무력화
    );

    // 2번 허용 (카운트=2 = rateLimit)
    await guard.tryConsume('alert_api');
    await guard.tryConsume('alert_api');
    // 3번째 → 차단 시작 → sender 호출 예상
    await guard.tryConsume('alert_api');
    // sender는 unawaited로 실행되므로 microtask flush
    await Future<void>.delayed(Duration.zero);

    expect(senderCallCount, 1, reason: '차단 시작 시 sender가 1회 호출되어야 함');
    expect(lastApi, 'alert_api');
  });

  // ------------------------------------------------------------------ //
  // 6. 쿨다운 내 반복 차단에는 추가 통보 없음, 쿨다운 만료 후 재전송
  // ------------------------------------------------------------------ //
  test('쿨다운 내 반복 차단 시 sender가 추가로 호출되지 않는다', () async {
    var senderCallCount = 0;
    var fakeNow = DateTime(2026, 6, 28, 12, 0, 0);

    final guard = ApiUsageGuard(
      configs: {
        'cooldown_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 2),
      },
      now: () => fakeNow,
      overloadAlertSender: (api, count, date, stack) async {
        senderCallCount++;
      },
      alertCooldownMinutes: 5,
    );

    // 2번 허용 → 카운트=2
    await guard.tryConsume('cooldown_api');
    await guard.tryConsume('cooldown_api');
    // 3번째 → 차단 #1 → sender 예상
    await guard.tryConsume('cooldown_api');
    await Future<void>.delayed(Duration.zero);
    expect(senderCallCount, 1, reason: '첫 차단 시 1회 통보');

    // 쿨다운 내(+2분) 재차단 → sender 추가 호출 없음
    fakeNow = fakeNow.add(const Duration(minutes: 2));
    await guard.tryConsume('cooldown_api'); // 윈도우 내 타임스탬프 여전히 2개
    await Future<void>.delayed(Duration.zero);
    expect(senderCallCount, 1, reason: '쿨다운 중 추가 통보 없어야 함');

    // 쿨다운 만료 + 윈도우 만료 후 재차단 → sender 재호출
    fakeNow = fakeNow.add(const Duration(minutes: 10)); // 총 +12분
    // 윈도우(60초)가 지났으므로 새로 2번 허용 후 차단
    await guard.tryConsume('cooldown_api');
    await guard.tryConsume('cooldown_api');
    await guard.tryConsume('cooldown_api'); // 차단 #2
    await Future<void>.delayed(Duration.zero);
    expect(senderCallCount, 2, reason: '쿨다운 만료 후 재차단 시 통보 재개');
  });

  // ------------------------------------------------------------------ //
  // 7. 전송기 미주입 시 네트워크 호출 없음
  // ------------------------------------------------------------------ //
  test('overloadAlertSender가 null이면 차단 시 예외 없이 조용히 동작한다', () async {
    final guard = ApiUsageGuard(
      configs: {
        'no_sender_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 2),
      },
      // overloadAlertSender 생략 → null
    );

    await guard.tryConsume('no_sender_api');
    await guard.tryConsume('no_sender_api'); // 카운트=2
    final result = await guard.tryConsume('no_sender_api'); // 차단
    expect(result, isFalse, reason: '차단은 되어야 함');
    // 여기까지 예외 없이 도달하면 네트워크 호출 없이 정상 동작
  });

  // ------------------------------------------------------------------ //
  // 8. API별 카운트는 독립적으로 관리된다
  // ------------------------------------------------------------------ //
  test('서로 다른 API의 카운트는 독립적이다', () async {
    final guard = ApiUsageGuard(
      configs: {
        'api_a': const ApiRateConfig(windowSeconds: 60, rateLimit: 3),
        'api_b': const ApiRateConfig(windowSeconds: 60, rateLimit: 100),
      },
    );

    // api_a를 3번 허용 → 이후 차단
    for (var i = 0; i < 3; i++) {
      await guard.tryConsume('api_a');
    }
    expect(await guard.tryConsume('api_a'), isFalse,
        reason: 'api_a는 차단되어야 함');

    // api_b는 영향 없이 정상
    expect(await guard.tryConsume('api_b'), isTrue);
    expect(await guard.tryConsume('api_b'), isTrue);
  });

  // ------------------------------------------------------------------ //
  // 9. tmap_poi 차단 시 LocationLookupService가 HTTP 호출 없이 빈 결과 반환
  // ------------------------------------------------------------------ //
  test('tmap_poi 차단 시 LocationLookupService가 HTTP 호출 없이 빈 결과 반환', () async {
    var httpCallCount = 0;

    // rateLimit=1: 1개 쌓이면 이후 모두 차단
    final guard = ApiUsageGuard(
      configs: {
        ApiName.tmapPoi: const ApiRateConfig(windowSeconds: 60, rateLimit: 1),
      },
    );
    await guard.tryConsume(ApiName.tmapPoi); // 카운트=1 (다음 호출부터 차단)

    final service = LocationLookupService(
      clientId: '',
      clientSecret: '',
      proxyUrl: '',
      tmapApiKey: 'real-tmap-key',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        httpCallCount++;
        return http.Response(
          jsonEncode({
            'searchPoiInfo': {
              'pois': {
                'poi': [
                  {
                    'name': 'TMAP 결과',
                    'noorLat': '37.5665',
                    'noorLon': '126.978',
                  }
                ]
              }
            }
          }),
          200,
        );
      }),
      usageGuard: guard,
    );

    final results = await service.search('테스트 장소');

    expect(results, isEmpty, reason: 'tmap_poi 차단 시 결과는 비어야 함');
    expect(httpCallCount, 0,
        reason: 'tmap_poi 차단 시 HTTP 요청이 발생하면 안 됨');
  });

  // ------------------------------------------------------------------ //
  // 10. tmap_routes 차단 시 MapService.getTravelMinutes가 null 반환
  // ------------------------------------------------------------------ //
  test('tmap_routes 차단 시 MapService가 HTTP 호출 없이 null 반환한다', () async {
    var httpCallCount = 0;

    final guard = ApiUsageGuard(
      configs: {
        ApiName.tmapRoutes:
            const ApiRateConfig(windowSeconds: 60, rateLimit: 1),
      },
    );
    await guard.tryConsume(ApiName.tmapRoutes); // 카운트=1

    final service = MapService(
      tmapApiKey: 'real-tmap-key',
      naverProxyUrl: '',
      naverClientId: '',
      naverClientSecret: '',
      httpClientFactory: () => MockClient((request) async {
        httpCallCount++;
        return http.Response(
          jsonEncode({
            'features': [
              {'properties': <String, int>{'totalTime': 1800}}
            ]
          }),
          200,
        );
      }),
      usageGuard: guard,
    );

    final estimate = await service.getTravelMinutes(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
    );

    expect(estimate, isNull, reason: 'tmap_routes 차단 시 null을 반환해야 함');
    expect(httpCallCount, 0,
        reason: 'tmap_routes 차단 시 HTTP 요청이 발생하면 안 됨');
  });

  // ------------------------------------------------------------------ //
  // 11. 하위 호환: ApiUsageThreshold가 rateLimit=block으로 동작
  // ------------------------------------------------------------------ //
  test('ApiUsageThreshold(warn:, block:)를 configs에 넣으면 block이 rateLimit으로 동작한다',
      () async {
    // ignore: deprecated_member_use_from_same_package
    final guard = ApiUsageGuard(
      configs: {
        'compat_api': const ApiUsageThreshold(warn: 2, block: 4),
      },
    );

    // block=4: 4개 쌓이면 이후 차단
    for (var i = 0; i < 4; i++) {
      expect(await guard.tryConsume('compat_api'), isTrue,
          reason: '${i + 1}번째: 허용 (block=4)');
    }
    // 5번째 → 카운트=4 >= rateLimit=4 → 차단
    expect(await guard.tryConsume('compat_api'), isFalse,
        reason: 'block(4)에 도달한 이후 차단');
  });

  // ------------------------------------------------------------------ //
  // 12. cleanupOldKeys — 구 날짜 형식 키 마이그레이션 정리
  // ------------------------------------------------------------------ //
  test('cleanupOldKeys는 구 날짜 형식 키(api_usage:...)를 제거한다', () async {
    final prefs = await SharedPreferences.getInstance();
    // 구 포맷 키를 수동으로 심기
    await prefs.setInt('api_usage:2026-01-01:old_api', 999);
    await prefs.setInt('api_usage:2026-06-26:old_api', 50);
    await prefs.setBool('api_usage_warned:2026-06-26:old_api', true);

    final guard = ApiUsageGuard(
      now: () => DateTime(2026, 6, 27),
    );
    // 새 포맷으로 타임스탬프 생성
    await guard.tryConsume('live_api');

    await guard.cleanupOldKeys(today: '2026-06-27');

    final keys = prefs.getKeys();
    expect(keys.any((k) => k.startsWith('api_usage:')), isFalse,
        reason: '구 날짜별 카운트 키가 제거되어야 함');
    expect(keys.any((k) => k.startsWith('api_usage_warned:')), isFalse,
        reason: '구 warn 플래그 키가 제거되어야 함');
    // 새 포맷 키(api_rate:...)는 유지
    expect(keys.any((k) => k.startsWith('api_rate:')), isTrue,
        reason: '새 슬라이딩 윈도우 버킷은 유지되어야 함');
  });

  // ------------------------------------------------------------------ //
  // 13. windowCount는 차단 이후 허용된 호출 수만 정확히 반환
  // ------------------------------------------------------------------ //
  test('windowCount는 허용된 호출 수만 반환하고 차단된 호출은 포함하지 않는다', () async {
    final guard = ApiUsageGuard(
      configs: {
        'count_api': const ApiRateConfig(windowSeconds: 60, rateLimit: 3),
      },
    );

    // 3번 허용 → windowCount=3
    await guard.tryConsume('count_api');
    await guard.tryConsume('count_api');
    await guard.tryConsume('count_api');
    // 이후 차단된 호출들
    await guard.tryConsume('count_api'); // 차단
    await guard.tryConsume('count_api'); // 차단

    final count = await guard.windowCount('count_api');
    expect(count, 3,
        reason: '차단된 호출은 windowCount에 포함되지 않아 정확히 3이어야 함');
  });
}
