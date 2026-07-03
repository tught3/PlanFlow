import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/env.dart';
import 'api_usage_guard.dart';
import 'app_permission_service.dart';

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

  String get bestPlaceLabel => name.trim().isNotEmpty ? name : label;

  String get providerLabel => provider.providerLabel;
}

class LocationLookupSearchResult {
  const LocationLookupSearchResult({
    required this.originalQuery,
    required this.results,
    required this.searchedQueries,
    required this.fallbackQueries,
    this.authFailure,
  });

  final String originalQuery;
  final List<LocationLookupResult> results;
  final List<String> searchedQueries;
  final List<String> fallbackQueries;
  final LocationLookupException? authFailure;

  bool get hasResults => results.isNotEmpty;
}

/// 캐시 항목 — 결과와 만료 시각을 묶음.
class _LookupCacheEntry {
  _LookupCacheEntry({
    required this.result,
    required this.expiresAt,
  });

  final LocationLookupSearchResult result;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class LocationLookupService {
  LocationLookupService({
    String? clientId,
    String? clientSecret,
    String? proxyUrl,
    String? tmapApiKey,
    String? googleMapsApiKey,
    http.Client Function()? httpClientFactory,
    ApiUsageGuard? usageGuard,
  })  : _clientId = clientId ?? AppEnv.naverMapClientId,
        _clientSecret = clientSecret ?? '',
        _proxyUrl = proxyUrl ?? AppEnv.naverMapProxyUrl,
        _tmapApiKey = tmapApiKey ?? AppEnv.tmapApiKey,
        _googleMapsApiKey = googleMapsApiKey ?? AppEnv.googleMapsApiKey,
        _httpClientFactory = httpClientFactory ?? http.Client.new,
        _usageGuard = usageGuard;

  final String _clientId;
  final String _clientSecret;
  final String _proxyUrl;
  final String _tmapApiKey;
  final String _googleMapsApiKey;
  final http.Client Function() _httpClientFactory;
  final ApiUsageGuard? _usageGuard;

  ApiUsageGuard get _guard => _usageGuard ?? ApiUsageGuard.instance;

  // ── static 공유 캐시 ────────────────────────────────────────────────────────
  // 호출처가 매번 new LocationLookupService()를 생성하므로 인스턴스 필드로는
  // 캐시를 공유할 수 없다. 반드시 클래스 레벨(static) 캐시를 사용해야 한다.

  /// 성공(결과 있음) 캐시 TTL — 24시간.
  static const Duration _positiveCacheTtl = Duration(hours: 24);

  /// 네거티브(결과 빈 리스트) 캐시 TTL — 6시간.
  static const Duration _negativeCacheTtl = Duration(hours: 6);

  /// fallback 루프 최대 시도 횟수 — 한 미해결 검색이 tmap ≤ 1+5 = 6콜.
  static const int _maxFallbackQueries = 5;

  /// query 키 → 캐시 항목. key = query.trim().toLowerCase() (정규화).
  /// origin/preferredProvider는 key에 포함하지 않는다(과도복잡 방지; POI 결과는 query 기반).
  static final Map<String, _LookupCacheEntry> _resultCache = {};

  /// 동일 key 동시 요청의 Future를 공유해 중복 HTTP 호출을 막는다.
  static final Map<String, Future<LocationLookupSearchResult>> _inFlight = {};

  /// 테스트 간 static 누수 방지용 리셋. 프로덕션 코드에서는 호출 금지.
  static void resetLookupCacheForTesting() {
    _resultCache.clear();
    _inFlight.clear();
  }

  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    final response = await searchWithFallback(
      query,
      origin: origin,
      preferredProvider: preferredProvider,
    );
    return response.results;
  }

  /// 공개 진입점 — static 캐시 + in-flight 중복제거 래퍼.
  /// 실제 검색 로직은 [_searchWithFallbackUncached]에 있다.
  Future<LocationLookupSearchResult> searchWithFallback(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    final normalized = query.trim();

    // 빈 쿼리, 광범위 일반어, 지역명 단독은 캐시 없이 즉시 반환.
    if (normalized.isEmpty) {
      return LocationLookupSearchResult(
        originalQuery: query,
        results: const <LocationLookupResult>[],
        searchedQueries: const <String>[],
        fallbackQueries: const <String>[],
      );
    }

    // 캐시 key: query 정규화(소문자 trim). origin/preferredProvider는 제외.
    final cacheKey = normalized.toLowerCase();

    // 유효한 캐시 항목이 있으면 즉시 반환.
    final cached = _resultCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.result;
    }

