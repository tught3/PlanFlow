import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:xml/xml.dart';

import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';

enum NaverCalDavConnectionStatus {
  success,
  unauthorized,
  forbidden,
  notFound,
  networkError,
  serverError,
  failed,
}

class NaverCalDavConnectionResult {
  const NaverCalDavConnectionResult({
    required this.status,
    required this.message,
    this.statusCode,
    this.endpoint,
    this.error,
  });

  final NaverCalDavConnectionStatus status;
  final String message;
  final int? statusCode;
  final Uri? endpoint;
  final Object? error;

  bool get isSuccess => status == NaverCalDavConnectionStatus.success;
}

class NaverCalDavCalendar {
  const NaverCalDavCalendar({
    required this.path,
    required this.displayName,
    this.ctag,
  });

  final String path;
  final String displayName;
  final String? ctag;
}

class NaverCalDavEvent {
  const NaverCalDavEvent({
    required this.uid,
    required this.href,
    required this.etag,
    required this.icsData,
    required this.title,
    required this.startAt,
    this.endAt,
    this.location,
    this.description,
    this.lastModifiedAt,
    this.isAllDay = false,
  });

  final String uid;
  final String href;
  final String etag;
  final String icsData;
  final String title;
  final DateTime startAt;
  final DateTime? endAt;
  final String? location;
  final String? description;
  final DateTime? lastModifiedAt;
  final bool isAllDay;

  EventModel toEventModel({
    required String userId,
    required String calendarPath,
    required DateTime syncedAt,
  }) {
    return EventModel(
      id: '',
      userId: userId,
      title: title.trim().isEmpty ? '네이버 캘린더 일정' : title.trim(),
      startAt: startAt.toUtc(),
      endAt: endAt?.toUtc(),
      location: _blankToNull(location),
      memo: _blankToNull(description),
      supplies: const <String>[],
      suppliesChecked: const <String>[],
      isCritical: false,
      source: 'naver_caldav',
      externalId: 'naver-caldav:$uid',
      externalCalendarId: 'naver-caldav:$calendarPath',
      externalUpdatedAt: lastModifiedAt?.toUtc() ?? syncedAt,
      lastSyncedAt: syncedAt,
    );
  }
}

class NaverCalDavSyncResult {
  const NaverCalDavSyncResult({
    required this.success,
    required this.message,
    this.createdOrUpdated = 0,
    this.calendars = 0,
    this.events = 0,
    this.error,
  });

  final bool success;
  final String message;
  final int createdOrUpdated;
  final int calendars;
  final int events;
  final Object? error;
}

abstract class NaverCalDavCredentialStore {
  const NaverCalDavCredentialStore();

  Future<NaverCalDavCredentials?> readCredentials();

  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  });

  Future<void> clearCredentials();
}

class NaverCalDavCredentials {
  const NaverCalDavCredentials({
    required this.naverId,
    required this.appPassword,
  });

  final String naverId;
  final String appPassword;
}

class FlutterSecureNaverCalDavCredentialStore
    implements NaverCalDavCredentialStore {
  const FlutterSecureNaverCalDavCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const String _idKey = 'naver_caldav_id';
  static const String _passwordKey = 'naver_caldav_app_password';

  final FlutterSecureStorage _storage;

  @override
  Future<NaverCalDavCredentials?> readCredentials() async {
    final id = await _storage.read(key: _idKey);
    final password = await _storage.read(key: _passwordKey);
    if (id == null ||
        id.trim().isEmpty ||
        password == null ||
        password.trim().isEmpty) {
      return null;
    }
    return NaverCalDavCredentials(
      naverId: id,
      appPassword: password,
    );
  }

  @override
  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  }) async {
    await _storage.write(key: _idKey, value: naverId);
    await _storage.write(key: _passwordKey, value: appPassword);
  }

  @override
  Future<void> clearCredentials() async {
    await _storage.delete(key: _idKey);
    await _storage.delete(key: _passwordKey);
  }
}

