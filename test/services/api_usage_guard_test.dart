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
  // 1. 카운트 증가 및 persist
  // ------------------------------------------------------------------ //
  test('tryConsume 호출마다 카운트가 1씩 증가하고 SharedPreferences에 저장된다', () async {
    final guard = ApiUsageGuard(
      thresholds: {
        'test_api': const ApiUsageThreshold(warn: 1000, block: 5000),
      },
    );

    expect(await guard.todayCount('test_api'), 0);
    await guard.tryConsume('test_api');
    expect(await guard.todayCount('test_api'), 1);
    await guard.tryConsume('test_api');
    await guard.tryConsume('test_api');
    expect(await guard.todayCount('test_api'), 3);
  });

  // ------------------------------------------------------------------ //
  // 2. 날짜가 바뀌면 새 날짜의 카운트는 0
  // ------------------------------------------------------------------ //
  test('날짜가 다르면 카운트가 독립적으로 관리된다', () async {
    var fakeDay = DateTime(2026, 6, 27);
    final guard = ApiUsageGuard(
      thresholds: {
        'test_api': const ApiUsageThreshold(warn: 1000, block: 5000),
      },
      now: () => fakeDay,
    );

    // 오늘(6/27) 3회 소비
    await guard.tryConsume('test_api');
    await guard.tryConsume('test_api');
    await guard.tryConsume('test_api');
    expect(await guard.todayCount('test_api'), 3);

    // 날짜가 바뀌면(6/28) 카운트는 0에서 시작
    fakeDay = DateTime(2026, 6, 28);
    expect(await guard.todayCount('test_api'), 0);

    await guard.tryConsume('test_api');
    expect(await guard.todayCount('test_api'), 1);
  });

  // ------------------------------------------------------------------ //
  // 3. block 임계 초과 시 false 반환
  // ------------------------------------------------------------------ //
  test('block 임계 초과 시 tryConsume이 false를 반환한다', () async {
    final guard = ApiUsageGuard(
      thresholds: {
        'test_api': const ApiUsageThreshold(warn: 3, block: 5),
      },
    );

    // 5번까지는 true (4번은 warn 영역, 5번째가 block 임계 도달)
    for (var i = 0; i < 4; i++) {
      expect(await guard.tryConsume('test_api'), isTrue,
          reason: '${i + 1}번째 호출은 허용되어야 함');
    }

    // 5번째 호출이 block 임계(5) 도달 → false
    expect(await guard.tryConsume('test_api'), isFalse);
    // 이후 호출도 계속 false
    expect(await guard.tryConsume('test_api'), isFalse);
    expect(await guard.tryConsume('test_api'), isFalse);
  });

  // ------------------------------------------------------------------ //
  // 4. 정상 범위에서 true 반환
  // ------------------------------------------------------------------ //
  test('block 임계 미만에서는 항상 true를 반환한다', () async {
    final guard = ApiUsageGuard(
      thresholds: {
        'normal_api': const ApiUsageThreshold(warn: 1000, block: 5000),
      },
    );

    // 정상 사용량(수백 회) 시뮬레이션
    for (var i = 0; i < 300; i++) {
      final result = await guard.tryConsume('normal_api');
      expect(result, isTrue, reason: '${i + 1}번째 정상 호출이 차단되면 안 됨');
    }
    expect(await guard.todayCount('normal_api'), 300);
  });

  // ------------------------------------------------------------------ //
  // 5. 차단 시 SharedPreferences에 진단 키 기록
  // ------------------------------------------------------------------ //
  test('block 임계 도달 시 SharedPreferences에 진단 메시지가 기록된다', () async {
    final guard = ApiUsageGuard(
      thresholds: {
        'diag_api': const ApiUsageThreshold(warn: 2, block: 3),
      },
    );

    // 3번째 호출에서 block
    await guard.tryConsume('diag_api');
    await guard.tryConsume('diag_api');
    expect(await guard.tryConsume('diag_api'), isFalse);

    final prefs = await SharedPreferences.getInstance();
    final blocked = prefs.getString(ApiUsageGuard.keyBlocked);
    expect(blocked, isNotNull);
    expect(blocked, contains('diag_api'));
    expect(blocked, contains('BLOCKED'));
  });

  // ------------------------------------------------------------------ //
  // 6. warn 임계 도달 시 경고 키 기록 (1회성)
  // ------------------------------------------------------------------ //
  test('warn 임계 도달 시 SharedPreferences에 경고 메시지가 기록된다', () async {
    final guard = ApiUsageGuard(
      thresholds: {
        'warn_api': const ApiUsageThreshold(warn: 2, block: 10),
      },
    );

    // 1번째 — warn 미도달
    await guard.tryConsume('warn_api');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ApiUsageGuard.keyLastWarning), isNull);

    // 2번째 — warn 임계(2) 도달 → 경고 기록
    await guard.tryConsume('warn_api');
    final warning = prefs.getString(ApiUsageGuard.keyLastWarning);
    expect(warning, isNotNull);
    expect(warning, contains('WARN'));
    expect(warning, contains('warn_api'));

    // 3번째 — 경고는 1회성이므로 내용이 바뀌지 않아야 함
    final warningBefore = warning;
    await guard.tryConsume('warn_api');
    expect(
      prefs.getString(ApiUsageGuard.keyLastWarning),
      warningBefore,
      reason: '경고 메시지는 1회만 기록되어야 함',
    );
  });

  // ------------------------------------------------------------------ //
  // 7. tmap_poi가 block 초과면 _searchTmap이 빈 결과 반환 (HTTP 호출 0회)
  // ------------------------------------------------------------------ //
  test('tmap_poi가 block 초과 시 LocationLookupService가 HTTP 호출 없이 빈 결과 반환', () async {
    var httpCallCount = 0;

    // block을 1로 설정한 가드로 이미 차단 상태를 만든다
    final guard = ApiUsageGuard(
      thresholds: {
        ApiName.tmapPoi: const ApiUsageThreshold(warn: 1, block: 1),
      },
    );
    // 1번 소비 → block 임계(1) 도달
    await guard.tryConsume(ApiName.tmapPoi);

    final service = LocationLookupService(
      clientId: '',
      clientSecret: '',
      proxyUrl: '',
      tmapApiKey: 'real-tmap-key',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        httpCallCount++;
        // tmap_poi 차단 시 이 핸들러가 호출되어선 안 됨
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

    // tmap_poi 차단 → Naver도 key 없음 → 결과 없음
    expect(results, isEmpty);
    // tmap_poi HTTP 호출이 0회여야 함
    expect(httpCallCount, 0,
        reason: 'tmap_poi가 차단된 경우 HTTP 요청이 발생하면 안 됨');
  });

  // ------------------------------------------------------------------ //
  // 8. tmap_routes 차단 시 MapService.getTravelMinutes가 null 반환
  // ------------------------------------------------------------------ //
  test('tmap_routes 차단 시 MapService가 HTTP 호출 없이 null 반환한다', () async {
    var httpCallCount = 0;

    final guard = ApiUsageGuard(
      thresholds: {
        ApiName.tmapRoutes: const ApiUsageThreshold(warn: 1, block: 1),
      },
    );
    // 미리 block 임계 도달
    await guard.tryConsume(ApiName.tmapRoutes);

    final service = MapService(
      tmapApiKey: 'real-tmap-key',
      naverProxyUrl: '',
      naverClientId: '',
      naverClientSecret: '',
      httpClientFactory: () => MockClient((request) async {
        httpCallCount++;
        // tmap_routes 차단 → 이 핸들러가 호출되면 안 됨
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

    // tmap_routes 차단 → Naver도 key 없음 → null
    expect(estimate, isNull);
    expect(httpCallCount, 0,
        reason: 'tmap_routes가 차단된 경우 HTTP 요청이 발생하면 안 됨');
  });

  // ------------------------------------------------------------------ //
  // 9. API별 카운트는 독립적으로 관리된다
  // ------------------------------------------------------------------ //
  test('서로 다른 API의 카운트는 독립적이다', () async {
    final guard = ApiUsageGuard(
      thresholds: {
        'api_a': const ApiUsageThreshold(warn: 10, block: 5),
        'api_b': const ApiUsageThreshold(warn: 1000, block: 5000),
      },
    );

    // api_a를 block 초과
    for (var i = 0; i < 5; i++) {
      await guard.tryConsume('api_a');
    }
    expect(await guard.tryConsume('api_a'), isFalse);

    // api_b는 영향 없이 정상
    expect(await guard.tryConsume('api_b'), isTrue);
    expect(await guard.tryConsume('api_b'), isTrue);
  });

  // ------------------------------------------------------------------ //
  // 10. cleanupOldKeys — 과거 날짜 키 정리
  // ------------------------------------------------------------------ //
  test('cleanupOldKeys는 과거 날짜 키만 제거하고 오늘 키는 유지한다', () async {
    final prefs = await SharedPreferences.getInstance();
    // 과거 날짜 키를 수동으로 심기
    await prefs.setInt('api_usage:2026-01-01:old_api', 999);
    await prefs.setInt('api_usage:2026-06-26:old_api', 50);

    final guard = ApiUsageGuard(
      now: () => DateTime(2026, 6, 27),
    );
    // 오늘 키 생성
    await guard.tryConsume('live_api');

    await guard.cleanupOldKeys(today: '2026-06-27');

    final keys = prefs.getKeys();
    expect(keys.any((k) => k.contains('2026-01-01')), isFalse);
    expect(keys.any((k) => k.contains('2026-06-26')), isFalse);
    expect(keys.any((k) => k.contains('2026-06-27')), isTrue);
  });
}
