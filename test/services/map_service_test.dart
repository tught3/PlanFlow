import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/map_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // MapService._tryTmapDuration이 ApiUsageGuard.tryConsume →
  // SharedPreferences.getInstance()를 호출하므로 binding 초기화와 mock이 필요하다.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiUsageGuard.resetForTesting();
  });

  test('MapService uses Tmap first for car travel', () async {
    final service = MapService(
      tmapApiKey: 'tmap-key',
      naverProxyUrl: '',
      naverClientId: 'naver-id',
      naverClientSecret: 'naver-secret',
      httpClientFactory: () => MockClient((request) async {
        expect(request.url.host, 'apis.openapi.sk.com');
        return http.Response(
          '{"features":[{"properties":{"totalTime":1860}}]}',
          200,
        );
      }),
    );

    final estimate = await service.getTravelMinutes(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
    );

    expect(estimate, isNotNull);
    expect(estimate!.provider, MapTravelProvider.tmap);
    expect(estimate.minutes, 31);
  });

  test('MapService falls back to Naver when Tmap fails', () async {
    var calls = 0;
    final service = MapService(
      tmapApiKey: 'tmap-key',
      naverProxyUrl: '',
      naverClientId: 'naver-id',
      naverClientSecret: 'naver-secret',
      httpClientFactory: () => MockClient((request) async {
        calls += 1;
        if (calls == 1) {
          expect(request.url.host, 'apis.openapi.sk.com');
          return http.Response('server error', 500);
        }

        expect(request.url.host, 'naveropenapi.apigw.ntruss.com');
        return http.Response(
          '{"route":{"trafast":[{"summary":{"duration":1920000}}]}}',
          200,
        );
      }),
    );

    final estimate = await service.getTravelMinutes(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
    );

    expect(estimate, isNotNull);
    expect(estimate!.provider, MapTravelProvider.naver);
    expect(estimate.minutes, 32);
  });

  test('MapService uses Naver proxy without client secret headers', () async {
    final service = MapService(
      naverProxyUrl: 'https://example.supabase.co/functions/v1/naver-geocode',
      httpClientFactory: () => MockClient((request) async {
        expect(request.url.host, 'example.supabase.co');
        expect(request.url.queryParameters['start'], '126.978,37.5665');
        expect(request.url.queryParameters['goal'], '127.0276,37.4979');
        expect(request.url.queryParameters['mode'], 'transit');
        expect(request.url.queryParameters.containsKey('option'), isFalse);
        expect(request.headers.containsKey('X-NCP-APIGW-API-KEY'), isFalse);
        return http.Response(
          '{"result":{"path":[{"summary":{"duration":1920000}}]}}',
          200,
        );
      }),
    );

    final estimate = await service.getTravelMinutes(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
      mode: MapTravelMode.transit,
    );

    expect(estimate, isNotNull);
    expect(estimate!.provider, MapTravelProvider.naver);
    expect(estimate.minutes, 32);
  });

  test('MapService uses Naver first for transit mode', () async {
    final service = MapService(
      tmapApiKey: 'tmap-key',
      naverProxyUrl: '',
      naverClientId: 'naver-id',
      naverClientSecret: 'naver-secret',
      httpClientFactory: () => MockClient((request) async {
        expect(request.url.host, 'naveropenapi.apigw.ntruss.com');
        expect(request.url.path, '/map-direction-15/v1/transit');
        return http.Response(
          '{"result":{"path":[{"summary":{"duration":900000}}]}}',
          200,
        );
      }),
    );

    final estimate = await service.getTravelMinutes(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
      mode: MapTravelMode.transit,
    );

    expect(estimate, isNotNull);
    expect(estimate!.provider, MapTravelProvider.naver);
    expect(estimate.minutes, 15);
  });

  test('MapService falls back to Naver driving when transit endpoint fails',
      () async {
    var calls = 0;
    final service = MapService(
      tmapApiKey: 'tmap-key',
      naverProxyUrl: '',
      naverClientId: 'naver-id',
      naverClientSecret: 'naver-secret',
      httpClientFactory: () => MockClient((request) async {
        calls += 1;
        expect(request.url.host, 'naveropenapi.apigw.ntruss.com');
        if (calls == 1) {
          expect(request.url.path, '/map-direction-15/v1/transit');
          return http.Response('forbidden', 403);
        }
        expect(request.url.path, '/map-direction/v1/driving');
        return http.Response(
          '{"route":{"trafast":[{"summary":{"duration":1800000}}]}}',
          200,
        );
      }),
    );

    final estimate = await service.getTravelMinutes(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
      mode: MapTravelMode.transit,
    );

    expect(estimate, isNotNull);
    expect(estimate!.provider, MapTravelProvider.naver);
    expect(estimate.minutes, 30);
    expect(calls, 2);
  });
}
