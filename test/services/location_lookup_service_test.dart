import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/location_lookup_service.dart';

void main() {
  test('LocationLookupService parses Naver geocoding results', () async {
    final service = LocationLookupService(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      httpClientFactory: () => MockClient((request) async {
        expect(request.url.host, 'naveropenapi.apigw.ntruss.com');
        return http.Response(
          '{"addresses":[{"roadAddress":"Seoul City Hall","jibunAddress":"Seoul","x":"126.9784147","y":"37.5666805"}]}',
          200,
        );
      }),
    );

    final results = await service.search('서울시청');

    expect(results, hasLength(1));
    expect(results.single.label, 'Seoul City Hall');
    expect(results.single.latitude, 37.5666805);
    expect(results.single.longitude, 126.9784147);
  });

  test('LocationLookupService exposes Naver auth failures', () async {
    final service = LocationLookupService(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      httpClientFactory: () => MockClient((request) async {
        return http.Response('unauthorized', 401);
      }),
    );

    expect(
      () => service.search('서울역'),
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
}
