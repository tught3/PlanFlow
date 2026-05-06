import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/env.dart';

enum LocationLookupProvider {
  tmap,
  naver,
  google,
  manual,
}

extension LocationLookupProviderLabel on LocationLookupProvider {
  String get providerLabel => switch (this) {
        LocationLookupProvider.tmap => 'TMAP',
        LocationLookupProvider.naver => 'Naver',
        LocationLookupProvider.google => 'Google',
        LocationLookupProvider.manual => '직접 선택',
      };
}

class LocationLookupException implements Exception {
  const LocationLookupException({
    required this.statusCode,
    required this.message,
    this.provider = LocationLookupProvider.naver,
  });

  final int statusCode;
  final String message;
  final LocationLookupProvider provider;

  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'LocationLookupException($statusCode, $message)';
}

class LocationLookupResult {
  const LocationLookupResult({
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.provider = LocationLookupProvider.naver,
  });

  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final LocationLookupProvider provider;

  String get label => address.isNotEmpty ? address : name;

  String get providerLabel => provider.providerLabel;
}

class LocationLookupService {
  LocationLookupService({
    String? clientId,
    String? clientSecret,
    String? proxyUrl,
    String? tmapApiKey,
    String? googleMapsApiKey,
    http.Client Function()? httpClientFactory,
  })  : _clientId = clientId ?? AppEnv.naverMapClientId,
        _clientSecret = clientSecret ?? AppEnv.naverMapClientSecret,
        _proxyUrl = proxyUrl ?? AppEnv.naverMapProxyUrl,
        _tmapApiKey = tmapApiKey ?? AppEnv.tmapApiKey,
        _googleMapsApiKey = googleMapsApiKey ?? AppEnv.googleMapsApiKey,
        _httpClientFactory = httpClientFactory ?? http.Client.new;

  final String _clientId;
  final String _clientSecret;
  final String _proxyUrl;
  final String _tmapApiKey;
  final String _googleMapsApiKey;
  final http.Client Function() _httpClientFactory;

  Future<List<LocationLookupResult>> search(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const <LocationLookupResult>[];
    }

    final regionResult = _lookupKoreanRegion(normalized);
    if (regionResult != null) {
      return <LocationLookupResult>[regionResult];
    }

    final results = <LocationLookupResult>[];
    LocationLookupException? authFailure;

    try {
      results.addAll(await _searchTmap(normalized));
    } on LocationLookupException catch (error) {
      authFailure ??= error;
    }

    try {
      results.addAll(await _searchNaver(normalized));
    } on LocationLookupException catch (error) {
      authFailure ??= error;
    }

    try {
      results.addAll(await _searchGoogle(normalized));
    } on LocationLookupException catch (error) {
      authFailure ??= error;
    }