    // 같은 key의 in-flight Future가 있으면 공유 — HTTP 중복 호출 방지.
    final existing = _inFlight[cacheKey];
    if (existing != null) {
      return existing;
    }

    // 새 Future를 생성해 등록하고 실제 검색을 수행한다.
    final future = _searchWithFallbackUncached(
      normalized,
      origin: origin,
      preferredProvider: preferredProvider,
    ).then((result) {
      // authFailure가 있으면 캐싱 금지 — 일시적 401/403이 캐시를 오염하지 않게.
      if (result.authFailure == null) {
        final ttl = result.hasResults ? _positiveCacheTtl : _negativeCacheTtl;
        _resultCache[cacheKey] = _LookupCacheEntry(
          result: result,
          expiresAt: DateTime.now().add(ttl),
        );
      }
      _inFlight.remove(cacheKey);
      return result;
    }).onError<Object>((error, stackTrace) {
      _inFlight.remove(cacheKey);
      // ignore: only_throw_errors
      throw error;
    });

    _inFlight[cacheKey] = future;
    return future;
  }

  /// 실제 검색 로직 — 캐시/in-flight 없이 항상 HTTP를 수행한다.
  /// [searchWithFallback]이 캐시 미스 시에만 호출한다.
  Future<LocationLookupSearchResult> _searchWithFallbackUncached(
    String normalized, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    if (_isBroadGenericPlaceQuery(normalized)) {
      return LocationLookupSearchResult(
        originalQuery: normalized,
        results: const <LocationLookupResult>[],
        searchedQueries: const <String>[],
        fallbackQueries: const <String>[],
      );
    }

    final regionResult = _lookupKoreanRegion(normalized);
    if (regionResult != null) {
      return LocationLookupSearchResult(
        originalQuery: normalized,
        results: <LocationLookupResult>[regionResult],
        searchedQueries: const <String>[],
        fallbackQueries: const <String>[],
      );
    }

    final results = <LocationLookupResult>[];
    final searchedQueries = <String>[];
    LocationLookupException? authFailure;
    final fallbackQueries = buildRetryQueries(normalized);

    await _searchAllProviders(normalized, results, searchedQueries, origin,
        (error) {
      authFailure ??= error;
    });

    if (results.isEmpty && fallbackQueries.isNotEmpty) {
      // fallback 캡: 최대 _maxFallbackQueries 개만 시도 — 한 검색이 tmap ≤ 1+5 = 6콜.
      for (final retryQuery in fallbackQueries.take(_maxFallbackQueries)) {
        await _searchAllProviders(retryQuery, results, searchedQueries, origin,
            (error) {
          authFailure ??= error;
        });
        if (results.isNotEmpty) {
          break;
        }
      }
    }

    final deduped = _rankResults(
      normalized,
      _dedupeResults(results),
      origin: origin,
      preferredProvider: preferredProvider,
    );
    final outcome = LocationLookupSearchResult(
      originalQuery: normalized,
      results: deduped,
      searchedQueries: searchedQueries,
      fallbackQueries: fallbackQueries,
      authFailure: authFailure,
    );
    if (deduped.isEmpty && authFailure != null) {
      throw authFailure!;
    }
    return outcome;
  }

  List<String> buildRetryQueries(String query) {
    final normalized = _normalizeWhitespace(query);
    if (normalized.isEmpty) {
      return const <String>[];
    }
    if (_isBroadGenericPlaceQuery(normalized)) {
      return const <String>[];
    }

    final variants = <String>{};
    final noWhitespace = normalized.replaceAll(RegExp(r'\s+'), '');
    _addQueryVariant(variants, noWhitespace, original: normalized);
    _addKnownPlaceAliasQueries(variants, normalized);

    final normalizedTokens = _tokenize(normalized)
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final particleCleanTokens = normalizedTokens
        .map(_removeKoreanParticleSuffix)
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final fallbackTokens = particleCleanTokens
        .map(_removeLocationSuffix)
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    if (particleCleanTokens.isNotEmpty) {
      _addQueryVariant(variants, particleCleanTokens.join(' '),
          original: normalized);
      _addQueryVariant(variants, particleCleanTokens.join(''),
          original: normalized);
      if (particleCleanTokens.length >= 2) {
        _addQueryVariant(variants, particleCleanTokens.reversed.join(' '),
            original: normalized);
      }
    }

    if (fallbackTokens.isNotEmpty) {
      _addQueryVariant(variants, fallbackTokens.join(' '),
          original: normalized);
      _addQueryVariant(variants, fallbackTokens.join(''), original: normalized);
      if (fallbackTokens.length >= 2) {
        _addQueryVariant(
          variants,
          fallbackTokens.reversed.join(' '),
          original: normalized,
        );
      }
    }

    for (final region in _matchedKoreanRegionHints(normalized)) {
      _addQueryVariant(variants, region.displayName, original: normalized);
      final coreTokens = fallbackTokens
          .where((token) => !_containsAlias(token, region))
          .toList(growable: false);
      if (coreTokens.isNotEmpty) {
        final core = _normalizeWhitespace(coreTokens.join(' '));
        if (core.isNotEmpty) {
          _addQueryVariant(
            variants,
            '${region.displayName} $core',
            original: normalized,
          );
          _addQueryVariant(
            variants,
            '$core ${region.displayName}',
            original: normalized,
          );
        }
      }
      if (coreTokens.isNotEmpty) {
        _addQueryVariant(variants, coreTokens.first, original: normalized);
      }
    }

    if (normalizedTokens.length >= 2) {
      for (var i = 0; i < normalizedTokens.length - 1; i++) {
        final swapped = List<String>.from(normalizedTokens);
        final current = swapped[i];
        final next = swapped[i + 1];
        swapped[i] = next;
        swapped[i + 1] = current;
        _addQueryVariant(
          variants,
          _normalizeWhitespace(swapped.join(' ')),
          original: normalized,
        );
      }
    }

    return variants.toList(growable: false);
  }

  void _addKnownPlaceAliasQueries(Set<String> variants, String normalized) {
    final compact = normalized.replaceAll(RegExp(r'\s+'), '');
    for (final alias in _knownPlaceAliases) {
      if (!alias.matches(compact)) {
        continue;
      }
      for (final query in alias.queries) {
        _addQueryVariant(variants, query, original: normalized);
      }
    }
  }

  String _normalizeWhitespace(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<void> _searchAllProviders(
    String query,
    List<LocationLookupResult> results,
    List<String> searchedQueries,
    GeoPoint? origin,
    void Function(LocationLookupException error) onAuthError,
  ) async {
    searchedQueries.add(query);
    final rawResults = await Future.wait<List<LocationLookupResult>>([
      _searchTmap(query, origin: origin).catchError((Object error, _) {
        if (error is LocationLookupException) {
          onAuthError(error);
        }
        return const <LocationLookupResult>[];
      }),
      _searchNaver(query).catchError((Object error, _) {
        if (error is LocationLookupException) {
          onAuthError(error);
        }
        return const <LocationLookupResult>[];
      }),
      _searchGoogle(query).catchError((Object error, _) {
        if (error is LocationLookupException) {
          onAuthError(error);
        }
        return const <LocationLookupResult>[];
      }),
    ]);
    for (final providerResults in rawResults) {
      results.addAll(providerResults);
    }
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

  Future<List<LocationLookupResult>> _searchTmap(
    String normalized, {
    GeoPoint? origin,
  }) async {
    if (_tmapApiKey.trim().isEmpty) {
      return const <LocationLookupResult>[];
    }

    // circuit breaker — 일일 한도 초과 시 실제 HTTP 호출 없이 즉시 빈 결과 반환
    if (!await _guard.tryConsume(ApiName.tmapPoi)) {
      debugPrint('ApiUsageGuard: tmap_poi blocked — daily limit exceeded');
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
          if (origin != null) ...<String, String>{
            'centerLat': origin.latitude.toString(),
            'centerLon': origin.longitude.toString(),
          },
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

  List<LocationLookupResult> _rankResults(
    String query,
    List<LocationLookupResult> results, {
    required GeoPoint? origin,
    required LocationLookupProvider? preferredProvider,
  }) {
    if (results.length < 2) {
      return results;
    }
    final originalIndex = <LocationLookupResult, int>{
      for (var index = 0; index < results.length; index++) results[index]: index,
    };
    final ranked = List<LocationLookupResult>.of(results);
    ranked.sort((a, b) {
      final scoreCompare = _relevanceScore(
        query,
        b,
        origin: origin,
        preferredProvider: preferredProvider,
      ).compareTo(
        _relevanceScore(
          query,
          a,
          origin: origin,
          preferredProvider: preferredProvider,
        ),
      );
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return (originalIndex[a] ?? 0).compareTo(originalIndex[b] ?? 0);
    });
    return ranked;
  }

  double _relevanceScore(
    String query,
    LocationLookupResult result, {
    required GeoPoint? origin,
    required LocationLookupProvider? preferredProvider,
  }) {
    final normalizedQuery = _compactSearchText(query);
    final nameCompact = _compactSearchText(result.name);
    final label = _compactSearchText('${result.name} ${result.address}');
    var score = 0.0;

    // --- 이름 기반 유사도 (name-only 우선, label 보조) ---
    if (normalizedQuery.isNotEmpty) {
      if (nameCompact == normalizedQuery) {
        // (1) 이름이 검색어와 정확히 일치
        score += 150;
      } else if (label == normalizedQuery) {
        // (1) label 정확 일치
        score += 120;
      } else if (nameCompact.startsWith(normalizedQuery)) {
        // (2) 이름이 검색어로 시작 (접두 일치) — 짧을수록 가산
        score += 110;
        final extraChars = nameCompact.length - normalizedQuery.length;
        score += (20 - extraChars.clamp(0, 20)).toDouble();
      } else if (label.startsWith(normalizedQuery)) {
        // (2) label 접두 일치 — 짧을수록 가산
        score += 90;
        final extraChars = label.length - normalizedQuery.length;
        score += (10 - extraChars.clamp(0, 10)).toDouble();
      } else if (nameCompact.contains(normalizedQuery)) {
        // (3) 이름에 검색어 포함 — 짧을수록 더 유사
        score += 80;
        // 이름이 짧을수록 가산 (군더더기가 적음): 최대 +20
        final extraChars = nameCompact.length - normalizedQuery.length;
        score += (20 - extraChars.clamp(0, 20)).toDouble();
      } else if (label.contains(normalizedQuery)) {
        // (3) label에 검색어 포함 — 이름 포함보다 낮은 점수
        score += 60;
        final extraChars = label.length - normalizedQuery.length;
        score += (10 - extraChars.clamp(0, 10)).toDouble();
      } else if (normalizedQuery.contains(nameCompact) ||
          normalizedQuery.contains(label)) {
        score += 45;
      } else {
        // (3.5) 오탈자/STT 오인식으로 한두 글자만 다른 근접 일치
        // (예: 검색어 "레온동물병원" vs 실제 이름 "래온동물병원" — 편집거리 1).
        // 완전 무관한 결과와 동일하게(0점) 취급되면 실제로 찾던 곳이 밀려난다.
        final nameDistance = _editDistance(nameCompact, normalizedQuery);
        final nameMaxLen = math.max(nameCompact.length, normalizedQuery.length);
        if (nameMaxLen >= 3 && nameDistance <= _nearMatchMaxDistance(nameMaxLen)) {
          score += (70 - nameDistance * 15).clamp(0, 70).toDouble();
        }
      }
    }

    // --- 교통 키워드 가산점 ---
    // 검색어에 역/지하철/버스 등이 있을 때 결과 이름에도 같은 키워드 있으면 +15
    const transitKeywords = <String>['역', '지하철', '버스', '터미널', '공항', '기차'];
    final queryRaw = query.replaceAll(RegExp(r'\s+'), '');
    for (final kw in transitKeywords) {
      if (queryRaw.contains(kw) && nameCompact.contains(kw)) {
        score += 15;
        break; // 한 번만 가산
      }
    }

    // --- 토큰 단위 포함 점수 ---
    final queryTokens = _tokenize(query)
        .map(_removeKoreanParticleSuffix)
        .map(_removeLocationSuffix)
        .map(_compactSearchText)
        .where((token) => token.length >= 2)
        .toList(growable: false);
    for (final token in queryTokens) {
      if (label.contains(token)) {
        score += 12;
      }
    }

    // --- 지역 힌트 가산점 ---
    for (final region in _matchedKoreanRegionHints(query)) {
      if (_containsAlias(_compactSearchText(result.name), region) ||
          _containsAlias(_compactSearchText(result.address), region)) {
        score += 30;
      }
    }

    // --- 제공자 선호 ---
    if (preferredProvider != null && result.provider == preferredProvider) {
      score += 8;
    }

    // --- 거리 가산점 ---
    if (origin != null && !_hasExplicitRegionHint(query)) {
      final distance = _distanceMeters(origin, result);
      score += (30 - (distance / 1000)).clamp(0, 30).toDouble();
    }
    return score;
  }

  /// 검색어와의 유사도로 결과 리스트를 재정렬하는 순수 함수.
  /// API 호출 없이 이미 받은 [results] 리스트에 적용.
  /// 정렬 우선순위:
  ///   (1) 이름 정확 일치
  ///   (2) 이름이 검색어로 시작(접두 일치)
  ///   (3) 이름에 검색어 포함(짧은 이름 우선)
  ///   (4) 교통 키워드(역·지하철 등) 가산
  ///   (5) 나머지 API 기본 순서
  List<LocationLookupResult> sortByRelevance(
    String query,
    List<LocationLookupResult> results, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) {
    return _rankResults(
      query,
      results,
      origin: origin,
      preferredProvider: preferredProvider,
    );
  }

  /// 두 문자열의 Levenshtein 편집거리(치환/삽입/삭제 1회당 1).
  int _editDistance(String a, String b) {
    if (a == b) {
      return 0;
    }
    if (a.isEmpty) {
      return b.length;
    }
    if (b.isEmpty) {
      return a.length;
    }
    var previousRow = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final currentRow = List<int>.filled(b.length + 1, 0);
      currentRow[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final deletionCost = previousRow[j + 1] + 1;
        final insertionCost = currentRow[j] + 1;
        final substitutionCost =
            previousRow[j] + (a[i] == b[j] ? 0 : 1);
        currentRow[j + 1] =
            [deletionCost, insertionCost, substitutionCost].reduce(math.min);
      }
      previousRow = currentRow;
    }
    return previousRow[b.length];
  }

  /// 근접 일치로 인정할 최대 편집거리 — 문자열이 길수록 조금 더 허용.
  int _nearMatchMaxDistance(int length) {
    if (length <= 8) {
      return 1;
    }
    if (length <= 16) {
      return 2;
    }
    return 3;
  }

  String _compactSearchText(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  }

  double _distanceMeters(GeoPoint origin, LocationLookupResult result) {
    const earthRadiusMeters = 6371000.0;
    final lat1 = _degreesToRadians(origin.latitude);
    final lat2 = _degreesToRadians(result.latitude);
    final deltaLat = _degreesToRadians(result.latitude - origin.latitude);
    final deltaLng = _degreesToRadians(result.longitude - origin.longitude);
    final sinLat = math.sin(deltaLat / 2);
    final sinLng = math.sin(deltaLng / 2);
    final haversine =
        sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLng * sinLng;
    return earthRadiusMeters *
        2 *
        math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
  }

  double _degreesToRadians(double degrees) => degrees * math.pi / 180;

  bool _hasExplicitRegionHint(String query) {
    final normalized = query.replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) {
      return false;
    }
    for (final region in _koreanRegionHints) {
      for (final alias in region.aliases) {
        if (normalized.contains(alias)) {
          return true;
        }
      }
    }
    return false;
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

  List<String> _tokenize(String query) {
    return _normalizeWhitespace(query)
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  String _removeKoreanParticleSuffix(String token) {
    var value = token;
    for (final suffix in _koreanParticleSuffixes) {
      if (value.length <= suffix.length + 1) {
        continue;
      }
      if (value.endsWith(suffix)) {
        value = value.substring(0, value.length - suffix.length);
        break;
      }
    }
    return value;
  }

  String _removeLocationSuffix(String token) {
    var value = token;
    for (final suffix in _locationSuffixes) {
      if (value.length <= suffix.length + 1) {
        continue;
      }
      if (value.endsWith(suffix)) {
        value = value.substring(0, value.length - suffix.length);
        break;
      }
    }
    return value;
  }

  List<_KoreanRegionHint> _matchedKoreanRegionHints(
    String query,
  ) {
    final normalized = query.replaceAll(' ', '');
    final regionSet = <String>{};
    final matchedRegions = <_KoreanRegionHint>[];
    for (final region in _koreanRegionHints) {
      final isMatched = region.aliases
          .any((alias) => normalized == alias || normalized.startsWith(alias));
      if (!isMatched) {
        continue;
      }
      if (regionSet.add(region.displayName)) {
        matchedRegions.add(region);
      }
    }
    return matchedRegions;
  }

  bool _containsAlias(String token, _KoreanRegionHint region) {
    return region.aliases
        .any((alias) => token == alias || token.contains(alias));
  }

  bool _isBroadGenericPlaceQuery(String query) {
    if (_hasExplicitRegionHint(query)) {
      return false;
    }
    final tokens = _tokenize(query)
        .map(_removeKoreanParticleSuffix)
        .map(_removeLocationSuffix)
        .map((token) => token.replaceAll(RegExp(r'\s+'), ''))
        .where((token) => token.isNotEmpty)
        .where((token) => !_genericPlaceActionWords.contains(token))
        .toList(growable: false);
    if (tokens.isEmpty) {
      return false;
    }
    return tokens.every(_genericPlaceWords.contains);
  }

  static const List<String> _koreanParticleSuffixes = <String>[
    '에서',
    '으로',
    '로',
    '을',
    '를',
    '이',
    '가',
    '의',
    '에',
    '로부터',
    '부터',
    '에게',
    '께',
    '하고',
  ];

  static const List<String> _locationSuffixes = <String>[
    '앞',
    '옆',
    '부근',
    '입구',
    '역',
    '일대',
    '거리',
    '로',
    '길',
    '가',
    '동',
    '구',
    '시',
  ];

  void _addQueryVariant(
    Set<String> variants,
    String candidate, {
    required String original,
  }) {
    final value = _normalizeWhitespace(candidate);
    if (value.isEmpty) {
      return;
    }
    if (value == original || variants.contains(value)) {
      return;
    }
    variants.add(value);
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
      if (normalizedQuery == alias) {
        return true;
      }
    }
    return false;
  }
}

const List<_KoreanRegionHint> _koreanRegionHints = <_KoreanRegionHint>[
  _KoreanRegionHint(
    displayName: '원주',
    latitude: 37.3422,
    longitude: 127.9202,
    aliases: <String>['원주', '원주시'],
  ),
  _KoreanRegionHint(
    displayName: '서울',
    latitude: 37.5665,
    longitude: 126.978,
    aliases: <String>['서울', '서울시', '서울특별시'],
  ),
  _KoreanRegionHint(
    displayName: '용산',
    latitude: 37.5326,
    longitude: 126.9900,
    aliases: <String>['용산', '용산구'],
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

class _KnownPlaceAlias {
  const _KnownPlaceAlias({
    required this.aliases,
    required this.queries,
  });

  final List<String> aliases;
  final List<String> queries;

  bool matches(String compactQuery) {
    for (final alias in aliases) {
      if (compactQuery == alias || compactQuery.contains(alias)) {
        return true;
      }
    }
    return false;
  }
}

const Set<String> _genericPlaceWords = <String>{
  '병원',
  '의원',
  '치과',
  '한의원',
  '약국',
};

const Set<String> _genericPlaceActionWords = <String>{
  '방문',
  '가기',
  '감',
  '가',
  '예약',
  '미팅',
  '회의',
  '약속',
  '진료',
  '검진',
  '검사',
  '치료',
  '처방',
  '접종',
  '들르기',
  '들름',
};

const List<_KnownPlaceAlias> _knownPlaceAliases = <_KnownPlaceAlias>[
  _KnownPlaceAlias(
    aliases: <String>[
      '원주기독',
      '원주기독병원',
      '원주기독정형외과',
      '원주세브',
      '원주세브란스',
      '원주세브란스기독',
    ],
    queries: <String>[
      '원주세브란스기독병원',
      '원주 세브란스 기독병원',
      '연세대학교 원주세브란스기독병원',
    ],
  ),
];