class NaverCalDavService {
  NaverCalDavService({
    http.Client? httpClient,
    NaverCalDavCredentialStore credentialStore =
        const FlutterSecureNaverCalDavCredentialStore(),
    EventRepository? eventRepository,
    SupabaseClient? client,
    String? currentUserId,
    Duration timeout = const Duration(seconds: 10),
    Uri? baseUri,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _credentialStore = credentialStore,
        _eventRepositoryOverride = eventRepository,
        _client = client,
        _currentUserId = currentUserId,
        _timeout = timeout,
        _baseUri = baseUri ??
            Uri(
              scheme: 'https',
              host: 'caldav.calendar.naver.com',
            );

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final NaverCalDavCredentialStore _credentialStore;
  final EventRepository? _eventRepositoryOverride;
  final SupabaseClient? _client;
  final String? _currentUserId;
  final Duration _timeout;
  final Uri _baseUri;

  EventRepository get _eventRepository =>
      _eventRepositoryOverride ?? EventRepository.supabase(client: _client);

  Future<void> dispose() async {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  Future<NaverCalDavConnectionResult> testConnection({
    required String naverId,
    required String appPassword,
    bool saveOnSuccess = false,
  }) async {
    final normalizedId = naverId.trim();
    final normalizedPassword = appPassword.trim();
    if (normalizedId.isEmpty || normalizedPassword.isEmpty) {
      return const NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.failed,
        message: '네이버 ID와 앱 비밀번호를 모두 입력해 주세요.',
      );
    }

    final endpoints = _candidateEndpoints(normalizedId);
    NaverCalDavConnectionResult? lastNotFound;

    for (final endpoint in endpoints) {
      final result = await _propfind(
        endpoint: endpoint,
        naverId: normalizedId,
        appPassword: normalizedPassword,
      );

      if (result.isSuccess) {
        if (saveOnSuccess) {
          await _credentialStore.saveCredentials(
            naverId: normalizedId,
            appPassword: normalizedPassword,
          );
        }
        return result;
      }

      if (result.status == NaverCalDavConnectionStatus.notFound) {
        lastNotFound = result;
        continue;
      }

      return result;
    }

    return lastNotFound ??
        const NaverCalDavConnectionResult(
          status: NaverCalDavConnectionStatus.notFound,
          message: '네이버 CalDAV 경로를 찾지 못했습니다. 서버 경로를 추가 확인해야 합니다.',
        );
  }

  Future<void> clearCredentials() {
    return _credentialStore.clearCredentials();
  }

  Future<List<NaverCalDavCalendar>> getCalendars({
    String? naverId,
    String? appPassword,
  }) async {
    final credentials = await _resolveCredentials(
      naverId: naverId,
      appPassword: appPassword,
    );
    final homePaths = await _discoverCalendarHomePaths(credentials);
    debugPrint('Naver CalDAV 캘린더 홈 후보: $homePaths');
    Object? lastError;
    for (final path in homePaths) {
      final endpoint = _baseUri.replace(path: path);
      try {
        final response = await _sendXmlRequest(
          method: 'PROPFIND',
          endpoint: endpoint,
          naverId: credentials.naverId,
          appPassword: credentials.appPassword,
          body: _calendarListPropfindBody,
        );
        if (response.statusCode == 404) {
          lastError = StateError('CalDAV calendar-home not found: $endpoint');
          continue;
        }
        _throwForCalDavStatus(response.statusCode, endpoint);
        final calendars = _parseCalendarsFromResponse(response.body);
        debugPrint('Naver CalDAV 캘린더 목록: $path / ${calendars.length}개');
        if (calendars.isNotEmpty) {
          return calendars;
        }
      } catch (error) {
        lastError = error;
        debugPrint('Naver CalDAV calendar path failed: $path / $error');
      }
    }
    if (lastError != null) {
      throw StateError('네이버 CalDAV 캘린더 경로를 찾지 못했습니다. 서버 경로를 추가 확인해야 합니다.');
    }
    return const <NaverCalDavCalendar>[];
  }

  Future<List<NaverCalDavEvent>> getEvents({
    required String calendarPath,
    DateTime? from,
    DateTime? to,
    String? naverId,
    String? appPassword,
  }) async {
    final credentials = await _resolveCredentials(
      naverId: naverId,
      appPassword: appPassword,
    );
    final now = DateTime.now().toUtc();
    final startAt = (from ?? now.subtract(const Duration(days: 90))).toUtc();
    final endAt = (to ?? now.add(const Duration(days: 180))).toUtc();
    final endpoint = _baseUri.replace(path: calendarPath);
    final rangedEvents = await _queryEvents(
      endpoint: endpoint,
      naverId: credentials.naverId,
      appPassword: credentials.appPassword,
      body: _reportBody(startAt, endAt),
    );
    debugPrint('Naver CalDAV 범위 REPORT: $calendarPath / ${rangedEvents.length}개');
    if (rangedEvents.isNotEmpty) {
      return rangedEvents;
    }

    final fallbackEvents = await _queryEvents(
      endpoint: endpoint,
      naverId: credentials.naverId,
      appPassword: credentials.appPassword,
      body: _reportBody(null, null, includeTimeRange: false),
    );
    debugPrint('Naver CalDAV 전체 REPORT: $calendarPath / ${fallbackEvents.length}개');
    if (fallbackEvents.isNotEmpty) {
      return fallbackEvents;
    }

    final resourceEvents = await _loadEventsFromResources(
      endpoint: endpoint,
      naverId: credentials.naverId,
      appPassword: credentials.appPassword,
    );
    debugPrint('Naver CalDAV 리소스 GET: $calendarPath / ${resourceEvents.length}개');
    return resourceEvents;
  }

  Future<List<NaverCalDavEvent>> _queryEvents({
    required Uri endpoint,
    required String naverId,
    required String appPassword,
    required String body,
  }) async {
    final response = await _sendXmlRequest(
      method: 'REPORT',
      endpoint: endpoint,
      naverId: naverId,
      appPassword: appPassword,
      body: body,
      depth: '1',
    );
    _throwForCalDavStatus(response.statusCode, endpoint);

    final document = XmlDocument.parse(response.body);
    final events = <NaverCalDavEvent>[];
    for (final node in _descendantsByName(document, 'response')) {
      final icsData = _firstDescendantText(node, 'calendar-data');
      if (icsData == null || icsData.trim().isEmpty) {
        continue;
      }
      final parsed = parseIcal(
        icsData,
        etag: _firstDescendantText(node, 'getetag') ?? '',
        href: _firstDescendantText(node, 'href') ?? '',
      );
      if (parsed != null) {
        events.add(parsed);
      }
    }
    return events;
  }

  Future<List<NaverCalDavEvent>> _loadEventsFromResources({
    required Uri endpoint,
    required String naverId,
    required String appPassword,
  }) async {
    final hrefs = await _discoverEventHrefs(
      endpoint: endpoint,
      naverId: naverId,
      appPassword: appPassword,
    );
    if (hrefs.isEmpty) {
      return const <NaverCalDavEvent>[];
    }

    final events = <NaverCalDavEvent>[];
    for (final href in hrefs) {
      final event = await _loadEventFromHref(
        href: href,
        naverId: naverId,
        appPassword: appPassword,
      );
      if (event != null) {
        events.add(event);
      }
    }
    return events;
  }

  Future<List<String>> _discoverEventHrefs({
    required Uri endpoint,
    required String naverId,
    required String appPassword,
  }) async {
    final response = await _sendXmlRequest(
      method: 'PROPFIND',
      endpoint: endpoint,
      naverId: naverId,
      appPassword: appPassword,
      body: _eventListPropfindBody,
      depth: '1',
    );
    _throwForCalDavStatus(response.statusCode, endpoint);

    final document = XmlDocument.parse(response.body);
    final hrefs = <String>{};
    for (final node in _descendantsByName(document, 'response')) {
      final href = _firstDescendantText(node, 'href');
      if (href == null || href.trim().isEmpty) {
        continue;
      }
      final normalizedHref = _normalizeCalDavPath(href) ?? href;
      if (normalizedHref == endpoint.path) {
        continue;
      }

      final resourceTypes = _descendantsByName(node, 'resourcetype')
          .expand((element) => element.descendantElements)
          .map((element) => element.name.local)
          .toSet();
      final contentType =
          _firstDescendantText(node, 'getcontenttype')?.toLowerCase() ?? '';
      final looksLikeCalendarObject = resourceTypes.contains('calendar-object') ||
          resourceTypes.contains('vevent') ||
          contentType.contains('text/calendar') ||
          normalizedHref.toLowerCase().endsWith('.ics');
      if (!looksLikeCalendarObject) {
        continue;
      }

      hrefs.add(normalizedHref);
    }
    debugPrint('Naver CalDAV 이벤트 리소스 후보: ${hrefs.length}');
    return hrefs.toList(growable: false);
  }

  Future<NaverCalDavEvent?> _loadEventFromHref({
    required String href,
    required String naverId,
    required String appPassword,
  }) async {
    try {
      final endpoint = _baseUri.replace(path: href);
      final request = http.Request('GET', endpoint)
        ..headers.addAll(_authHeaders(naverId, appPassword));
      final streamed = await _httpClient.send(request).timeout(_timeout);
      final bytes = await streamed.stream.toBytes();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        debugPrint(
          'Naver CalDAV 이벤트 GET 실패: $href / ${streamed.statusCode}',
        );
        return null;
      }
      final icsData = utf8.decode(bytes, allowMalformed: true);
      final parsed = parseIcal(
        icsData,
        etag: '',
        href: href,
      );
      if (parsed == null) {
        debugPrint('Naver CalDAV 이벤트 파싱 실패: $href');
      }
      return parsed;
    } catch (error) {
      debugPrint('Naver CalDAV 이벤트 로드 실패: $href / $error');
      return null;
    }
  }

  Future<NaverCalDavSyncResult> syncAll({
    String? userId,
    DateTime? from,
    DateTime? to,
  }) async {
    final resolvedUserId = userId ?? _currentUserId ?? _currentSupabaseUserId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return const NaverCalDavSyncResult(
        success: false,
        message: '먼저 PlanFlow에 로그인해 주세요.',
      );
    }

    try {
      final calendars = await getCalendars();
      if (calendars.isEmpty) {
        return const NaverCalDavSyncResult(
          success: false,
          message: '네이버 CalDAV에서 읽을 수 있는 캘린더가 없습니다.',
        );
      }

      final syncedAt = DateTime.now().toUtc();
      var eventCount = 0;
      var savedCount = 0;
      for (final calendar in calendars) {
        final events = await getEvents(
          calendarPath: calendar.path,
          from: from,
          to: to,
        );
        debugPrint(
          'Naver CalDAV 동기화 대상: ${calendar.path} / ${events.length}개',
        );
        eventCount += events.length;
        for (final event in events) {
          await _eventRepository.upsertEventBySourceExternalId(
            event.toEventModel(
              userId: resolvedUserId,
              calendarPath: calendar.path,
              syncedAt: syncedAt,
            ),
          );
          savedCount += 1;
        }
      }

      return NaverCalDavSyncResult(
        success: true,
        message: savedCount > 0
            ? '네이버 CalDAV 일정 $savedCount개를 PlanFlow로 가져왔습니다.'
            : '네이버 CalDAV 연결은 성공했지만 가져올 일정이 없습니다.',
        calendars: calendars.length,
        events: eventCount,
        createdOrUpdated: savedCount,
      );
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV sync failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return NaverCalDavSyncResult(
        success: false,
        message: _syncFailureMessage(error),
        error: error,
      );
    }
  }