    final deduped = _dedupeResults(results);
    if (deduped.isEmpty && authFailure != null) {
      throw authFailure;
    }
    return deduped;
  }

  Future<List<LocationLookupResult>> _searchNaver(String normalized) async {
    final proxyUri = _proxyUri(normalized);
    final useProxy = proxyUri != null;
    if (!useProxy &&
        (_clientId.trim().isEmpty || _clientSecret.trim().isEmpty)) {
      return const <LocationLookupResult>[];
    }

    final client = _httpClientFactory();
    try {
      final response = await (useProxy
              ? client.get(proxyUri, headers: const <String, String>{
                  'accept': 'application/json',
                })
              : client.get(
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
                ))
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw LocationLookupException(
          statusCode: response.statusCode,
          message: '네이버 지도 API 인증 또는 서비스 권한을 확인해 주세요.',
          provider: LocationLookupProvider.naver,
        );
      }

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
    } on LocationLookupException {
      rethrow;
    } catch (error) {
      debugPrint('TMAP POI search failed: $error');
      return const <LocationLookupResult>[];
    } finally {
      client.close();
    }
  }

  Future<List<LocationLookupResult>> _searchTmap(String normalized) async {
    if (_tmapApiKey.trim().isEmpty) {
      return const <LocationLookupResult>[];
    }

    final client = _httpClientFactory();
    try {
      final response = await client.get(
        Uri.https('apis.openapi.sk.com', '/tmap/pois', <String, String>{
          'version': '1',
          'format': 'json',
          'searchKeyword': normalized,
          'page': '1',
          'count': '10',
          'searchType': 'all',
          'searchtypCd': 'A',
          'reqCoordType': 'WGS84GEO',
          'resCoordType': 'WGS84GEO',
        }),
        headers: <String, String>{
          'appKey': _tmapApiKey,
          'accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw LocationLookupException(
          statusCode: response.statusCode,
          message: 'TMAP API 키 또는 POI 검색 권한을 확인해 주세요.',
          provider: LocationLookupProvider.tmap,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <LocationLookupResult>[];
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const <LocationLookupResult>[];
      }
      final pois = decoded['searchPoiInfo'] is Map
          ? (decoded['searchPoiInfo'] as Map)['pois']
          : null;
      final poiList = pois is Map ? pois['poi'] : null;
      final poiItems = switch (poiList) {
        List items => items,
        Map item => <Object?>[item],
        _ => const <Object?>[],
      };
      if (poiItems.isEmpty) {
        return const <LocationLookupResult>[];
      }

      return poiItems
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .map(_parseTmapPoi)
          .whereType<LocationLookupResult>()
          .toList(growable: false);
    } on LocationLookupException {
      rethrow;
    } catch (error) {
      debugPrint('Naver geocoding search failed: $error');
      return const <LocationLookupResult>[];
    } finally {
      client.close();
    }
  }

  Future<List<LocationLookupResult>> _searchGoogle(String normalized) async {
    if (_googleMapsApiKey.trim().isEmpty) {
      return const <LocationLookupResult>[];
    }

    final client = _httpClientFactory();
    try {
      final response = await client.get(
        Uri.https(
            'maps.googleapis.com', '/maps/api/geocode/json', <String, String>{
          'address': normalized,
          'region': 'kr',
          'language': 'ko',
          'key': _googleMapsApiKey,
        }),
        headers: const <String, String>{
          'accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw LocationLookupException(
          statusCode: response.statusCode,
          message: 'Google 지도 API 키 또는 Geocoding 권한을 확인해 주세요.',
          provider: LocationLookupProvider.google,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <LocationLookupResult>[];
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const <LocationLookupResult>[];
      }
      final status = decoded['status']?.toString();
      if (status == 'REQUEST_DENIED') {
        throw LocationLookupException(
          statusCode: 403,
          message: 'Google Geocoding API 설정 또는 키 제한을 확인해 주세요.',
          provider: LocationLookupProvider.google,
        );
      }
      final items = decoded['results'];
      if (items is! List) {
        return const <LocationLookupResult>[];
      }
      return items
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .map(_parseGoogleResult)
          .whereType<LocationLookupResult>()
          .toList(growable: false);
    } on LocationLookupException {
      rethrow;
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
      provider: LocationLookupProvider.naver,
    );
  }

  LocationLookupResult? _parseTmapPoi(Map<String, dynamic> json) {
    final longitude =
        _doubleValue(json['frontLon']) ?? _doubleValue(json['noorLon']);
    final latitude =
        _doubleValue(json['frontLat']) ?? _doubleValue(json['noorLat']);
    if (longitude == null || latitude == null) {
      return null;
    }
    final name = _textValue(json['name']);
    final upperAddr = _textValue(json['upperAddrName']);
    final middleAddr = _textValue(json['middleAddrName']);
    final lowerAddr = _textValue(json['lowerAddrName']);
    final detailAddr = _textValue(json['detailAddrName']);
    final roadName = _textValue(json['roadName']);
    final buildingNo1 = _textValue(json['firstBuildNo']);
    final buildingNo2 = _textValue(json['secondBuildNo']);
    final roadAddress = [
      upperAddr,
      middleAddr,
      lowerAddr,
      roadName,
      [buildingNo1, buildingNo2].where((part) => part.isNotEmpty).join('-'),
    ].where((part) => part.isNotEmpty).join(' ');
    final jibunAddress = [upperAddr, middleAddr, lowerAddr, detailAddr]
        .where((part) => part.isNotEmpty)
        .join(' ');
    return LocationLookupResult(
      name: name.isNotEmpty
          ? name
          : (roadAddress.isNotEmpty ? roadAddress : jibunAddress),
      address: roadAddress.isNotEmpty ? roadAddress : jibunAddress,
      latitude: latitude,
      longitude: longitude,
      provider: LocationLookupProvider.tmap,
    );
  }

  LocationLookupResult? _parseGoogleResult(Map<String, dynamic> json) {
    final geometry = json['geometry'];
    final location = geometry is Map ? geometry['location'] : null;
    if (location is! Map) {
      return null;
    }
    final latitude = _doubleValue(location['lat']);
    final longitude = _doubleValue(location['lng']);
    if (latitude == null || longitude == null) {
      return null;
    }
    final formattedAddress = _textValue(json['formatted_address']);
    final name = _textValue(json['name']);
    return LocationLookupResult(
      name: name.isNotEmpty ? name : formattedAddress,
      address: formattedAddress,
      latitude: latitude,
      longitude: longitude,
      provider: LocationLookupProvider.google,
    );
  }

  List<LocationLookupResult> _dedupeResults(
      List<LocationLookupResult> results) {
    final seen = <String>{};
    final deduped = <LocationLookupResult>[];
    for (final result in results) {
      final key =
          '${result.name}|${result.latitude.toStringAsFixed(5)}|${result.longitude.toStringAsFixed(5)}';
      if (seen.add(key)) {
        deduped.add(result);
      }
    }
    return deduped;
  }

  LocationLookupResult? _lookupKoreanRegion(String query) {
    final normalized = query.replaceAll(RegExp(r'\s+'), '');
    for (final region in _koreanRegionHints) {
      if (region.matches(normalized)) {
        return LocationLookupResult(
          name: region.displayName,
          address: region.displayName,
          latitude: region.latitude,
          longitude: region.longitude,
          provider: LocationLookupProvider.manual,
        );
      }
    }
    return null;
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

  Uri? _proxyUri(String query) {
    final raw = _proxyUrl.trim();
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
        'query': query,
      },
    );
  }
}

