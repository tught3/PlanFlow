import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Tmap 경로가 ApiUsageGuard.tryConsume → SharedPreferences.getInstance()를
  // 호출하므로 binding 초기화와 mock이 필요하다.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiUsageGuard.resetForTesting();
  });

  test('TravelTimeBufferService prefers coordinates when both signals exist',
      () {
    final service = TravelTimeBufferService();

    final estimate = service.estimate(
      latitude: 37.5665,
      longitude: 126.978,
      locationText: 'Seoul Station',
    );

    expect(estimate.source, TravelTimeBufferSource.coordinates);
    expect(estimate.minutes, greaterThan(0));
  });

  test(
      'TravelTimeBufferService uses text heuristic when coordinates are absent',
      () {
    final service = TravelTimeBufferService();

    final estimate =
        service.estimate(locationText: 'Incheon Airport Terminal 2');

    expect(estimate.source, TravelTimeBufferSource.locationText);
    expect(estimate.minutes, inInclusiveRange(10, 75));
  });

  test('TravelTimeBufferService falls back to a stable default buffer', () {
    final service = TravelTimeBufferService();

    final estimate = service.estimate();

    expect(estimate.source, TravelTimeBufferSource.defaultFallback);
    expect(estimate.buffer, const Duration(minutes: 15));
  });

  test('TravelTimeBufferService uses Google Maps duration when available',
      () async {
    final service = TravelTimeBufferService(
      googleMapsApiKey: 'test-key',
      httpClientFactory: () => MockClient((request) async {
        return http.Response(
          '{"status":"OK","rows":[{"elements":[{"status":"OK","duration":{"value":1920}}]}]}',
          200,
        );
      }),
    );

    final estimate = await service.estimateWithGoogleMaps(
      origin: 'Home',
      destination: 'Seoul Station',
    );

    expect(estimate.source, TravelTimeBufferSource.googleMaps);
    expect(estimate.minutes, 32);
  });

  test('TravelTimeBufferService sends transit mode to Google Maps', () async {
    Uri? capturedUri;
    final service = TravelTimeBufferService(
      googleMapsApiKey: 'test-key',
      httpClientFactory: () => MockClient((request) async {
        capturedUri = request.url;
        return http.Response(
          '{"status":"OK","rows":[{"elements":[{"status":"OK","duration":{"value":1920}}]}]}',
          200,
        );
      }),
    );

    final estimate = await service.estimateWithGoogleMaps(
      origin: 'Home',
      destination: 'Seoul Station',
      mode: MapTravelMode.transit,
    );

    expect(capturedUri?.queryParameters['mode'], 'transit');
    expect(estimate.source, TravelTimeBufferSource.googleMaps);
    expect(estimate.minutes, 32);
  });

  test('TravelTimeBufferService prefers Tmap before Google for car travel',
      () async {
    final service = TravelTimeBufferService(
      googleMapsApiKey: 'test-key',
      httpClientFactory: () => MockClient((request) async {
        return http.Response(
          '{"status":"OK","rows":[{"elements":[{"status":"OK","duration":{"value":1920}}]}]}',
          200,
        );
      }),
      mapService: MapService(
        tmapApiKey: 'tmap-key',
        httpClientFactory: () => MockClient((request) async {
          return http.Response(
            '{"features":[{"properties":{"totalTime":2100}}]}',
            200,
          );
        }),
      ),
    );

    final estimate = await service.estimateWithMapApis(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
    );

    expect(estimate.source, TravelTimeBufferSource.tmap);
    expect(estimate.minutes, 35);
  });

  test('TravelTimeBufferService falls back to Google when map APIs fail',
      () async {
    final service = TravelTimeBufferService(
      googleMapsApiKey: 'test-key',
      httpClientFactory: () => MockClient((request) async {
        return http.Response(
          '{"status":"OK","rows":[{"elements":[{"status":"OK","duration":{"value":1920}}]}]}',
          200,
        );
      }),
      mapService: _NullMapService(),
    );

    final estimate = await service.estimateWithMapApis(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
    );

    expect(estimate.source, TravelTimeBufferSource.googleMaps);
    expect(estimate.minutes, 32);
  });

  test(
      'TravelTimeBufferService falls back to deterministic estimate when Google and map APIs fail',
      () async {
    final service = TravelTimeBufferService(
      googleMapsApiKey: 'test-key',
      httpClientFactory: () => MockClient((request) async {
        return http.Response(
          '{"status":"ZERO_RESULTS"}',
          200,
        );
      }),
      mapService: _NullMapService(),
    );

    final estimate = await service.estimateWithMapApis(
      originLat: 37.5665,
      originLng: 126.978,
      destinationLat: 37.4979,
      destinationLng: 127.0276,
    );

    expect(estimate.source, TravelTimeBufferSource.coordinates);
    expect(estimate.minutes, greaterThan(0));
  });
}

class _NullMapService extends MapService {
  @override
  Future<MapTravelEstimate?> getTravelMinutes({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
  }) async {
    return null;
  }
}
