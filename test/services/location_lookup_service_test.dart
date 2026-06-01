import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/location_lookup_service.dart';

void main() {
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
}