class _KoreanRegionHint {
  const _KoreanRegionHint({
    required this.displayName,
    required this.latitude,
    required this.longitude,
    required this.aliases,
  });

  final String displayName;
  final double latitude;
  final double longitude;
  final List<String> aliases;

  bool matches(String normalizedQuery) {
    for (final alias in aliases) {
      if (normalizedQuery == alias || normalizedQuery.contains(alias)) {
        return true;
      }
    }
    return false;
  }
}

const List<_KoreanRegionHint> _koreanRegionHints = <_KoreanRegionHint>[
  _KoreanRegionHint(
    displayName: '서울',
    latitude: 37.5665,
    longitude: 126.978,
    aliases: <String>['서울', '서울시', '서울특별시'],
  ),
  _KoreanRegionHint(
    displayName: '대전',
    latitude: 36.3504,
    longitude: 127.3845,
    aliases: <String>['대전', '대전시', '대전광역시'],
  ),
  _KoreanRegionHint(
    displayName: '광주',
    latitude: 35.1595,
    longitude: 126.8526,
    aliases: <String>['광주', '광주시', '광주광역시'],
  ),
  _KoreanRegionHint(
    displayName: '대구',
    latitude: 35.8714,
    longitude: 128.6014,
    aliases: <String>['대구', '대구시', '대구광역시'],
  ),
  _KoreanRegionHint(
    displayName: '부산',
    latitude: 35.1796,
    longitude: 129.0756,
    aliases: <String>['부산', '부산시', '부산광역시'],
  ),
  _KoreanRegionHint(
    displayName: '남양주',
    latitude: 37.6364,
    longitude: 127.2147,
    aliases: <String>['남양주', '남양주시'],
  ),
  _KoreanRegionHint(
    displayName: '성남',
    latitude: 37.4200,
    longitude: 127.1260,
    aliases: <String>['성남', '성남시'],
  ),
  _KoreanRegionHint(
    displayName: '안양',
    latitude: 37.3943,
    longitude: 126.9568,
    aliases: <String>['안양', '안양시'],
  ),
  _KoreanRegionHint(
    displayName: '수원',
    latitude: 37.2636,
    longitude: 127.0286,
    aliases: <String>['수원', '수원시'],
  ),
  _KoreanRegionHint(
    displayName: '인천',
    latitude: 37.4563,
    longitude: 126.7052,
    aliases: <String>['인천', '인천시', '인천광역시'],
  ),
  _KoreanRegionHint(
    displayName: '울산',
    latitude: 35.5384,
    longitude: 129.3114,
    aliases: <String>['울산', '울산시', '울산광역시'],
  ),
  _KoreanRegionHint(
    displayName: '세종',
    latitude: 36.4800,
    longitude: 127.2890,
    aliases: <String>['세종', '세종시', '세종특별자치시'],
  ),
  _KoreanRegionHint(
    displayName: '고양',
    latitude: 37.6564,
    longitude: 126.8395,
    aliases: <String>['고양', '고양시'],
  ),
  _KoreanRegionHint(
    displayName: '용인',
    latitude: 37.2411,
    longitude: 127.1776,
    aliases: <String>['용인', '용인시'],
  ),
  _KoreanRegionHint(
    displayName: '부천',
    latitude: 37.5035,
    longitude: 126.7660,
    aliases: <String>['부천', '부천시'],
  ),
  _KoreanRegionHint(
    displayName: '창원',
    latitude: 35.2285,
    longitude: 128.6811,
    aliases: <String>['창원', '창원시'],
  ),
];
