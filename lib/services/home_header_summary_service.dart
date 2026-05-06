import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_permission_service.dart';

class HomeHeaderSummaryService {
  HomeHeaderSummaryService({
    http.Client Function()? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new;

  final http.Client Function() _httpClientFactory;

  Future<HomeHeaderSummary> load({
    GeoPoint? location,
  }) async {
    if (location == null) {
      return const HomeHeaderSummary(
        locationLabel: '위치 확인 중',
        weatherLabel: '날씨 확인 중',
        detailLine: '위치 권한을 허용하면 현재 위치와 날씨를 보여드려요.',
        isReady: false,
      );
    }

    final client = _httpClientFactory();
    try {
      final reverseUri = Uri.https(
        'geocoding-api.open-meteo.com',
        '/v1/reverse',
        <String, String>{
          'latitude': location.latitude.toString(),
          'longitude': location.longitude.toString(),
          'language': 'ko',
          'count': '1',
        },
      );
      final weatherUri = Uri.https(
        'api.open-meteo.com',
        '/v1/forecast',
        <String, String>{
          'latitude': location.latitude.toString(),
          'longitude': location.longitude.toString(),
          'current':
              'temperature_2m,apparent_temperature,weather_code,windspeed_10m',
          'timezone': 'auto',
        },
      );

      final reverseResponse = await _safeGet(client, reverseUri);
      final weatherResponse = await _safeGet(client, weatherUri);
      final locationLabel = reverseResponse == null
          ? null
          : _parseLocationLabel(reverseResponse.body);
      final weatherSummary = weatherResponse == null
          ? const _WeatherSummary(
              label: '날씨 확인 중',
              detailLine: '현재 날씨를 불러오지 못했어요.',
            )
          : _parseWeatherSummary(weatherResponse.body);
      return HomeHeaderSummary(
        locationLabel: locationLabel ?? _coordinateLabel(location),
        weatherLabel: weatherSummary.label,
        detailLine: weatherSummary.detailLine,
        isReady: reverseResponse != null || weatherResponse != null,
        weatherIcon: weatherSummary.icon,
      );
    } catch (error, stackTrace) {
      debugPrint('Home header summary load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const HomeHeaderSummary(
        locationLabel: '위치 확인 중',
        weatherLabel: '날씨 확인 중',
        detailLine: '날씨를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.',
        isReady: false,
      );
    } finally {
      client.close();
    }
  }

  Future<http.Response?> _safeGet(http.Client client, Uri uri) async {
    try {
      final response = await client.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      return response;
    } catch (_) {
      return null;
    }
  }

  String? _parseLocationLabel(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      final results = decoded['results'];
      if (results is! List || results.isEmpty) {
        return null;
      }
      final first = results.first;
      if (first is! Map) {
        return null;
      }
      final name = _textValue(first['name']);
      final city = _textValue(first['city']);
      final admin3 = _textValue(first['admin3']);
      final admin2 = _textValue(first['admin2']);
      final admin1 = _textValue(first['admin1']);
      final country = _textValue(first['country']);
      final pieces = <String>[
        if (name.isNotEmpty) name,
        if (city.isNotEmpty && city != name) city,
        if (admin3.isNotEmpty && admin3 != name && admin3 != city) admin3,
        if (admin2.isNotEmpty &&
            admin2 != name &&
            admin2 != city &&
            admin2 != admin3)
          admin2,
        if (admin1.isNotEmpty &&
            admin1 != name &&
            admin1 != city &&
            admin1 != admin3 &&
            admin1 != admin2)
          admin1,
      ];
      if (pieces.isNotEmpty) {
        return pieces.join(' · ');
      }
      if (country.isNotEmpty) {
        return country;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  _WeatherSummary _parseWeatherSummary(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const _WeatherSummary(
          label: '날씨 확인 중',
          detailLine: '현재 날씨를 불러오지 못했어요.',
        );
      }
      final current = decoded['current'];
      if (current is! Map) {
        return const _WeatherSummary(
          label: '날씨 확인 중',
          detailLine: '현재 날씨를 불러오지 못했어요.',
        );
      }

      final temperature = _numValue(current['temperature_2m']);
      final feelsLike = _numValue(current['apparent_temperature']);
      final windSpeed = _numValue(current['windspeed_10m']);
      final weatherCode = _intValue(current['weather_code']);
      final condition = _weatherCondition(weatherCode);

      final label = temperature == null
          ? condition.label
          : '${condition.label} ${temperature.toStringAsFixed(0)}°';
      final detailParts = <String>[
        '현재 $label',
        if (feelsLike != null) '체감 ${feelsLike.toStringAsFixed(0)}°',
        if (windSpeed != null) '바람 ${windSpeed.toStringAsFixed(1)}m/s',
      ];

      return _WeatherSummary(
        label: label,
        detailLine: detailParts.join(' · '),
        icon: condition.icon,
      );
    } catch (_) {
      return const _WeatherSummary(
        label: '날씨 확인 중',
        detailLine: '현재 날씨를 불러오지 못했어요.',
      );
    }
  }

  _WeatherCondition _weatherCondition(int? code) {
    return switch (code) {
      0 => const _WeatherCondition('맑음', Icons.wb_sunny_outlined),
      1 || 2 => const _WeatherCondition('대체로 맑음', Icons.wb_sunny_outlined),
      3 => const _WeatherCondition('흐림', Icons.cloud_outlined),
      45 || 48 => const _WeatherCondition('안개', Icons.foggy),
      51 || 53 || 55 => const _WeatherCondition('이슬비', Icons.grain_outlined),
      61 ||
      63 ||
      65 =>
        const _WeatherCondition('비', Icons.beach_access_outlined),
      71 || 73 || 75 => const _WeatherCondition('눈', Icons.ac_unit_outlined),
      80 || 81 || 82 => const _WeatherCondition('소나기', Icons.umbrella_outlined),
      95 ||
      96 ||
      99 =>
        const _WeatherCondition('뇌우', Icons.thunderstorm_outlined),
      _ => const _WeatherCondition('날씨', Icons.cloud_outlined),
    };
  }

  String _textValue(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return '';
    }
    return text;
  }

  double? _numValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  String _coordinateLabel(GeoPoint location) {
    final latitude = location.latitude.toStringAsFixed(4);
    final longitude = location.longitude.toStringAsFixed(4);
    return '좌표 $latitude, $longitude';
  }
}

class HomeHeaderSummary {
  const HomeHeaderSummary({
    required this.locationLabel,
    required this.weatherLabel,
    required this.detailLine,
    required this.isReady,
    this.weatherIcon = Icons.cloud_outlined,
  });

  final String locationLabel;
  final String weatherLabel;
  final String detailLine;
  final bool isReady;
  final IconData weatherIcon;
}

class _WeatherSummary {
  const _WeatherSummary({
    required this.label,
    required this.detailLine,
    this.icon = Icons.cloud_outlined,
  });

  final String label;
  final String detailLine;
  final IconData icon;
}

class _WeatherCondition {
  const _WeatherCondition(this.label, this.icon);

  final String label;
  final IconData icon;
}
