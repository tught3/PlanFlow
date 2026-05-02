import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/env.dart';
import 'map_service.dart';

enum TravelTimeBufferSource {
  coordinates,
  locationText,
  googleMaps,
  tmap,
  naverMap,
  defaultFallback,
}

class TravelTimeBufferEstimate {
  const TravelTimeBufferEstimate({
    required this.buffer,
    required this.source,
    required this.reason,
  });

  final Duration buffer;
  final TravelTimeBufferSource source;
  final String reason;

  int get minutes => buffer.inMinutes;
}

class TravelTimeBufferService {
  TravelTimeBufferService({
    String? googleMapsApiKey,
    http.Client Function()? httpClientFactory,
    MapService? mapService,
  })  : _googleMapsApiKey = googleMapsApiKey ?? AppEnv.googleMapsApiKey,
        _mapService = mapService,
        _httpClientFactory = httpClientFactory ?? http.Client.new;

  final String _googleMapsApiKey;
  final MapService? _mapService;
  final http.Client Function() _httpClientFactory;

  /// Returns a deterministic travel buffer for the available location signal.
  ///
  /// This is intentionally not a routing engine. When Google Maps is available,
  /// callers can use [estimateWithGoogleMaps] for a route-based duration.
  /// Otherwise, this remains a stable heuristic:
  /// - coordinates are mapped to a pseudo-distance score from the origin
  /// - location text is mapped by keyword and length hints
  /// - missing input falls back to a safe default
  TravelTimeBufferEstimate estimate({
    double? latitude,
    double? longitude,
    String? locationText,
  }) {
    if (latitude != null && longitude != null) {
      final minutes = _estimateFromCoordinates(latitude, longitude);
      return TravelTimeBufferEstimate(
        buffer: Duration(minutes: minutes),
        source: TravelTimeBufferSource.coordinates,
        reason: 'Deterministic coordinate heuristic.',
      );
    }

    final normalizedText = _normalizeLocationText(locationText);
    if (normalizedText.isNotEmpty) {
      final minutes = _estimateFromLocationText(normalizedText);
      return TravelTimeBufferEstimate(
        buffer: Duration(minutes: minutes),
        source: TravelTimeBufferSource.locationText,
        reason: 'Deterministic text heuristic.',
      );
    }

    return const TravelTimeBufferEstimate(
      buffer: Duration(minutes: 15),
      source: TravelTimeBufferSource.defaultFallback,
      reason: 'Default buffer when no location signal is available.',
    );
  }

