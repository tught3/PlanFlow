import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/env.dart';
import 'api_usage_guard.dart';

enum MapTravelMode {
  car,
  transit,
}

enum MapTravelProvider {
  tmap,
  naver,
}

class MapTravelEstimate {
  const MapTravelEstimate({
    required this.minutes,
    required this.provider,
  });

  final int minutes;
  final MapTravelProvider provider;
}

class MapService {
  MapService({
    String? tmapApiKey,
    String? naverProxyUrl,
    String? naverClientId,
    String? naverClientSecret,
    http.Client Function()? httpClientFactory,
    ApiUsageGuard? usageGuard,
  })  : _tmapApiKey = tmapApiKey ?? AppEnv.tmapApiKey,
        _naverProxyUrl = naverProxyUrl ?? AppEnv.naverMapProxyUrl,
        _naverClientId = naverClientId ?? AppEnv.naverMapClientId,
        _naverClientSecret = naverClientSecret ?? '',
        _httpClientFactory = httpClientFactory ?? http.Client.new,
        _usageGuard = usageGuard;

  final String _tmapApiKey;
  final String _naverProxyUrl;
  final String _naverClientId;
  final String _naverClientSecret;
  final http.Client Function() _httpClientFactory;
  final ApiUsageGuard? _usageGuard;

  ApiUsageGuard get _guard => _usageGuard ?? ApiUsageGuard.instance;

  Future<MapTravelEstimate?> getTravelMinutes({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
  }) async {
    final providers = mode == MapTravelMode.transit
        ? const <MapTravelProvider>[MapTravelProvider.naver]
        : const <MapTravelProvider>[
            MapTravelProvider.tmap,
            MapTravelProvider.naver,
          ];

    for (final provider in providers) {
      final minutes = switch (provider) {
        MapTravelProvider.tmap => await _tryTmapDuration(
            originLat: originLat,
            originLng: originLng,
            destinationLat: destinationLat,
            destinationLng: destinationLng,
          ),
        MapTravelProvider.naver => await _tryNaverDuration(
            originLat: originLat,
            originLng: originLng,
            destinationLat: destinationLat,
            destinationLng: destinationLng,
            mode: mode,
          ),
      };

      if (minutes != null) {
        return MapTravelEstimate(minutes: minutes, provider: provider);
      }
    }

    return null;
  }

  Future<int?> _tryTmapDuration({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
  }) async {
    if (_tmapApiKey.trim().isEmpty) {
      return null;
    }

    // circuit breaker — 일일 한도 초과 시 null 반환 → 호출부가 Naver로 폴백
    if (!await _guard.tryConsume(ApiName.tmapRoutes)) {
      return null;
    }

    final client = _httpClientFactory();
    try {
      final response = await client
          .post(
            Uri.https('apis.openapi.sk.com', '/tmap/routes', <String, String>{
              'version': '1',
            }),
            headers: <String, String>{
              'appKey': _tmapApiKey,
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode(<String, String>{
              'startX': originLng.toString(),
              'startY': originLat.toString(),
              'endX': destinationLng.toString(),
              'endY': destinationLat.toString(),
              'reqCoordType': 'WGS84GEO',
              'resCoordType': 'WGS84GEO',
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final features = decoded['features'];
      if (features is! List || features.isEmpty) {
        return null;
      }

      for (final feature in features.whereType<Map<String, dynamic>>()) {
        final properties = feature['properties'];
        if (properties is! Map<String, dynamic>) {
          continue;
        }

        final seconds = _numValue(properties['totalTime']);
        if (seconds != null && seconds > 0) {
          return math.max(1, (seconds / 60).ceil());
        }
      }

      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<int?> _tryNaverDuration({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    required MapTravelMode mode,
  }) async {
    if (mode == MapTravelMode.transit) {
      final transitMinutes = await _tryNaverDurationForMode(
        originLat: originLat,
        originLng: originLng,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        mode: MapTravelMode.transit,
      );
      if (transitMinutes != null) {
        return transitMinutes;
      }
      return _tryNaverDurationForMode(
        originLat: originLat,
        originLng: originLng,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        mode: MapTravelMode.car,
      );
    }
    return _tryNaverDurationForMode(
      originLat: originLat,
      originLng: originLng,
      destinationLat: destinationLat,
      destinationLng: destinationLng,
      mode: MapTravelMode.car,
    );
  }

  Future<int?> _tryNaverDurationForMode({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    required MapTravelMode mode,
  }) async {
    final proxyUri = _naverDirectionProxyUri(
      originLat: originLat,
      originLng: originLng,
      destinationLat: destinationLat,
      destinationLng: destinationLng,
      mode: mode,
    );
    if (proxyUri == null &&
        (_naverClientId.trim().isEmpty || _naverClientSecret.trim().isEmpty)) {
      return null;
    }

    final client = _httpClientFactory();
    try {
      final response = await client
          .get(
            proxyUri ??
                Uri.https(
                  'naveropenapi.apigw.ntruss.com',
                  mode == MapTravelMode.transit
                      ? '/map-direction-15/v1/transit'
                      : '/map-direction/v1/driving',
                  <String, String>{
                    'start': '$originLng,$originLat',
                    'goal': '$destinationLng,$destinationLat',
                    if (mode == MapTravelMode.car) 'option': 'trafast',
                  },
                ),
            headers: proxyUri == null
                ? <String, String>{
                    'X-NCP-APIGW-API-KEY-ID': _naverClientId,
                    'X-NCP-APIGW-API-KEY': _naverClientSecret,
                    'accept': 'application/json',
                  }
                : const <String, String>{
                    'accept': 'application/json',
                  },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      return switch (mode) {
        MapTravelMode.transit => _parseNaverTransitDuration(decoded),
        MapTravelMode.car => _parseNaverDrivingDuration(decoded),
      };
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Uri? _naverDirectionProxyUri({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    required MapTravelMode mode,
  }) {
    final raw = _naverProxyUrl.trim();
    if (raw.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        'start': '$originLng,$originLat',
        'goal': '$destinationLng,$destinationLat',
        'mode': mode.name,
        if (mode == MapTravelMode.car) 'option': 'trafast',
      },
    );
  }

  int? _parseNaverDrivingDuration(Map<String, dynamic> decoded) {
    final route = decoded['route'];
    if (route is! Map<String, dynamic>) {
      return null;
    }

    final routes = route['trafast'] ?? route['traoptimal'];
    if (routes is! List || routes.isEmpty) {
      return null;
    }

    final first = routes.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }

    final summary = first['summary'];
    if (summary is! Map<String, dynamic>) {
      return null;
    }

    final milliseconds = _numValue(summary['duration']);
    if (milliseconds == null || milliseconds <= 0) {
      return null;
    }

    return math.max(1, (milliseconds / 60000).ceil());
  }

  int? _parseNaverTransitDuration(Map<String, dynamic> decoded) {
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) {
      return null;
    }

    final paths = result['path'];
    if (paths is! List || paths.isEmpty) {
      return null;
    }

    final first = paths.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }

    final summary = first['summary'];
    if (summary is! Map<String, dynamic>) {
      return null;
    }

    final milliseconds = _numValue(summary['duration']);
    if (milliseconds == null || milliseconds <= 0) {
      return null;
    }

    return math.max(1, (milliseconds / 60000).ceil());
  }

  num? _numValue(Object? value) {
    if (value is num) {
      return value;
    }
    return num.tryParse(value?.toString() ?? '');
  }
}
