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
    expect(summary.locationLabel, isNotEmpty);
    expect(summary.weatherLabel, contains('맑음'));
    expect(summary.detailLine, contains('체감'));
  });

  test('HomeHeaderSummaryService falls back without location', () async {
    final summary = await HomeHeaderSummaryService().load();

    expect(summary.isReady, isFalse);
    expect(summary.locationLabel, '위치 확인 중');
    expect(summary.weatherLabel, '날씨 확인 중');
  });
}