  @visibleForTesting
  NaverCalDavEvent? parseIcal(
    String icsData, {
    required String etag,
    required String href,
  }) {
    final fields = _parseIcalFields(icsData);
    final uid = fields['UID']?.firstOrNull?.trim();
    final startRaw = fields['DTSTART']?.firstOrNull;
    if (uid == null || uid.isEmpty || startRaw == null) {
      return null;
    }
    final startAt = _parseIcalDateTime(startRaw);
    if (startAt == null) {
      return null;
    }
    final endAt = _parseIcalDateTime(fields['DTEND']?.firstOrNull);
    return NaverCalDavEvent(
      uid: uid,
      href: href,
      etag: etag,
      icsData: icsData,
      title: _unescapeIcalText(fields['SUMMARY']?.firstOrNull) ?? '',
      startAt: startAt,
      endAt: endAt,
      location: _unescapeIcalText(fields['LOCATION']?.firstOrNull),
      description: _unescapeIcalText(fields['DESCRIPTION']?.firstOrNull),
      lastModifiedAt: _parseIcalDateTime(fields['LAST-MODIFIED']?.firstOrNull),
      isAllDay: startRaw.contains('VALUE=DATE') ||
          RegExp(r':\d{8}$').hasMatch(startRaw.trim()),
    );
  }

