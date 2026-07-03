import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // tmap 호출은 ApiUsageGuard(SharedPreferences)를 거치므로 prefs를 초기화해야
  // 가드가 정상 동작(차단 아님)한다. 또한 static 캐시/가드 카운터를 테스트마다 리셋.
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiUsageGuard.resetForTesting();
    LocationLookupService.resetLookupCacheForTesting();
  });

  test('LocationLookupService parses Naver geocoding results', () async {
    final service = LocationLookupService(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      proxyUrl: '',
      tmapApiKey: '',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        expect(request.url.host, 'naveropenapi.apigw.ntruss.com');
        return http.Response(
          '{"addresses":[{"roadAddress":"Seoul City Hall","jibunAddress":"Seoul","x":"126.9784147","y":"37.5666805"}]}',
          200,
        );
      }),
    );

    final results = await service.search('Seoul City Hall');

    expect(results, hasLength(1));
    expect(results.single.label, 'Seoul City Hall');
    expect(results.single.latitude, 37.5666805);
    expect(results.single.longitude, 126.9784147);
  });

  test('LocationLookupService exposes Naver auth failures', () async {
    final service = LocationLookupService(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      proxyUrl: '',
      tmapApiKey: '',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        return http.Response('unauthorized', 401);
      }),
    );

    expect(
      () => service.search('Seoul Station'),
      throwsA(
        isA<LocationLookupException>().having(
          (error) => error.isAuthFailure,
          'isAuthFailure',
          isTrue,
        ),
      ),
    );
  });

  test('LocationLookupService uses proxy url before client secret headers',
      () async {
    final service = LocationLookupService(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      proxyUrl: 'https://example.supabase.co/functions/v1/naver-geocode',
      tmapApiKey: '',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        expect(request.url.host, 'example.supabase.co');
        expect(request.url.queryParameters['query'], 'Seoul Station');
        expect(request.headers.containsKey('X-NCP-APIGW-API-KEY'), isFalse);
        return http.Response(
          '{"addresses":[{"roadAddress":"Seoul Station","x":"126.9707","y":"37.5547"}]}',
          200,
        );
      }),
    );

    final results = await service.search('Seoul Station');

    expect(results, hasLength(1));
    expect(results.single.latitude, 37.5547);
  });

  test('LocationLookupService merges TMAP POI results before Naver', () async {
    final hosts = <String>[];
    final service = LocationLookupService(
      tmapApiKey: 'tmap-key',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      httpClientFactory: () => MockClient((request) async {
        hosts.add('${request.url.host}${request.url.path}');
        if (request.url.host == 'apis.openapi.sk.com') {
          return http.Response.bytes(
            utf8.encode(
              '{"searchPoiInfo":{"pois":{"poi":[{"name":"원주시청","upperAddrName":"강원특별자치도","middleAddrName":"원주시","lowerAddrName":"무실동","roadName":"시청로","firstBuildNo":"1","frontLon":"127.9197","frontLat":"37.3422"}]}}}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        if (request.url.host == 'naveropenapi.apigw.ntruss.com') {
          return http.Response('{"addresses":[]}', 200);
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final results = await service.search('원주시청');

    expect(hosts, contains('apis.openapi.sk.com/tmap/pois'));
    expect(results, hasLength(1));
    expect(results.single.provider, LocationLookupProvider.tmap);
    expect(results.single.name, '원주시청');
    expect(results.single.latitude, 37.3422);
    expect(results.single.longitude, 127.9197);
  });

  test('LocationLookupService ranks branch candidates by current location',
      () async {
    final service = LocationLookupService(
      tmapApiKey: 'tmap-key',
      clientId: '',
      clientSecret: '',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        if (request.url.host == 'apis.openapi.sk.com') {
          return http.Response.bytes(
            utf8.encode(
              '{"searchPoiInfo":{"pois":{"poi":['
              '{"name":"삼성전자서비스 용산센터","upperAddrName":"서울","middleAddrName":"용산구","lowerAddrName":"한강로동","frontLon":"126.9640","frontLat":"37.5298"},'
              '{"name":"삼성전자서비스 성남센터","upperAddrName":"경기도","middleAddrName":"성남시","lowerAddrName":"수정구","frontLon":"127.1260","frontLat":"37.4200"}'
              ']}}}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final results = await service.search(
      '삼성서비스센터',
      origin: const GeoPoint(latitude: 37.4210, longitude: 127.1250),
    );

    expect(results, hasLength(2));
    expect(results.first.name, '삼성전자서비스 성남센터');
  });

  test('LocationLookupService preserves explicit region intent over distance',
      () async {
    final service = LocationLookupService(
      tmapApiKey: 'tmap-key',
      clientId: '',
      clientSecret: '',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        if (request.url.host == 'apis.openapi.sk.com') {
          return http.Response.bytes(
            utf8.encode(
              '{"searchPoiInfo":{"pois":{"poi":['
              '{"name":"삼성전자서비스 용산센터","upperAddrName":"서울","middleAddrName":"용산구","lowerAddrName":"한강로동","frontLon":"126.9640","frontLat":"37.5298"},'
              '{"name":"삼성전자서비스 성남센터","upperAddrName":"경기도","middleAddrName":"성남시","lowerAddrName":"수정구","frontLon":"127.1260","frontLat":"37.4200"}'
              ']}}}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final results = await service.search(
      '용산 삼성서비스센터',
      origin: const GeoPoint(latitude: 37.4210, longitude: 127.1250),
    );

    expect(results, hasLength(2));
    expect(results.first.name, '삼성전자서비스 용산센터');
  });

  test('LocationLookupService ranks query relevance before provider preference',
      () async {
    final service = LocationLookupService(
      tmapApiKey: 'tmap-key',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      proxyUrl: '',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        if (request.url.host == 'apis.openapi.sk.com') {
          return http.Response.bytes(
            utf8.encode(
              '{"searchPoiInfo":{"pois":{"poi":['
              '{"name":"해링턴플레이스","upperAddrName":"서울","middleAddrName":"강남구","lowerAddrName":"역삼동","frontLon":"127.0300","frontLat":"37.5000"}'
              ']}}}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        if (request.url.host == 'naveropenapi.apigw.ntruss.com') {
          return http.Response.bytes(
            utf8.encode(
              '{"addresses":[{"roadAddress":"경기 성남시 분당구 대장동 해링턴플레이스","jibunAddress":"경기 성남시 분당구 대장동","x":"127.0700","y":"37.3700"}]}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final results = await service.search(
      '대장동 해링턴플레이스',
      preferredProvider: LocationLookupProvider.tmap,
    );

    expect(results, hasLength(2));
    expect(results.first.label, contains('대장동'));
    expect(results.first.provider, LocationLookupProvider.naver);
  });

  test(
      'LocationLookupService retries local fallback queries when exact search is empty',
      () async {
    final requests = <String>[];
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        final query = request.url.queryParameters['query'] ??
            request.url.queryParameters['searchKeyword'] ??
            '';
        requests.add('naver:$query');

        if (query == '강남역') {
          return http.Response(
            '{"addresses":[{"roadAddress":"Gangnam Station","jibunAddress":"Gangnam","x":"127.001","y":"37.566"}]}',
            200,
          );
        }

        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final result = await service.search('강남역에서');

    expect(requests, contains('naver:강남역에서'));
    expect(requests, contains('naver:강남역'));
    expect(result, hasLength(1));
    expect(result.single.name, 'Gangnam Station');
  });

  test('LocationLookupService builds deduped fallback query suggestions', () {
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
    );

    final fallbackQueries = service.buildRetryQueries('  강남역  앞  ');

    expect(fallbackQueries, contains('강남역앞'));
    expect(fallbackQueries, contains('앞 강남역'));
    expect(
      fallbackQueries,
      hasLength(fallbackQueries.toSet().length),
    );
  });

  test(
      'LocationLookupService retry queries try the bare place name before '
      'the bare region name', () {
    // 실증: "성남 래온동물병원" 검색 시 지역명 단독 후보("성남")가 장소명
    // 단독 후보("래온동물병원")보다 먼저 시도되면, "성남"이 지오코더에서
    // 항상 성공(예: "경기도 성남시")해 실제 장소를 찾기도 전에 엉뚱한
    // 시/구 단위 주소로 조기 확정된다. 지역명 단독 후보는 항상 최후순위여야
    // 한다.
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: '',
      clientSecret: '',
      googleMapsApiKey: '',
    );

    final fallbackQueries = service.buildRetryQueries('성남 래온동물병원');

    expect(fallbackQueries, contains('성남'));
    expect(fallbackQueries, contains('래온동물병원'));
    expect(
      fallbackQueries.indexOf('래온동물병원'),
      lessThan(fallbackQueries.indexOf('성남')),
      reason: '장소명 단독 후보가 지역명 단독 후보보다 먼저 와야 합니다. '
          '실제 순서: $fallbackQueries',
    );
  });

  test(
      'LocationLookupService prefers the specific place over the bare '
      'region when the region-only query would also succeed', () async {
    final requests = <String>[];
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        final query = request.url.queryParameters['query'] ?? '';
        requests.add(query);
        if (query == '래온동물병원') {
          return http.Response.bytes(
            utf8.encode(
              '{"addresses":[{"placeName":"래온동물병원",'
              '"roadAddress":"경기도 성남시 수정구 123","x":"127.13","y":"37.45"}]}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        if (query == '성남') {
          // 지역명 단독 검색은 지오코더가 항상 성공(시/구 대표주소)한다.
          return http.Response.bytes(
            utf8.encode(
              '{"addresses":[{"roadAddress":"경기도 성남시",'
              '"x":"127.126","y":"37.42"}]}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final result = await service.searchWithFallback('성남 래온동물병원');

    expect(result.results, hasLength(1));
    expect(result.results.single.name, '래온동물병원');
  });

  test(
      'LocationLookupService retry queries include common Korean STT vowel '
      'confusions (애/에, 얘/예, 왜/외/웨)', () {
    // 현대 한국어 발음상 거의 구별되지 않아 STT가 흔히 바꿔 듣는 모음쌍.
    // "래온동물병원"을 "레온동물병원"으로 잘못 들었어도 검색에서 찾을 수
    // 있어야 한다.
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: '',
      clientSecret: '',
      googleMapsApiKey: '',
    );

    expect(service.buildRetryQueries('레온동물병원'), contains('래온동물병원'));
    expect(service.buildRetryQueries('얘기'), contains('예기'));
    expect(service.buildRetryQueries('웨딩홀'), containsAll(['왜딩홀', '외딩홀']));
    // 혼동 그룹에 속하지 않는 평범한 텍스트는 엉뚱한 변형을 만들지 않는다.
    expect(service.buildRetryQueries('강남역'), isNot(contains('걍남역')));
  });

  test(
      'LocationLookupService finds the real place via vowel-confusion retry '
      'when the exact STT-mangled query returns nothing', () async {
    final requests = <String>[];
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        final query = request.url.queryParameters['query'] ?? '';
        requests.add(query);
        // "레온동물병원"(STT 오인식)은 실제 DB에 없고, 진짜 이름
        // "래온동물병원"만 존재하는 상황을 시뮬레이션.
        if (query == '래온동물병원') {
          return http.Response.bytes(
            utf8.encode(
              '{"addresses":[{"placeName":"래온동물병원",'
              '"roadAddress":"경기 성남시 수정구 123","x":"127.13","y":"37.45"}]}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final result = await service.searchWithFallback('레온동물병원');

    expect(requests, contains('래온동물병원'));
    expect(result.results, hasLength(1));
    expect(result.results.single.name, '래온동물병원');
  });

  test('LocationLookupService does not auto-resolve broad medical categories',
      () async {
    final requests = <String>[];
    final service = LocationLookupService(
      tmapApiKey: 'tmap-key',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        requests.add(request.url.toString());
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    for (final query in const <String>[
      '병원',
      '병원 방문',
      '병원 미팅',
      '병원 진료',
      '치과 예약',
      '약국 가기',
    ]) {
      final result = await service.searchWithFallback(query);
      expect(result.results, isEmpty, reason: query);
      expect(result.searchedQueries, isEmpty, reason: query);
      expect(result.fallbackQueries, isEmpty, reason: query);
    }
    expect(requests, isEmpty);
  });

  test('LocationLookupService still resolves region-qualified hospital queries',
      () async {
    final requests = <String>[];
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        final query = request.url.queryParameters['query'] ?? '';
        requests.add(query);
        if (query == '성남 병원') {
          return http.Response.bytes(
            utf8.encode(
              '{"addresses":[{"roadAddress":"경기도 성남시 병원로 1","x":"127.126","y":"37.42"}]}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final result = await service.searchWithFallback('성남 병원');

    expect(requests, contains('성남 병원'));
    expect(result.results, hasLength(1));
    expect(result.results.single.latitude, 37.42);
  });

  test('LocationLookupService expands Wonju Christian hospital aliases', () {
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
    );

    final fallbackQueries = service.buildRetryQueries('원주기독');

    expect(fallbackQueries, contains('원주세브란스기독병원'));
    expect(fallbackQueries, contains('연세대학교 원주세브란스기독병원'));
    expect(
      fallbackQueries,
      hasLength(fallbackQueries.toSet().length),
    );
  });

  test('LocationLookupService resolves Wonju Christian alias through fallback',
      () async {
    final requests = <String>[];
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        final query = request.url.queryParameters['query'] ??
            request.url.queryParameters['searchKeyword'] ??
            '';
        requests.add(query);

        if (query == '원주세브란스기독병원') {
          return http.Response.bytes(
            utf8.encode(
              '{"addresses":[{"roadAddress":"강원특별자치도 원주시 일산로 20","jibunAddress":"강원특별자치도 원주시 일산동 162","x":"127.9458","y":"37.3495"}]}',
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }

        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final result = await service.searchWithFallback('원주기독');

    expect(requests, contains('원주기독'));
    expect(requests, contains('원주세브란스기독병원'));
    expect(result.results, hasLength(1));
    expect(result.results.single.latitude, 37.3495);
    expect(result.results.single.longitude, 127.9458);
  });

  test(
      'LocationLookupService searchWithFallback exposes metadata for retry suggestions',
      () async {
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        final query = request.url.queryParameters['query'] ??
            request.url.queryParameters['searchKeyword'] ??
            '';
        if (query == '강남역') {
          return http.Response(
            '{"addresses":[{"roadAddress":"Gangnam Station","jibunAddress":"Gangnam","x":"127.001","y":"37.566"}]}',
            200,
          );
        }
        return http.Response('{"addresses":[]}', 200);
      }),
    );

    final result = await service.searchWithFallback('강남역에서');

    expect(result.searchedQueries, contains('강남역에서'));
    expect(result.fallbackQueries, contains('강남역'));
    expect(result.searchedQueries, contains('강남역'));
    expect(result.results, hasLength(1));
  });

  test('LocationLookupService returns Korean region hints for simple names',
      () async {
    final service = LocationLookupService();

    final results = await service.search('서울');

    expect(results, hasLength(1));
    expect(results.single.provider, LocationLookupProvider.manual);
    expect(results.single.name, '서울');
    expect(results.single.label, '서울');
    expect(results.single.latitude, closeTo(37.5665, 0.0001));
    expect(results.single.longitude, closeTo(126.978, 0.0001));
  });

  test(
      'LocationLookupService throws auth failure if fallback search still empty',
      () async {
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: 'client-id',
      clientSecret: 'client-secret',
      googleMapsApiKey: '',
      httpClientFactory: () => MockClient((request) async {
        final host = request.url.host;
        final query = request.url.queryParameters['query'] ??
            request.url.queryParameters['searchKeyword'] ??
            '';

        if (host.contains('naveropenapi.apigw.ntruss.com')) {
          if (query == '강남역') {
            return http.Response('unauthorized', 401);
          }
          return http.Response('{"addresses":[]}', 200);
        }

        return http.Response('{"addresses":[]}', 200);
      }),
    );

    expect(
      () => service.search('강남역에서'),
      throwsA(
        isA<LocationLookupException>()
            .having((error) => error.isAuthFailure, 'isAuthFailure', isTrue),
      ),
    );
  });

  // ──────────────────────────────────────────────────────────────────────────
  // sortByRelevance — 검색어 유사도 정렬 (순수 함수, API 호출 없음)
  // ──────────────────────────────────────────────────────────────────────────

  LocationLookupResult makeResult(String name, {String address = ''}) =>
      LocationLookupResult(
        name: name,
        address: address,
        latitude: 0.0,
        longitude: 0.0,
        provider: LocationLookupProvider.tmap,
      );

  // ──────────────────────────────────────────────────────────────────────────
  // static 캐시 / in-flight 중복제거 / fallback 캡
  // ──────────────────────────────────────────────────────────────────────────

  /// tmap POI 엔드포인트 여부 확인.
  bool isTmapRequest(http.Request request) =>
      request.url.host == 'apis.openapi.sk.com' &&
      request.url.path.startsWith('/tmap/pois');

  /// 유효한 tmap POI 응답 픽스처 — 결과 1건.
  http.Response tmapSuccessResponse() => http.Response.bytes(
        utf8.encode(
          '{"searchPoiInfo":{"pois":{"poi":['
          '{"name":"강남역","upperAddrName":"서울","middleAddrName":"강남구",'
          '"lowerAddrName":"역삼동","roadName":"강남대로","firstBuildNo":"396",'
          '"frontLon":"127.0276","frontLat":"37.4979"}'
          ']}}}',
        ),
        200,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  /// 빈 결과 tmap 응답 픽스처.
  http.Response tmapEmptyResponse() => http.Response.bytes(
        utf8.encode(
          '{"searchPoiInfo":{"pois":{"poi":[]}}}',
        ),
        200,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  /// 빈 결과 naver/google 응답 픽스처.
  http.Response emptyResponse() =>
      http.Response('{"addresses":[]}', 200);

  group('캐시 / in-flight 중복제거 / fallback 캡', () {
    setUp(() {
      // 테스트 간 static 누수 방지.
      LocationLookupService.resetLookupCacheForTesting();
      ApiUsageGuard.resetForTesting();
    });

    test('같은 query 2회 검색 → tmap HTTP 1회(캐시 적중)', () async {
      var tmapCallCount = 0;

      final service = LocationLookupService(
        tmapApiKey: 'tmap-key',
        clientId: '',
        clientSecret: '',
        googleMapsApiKey: '',
        httpClientFactory: () => MockClient((request) async {
          if (isTmapRequest(request)) {
            tmapCallCount++;
            return tmapSuccessResponse();
          }
          return emptyResponse();
        }),
      );

      await service.searchWithFallback('강남역');
      await service.searchWithFallback('강남역'); // 캐시 적중 — HTTP 없어야 함

      expect(tmapCallCount, equals(1),
          reason: '캐시 적중 시 tmap HTTP는 1회만 호출돼야 한다');
    });

    test('결과 없는(빈) query 2회 → 2회째 tmap 0회(네거티브 캐시)', () async {
      var tmapCallCount = 0;

      final service = LocationLookupService(
        tmapApiKey: 'tmap-key',
        clientId: '',
        clientSecret: '',
        googleMapsApiKey: '',
        httpClientFactory: () => MockClient((request) async {
          if (isTmapRequest(request)) {
            tmapCallCount++;
            return tmapEmptyResponse();
          }
          return emptyResponse();
        }),
      );

      // 결과 없는 쿼리로 두 번 검색.
      await service.searchWithFallback('존재하지않는장소xyz');
      final countAfterFirst = tmapCallCount;

      await service.searchWithFallback('존재하지않는장소xyz'); // 네거티브 캐시 적중

      expect(countAfterFirst, greaterThan(0),
          reason: '첫 번째 검색은 tmap을 호출해야 한다');
      expect(tmapCallCount, equals(countAfterFirst),
          reason: '두 번째 검색은 네거티브 캐시 적중으로 tmap HTTP를 추가 호출하지 않아야 한다');
    });

    test('같은 query 동시(Future.wait) → tmap 1회(in-flight dedup)', () async {
      var tmapCallCount = 0;

      final service = LocationLookupService(
        tmapApiKey: 'tmap-key',
        clientId: '',
        clientSecret: '',
        googleMapsApiKey: '',
        httpClientFactory: () => MockClient((request) async {
          if (isTmapRequest(request)) {
            tmapCallCount++;
            return tmapSuccessResponse();
          }
          return emptyResponse();
        }),
      );

      // 두 요청을 동시에 시작.
      final results = await Future.wait([
        service.searchWithFallback('강남역'),
        service.searchWithFallback('강남역'),
      ]);

      expect(tmapCallCount, equals(1),
          reason: 'in-flight dedup: 동시 동일 쿼리는 tmap을 1회만 호출해야 한다');
      expect(results[0].results, equals(results[1].results),
          reason: '두 결과는 동일해야 한다');
    });

    test('fallback 캡: 끝까지 못 찾는 query → tmap 호출 ≤ 6회', () async {
      // 기존 ApiUsageGuard 일일 한도(기본값 60회/60초)를 넘지 않도록
      // 충분히 큰 한도를 설정한 guard를 주입한다.
      final guard = ApiUsageGuard(
        configs: const <String, ApiRateConfig>{
          ApiName.tmapPoi: ApiRateConfig(
            windowSeconds: 60,
            rateLimit: 1000, // 테스트에서 차단되지 않을 만큼 큰 값
          ),
        },
      );

      var tmapCallCount = 0;

      final service = LocationLookupService(
        tmapApiKey: 'tmap-key',
        clientId: '',
        clientSecret: '',
        googleMapsApiKey: '',
        usageGuard: guard,
        httpClientFactory: () => MockClient((request) async {
          if (isTmapRequest(request)) {
            tmapCallCount++;
            return tmapEmptyResponse(); // 항상 빈 결과
          }
          return emptyResponse();
        }),
      );

      // buildRetryQueries가 5개 이상을 생성하는 쿼리 사용.
      try {
        await service.searchWithFallback('원주세브란스기독병원근처카페');
      } catch (_) {
        // fallback 캡(콜 수)만 검증하므로 결과/예외는 무시한다.
      }

      expect(tmapCallCount, lessThanOrEqualTo(6),
          reason: 'fallback 캡(_maxFallbackQueries=5): 한 검색이 tmap ≤ 1+5 = 6콜이어야 한다');
    });

    test('401 응답 → authFailure 있으면 캐싱 안 됨: 다음 검색이 다시 HTTP 시도', () async {
      var requestCount = 0;

      final service = LocationLookupService(
        tmapApiKey: 'tmap-key',
        clientId: 'client-id',
        clientSecret: 'client-secret',
        googleMapsApiKey: '',
        httpClientFactory: () => MockClient((request) async {
          requestCount++;
          if (isTmapRequest(request)) {
            // 401 반환 — authFailure 유발.
            return http.Response('unauthorized', 401);
          }
          if (request.url.host.contains('naveropenapi')) {
            return http.Response('unauthorized', 401);
          }
          return emptyResponse();
        }),
      );

      // 첫 번째 검색 — 401로 authFailure, 예외 발생 가능.
      try {
        await service.searchWithFallback('강남역');
      } on LocationLookupException {
        // 예상된 예외.
      }
      final requestsAfterFirst = requestCount;

      // 두 번째 검색 — 캐싱되지 않았으면 다시 HTTP를 시도해야 함.
      try {
        await service.searchWithFallback('강남역');
      } on LocationLookupException {
        // 예상된 예외.
      }

      expect(requestCount, greaterThan(requestsAfterFirst),
          reason: 'authFailure 시 결과가 캐싱되지 않아야 하므로 두 번째 검색도 HTTP를 시도해야 한다');
    });
  });

  group('sortByRelevance', () {
    final service = LocationLookupService(
      tmapApiKey: '',
      clientId: '',
      clientSecret: '',
      googleMapsApiKey: '',
    );

    test('수진역 검색 시 정확 일치 결과가 1순위, 군더더기 많은 결과는 후순위', () {
      // 재현 케이스: '수진역코아루천년가 정문'이 1순위로 나오던 버그
      final input = [
        makeResult('수진역코아루천년가 정문'),
        makeResult('수진역'),
        makeResult('수진역 8호선'),
        makeResult('수진역사거리'),
      ];
      final sorted = service.sortByRelevance('수진역', input);

      // '수진역' 또는 '수진역 8호선'이 앞쪽에 와야 함
      final shortIndex = sorted.indexWhere((r) =>
          r.name == '수진역' || r.name == '수진역 8호선');
      final longIndex =
          sorted.indexWhere((r) => r.name == '수진역코아루천년가 정문');

      expect(shortIndex, lessThan(longIndex),
          reason: '유사도 높은 결과("수진역" 또는 "수진역 8호선")가 '
              '"수진역코아루천년가 정문"보다 앞에 위치해야 합니다');
      // 첫 번째 결과가 '수진역' 또는 '수진역 8호선'이어야 함 (버그 케이스: 1순위가 엉뚱한 결과)
      expect(
        sorted.first.name == '수진역' || sorted.first.name == '수진역 8호선',
        isTrue,
        reason: '1순위가 "수진역" 또는 "수진역 8호선"이어야 합니다. 실제: ${sorted.first.name}',
      );
    });

    test('정확 일치가 접두 일치보다 우선순위가 높다', () {
      final input = [
        makeResult('수진역사거리'),   // 접두 일치
        makeResult('수진역'),         // 정확 일치
      ];
      final sorted = service.sortByRelevance('수진역', input);

      expect(sorted.first.name, equals('수진역'));
    });

    test('접두 일치가 내부 포함보다 우선순위가 높다', () {
      final input = [
        makeResult('역수진홀'),       // 내부 포함
        makeResult('수진역사거리'),   // 접두 일치
      ];
      final sorted = service.sortByRelevance('수진역', input);

      expect(sorted.first.name, equals('수진역사거리'));
    });

    test('교통 키워드(역) 포함 결과에 가산점이 붙는다', () {
      // '수진역' 검색 시 역 이름이 없는 결과보다 역 포함 결과가 앞에 와야 함
      final input = [
        makeResult('수진 코아루천년가'),   // 역 키워드 없음
        makeResult('수진역 8호선'),         // 역 키워드 포함
      ];
      final sorted = service.sortByRelevance('수진역', input);

      expect(sorted.first.name, equals('수진역 8호선'));
    });

    test('이름 길이가 짧을수록(군더더기 적을수록) 더 높은 점수를 받는다', () {
      final input = [
        makeResult('수진역광장아파트단지'),  // 길이 가장 긺 (접두 일치, extraChars 큼)
        makeResult('수진역사거리'),            // 중간 (접두 일치, extraChars 작음)
        makeResult('수진역'),                  // 가장 짧음 (정확 일치)
      ];
      final sorted = service.sortByRelevance('수진역', input);

      // '수진역'은 정확 일치(150점)로 1순위
      expect(sorted[0].name, equals('수진역'));
      // '수진역광장아파트단지'는 접두 일치지만 군더더기가 가장 많으므로 3순위
      expect(sorted[2].name, equals('수진역광장아파트단지'));
    });

    test('단일 결과면 정렬 없이 그대로 반환', () {
      final input = [makeResult('수진역')];
      final sorted = service.sortByRelevance('수진역', input);
      expect(sorted, equals(input));
    });

    test('빈 목록이면 빈 목록을 반환', () {
      final sorted = service.sortByRelevance('수진역', []);
      expect(sorted, isEmpty);
    });

    test('STT 오인식으로 한 글자만 다른 이름은 완전 무관한 결과보다 우선한다', () {
      // 실증: "성남래온동물병원 가기 일정추가해줘"를 STT가 "레온동물병원"으로
      // 잘못 인식(래→레). 완전 일치가 아니라고 편집거리 1인 후보를
      // 무관한 결과와 동일하게(0점) 취급하면 실제로 찾던 곳이 밀려난다.
      final input = [
        makeResult('무지개동물메디컬센터'), // 완전 무관
        makeResult('래온동물병원', address: '경기 성남시 수정구'), // 편집거리 1
      ];
      final sorted = service.sortByRelevance('레온동물병원', input);

      expect(sorted.first.name, equals('래온동물병원'));
    });

    test('편집거리가 클수록(2글자 이상 다름) 근접 매칭 가산이 줄어든다', () {
      final input = [
        makeResult('완전다른이름병원'), // 편집거리 큼, 무관
        makeResult('래온동물병원'), // 편집거리 1 — 여전히 우선
      ];
      final sorted = service.sortByRelevance('레온동물병원', input);

      expect(sorted.first.name, equals('래온동물병원'));
    });
  });
}