  Future<TravelTimeBufferEstimate> estimateWithGoogleMaps({
    required String origin,
    required String destination,
    double? latitude,
    double? longitude,
    String? locationText,
  }) async {
    final normalizedOrigin = origin.trim();
    final normalizedDestination = destination.trim();
    if (_googleMapsApiKey.trim().isEmpty ||
        normalizedOrigin.isEmpty ||
        normalizedDestination.isEmpty) {
      return estimate(
        latitude: latitude,
        longitude: longitude,
        locationText: locationText ?? destination,
      );
    }

    final client = _httpClientFactory();
    try {
      final response = await client.get(
        Uri.https(
          'maps.googleapis.com',
          '/maps/api/distancematrix/json',
          <String, String>{
            'origins': normalizedOrigin,
            'destinations': normalizedDestination,
            'mode': 'driving',
            'units': 'metric',
            'key': _googleMapsApiKey,
          },
        ),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      if (_stringValue(decoded['status']) != 'OK') {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      final rows = decoded['rows'];
      if (rows is! List || rows.isEmpty) {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      final firstRow = rows.first;
      if (firstRow is! Map<String, dynamic>) {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      final elements = firstRow['elements'];
      if (elements is! List || elements.isEmpty) {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      final firstElement = elements.first;
      if (firstElement is! Map<String, dynamic>) {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      if (_stringValue(firstElement['status']) != 'OK') {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      final duration = firstElement['duration'];
      final seconds =
          duration is Map<String, dynamic> ? duration['value'] : null;
      final durationSeconds = seconds is int
          ? seconds
          : seconds is num
              ? seconds.toInt()
              : null;
      if (durationSeconds == null || durationSeconds <= 0) {
        return estimate(
          latitude: latitude,
          longitude: longitude,
          locationText: locationText ?? destination,
        );
      }

      final bufferedMinutes = math.max(1, (durationSeconds / 60).ceil());
      return TravelTimeBufferEstimate(
        buffer: Duration(minutes: bufferedMinutes),
        source: TravelTimeBufferSource.googleMaps,
        reason: 'Google Maps Distance Matrix API response.',
      );
    } catch (_) {
      return estimate(
        latitude: latitude,
        longitude: longitude,
        locationText: locationText ?? destination,
      );
    } finally {
      client.close();
    }
  }

  Future<TravelTimeBufferEstimate> estimateWithMapApis({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
    MapTravelMode mode = MapTravelMode.car,
    String? locationText,
  }) async {
    final mapEstimate = await (_mapService ?? MapService()).getTravelMinutes(
      originLat: originLat,
      originLng: originLng,
      destinationLat: destinationLat,
      destinationLng: destinationLng,
      mode: mode,
    );

    if (mapEstimate == null) {
      return estimate(
        latitude: destinationLat,
        longitude: destinationLng,
        locationText: locationText,
      );
    }

    return TravelTimeBufferEstimate(
      buffer: Duration(minutes: mapEstimate.minutes),
      source: switch (mapEstimate.provider) {
        MapTravelProvider.tmap => TravelTimeBufferSource.tmap,
        MapTravelProvider.naver => TravelTimeBufferSource.naverMap,
      },
      reason: switch (mapEstimate.provider) {
        MapTravelProvider.tmap => 'Tmap route API response.',
        MapTravelProvider.naver => 'Naver Map directions API response.',
      },
    );
  }

  Future<int> estimateMinutesWithGoogleMaps({
    required String origin,
    required String destination,
    double? latitude,
    double? longitude,
    String? locationText,
  }) async {
    return (await estimateWithGoogleMaps(
      origin: origin,
      destination: destination,
      latitude: latitude,
      longitude: longitude,
      locationText: locationText,
    ))
        .minutes;
  }

  Future<Duration> estimateBufferWithGoogleMaps({
    required String origin,
    required String destination,
    double? latitude,
    double? longitude,
    String? locationText,
  }) async {
    return (await estimateWithGoogleMaps(
      origin: origin,
      destination: destination,
      latitude: latitude,
      longitude: longitude,
      locationText: locationText,
    ))
        .buffer;
  }

  int estimateMinutes({
    double? latitude,
    double? longitude,
    String? locationText,
  }) {
    return estimate(
      latitude: latitude,
      longitude: longitude,
      locationText: locationText,
    ).minutes;
  }

  Duration estimateBuffer({
    double? latitude,
    double? longitude,
    String? locationText,
  }) {
    return estimate(
      latitude: latitude,
      longitude: longitude,
      locationText: locationText,
    ).buffer;
  }

  int _estimateFromCoordinates(double latitude, double longitude) {
    final pseudoDistance = math.sqrt(
      (latitude * latitude) + (longitude * longitude),
    );
    final normalized = (pseudoDistance / 180.0).clamp(0.0, 1.0);
    return _clampMinutes(15 + (normalized * 45).round());
  }

  int _estimateFromLocationText(String locationText) {
    var score = 12 + (locationText.length ~/ 12);

    const keywordBonuses = <String, int>{
      'airport': 35,
      'station': 18,
      'terminal': 20,
      'downtown': 10,
      'city center': 10,
      'suburb': 8,
      'campus': 10,
      'hospital': 20,
      'clinic': 18,
      'hotel': 12,
      'resort': 12,
      'office': 8,
      'meeting': 10,
      'conference': 15,
      'home': 5,
      'park': 8,
      'museum': 8,
      'port': 12,
      'seaport': 12,
      'mall': 10,
      'market': 10,
      'seoul': 10,
      'busan': 10,
      'incheon': 10,
    };

    for (final entry in keywordBonuses.entries) {
      if (locationText.contains(entry.key)) {
        score += entry.value;
      }
    }

    if (RegExp(r'\d').hasMatch(locationText)) {
      score += 3;
    }

    if (locationText.contains(',')) {
      score += 2;
    }

    if (locationText.length > 24) {
      score += 4;
    }

    return _clampMinutes(score);
  }

  String _normalizeLocationText(String? locationText) {
    final text = locationText?.trim() ?? '';
    if (text.isEmpty) {
      return '';
    }
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _stringValue(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text;
  }

  int _clampMinutes(int minutes) {
    return minutes.clamp(10, 75).toInt();
  }
}