  List<Uri> _candidateEndpoints(String naverId) {
    final encodedId = Uri.encodeComponent(naverId);
    return <Uri>[
      _baseUri.replace(path: '/'),
      _baseUri.replace(path: '/calendars/$encodedId/'),
    ];
  }

  Future<NaverCalDavConnectionResult> _propfind({
    required Uri endpoint,
    required String naverId,
    required String appPassword,
  }) async {
    try {
      final request = http.Request('PROPFIND', endpoint)
        ..headers.addAll(_authHeaders(naverId, appPassword))
        ..body = _propfindBody;

      final streamed = await _httpClient.send(request).timeout(_timeout);
      await streamed.stream.drain<void>();

      return _resultForStatusCode(
        streamed.statusCode,
        endpoint: endpoint,
      );
    } on TimeoutException catch (error) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.networkError,
        message: '네이버 CalDAV 서버 연결 시간이 초과되었습니다. 네트워크 상태를 확인해 주세요.',
        endpoint: endpoint,
        error: error,
      );
    } on SocketException catch (error) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.networkError,
        message: '네이버 CalDAV 서버에 연결하지 못했습니다. 네트워크 상태를 확인해 주세요.',
        endpoint: endpoint,
        error: error,
      );
    } on http.ClientException catch (error) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.networkError,
        message: '네이버 CalDAV 요청을 보내지 못했습니다. 네트워크 상태를 확인해 주세요.',
        endpoint: endpoint,
        error: error,
      );
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV test failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.failed,
        message: '네이버 CalDAV 연결 테스트 중 알 수 없는 오류가 발생했습니다.',
        endpoint: endpoint,
        error: error,
      );
    }
  }

  Future<NaverCalDavCredentials> _resolveCredentials({
    String? naverId,
    String? appPassword,
  }) async {
    final directId = naverId?.trim();
    final directPassword = appPassword?.trim();
    if (directId != null &&
        directId.isNotEmpty &&
        directPassword != null &&
        directPassword.isNotEmpty) {
      return NaverCalDavCredentials(
        naverId: directId,
        appPassword: directPassword,
      );
    }

    final stored = await _credentialStore.readCredentials();
    if (stored == null) {
      throw StateError('네이버 CalDAV 연결 정보가 없습니다. 먼저 연결 테스트를 완료해 주세요.');
    }
    return stored;
  }

  Future<List<String>> _discoverCalendarHomePaths(
    NaverCalDavCredentials credentials,
  ) async {
    final paths = <String>{};
    void addPath(String? rawPath) {
      final normalized = _normalizeCalDavPath(rawPath);
      if (normalized != null) {
        paths.add(normalized);
      }
    }

    try {
      final root = await _sendXmlRequest(
        method: 'PROPFIND',
        endpoint: _baseUri.replace(path: '/'),
        naverId: credentials.naverId,
        appPassword: credentials.appPassword,
        body: _discoveryPropfindBody,
        depth: '0',
      );
      if (root.statusCode >= 200 && root.statusCode < 300) {
        final document = XmlDocument.parse(root.body);
        final rootCalendarHome =
            _firstNestedHrefText(document, 'calendar-home-set');
        addPath(rootCalendarHome);
        final principalPath =
            _firstNestedHrefText(document, 'current-user-principal');
        if (principalPath != null) {
          addPath(await _discoverCalendarHomeFromPrincipal(
            credentials,
            principalPath,
          ));
        }
      }
    } catch (error) {
      debugPrint('Naver CalDAV root discovery failed: $error');
    }

    addPath('/calendars/${Uri.encodeComponent(credentials.naverId)}/');
    return paths.toList(growable: false);
  }

  Future<String?> _discoverCalendarHomeFromPrincipal(
    NaverCalDavCredentials credentials,
    String principalPath,
  ) async {
    final normalizedPrincipal = _normalizeCalDavPath(principalPath);
    if (normalizedPrincipal == null) {
      return null;
    }
    final endpoint = _baseUri.replace(path: normalizedPrincipal);
    final response = await _sendXmlRequest(
      method: 'PROPFIND',
      endpoint: endpoint,
      naverId: credentials.naverId,
      appPassword: credentials.appPassword,
      body: _calendarHomePropfindBody,
      depth: '0',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final document = XmlDocument.parse(response.body);
    return _firstNestedHrefText(document, 'calendar-home-set');
  }

  List<NaverCalDavCalendar> _parseCalendarsFromResponse(String body) {
    final document = XmlDocument.parse(body);
    final calendars = <NaverCalDavCalendar>[];
    for (final node in _descendantsByName(document, 'response')) {
      final href = _firstDescendantText(node, 'href');
      if (href == null || href.trim().isEmpty) {
        continue;
      }
      final resourceTypes = _descendantsByName(node, 'resourcetype')
          .expand((element) => element.descendantElements)
          .map((element) => element.name.local)
          .toSet();
      if (!resourceTypes.contains('calendar')) {
        continue;
      }
      final displayName = _firstDescendantText(node, 'displayname') ??
          Uri.decodeComponent(
            href.split('/').where((part) => part.isNotEmpty).lastOrNull ?? href,
          );
      calendars.add(
        NaverCalDavCalendar(
          path: _normalizeCalDavPath(href) ?? href,
          displayName: displayName,
          ctag: _firstDescendantText(node, 'getctag'),
        ),
      );
    }
    return calendars;
  }

  String? _normalizeCalDavPath(String? rawPath) {
    final text = rawPath?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    final parsed = Uri.tryParse(text);
    final path = parsed != null && parsed.hasScheme ? parsed.path : text;
    final withLeadingSlash = path.startsWith('/') ? path : '/$path';
    return withLeadingSlash.endsWith('/')
        ? withLeadingSlash
        : '$withLeadingSlash/';
  }

  Future<_NaverCalDavHttpResponse> _sendXmlRequest({
    required String method,
    required Uri endpoint,
    required String naverId,
    required String appPassword,
    required String body,
    String depth = '1',
  }) async {
    final request = http.Request(method, endpoint)
      ..headers.addAll(
        _authHeaders(naverId, appPassword)..['Depth'] = depth,
      )
      ..body = body;
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final bytes = await streamed.stream.toBytes();
    return _NaverCalDavHttpResponse(
      statusCode: streamed.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
    );
  }

  void _throwForCalDavStatus(int statusCode, Uri endpoint) {
    if (statusCode >= 200 && statusCode < 300) {
      return;
    }
    if (statusCode == 401) {
      throw StateError('네이버 ID 또는 앱 비밀번호를 확인해 주세요.');
    }
    if (statusCode == 403) {
      throw StateError('네이버 CalDAV 접근이 거부되었습니다.');
    }
    if (statusCode == 404) {
      throw StateError('네이버 CalDAV 경로를 찾지 못했습니다: $endpoint');
    }
    throw StateError('네이버 CalDAV 응답 코드가 올바르지 않습니다: $statusCode');
  }

  Map<String, String> _authHeaders(String naverId, String appPassword) {
    final encoded = base64Encode(utf8.encode('$naverId:$appPassword'));
    return <String, String>{
      HttpHeaders.authorizationHeader: 'Basic $encoded',
      HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
      'Depth': '1',
    };
  }

  String? _currentSupabaseUserId() {
    try {
      final auth = _client?.auth ?? Supabase.instance.client.auth;
      return auth.currentSession?.user.id ?? auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Iterable<XmlElement> _descendantsByName(XmlNode node, String localName) {
    return node.descendantElements.where(
      (element) => element.name.local == localName,
    );
  }

  String? _firstDescendantText(XmlNode node, String localName) {
    final text = _descendantsByName(node, localName).firstOrNull?.innerText;
    final normalized = text?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  String? _firstNestedHrefText(XmlNode node, String localName) {
    final container = _descendantsByName(node, localName).firstOrNull;
    if (container == null) {
      return null;
    }
    return _firstDescendantText(container, 'href') ??
        _firstDescendantText(container, localName);
  }

  String _reportBody(
    DateTime? from,
    DateTime? to, {
    bool includeTimeRange = true,
  }) {
    final start = from == null ? null : _formatCalDavUtc(from);
    final end = to == null ? null : _formatCalDavUtc(to);
    final timeRange = includeTimeRange && start != null && end != null
        ? '        <c:time-range start="$start" end="$end"/>\n'
        : '';
    return '''
<?xml version="1.0" encoding="utf-8" ?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag />
    <c:calendar-data />
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
$timeRange      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>
''';
  }

  static const String _eventListPropfindBody = '''
<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag />
    <d:resourcetype />
    <d:getcontenttype />
    <d:displayname />
  </d:prop>
</d:propfind>
''';

  String _formatCalDavUtc(DateTime value) {
    final utc = value.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}Z';
  }

  Map<String, List<String>> _parseIcalFields(String icsData) {
    final unfolded = <String>[];
    for (final rawLine in icsData.replaceAll('\r\n', '\n').split('\n')) {
      if (rawLine.startsWith(' ') || rawLine.startsWith('\t')) {
        if (unfolded.isNotEmpty) {
          unfolded[unfolded.length - 1] += rawLine.substring(1);
        }
      } else {
        unfolded.add(rawLine);
      }
    }

    final fields = <String, List<String>>{};
    for (final line in unfolded) {
      final separator = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      final key = line.substring(0, separator).split(';').first.toUpperCase();
      final value = line.substring(separator + 1);
      fields.putIfAbsent(key, () => <String>[]).add(line.contains(';')
          ? '${line.substring(0, separator)}:$value'
          : value);
    }
    return fields;
  }

  DateTime? _parseIcalDateTime(String? rawValue) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return null;
    }
    final trimmed = rawValue.trim();
    final separator = trimmed.indexOf(':');
    final params = separator >= 0 ? trimmed.substring(0, separator) : '';
    final value = separator >= 0 ? trimmed.substring(separator + 1) : trimmed;
    if (RegExp(r'^\d{8}$').hasMatch(value)) {
      return DateTime.utc(
        int.parse(value.substring(0, 4)),
        int.parse(value.substring(4, 6)),
        int.parse(value.substring(6, 8)),
      );
    }
    final match = RegExp(r'^(\d{8})T(\d{6})(Z?)$').firstMatch(value);
    if (match == null) {
      return null;
    }
    final date = match.group(1)!;
    final time = match.group(2)!;
    final localLike = DateTime(
      int.parse(date.substring(0, 4)),
      int.parse(date.substring(4, 6)),
      int.parse(date.substring(6, 8)),
      int.parse(time.substring(0, 2)),
      int.parse(time.substring(2, 4)),
      int.parse(time.substring(4, 6)),
    );
    if (match.group(3) == 'Z') {
      return DateTime.utc(
        localLike.year,
        localLike.month,
        localLike.day,
        localLike.hour,
        localLike.minute,
        localLike.second,
      );
    }
    if (params.toUpperCase().contains('TZID=ASIA/SEOUL')) {
      return DateTime.utc(
        localLike.year,
        localLike.month,
        localLike.day,
        localLike.hour - 9,
        localLike.minute,
        localLike.second,
      );
    }
    return localLike.toUtc();
  }

  String? _unescapeIcalText(String? value) {
    if (value == null) {
      return null;
    }
    final separator = value.indexOf(':');
    final raw = separator >= 0 && value.substring(0, separator).contains(';')
        ? value.substring(separator + 1)
        : value;
    return raw
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\,', ',')
        .replaceAll(r'\;', ';')
        .replaceAll(r'\\', r'\');
  }

  String _syncFailureMessage(Object error) {
    final text = error.toString();
    if (text.contains('앱 비밀번호') || text.contains('ID')) {
      return '네이버 CalDAV 인증에 실패했습니다. ID와 앱 비밀번호를 확인해 주세요.';
    }
    if (text.contains('접근이 거부')) {
      return '네이버 CalDAV 접근이 거부되었습니다. 네이버 정책 또는 계정 보안 설정을 확인해 주세요.';
    }
    if (text.contains('경로')) {
      return '네이버 CalDAV 경로를 찾지 못했습니다. 서버 경로를 추가 확인해야 합니다.';
    }
    return '네이버 CalDAV 일정 가져오기에 실패했습니다. 네트워크와 계정 설정을 확인해 주세요.';
  }

  NaverCalDavConnectionResult _resultForStatusCode(
    int statusCode, {
    required Uri endpoint,
  }) {
    if (statusCode >= 200 && statusCode < 300) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.success,
        statusCode: statusCode,
        endpoint: endpoint,
        message: '네이버 CalDAV 연결 테스트에 성공했습니다. 이 기기에서 직접 일정 가져오기를 시도할 수 있습니다.',
      );
    }
    if (statusCode == 401) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.unauthorized,
        statusCode: statusCode,
        endpoint: endpoint,
        message: '네이버 ID 또는 앱 비밀번호를 확인해 주세요.',
      );
    }
    if (statusCode == 403) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.forbidden,
        statusCode: statusCode,
        endpoint: endpoint,
        message: '네이버 CalDAV 접근이 거부되었습니다. Android 직접 접근이 정책상 막혔을 수 있습니다.',
      );
    }
    if (statusCode == 404) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.notFound,
        statusCode: statusCode,
        endpoint: endpoint,
        message: '네이버 CalDAV 경로를 찾지 못했습니다. 다른 경로를 확인합니다.',
      );
    }
    if (statusCode >= 500) {
      return NaverCalDavConnectionResult(
        status: NaverCalDavConnectionStatus.serverError,
        statusCode: statusCode,
        endpoint: endpoint,
        message: '네이버 CalDAV 서버 응답이 불안정합니다. 잠시 후 다시 시도해 주세요.',
      );
    }
    return NaverCalDavConnectionResult(
      status: NaverCalDavConnectionStatus.failed,
      statusCode: statusCode,
      endpoint: endpoint,
      message: '네이버 CalDAV 연결 테스트에 실패했습니다. 응답 코드: $statusCode',
    );
  }

  static const String _propfindBody = '''
<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">
  <d:prop>
    <d:displayname />
    <cs:getctag />
    <d:resourcetype />
  </d:prop>
</d:propfind>
''';

  static const String _discoveryPropfindBody = '''
<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:current-user-principal />
    <c:calendar-home-set />
  </d:prop>
</d:propfind>
''';

  static const String _calendarHomePropfindBody = '''
<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <c:calendar-home-set />
  </d:prop>
</d:propfind>
''';

  static const String _calendarListPropfindBody = '''
<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">
  <d:prop>
    <d:displayname />
    <cs:getctag />
    <d:resourcetype />
  </d:prop>
</d:propfind>
''';
}

String? _blankToNull(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

extension _IterableFirstLastOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }

  T? get lastOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    var current = iterator.current;
    while (iterator.moveNext()) {
      current = iterator.current;
    }
    return current;
  }
}

class _NaverCalDavHttpResponse {
  const _NaverCalDavHttpResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}
