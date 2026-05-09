import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/home_header_summary_service.dart';

void main() {
  test('HomeHeaderSummaryService parses location and weather summary',
      () async {
    final service = HomeHeaderSummaryService(
      httpClientFactory: () => MockClient((request) async {
        if (request.url.host == 'geocoding-api.open-meteo.com') {
          return http.Response(
            '''
            {
              "results": [
                {
                  "name": "강남구",
                  "admin1": "서울특별시",
                  "country": "대한민국"
                }
              ]
            }
            ''',
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response(
          '''
          {
            "current": {
              "temperature_2m": 24.4,
              "apparent_temperature": 25.1,
              "weather_code": 0,
              "windspeed_10m": 2.7
            }
          }
          ''',
          200,
        );
      }),
    );

    final summary = await service.load(
      location: const GeoPoint(latitude: 37.5, longitude: 127.0),
    );

    expect(summary.isReady, isTrue);
    expect(summary.locationLabel, '서울시 강남구');
    expect(summary.weatherLabel, contains('맑음'));
    expect(summary.detailLine, contains('체감'));
  });

  test('HomeHeaderSummaryService does not fall back to coordinates', () async {
    final service = HomeHeaderSummaryService(
      httpClientFactory: () => MockClient((request) async {
        if (request.url.host == 'geocoding-api.open-meteo.com') {
          return http.Response('not found', 500);
        }
        return http.Response(
          '''
          {
            "current": {
              "temperature_2m": 18.0,
              "apparent_temperature": 18.0,
              "weather_code": 3,
              "windspeed_10m": 1.2
            }
          }
          ''',
          200,
        );
      }),
    );

    final summary = await service.load(
      location: const GeoPoint(latitude: 37.5665, longitude: 126.9780),
    );

    expect(summary.isReady, isTrue);
    expect(summary.locationLabel, '위치 정보 확인 중');
    expect(summary.locationLabel, isNot(contains('좌표')));
    expect(summary.locationLabel, isNot(contains('37.')));
    expect(summary.weatherLabel, contains('흐림'));
  });

  test('HomeHeaderSummaryService prefers city names over coordinates/province',
      () async {
    final service = HomeHeaderSummaryService(
      httpClientFactory: () => MockClient((request) async {
        if (request.url.host == 'geocoding-api.open-meteo.com') {
          return http.Response(
            '''
            {
              "results": [
                {
                  "name": "분당구",
                  "city": "성남시",
                  "admin1": "경기도",
                  "admin2": "성남시",
                  "admin3": "분당구",
                  "country": "대한민국"
                }
              ]
            }
            ''',
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response(
          '''
          {
            "current": {
              "temperature_2m": 12.0,
              "apparent_temperature": 11.0,
              "weather_code": 1,
              "windspeed_10m": 1.0
            }
          }
          ''',
          200,
        );
      }),
    );

    final summary = await service.load(
      location: const GeoPoint(latitude: 37.4, longitude: 127.1),
    );

    expect(summary.locationLabel, '성남시 분당구');
    expect(summary.locationLabel, isNot(contains('경기도')));
    expect(summary.locationLabel, isNot(contains('37.')));
  });

  test('HomeHeaderSummaryService falls back without location', () async {
    final summary = await HomeHeaderSummaryService().load();

    expect(summary.isReady, isFalse);
    expect(summary.locationLabel, '위치 확인 중');
    expect(summary.weatherLabel, '날씨 확인 중');
  });
}
