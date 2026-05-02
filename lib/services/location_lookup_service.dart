import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/env.dart';

class LocationLookupResult {
  const LocationLookupResult({
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
  });

  final String name;
  final String address;
  final double latitude;
  final double longitude;

  String get label => address.isNotEmpty ? address : name;
}

class LocationLookupService {
  LocationLookupService({
    String? clientId,
    String? clientSecret,
    http.Client Function()? httpClientFactory,
  })  : _clientId = clientId ?? AppEnv.naverMapClientId,
        _clientSecret = clientSecret ?? AppEnv.naverMapClientSecret,
        _httpClientFactory = httpClientFactory ?? http.Client.new;

  final String _clientId;
  final String _clientSecret;
  final http.Client Function() _httpClientFactory;

  Future<List<LocationLookupResult>> search(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty ||
        _clientId.trim().isEmpty ||
        _clientSecret.trim().isEmpty) {
      return const <LocationLookupResult>[];
    }

    final client = _httpClientFactory();
    try {
      final response = await client.get(
        Uri.https(
          'naveropenapi.apigw.ntruss.com',
          '/map-geocode/v2/geocode',
          <String, String>{
            'query': normalized,
          },
        ),
        headers: <String, String>{
          'X-NCP-APIGW-API-KEY-ID': _clientId,
          'X-NCP-APIGW-API-KEY': _clientSecret,
          'accept': 'application/json',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <LocationLookupResult>[];
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const <LocationLookupResult>[];
      }

      final addresses = decoded['addresses'];
      if (addresses is! List) {
        return const <LocationLookupResult>[];
      }

      return addresses
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .map(_parseAddress)
          .whereType<LocationLookupResult>()
          .toList(growable: false);
    } catch (_) {
      return const <LocationLookupResult>[];
    } finally {
      client.close();
    }
  }

  LocationLookupResult? _parseAddress(Map<String, dynamic> json) {
    final longitude = _doubleValue(json['x']);
    final latitude = _doubleValue(json['y']);
    if (longitude == null || latitude == null) {
      return null;
    }

    final roadAddress = _textValue(json['roadAddress']);
    final jibunAddress = _textValue(json['jibunAddress']);
    final name = _textValue(json['placeName']);
    final formattedAddress = _textValue(json['formattedAddress']);
    final displayName = name.isNotEmpty
        ? name
        : (formattedAddress.isNotEmpty
            ? formattedAddress
            : (roadAddress.isNotEmpty ? roadAddress : jibunAddress));

    return LocationLookupResult(
      name: displayName,
      address: roadAddress.isNotEmpty ? roadAddress : jibunAddress,
      latitude: latitude,
      longitude: longitude,
    );
  }

  String _textValue(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return '';
    }
    return text;
  }

  double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }
}
