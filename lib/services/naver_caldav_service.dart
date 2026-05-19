import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:xml/xml.dart';

import '../core/env.dart';
import '../core/local_time.dart';
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

enum NaverCalDavSyncMode {
  quick,
  custom,
  all,
}

enum NaverCalDavSyncStage {
  preparing,
  calendars,
  querying,
  saving,
  completed,
}

class NaverCalDavSyncProgress {
  const NaverCalDavSyncProgress({
    required this.mode,
    required this.stage,
    required this.message,
    this.currentCalendar,
    this.currentCalendarIndex = 0,
    this.totalCalendars = 0,
    this.processedEvents = 0,
    this.totalEvents = 0,
    this.savedEvents = 0,
    this.skippedEvents = 0,
    this.failedEvents = 0,
  });

  final NaverCalDavSyncMode mode;
  final NaverCalDavSyncStage stage;
  final String message;
  final String? currentCalendar;
  final int currentCalendarIndex;
  final int totalCalendars;
  final int processedEvents;
  final int totalEvents;
  final int savedEvents;
  final int skippedEvents;
  final int failedEvents;
}

typedef NaverCalDavProgressCallback = void Function(
  NaverCalDavSyncProgress progress,
);

class NaverCalDavDebugSample {
  const NaverCalDavDebugSample({
    required this.calendarPath,
    required this.href,
    required this.uid,
    required this.title,
    required this.rawStart,
    required this.rawEnd,
    required this.startAt,
    this.endAt,
    this.etag,
  });

  final String calendarPath;
  final String href;
  final String uid;
  final String title;
  final String rawStart;
  final String? rawEnd;
  final DateTime startAt;
  final DateTime? endAt;
  final String? etag;

  String toSafeLogLine() {
    return 'calendar="$calendarPath", href="$href", uid="$uid", '
        'title="$title", rawStart="$rawStart", rawEnd="${rawEnd ?? ''}", '
        'startAt=${startAt.toIso8601String()}, '
        'endAt=${endAt?.toIso8601String() ?? ''}, etag="${etag ?? ''}"';
  }
}

class NaverCalDavInvalidSample {
  const NaverCalDavInvalidSample({
    required this.calendarPath,
    required this.href,
    required this.reason,
    this.title,
    this.uid,
    this.rawStart,
    this.rawEnd,
    this.component,
  });

  final String calendarPath;
  final String href;
  final String reason;
  final String? title;
  final String? uid;
  final String? rawStart;
  final String? rawEnd;
  final String? component;

  String toSafeLogLine() {
    return 'calendar="$calendarPath", href="$href", component="${component ?? ''}", '
        'reason="$reason", uid="${uid ?? ''}", title="${title ?? ''}", '
        'rawStart="${rawStart ?? ''}", rawEnd="${rawEnd ?? ''}"';
  }
}

class NaverCalDavSyncDiagnostics {
  const NaverCalDavSyncDiagnostics({
    this.rawEvents = 0,
    this.parsedEvents = 0,
    this.invalidEvents = 0,
    this.saveCandidates = 0,
    this.duplicateSkipped = 0,
    this.unchangedSkipped = 0,
    this.saved = 0,
    this.failed = 0,
    this.skipReasons = const <String, int>{},
    this.samples = const <NaverCalDavDebugSample>[],
    this.invalidSamples = const <NaverCalDavInvalidSample>[],
  });

  final int rawEvents;
  final int parsedEvents;
  final int invalidEvents;
  final int saveCandidates;
  final int duplicateSkipped;
  final int unchangedSkipped;
  final int saved;
  final int failed;
  final Map<String, int> skipReasons;
  final List<NaverCalDavDebugSample> samples;
  final List<NaverCalDavInvalidSample> invalidSamples;

  String toSummaryMessage() {
    final reasonText = skipReasons.entries
        .map((entry) => '${entry.key} ${entry.value}개')
        .join(' · ');
    return '읽음 $rawEvents개 · 파싱 성공 $parsedEvents개 · '
        '파싱 실패 $invalidEvents개 · 저장 대상 $saveCandidates개 · '
        '저장 $saved개 · 중복 스킵 $duplicateSkipped개 · '
        '변경 없음 $unchangedSkipped개 · 실패 $failed개'
        '${reasonText.isEmpty ? '' : ' ($reasonText)'}';
  }
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
      externalId: 'naver-caldav:${_stableExternalKey(calendarPath, uid)}',
      externalCalendarId: 'naver-caldav:$calendarPath',
      externalEtag: _blankToNull(etag),
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
    this.skipped = 0,
    this.failed = 0,
    this.calendars = 0,
    this.events = 0,
    this.mode = NaverCalDavSyncMode.custom,
    this.from,
    this.to,
    this.error,
    this.diagnostics = const NaverCalDavSyncDiagnostics(),
  });

  final bool success;
  final String message;
  final int createdOrUpdated;
  final int skipped;
  final int failed;
  final int calendars;
  final int events;
  final NaverCalDavSyncMode mode;
  final DateTime? from;
  final DateTime? to;
  final Object? error;
  final NaverCalDavSyncDiagnostics diagnostics;
}

class _NaverCalDavMutableDiagnostics {
  int rawEvents = 0;
  int parsedEvents = 0;
  int invalidEvents = 0;
  int saveCandidates = 0;
  int duplicateSkipped = 0;
  int unchangedSkipped = 0;
  int saved = 0;
  int failed = 0;
  final Map<String, int> skipReasons = <String, int>{};
  final List<NaverCalDavDebugSample> samples = <NaverCalDavDebugSample>[];
  final List<NaverCalDavInvalidSample> invalidSamples =
      <NaverCalDavInvalidSample>[];

  void addSkipReason(String reason) {
    skipReasons.update(reason, (count) => count + 1, ifAbsent: () => 1);
  }

  void addSample(NaverCalDavDebugSample sample) {
    if (samples.length >= 5) {
      return;
    }
    samples.add(sample);
  }

  void addInvalidSample(NaverCalDavInvalidSample sample) {
    if (invalidSamples.length >= 5) {
      return;
    }
    invalidSamples.add(sample);
  }

  NaverCalDavSyncDiagnostics freeze() {
    return NaverCalDavSyncDiagnostics(
      rawEvents: rawEvents,
      parsedEvents: parsedEvents,
      invalidEvents: invalidEvents,
      saveCandidates: saveCandidates,
      duplicateSkipped: duplicateSkipped,
      unchangedSkipped: unchangedSkipped,
      saved: saved,
      failed: failed,
      skipReasons: Map<String, int>.unmodifiable(skipReasons),
      samples: List<NaverCalDavDebugSample>.unmodifiable(samples),
      invalidSamples:
          List<NaverCalDavInvalidSample>.unmodifiable(invalidSamples),
    );
  }
}

class NaverCalDavParseStats {
  NaverCalDavParseStats._({
    required this.calendarPath,
    required _NaverCalDavMutableDiagnostics diagnostics,
    required this.from,
    required this.to,
  }) : _diagnostics = diagnostics;

  final String calendarPath;
  final DateTime? from;
  final DateTime? to;
  final _NaverCalDavMutableDiagnostics _diagnostics;

  bool shouldKeepSample(NaverCalDavEvent event) {
    final startBoundary = from;
    final endBoundary = to;
    if (startBoundary == null || endBoundary == null) {
      return true;
    }
    final eventStart = event.startAt.toUtc();
    final eventEnd = event.endAt?.toUtc() ?? eventStart;
    if (eventEnd == eventStart) {
      return !eventStart.isBefore(startBoundary) &&
          eventStart.isBefore(endBoundary);
    }
    return eventEnd.isAfter(startBoundary) && eventStart.isBefore(endBoundary);
  }
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

class LocalNaverCalDavCredentialStore implements NaverCalDavCredentialStore {
  const LocalNaverCalDavCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
        resetOnError: false,
      ),
    ),
    String? Function()? currentUserId,
    bool requireUserScopedKey = false,
  })  : _storage = storage,
        _currentUserId = currentUserId,
        _requireUserScopedKey = requireUserScopedKey;

  static const String _idKey = 'naver_caldav_id';
  static const String _passwordKey = 'naver_caldav_app_password';

  final FlutterSecureStorage _storage;
  final String? Function()? _currentUserId;
  final bool _requireUserScopedKey;

  @override
  Future<NaverCalDavCredentials?> readCredentials() async {
    final idKey = _scopedKey(_idKey);
    final passwordKey = _scopedKey(_passwordKey);
    if (idKey == null || passwordKey == null) {
      return null;
    }

    final id = await _storage.read(key: idKey);
    final password = await _storage.read(key: passwordKey);
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
    final idKey = _scopedKey(_idKey);
    final passwordKey = _scopedKey(_passwordKey);
    if (idKey == null || passwordKey == null) {
      return;
    }

    await _storage.write(key: idKey, value: naverId);
    await _storage.write(key: passwordKey, value: appPassword);
  }

  @override
  Future<void> clearCredentials() async {
    final idKey = _scopedKey(_idKey);
    final passwordKey = _scopedKey(_passwordKey);
    if (idKey == null || passwordKey == null) {
      return;
    }

    await _storage.delete(key: idKey);
    await _storage.delete(key: passwordKey);
  }

  String? _scopedKey(String key) {
    final rawUserId = _currentUserId?.call()?.trim();
    if (rawUserId == null || rawUserId.isEmpty) {
      return _requireUserScopedKey ? null : key;
    }
    return '$key:$rawUserId';
  }
}

class SupabaseNaverCalDavCredentialStore implements NaverCalDavCredentialStore {
  const SupabaseNaverCalDavCredentialStore({SupabaseClient? client})
      : _client = client;

  final SupabaseClient? _client;

  SupabaseClient? get _resolvedClient {
    final client = _client;
    if (client != null) {
      return client;
    }
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    return Supabase.instance.client;
  }

  @override
  Future<NaverCalDavCredentials?> readCredentials() async {
    final client = _resolvedClient;
    if (client == null || client.auth.currentUser == null) {
      return null;
    }

    try {
      final response = await client.rpc('fetch_naver_caldav_credentials');
      final rows = _asRows(response);
      if (rows.isEmpty) {
        return null;
      }
      final row = rows.first;
      final id = row['naver_caldav_id']?.toString().trim() ?? '';
      final password =
          row['naver_caldav_app_password']?.toString().trim() ?? '';
      if (id.isEmpty || password.isEmpty) {
        return null;
      }
      return NaverCalDavCredentials(naverId: id, appPassword: password);
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV remote credential read failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  @override
  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  }) async {
    final client = _resolvedClient;
    if (client == null || client.auth.currentUser == null) {
      return;
    }

    try {
      await client.rpc(
        'upsert_naver_caldav_credentials',
        params: <String, dynamic>{
          'naver_caldav_id': naverId,
          'naver_caldav_app_password': appPassword,
        },
      );
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV remote credential save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Future<void> clearCredentials() async {
    final client = _resolvedClient;
    if (client == null || client.auth.currentUser == null) {
      return;
    }

    try {
      await client.rpc('clear_naver_caldav_credentials');
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV remote credential clear failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  List<Map<String, dynamic>> _asRows(Object? value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    }
    if (value is Map) {
      return <Map<String, dynamic>>[Map<String, dynamic>.from(value)];
    }
    return const <Map<String, dynamic>>[];
  }
}

class CompositeNaverCalDavCredentialStore
    implements NaverCalDavCredentialStore {
  const CompositeNaverCalDavCredentialStore({
    required this.remoteStore,
    required this.localStore,
  });

  final NaverCalDavCredentialStore remoteStore;
  final NaverCalDavCredentialStore localStore;

  @override
  Future<NaverCalDavCredentials?> readCredentials() async {
    final remote = await remoteStore.readCredentials();
    if (remote != null) {
      await localStore.saveCredentials(
        naverId: remote.naverId,
        appPassword: remote.appPassword,
      );
      return remote;
    }

    final local = await localStore.readCredentials();
    if (local == null) {
      return null;
    }

    await remoteStore.saveCredentials(
      naverId: local.naverId,
      appPassword: local.appPassword,
    );
    return local;
  }

  @override
  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  }) async {
    await remoteStore.saveCredentials(
      naverId: naverId,
      appPassword: appPassword,
    );
    await localStore.saveCredentials(
      naverId: naverId,
      appPassword: appPassword,
    );
  }

  @override
  Future<void> clearCredentials() async {
    await Future.wait(<Future<void>>[
      remoteStore.clearCredentials(),
      localStore.clearCredentials(),
    ]);
  }
}

class NaverCalDavService {
  NaverCalDavService({
    http.Client? httpClient,
    NaverCalDavCredentialStore? credentialStore,
    EventRepository? eventRepository,
    SupabaseClient? client,
    String? currentUserId,
    Duration timeout = const Duration(seconds: 10),
    Uri? baseUri,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _credentialStore = credentialStore ?? _defaultCredentialStore(client),
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

  static NaverCalDavCredentialStore _defaultCredentialStore(
    SupabaseClient? client,
  ) {
    final resolvedClient =
        client ?? (AppEnv.isSupabaseReady ? Supabase.instance.client : null);
    final localStore = LocalNaverCalDavCredentialStore(
      currentUserId: () => resolvedClient?.auth.currentUser?.id,
      requireUserScopedKey: resolvedClient != null,
    );
    if (!AppEnv.isSupabaseReady && client == null) {
      return localStore;
    }
    return CompositeNaverCalDavCredentialStore(
      remoteStore: SupabaseNaverCalDavCredentialStore(client: resolvedClient),
      localStore: localStore,
    );
  }

  Future<void> dispose() async {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  Future<bool> hasCredentials() async {
    final credentials = await _credentialStore.readCredentials();
    return credentials != null;
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
        for (final calendar in calendars) {
          debugPrint(
            'Naver CalDAV 캘린더: name="${calendar.displayName}", '
            'path="${calendar.path}", ctag="${calendar.ctag ?? ''}"',
          );
        }
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
    bool allowFullFallback = true,
    bool allowResourceFallback = true,
    NaverCalDavParseStats? parseStats,
  }) async {
    final credentials = await _resolveCredentials(
      naverId: naverId,
      appPassword: appPassword,
    );
    final now = DateTime.now().toUtc();
    final startAt = (from ?? now.subtract(const Duration(days: 90))).toUtc();
    final endAt = (to ?? now.add(const Duration(days: 180))).toUtc();
    final endpoint = _baseUri.replace(path: calendarPath);
    debugPrint(
      'Naver CalDAV 일정 조회 시작: path=$calendarPath, url=$endpoint, '
      'utc=${_formatCalDavUtc(startAt)}~${_formatCalDavUtc(endAt)}, '
      'kst=${planflowLocal(startAt)}~${planflowLocal(endAt)}',
    );
    final rangedEvents = await _queryEvents(
      endpoint: endpoint,
      naverId: credentials.naverId,
      appPassword: credentials.appPassword,
      body: _reportBody(startAt, endAt),
      parseStats: parseStats,
    );
    debugPrint(
        'Naver CalDAV 범위 REPORT: $calendarPath / ${rangedEvents.length}개');
    final filteredRangedEvents =
        _filterEventsByRange(rangedEvents, startAt, endAt);
    if (filteredRangedEvents.isNotEmpty &&
        filteredRangedEvents.length == rangedEvents.length) {
      return filteredRangedEvents;
    }
    if (!allowFullFallback) {
      return filteredRangedEvents;
    }

    final fallbackEvents = await _queryEvents(
      endpoint: endpoint,
      naverId: credentials.naverId,
      appPassword: credentials.appPassword,
      body: _reportBody(null, null, includeTimeRange: false),
      parseStats: parseStats,
    );
    final filteredFallbackEvents =
        _filterEventsByRange(fallbackEvents, startAt, endAt);
    debugPrint(
      'Naver CalDAV 전체 REPORT: $calendarPath / '
      '${fallbackEvents.length}개, 범위 내 ${filteredFallbackEvents.length}개',
    );
    final mergedFallbackEvents = _mergeEventsByIdentity(
      filteredRangedEvents,
      filteredFallbackEvents,
    );
    if (mergedFallbackEvents.isNotEmpty) {
      return mergedFallbackEvents;
    }
    if (!allowResourceFallback) {
      return const <NaverCalDavEvent>[];
    }

    final resourceEvents = await _loadEventsFromResources(
      endpoint: endpoint,
      naverId: credentials.naverId,
      appPassword: credentials.appPassword,
      parseStats: parseStats,
    );
    final filteredResourceEvents =
        _filterEventsByRange(resourceEvents, startAt, endAt);
    debugPrint(
      'Naver CalDAV 리소스 GET: $calendarPath / '
      '${resourceEvents.length}개, 범위 내 ${filteredResourceEvents.length}개',
    );
    return _mergeEventsByIdentity(filteredRangedEvents, filteredResourceEvents);
  }

  Future<List<NaverCalDavEvent>> _queryEvents({
    required Uri endpoint,
    required String naverId,
    required String appPassword,
    required String body,
    NaverCalDavParseStats? parseStats,
  }) async {
    final response = await _sendXmlRequest(
      method: 'REPORT',
      endpoint: endpoint,
      naverId: naverId,
      appPassword: appPassword,
      body: body,
      depth: '1',
    );
    debugPrint('Naver CalDAV REPORT 응답: $endpoint / ${response.statusCode}');
    _throwForCalDavStatus(response.statusCode, endpoint);

    final document = XmlDocument.parse(response.body);
    final events = <NaverCalDavEvent>[];
    for (final node in _descendantsByName(document, 'response')) {
      final icsData = _firstDescendantText(node, 'calendar-data');
      if (icsData == null || icsData.trim().isEmpty) {
        continue;
      }
      parseStats?._diagnostics.rawEvents += 1;
      final parsed = parseIcal(
        icsData,
        etag: _firstDescendantText(node, 'getetag') ?? '',
        href: _firstDescendantText(node, 'href') ?? '',
      );
      if (parsed != null) {
        parseStats?._diagnostics.parsedEvents += 1;
        final sample = _buildDebugSample(
          parsed,
          calendarPath: parseStats?.calendarPath ?? endpoint.path,
        );
        if (sample != null && parseStats?.shouldKeepSample(parsed) != false) {
          parseStats?._diagnostics.addSample(sample);
        }
        events.add(parsed);
      } else {
        parseStats?._diagnostics.invalidEvents += 1;
        final invalidSample = _buildInvalidDebugSample(
          icsData,
          href: _firstDescendantText(node, 'href') ?? '',
          calendarPath: parseStats?.calendarPath ?? endpoint.path,
        );
        if (invalidSample != null) {
          parseStats?._diagnostics.addInvalidSample(invalidSample);
          debugPrint(
            'Naver CalDAV parse invalid sample: '
            '${invalidSample.toSafeLogLine()}',
          );
        }
      }
    }
    return events;
  }

  List<NaverCalDavEvent> _filterEventsByRange(
    List<NaverCalDavEvent> events,
    DateTime startAt,
    DateTime endAt,
  ) {
    return events.where((event) {
      final eventStart = event.startAt.toUtc();
      final eventEnd = event.endAt?.toUtc() ?? eventStart;
      if (eventEnd == eventStart) {
        return !eventStart.isBefore(startAt) && eventStart.isBefore(endAt);
      }
      return eventEnd.isAfter(startAt) && eventStart.isBefore(endAt);
    }).toList(growable: false);
  }

  List<NaverCalDavEvent> _mergeEventsByIdentity(
    List<NaverCalDavEvent> first,
    List<NaverCalDavEvent> second,
  ) {
    if (first.isEmpty) {
      return second;
    }
    if (second.isEmpty) {
      return first;
    }
    final seen = <String>{};
    final merged = <NaverCalDavEvent>[];
    for (final event in <NaverCalDavEvent>[...first, ...second]) {
      final key = '${event.href}::${event.uid}';
      if (seen.add(key)) {
        merged.add(event);
      }
    }
    return merged;
  }

  bool _isEventInsideOptionalRange(
    NaverCalDavEvent event,
    DateTime? startAt,
    DateTime? endAt,
  ) {
    if (startAt == null || endAt == null) {
      return true;
    }
    return _filterEventsByRange(<NaverCalDavEvent>[event], startAt, endAt)
        .isNotEmpty;
  }

  Future<List<NaverCalDavEvent>> _loadEventsFromResources({
    required Uri endpoint,
    required String naverId,
    required String appPassword,
    NaverCalDavParseStats? parseStats,
  }) async {
    final hrefs = await _discoverEventHrefs(
      endpoint: endpoint,
      naverId: naverId,
      appPassword: appPassword,
    );
    if (hrefs.isEmpty) {
      return const <NaverCalDavEvent>[];
    }

    debugPrint('Naver CalDAV 리소스 GET 시작: ${hrefs.length}개');
    final events = <NaverCalDavEvent>[];
    const batchSize = 8;
    for (var index = 0; index < hrefs.length; index += batchSize) {
      final chunk = hrefs.skip(index).take(batchSize);
      final loaded = await Future.wait(
        chunk.map(
          (href) => _loadEventFromHref(
            href: href,
            naverId: naverId,
            appPassword: appPassword,
            parseStats: parseStats,
          ),
        ),
      );
      events.addAll(loaded.whereType<NaverCalDavEvent>());
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
      final normalizedHref = _normalizeCalDavResourcePath(href) ?? href;
      if (normalizedHref == endpoint.path) {
        continue;
      }

      final resourceTypes = _descendantsByName(node, 'resourcetype')
          .expand((element) => element.descendantElements)
          .map((element) => element.name.local)
          .toSet();
      final contentType =
          _firstDescendantText(node, 'getcontenttype')?.toLowerCase() ?? '';
      final looksLikeCalendarObject =
          resourceTypes.contains('calendar-object') ||
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
    NaverCalDavParseStats? parseStats,
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
      parseStats?._diagnostics.rawEvents += 1;
      final parsed = parseIcal(
        icsData,
        etag: '',
        href: href,
      );
      if (parsed == null) {
        parseStats?._diagnostics.invalidEvents += 1;
        final invalidSample = _buildInvalidDebugSample(
          icsData,
          href: href,
          calendarPath: parseStats?.calendarPath ?? endpoint.path,
        );
        if (invalidSample != null) {
          parseStats?._diagnostics.addInvalidSample(invalidSample);
          debugPrint(
            'Naver CalDAV 이벤트 파싱 실패: '
            '${invalidSample.toSafeLogLine()}',
          );
        } else {
          debugPrint('Naver CalDAV 이벤트 파싱 실패: $href');
        }
      } else {
        parseStats?._diagnostics.parsedEvents += 1;
        final sample = _buildDebugSample(
          parsed,
          calendarPath: parseStats?.calendarPath ?? endpoint.path,
        );
        if (sample != null && parseStats?.shouldKeepSample(parsed) != false) {
          parseStats?._diagnostics.addSample(sample);
        }
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
    NaverCalDavSyncMode mode = NaverCalDavSyncMode.custom,
    bool skipUnchanged = true,
    bool diagnosticImport = false,
    NaverCalDavProgressCallback? onProgress,
  }) async {
    final resolvedUserId = userId ?? _currentUserId ?? _currentSupabaseUserId();
    final range = _resolveSyncRange(mode: mode, from: from, to: to);
    final diagnostics = _NaverCalDavMutableDiagnostics();
    if (resolvedUserId == null || resolvedUserId.isEmpty) {
      return NaverCalDavSyncResult(
        success: false,
        message: '먼저 PlanFlow에 로그인해 주세요.',
        mode: mode,
        from: range.from,
        to: range.to,
        diagnostics: diagnostics.freeze(),
      );
    }

    void emit(NaverCalDavSyncProgress progress) {
      onProgress?.call(progress);
    }

    try {
      final cleanedCount = await _cleanupSuspiciousImportedEvents(
        resolvedUserId,
      );
      if (cleanedCount > 0) {
        debugPrint(
          'Naver CalDAV cleanup removed $cleanedCount suspicious imported events before sync.',
        );
      }

      emit(NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.preparing,
        message: '네이버 CalDAV 연결을 확인하는 중입니다.',
      ));
      final calendars = await getCalendars();
      if (calendars.isEmpty) {
        return NaverCalDavSyncResult(
          success: false,
          message: '네이버 CalDAV에서 읽을 수 있는 캘린더가 없습니다.',
          mode: mode,
          from: range.from,
          to: range.to,
        );
      }

      emit(NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.calendars,
        message: '${calendars.length}개 캘린더를 확인했습니다.',
        totalCalendars: calendars.length,
      ));
      final syncedAt = DateTime.now().toUtc();
      var eventCount = 0;
      var savedCount = 0;
      var skippedCount = 0;
      var failedCount = 0;
      for (var index = 0; index < calendars.length; index += 1) {
        final calendar = calendars[index];
        final calendarNumber = index + 1;
        emit(NaverCalDavSyncProgress(
          mode: mode,
          stage: NaverCalDavSyncStage.querying,
          message: '일정을 조회하는 중입니다.',
          currentCalendar: calendar.displayName,
          currentCalendarIndex: calendarNumber,
          totalCalendars: calendars.length,
          savedEvents: savedCount,
          skippedEvents: skippedCount,
          failedEvents: failedCount,
        ));
        final events = await getEvents(
          calendarPath: calendar.path,
          from: range.from,
          to: range.to,
          allowFullFallback: true,
          allowResourceFallback: true,
          parseStats: NaverCalDavParseStats._(
            calendarPath: calendar.path,
            diagnostics: diagnostics,
            from: range.from,
            to: range.to,
          ),
        );
        eventCount += events.length;
        for (var eventIndex = 0; eventIndex < events.length; eventIndex += 1) {
          final event = events[eventIndex];
          if (!_isEventInsideOptionalRange(event, range.from, range.to)) {
            skippedCount += 1;
            diagnostics.addSkipReason('동기화 범위 밖');
            debugPrint(
              'Naver CalDAV out-of-range skipped: '
              'calendar="${calendar.displayName}", uid="${event.uid}", '
              'startAt=${event.startAt}, endAt=${event.endAt}',
            );
            continue;
          }
          final eventModel = event.toEventModel(
            userId: resolvedUserId,
            calendarPath: calendar.path,
            syncedAt: syncedAt,
          );
          final planFlowOriginId = _planFlowEventIdFromNaverUid(event.uid);
          final planFlowOrigin = planFlowOriginId == null
              ? null
              : await _eventRepository.fetchEvent(
                  planFlowOriginId,
                  userId: resolvedUserId,
                );
          if (planFlowOrigin != null) {
            final linked =
                await _eventRepository.attachExternalSyncMetadataIfCompatible(
              existing: planFlowOrigin,
              incoming: eventModel,
            );
            skippedCount += 1;
            diagnostics.duplicateSkipped += 1;
            diagnostics.addSkipReason(
              linked == null ? 'PlanFlow 원본 일정 되가져오기' : '기존 일정에 네이버 연결 정보 반영',
            );
            debugPrint(
              'Naver CalDAV reflected PlanFlow event handled: '
              'calendar="${calendar.displayName}", uid="${event.uid}", '
              'existing=${planFlowOrigin.id}, linked=${linked != null}',
            );
            emit(NaverCalDavSyncProgress(
              mode: mode,
              stage: NaverCalDavSyncStage.saving,
              message: 'PlanFlow에서 보낸 일정은 중복 저장하지 않는 중입니다.',
              currentCalendar: calendar.displayName,
              currentCalendarIndex: calendarNumber,
              totalCalendars: calendars.length,
              processedEvents: eventIndex + 1,
              totalEvents: events.length,
              savedEvents: savedCount,
              skippedEvents: skippedCount,
              failedEvents: failedCount,
            ));
            continue;
          }

          final duplicateReason = diagnosticImport
              ? null
              : await _sameTitleStartDuplicateReason(eventModel);
          if (duplicateReason != null) {
            final duplicate = await _findSameTitleStartDuplicate(eventModel);
            final linked = duplicate == null
                ? null
                : await _eventRepository.attachExternalSyncMetadataIfCompatible(
                    existing: duplicate,
                    incoming: eventModel,
                  );
            skippedCount += 1;
            diagnostics.duplicateSkipped += 1;
            diagnostics.addSkipReason(
              linked == null ? '같은 제목+시간 중복' : '기존 일정에 네이버 연결 정보 반영',
            );
            debugPrint(
              'Naver CalDAV duplicate handled: '
              'calendar="${calendar.displayName}", '
              'uid="${event.uid}", '
              'externalId="${eventModel.externalId}", '
              'title="${event.title}", '
              'reason=$duplicateReason, linked=${linked != null}',
            );
            emit(NaverCalDavSyncProgress(
              mode: mode,
              stage: NaverCalDavSyncStage.saving,
              message: '이미 PlanFlow에 있는 일정은 건너뛰는 중입니다.',
              currentCalendar: calendar.displayName,
              currentCalendarIndex: calendarNumber,
              totalCalendars: calendars.length,
              processedEvents: eventIndex + 1,
              totalEvents: events.length,
              savedEvents: savedCount,
              skippedEvents: skippedCount,
              failedEvents: failedCount,
            ));
            continue;
          } else if (diagnosticImport) {
            final broadDuplicateReason =
                await _sameTitleStartDuplicateReason(eventModel);
            if (broadDuplicateReason != null) {
              debugPrint(
                'Naver CalDAV diagnostic duplicate warning: '
                'calendar="${calendar.displayName}", '
                'uid="${event.uid}", externalId="${eventModel.externalId}", '
                'title="${event.title}", reason=$broadDuplicateReason',
              );
            }
          }
          final skipReason =
              skipUnchanged ? await _skipUnchangedReason(eventModel) : null;
          if (skipReason != null) {
            skippedCount += 1;
            diagnostics.unchangedSkipped += 1;
            diagnostics.addSkipReason(skipReason);
            debugPrint(
              'Naver CalDAV skip reason: '
              'calendar="${calendar.displayName}", '
              'uid="${event.uid}", '
              'externalId="${eventModel.externalId}", '
              'title="${event.title}", '
              'reason=$skipReason',
            );
            emit(NaverCalDavSyncProgress(
              mode: mode,
              stage: NaverCalDavSyncStage.saving,
              message: '이미 가져온 일정은 건너뛰는 중입니다.',
              currentCalendar: calendar.displayName,
              currentCalendarIndex: calendarNumber,
              totalCalendars: calendars.length,
              processedEvents: eventIndex + 1,
              totalEvents: events.length,
              savedEvents: savedCount,
              skippedEvents: skippedCount,
              failedEvents: failedCount,
            ));
            continue;
          }
          diagnostics.saveCandidates += 1;
          try {
            await _eventRepository.upsertEventBySourceExternalId(eventModel);
            savedCount += 1;
            diagnostics.saved += 1;
          } catch (error, stackTrace) {
            failedCount += 1;
            diagnostics.failed += 1;
            diagnostics.addSkipReason('Supabase 저장 실패');
            debugPrint(
              'Naver CalDAV event save failed: '
              'calendar="${calendar.displayName}", uid="${event.uid}", '
              'title="${event.title}", error=$error',
            );
            debugPrintStack(stackTrace: stackTrace);
          }
          emit(NaverCalDavSyncProgress(
            mode: mode,
            stage: NaverCalDavSyncStage.saving,
            message: failedCount > 0 ? '일부 일정 저장에 실패했습니다.' : '일정을 저장하는 중입니다.',
            currentCalendar: calendar.displayName,
            currentCalendarIndex: calendarNumber,
            totalCalendars: calendars.length,
            processedEvents: eventIndex + 1,
            totalEvents: events.length,
            savedEvents: savedCount,
            skippedEvents: skippedCount,
            failedEvents: failedCount,
          ));
        }
        debugPrint(
          'Naver CalDAV calendar summary: '
          'calendar="${calendar.displayName}", '
          'read=${events.length}, '
          'saved=$savedCount, '
          'skipped=$skippedCount, '
          'failed=$failedCount',
        );
      }

      emit(NaverCalDavSyncProgress(
        mode: mode,
        stage: NaverCalDavSyncStage.completed,
        message: '네이버 CalDAV 동기화를 마쳤습니다.',
        totalCalendars: calendars.length,
        processedEvents: eventCount,
        totalEvents: eventCount,
        savedEvents: savedCount,
        skippedEvents: skippedCount,
        failedEvents: failedCount,
      ));
      final frozenDiagnostics = diagnostics.freeze();
      debugPrint(
        'Naver CalDAV diagnostics summary: '
        '${frozenDiagnostics.toSummaryMessage()}',
      );
      for (final sample in frozenDiagnostics.samples) {
        debugPrint('Naver CalDAV safe sample: ${sample.toSafeLogLine()}');
      }
      return NaverCalDavSyncResult(
        success: failedCount == 0 || savedCount > 0 || skippedCount > 0,
        message: _syncSuccessMessage(
          readCount: eventCount,
          savedCount: savedCount,
          skippedCount: skippedCount,
          failedCount: failedCount,
          diagnostics: frozenDiagnostics,
        ),
        calendars: calendars.length,
        events: eventCount,
        createdOrUpdated: savedCount,
        skipped: skippedCount,
        failed: failedCount,
        mode: mode,
        from: range.from,
        to: range.to,
        diagnostics: frozenDiagnostics,
      );
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV sync failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return NaverCalDavSyncResult(
        success: false,
        message: _syncFailureMessage(error),
        mode: mode,
        from: range.from,
        to: range.to,
        error: error,
        diagnostics: diagnostics.freeze(),
      );
    }
  }

  Future<bool> exportEvent(EventModel event) async {
    if (event.source == 'google' ||
        event.source == 'naver' ||
        event.source == 'naver_caldav' ||
        event.source == 'naver_device' ||
        event.source == 'device_calendar' ||
        event.startAt == null) {
      return true;
    }

    try {
      final credentials = await _resolveCredentials();
      final calendars = await getCalendars(
        naverId: credentials.naverId,
        appPassword: credentials.appPassword,
      );
      if (calendars.isEmpty) {
        return false;
      }
      final resourcePath =
          '${calendars.first.path}planflow-${Uri.encodeComponent(event.id)}.ics';
      final endpoint = _baseUri.replace(path: resourcePath);
      final request = http.Request('PUT', endpoint)
        ..headers.addAll(_authHeaders(
          credentials.naverId,
          credentials.appPassword,
        ))
        ..headers[HttpHeaders.contentTypeHeader] =
            'text/calendar; charset=utf-8'
        ..body = _buildPlanFlowIcal(event);
      final streamed = await _httpClient.send(request).timeout(_timeout);
      await streamed.stream.drain<void>();
      if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
        await _markCalDavExportMetadata(event, calendars.first.path);
        return true;
      }
      debugPrint('Naver CalDAV export failed: ${streamed.statusCode}');
      return false;
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV export skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  ({DateTime? from, DateTime? to}) _resolveSyncRange({
    required NaverCalDavSyncMode mode,
    DateTime? from,
    DateTime? to,
  }) {
    if (mode == NaverCalDavSyncMode.all) {
      return (from: from?.toUtc(), to: to?.toUtc());
    }
    if (from != null || to != null) {
      return (from: from?.toUtc(), to: to?.toUtc());
    }
    final now = DateTime.now().toUtc();
    return (
      from: DateTime.utc(now.year, now.month - 3, now.day),
      to: DateTime.utc(now.year, now.month + 6, now.day),
    );
  }

  Future<String?> _skipUnchangedReason(EventModel event) async {
    final externalId = event.externalId;
    if (externalId == null || externalId.trim().isEmpty) {
      return null;
    }
    final existing = await _eventRepository.fetchEventBySourceExternalId(
      source: event.source,
      externalId: externalId,
      userId: event.userId,
    );
    if (existing == null) {
      return null;
    }
    final incomingEtag = event.externalEtag?.trim();
    final existingEtag = existing.externalEtag?.trim();
    if (existing.startAt == null &&
        incomingEtag != null &&
        incomingEtag.isNotEmpty &&
        existingEtag != null &&
        existingEtag.isNotEmpty &&
        incomingEtag == existingEtag) {
      return 'external_etag 일치';
    }
    if (_hasMeaningfulEventDifference(event, existing)) {
      return null;
    }
    if (incomingEtag != null &&
        incomingEtag.isNotEmpty &&
        existingEtag != null &&
        existingEtag.isNotEmpty) {
      return incomingEtag == existingEtag ? 'external_etag 일치' : null;
    }
    final incomingUpdatedAt = event.externalUpdatedAt;
    final existingUpdatedAt = existing.externalUpdatedAt;
    if (incomingUpdatedAt == null || existingUpdatedAt == null) {
      return null;
    }
    return !incomingUpdatedAt.toUtc().isAfter(existingUpdatedAt.toUtc())
        ? 'external_updated_at이 기존값보다 최신이 아님'
        : null;
  }

  bool _hasMeaningfulEventDifference(EventModel incoming, EventModel existing) {
    if (incoming.title.trim() != existing.title.trim()) {
      return true;
    }
    if (!_sameInstant(incoming.startAt, existing.startAt)) {
      return true;
    }
    if (!_sameInstant(incoming.endAt, existing.endAt)) {
      return true;
    }
    if ((_blankToNull(incoming.location) ?? '') !=
        (_blankToNull(existing.location) ?? '')) {
      return true;
    }
    if ((_blankToNull(incoming.memo) ?? '') !=
        (_blankToNull(existing.memo) ?? '')) {
      return true;
    }
    return false;
  }

  bool _sameInstant(DateTime? left, DateTime? right) {
    if (left == null || right == null) {
      return left == null && right == null;
    }
    return left.toUtc().isAtSameMomentAs(right.toUtc());
  }

  Future<String?> _sameTitleStartDuplicateReason(EventModel event) async {
    final duplicate = await _findSameTitleStartDuplicate(event);
    if (duplicate == null) {
      return null;
    }
    return '같은 시작시간+제목 일정 존재(${duplicate.id}, source=${duplicate.source})';
  }

  Future<EventModel?> _findSameTitleStartDuplicate(EventModel event) async {
    final startAt = event.startAt;
    if (startAt == null) {
      return null;
    }
    return _eventRepository.findEventByTitleAndStart(
      title: event.title,
      startAt: startAt,
      userId: event.userId,
      excludedSources: const <String>{'naver_caldav'},
    );
  }

  Future<void> _markCalDavExportMetadata(
    EventModel event,
    String calendarPath,
  ) async {
    final uid = 'planflow-${event.id}@planflow';
    final incoming = EventModel(
      id: event.id,
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      locationLat: event.locationLat,
      locationLng: event.locationLng,
      memo: event.memo,
      supplies: event.supplies,
      suppliesChecked: event.suppliesChecked,
      participants: event.participants,
      targets: event.targets,
      isCritical: event.isCritical,
      recurrenceRule: event.recurrenceRule,
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
      parentEventId: event.parentEventId,
      category: event.category,
      source: event.source,
      externalId: 'naver-caldav:${_stableExternalKey(calendarPath, uid)}',
      externalCalendarId: 'naver-caldav:$calendarPath',
      externalUpdatedAt: DateTime.now().toUtc(),
      lastSyncedAt: DateTime.now().toUtc(),
      createdAt: event.createdAt,
      updatedAt: event.updatedAt,
    );
    await _eventRepository.attachExternalSyncMetadataIfCompatible(
      existing: event,
      incoming: incoming,
    );
  }

  String? _planFlowEventIdFromNaverUid(String uid) {
    const prefix = 'planflow-';
    const suffix = '@planflow';
    final normalized = uid.trim();
    if (!normalized.startsWith(prefix) || !normalized.endsWith(suffix)) {
      return null;
    }
    final id = normalized.substring(
      prefix.length,
      normalized.length - suffix.length,
    );
    return id.isEmpty ? null : id;
  }

  // Kept temporarily as a rollback reference while the progressive sync path
  // settles; it is not called by the app.
  // ignore: unused_element, unused_element_parameter
  Future<NaverCalDavSyncResult> _syncAllLegacy({
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
        debugPrint('Naver CalDAV 캘린더 동기화 시작: ${calendar.path}');
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
    final hasEndRaw = fields.containsKey('DTEND');
    final endRaw = fields['DTEND']?.firstOrNull;
    final parsedStartAt = _parseIcalDateTime(startRaw);
    final parsedEndAt = _parseIcalDateTime(endRaw);
    var startAt = parsedStartAt;
    var endAt = parsedEndAt;

    // Naver sometimes returns personal app-created items with a Unix-epoch
    // placeholder DTSTART and the real schedule time in DTEND. Treat that as
    // a single-point event instead of dropping the user's original calendar.
    if (startAt == null &&
        _isNaverPlaceholderStart(startRaw) &&
        parsedEndAt != null) {
      startAt = parsedEndAt;
      endAt = null;
      debugPrint(
        'Naver CalDAV recovered placeholder DTSTART from DTEND: '
        'uid=$uid, href=$href, rawStart=$startRaw, rawEnd=$endRaw, '
        'startAt=$startAt',
      );
    }

    if (startAt == null) {
      return null;
    }
    if (hasEndRaw && endRaw != null && parsedEndAt == null) {
      debugPrint(
        'Naver CalDAV parsed event skipped because DTEND failed to parse: '
        'uid=$uid, href=$href, rawEnd=$endRaw',
      );
      return null;
    }
    if (_isSuspiciousImportedDate(startAt) ||
        (endAt != null && _isSuspiciousImportedDate(endAt)) ||
        (endAt != null && endAt.isBefore(startAt))) {
      debugPrint(
        'Naver CalDAV parsed suspicious event skipped: '
        'uid=$uid, href=$href, startAt=$startAt, endAt=$endAt, rawStart=$startRaw',
      );
      return null;
    }
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

  NaverCalDavDebugSample? _buildDebugSample(
    NaverCalDavEvent event, {
    required String calendarPath,
  }) {
    final fields = _parseIcalFields(event.icsData);
    final rawStart = fields['DTSTART']?.firstOrNull;
    if (rawStart == null || rawStart.trim().isEmpty) {
      return null;
    }
    return NaverCalDavDebugSample(
      calendarPath: calendarPath,
      href: event.href,
      uid: event.uid,
      title: event.title,
      rawStart: rawStart,
      rawEnd: fields['DTEND']?.firstOrNull,
      startAt: event.startAt,
      endAt: event.endAt,
      etag: event.etag,
    );
  }

  NaverCalDavInvalidSample? _buildInvalidDebugSample(
    String icsData, {
    required String href,
    required String calendarPath,
  }) {
    final fields = _parseIcalFields(icsData);
    final rawStart = fields['DTSTART']?.firstOrNull;
    final rawEnd = fields['DTEND']?.firstOrNull;
    final uid = fields['UID']?.firstOrNull?.trim();
    final title = _unescapeIcalText(fields['SUMMARY']?.firstOrNull);
    final component = _detectIcalComponent(icsData);
    var reason = '알 수 없는 파싱 실패';

    if (component != null && component != 'VEVENT') {
      reason = '$component 항목이라 일정으로 저장하지 않음';
    } else if (uid == null || uid.isEmpty) {
      reason = 'UID 없음';
    } else if (rawStart == null || rawStart.trim().isEmpty) {
      reason = 'DTSTART 없음';
    } else {
      final parsedStart = _parseIcalDateTime(rawStart);
      if (parsedStart == null) {
        reason = 'DTSTART 파싱 실패';
      } else if (_isSuspiciousImportedDate(parsedStart)) {
        reason = 'DTSTART 비정상 날짜';
      } else if (rawEnd != null &&
          rawEnd.trim().isNotEmpty &&
          _parseIcalDateTime(rawEnd) == null) {
        reason = 'DTEND 파싱 실패';
      } else {
        final parsedEnd = _parseIcalDateTime(rawEnd);
        if (parsedEnd != null && parsedEnd.isBefore(parsedStart)) {
          reason = '종료 시간이 시작 시간보다 빠름';
        }
      }
    }

    return NaverCalDavInvalidSample(
      calendarPath: calendarPath,
      href: href,
      reason: reason,
      title: title,
      uid: uid,
      rawStart: rawStart,
      rawEnd: rawEnd,
      component: component,
    );
  }

  String? _detectIcalComponent(String icsData) {
    final upper = icsData.toUpperCase();
    if (upper.contains('BEGIN:VEVENT')) {
      return 'VEVENT';
    }
    if (upper.contains('BEGIN:VTODO')) {
      return 'VTODO';
    }
    if (upper.contains('BEGIN:VJOURNAL')) {
      return 'VJOURNAL';
    }
    if (upper.contains('BEGIN:VALARM')) {
      return 'VALARM';
    }
    return null;
  }

  List<Uri> _candidateEndpoints(String naverId) {
    final encodedId = Uri.encodeComponent(naverId);
    return <Uri>[
      _baseUri.replace(path: '/'),
      _baseUri.replace(path: '/calendars/$encodedId/'),
      _baseUri.replace(path: '/calendars/$encodedId/home/'),
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

    final encodedId = Uri.encodeComponent(credentials.naverId);
    addPath('/calendars/$encodedId/');
    addPath('/calendars/$encodedId/home/');
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

  String? _normalizeCalDavResourcePath(String? rawPath) {
    final text = rawPath?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    final parsed = Uri.tryParse(text);
    final path = parsed != null && parsed.hasScheme ? parsed.path : text;
    return path.startsWith('/') ? path : '/$path';
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

  String _buildPlanFlowIcal(EventModel event) {
    final startAt = event.startAt;
    if (startAt == null) {
      throw ArgumentError.value(event.startAt, 'event.startAt');
    }
    final endAt = event.endAt ?? startAt.add(const Duration(minutes: 30));
    final now = DateTime.now().toUtc();
    final uid = 'planflow-${event.id}@planflow';
    return <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//PlanFlow//PlanFlow Calendar//KO',
      'CALSCALE:GREGORIAN',
      'BEGIN:VEVENT',
      'UID:${_escapeIcalText(uid)}',
      'SUMMARY:${_escapeIcalText(event.title)}',
      'DTSTART;TZID=Asia/Seoul:${_formatLocalIcalDateTime(startAt)}',
      'DTEND;TZID=Asia/Seoul:${_formatLocalIcalDateTime(endAt)}',
      if ((event.memo ?? '').trim().isNotEmpty)
        'DESCRIPTION:${_escapeIcalText(event.memo!.trim())}',
      if ((event.location ?? '').trim().isNotEmpty)
        'LOCATION:${_escapeIcalText(event.location!.trim())}',
      'DTSTAMP:${_formatUtcIcalDateTime(now)}',
      'LAST-MODIFIED:${_formatUtcIcalDateTime(now)}',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');
  }

  String _formatLocalIcalDateTime(DateTime value) {
    final local = planflowLocal(value);
    return '${local.year.toString().padLeft(4, '0')}'
        '${local.month.toString().padLeft(2, '0')}'
        '${local.day.toString().padLeft(2, '0')}T'
        '${local.hour.toString().padLeft(2, '0')}'
        '${local.minute.toString().padLeft(2, '0')}'
        '${local.second.toString().padLeft(2, '0')}';
  }

  String _formatUtcIcalDateTime(DateTime value) {
    final utc = value.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}Z';
  }

  String _escapeIcalText(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll(';', r'\;')
        .replaceAll(',', r'\,')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', '');
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
      final year = int.parse(value.substring(0, 4));
      final month = int.parse(value.substring(4, 6));
      final day = int.parse(value.substring(6, 8));
      final localLike = DateTime(year, month, day);
      if (localLike.year != year ||
          localLike.month != month ||
          localLike.day != day) {
        return null;
      }
      final parsed = planflowSeoulDateTimeToUtc(DateTime(year, month, day));
      return _isSuspiciousImportedDate(parsed) ? null : parsed;
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
    final expectedYear = int.parse(date.substring(0, 4));
    final expectedMonth = int.parse(date.substring(4, 6));
    final expectedDay = int.parse(date.substring(6, 8));
    final expectedHour = int.parse(time.substring(0, 2));
    final expectedMinute = int.parse(time.substring(2, 4));
    final expectedSecond = int.parse(time.substring(4, 6));
    if (localLike.year != expectedYear ||
        localLike.month != expectedMonth ||
        localLike.day != expectedDay ||
        localLike.hour != expectedHour ||
        localLike.minute != expectedMinute ||
        localLike.second != expectedSecond) {
      return null;
    }
    if (match.group(3) == 'Z') {
      final parsed = DateTime.utc(
        localLike.year,
        localLike.month,
        localLike.day,
        localLike.hour,
        localLike.minute,
        localLike.second,
      );
      return _isSuspiciousImportedDate(parsed) ? null : parsed;
    }
    final parsed = params.toUpperCase().contains('TZID=ASIA/SEOUL') ||
            params.trim().isEmpty
        ? planflowSeoulDateTimeToUtc(localLike)
        : localLike.toUtc();
    return _isSuspiciousImportedDate(parsed) ? null : parsed;
  }

  Future<int> _cleanupSuspiciousImportedEvents(String userId) async {
    final events = await _eventRepository.listEvents(userId: userId);
    var deletedCount = 0;
    for (final event in events) {
      if (!_isImportedSource(event.source)) {
        continue;
      }
      final startAt = event.startAt;
      if (startAt == null) {
        continue;
      }
      if (!_isSuspiciousImportedDate(startAt)) {
        continue;
      }
      try {
        await _eventRepository.deleteEvent(event.id, userId: userId);
        deletedCount += 1;
      } catch (error) {
        debugPrint('Naver CalDAV cleanup delete failed: ${event.id} / $error');
      }
    }
    return deletedCount;
  }

  bool _isImportedSource(String source) {
    return source == 'naver_caldav' ||
        source == 'naver_ics' ||
        source == 'naver_device' ||
        source == 'device_calendar';
  }

  bool _isSuspiciousImportedDate(DateTime value) {
    return value.toUtc().year < 2000;
  }

  bool _isNaverPlaceholderStart(String rawValue) {
    final separator = rawValue.indexOf(':');
    final value = separator >= 0 ? rawValue.substring(separator + 1) : rawValue;
    return value.trim().startsWith('19700101');
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

  String _syncSuccessMessage({
    required int readCount,
    required int savedCount,
    required int skippedCount,
    required int failedCount,
    NaverCalDavSyncDiagnostics? diagnostics,
  }) {
    if (savedCount > 0) {
      final parts = <String>[
        '네이버 CalDAV 일정 $savedCount개를 PlanFlow로 가져왔습니다.',
        if (skippedCount > 0) '중복/변경 없음 $skippedCount개는 건너뛰었습니다.',
        if (failedCount > 0) '저장 실패 $failedCount개가 있습니다.',
      ];
      return parts.join(' ');
    }
    if (failedCount > 0) {
      return '네이버 CalDAV에서 일정 $readCount개를 읽었지만 $failedCount개 저장에 실패했습니다. Supabase 스키마/RLS 또는 네트워크 로그를 확인해 주세요.';
    }
    final diagnosticSummary = diagnostics?.toSummaryMessage();
    if (skippedCount > 0) {
      return '네이버 CalDAV에서 일정 $readCount개를 읽었고, 기존 일정 $skippedCount개는 중복 또는 변경 없음으로 건너뛰었습니다.'
          '${diagnosticSummary == null ? '' : ' 진단: $diagnosticSummary'}';
    }
    if (readCount > 0) {
      return '네이버 CalDAV에서 일정 $readCount개를 읽었지만 저장할 새 일정이 없습니다.'
          '${diagnosticSummary == null ? '' : ' 진단: $diagnosticSummary'}';
    }
    return '네이버 CalDAV 연결은 성공했지만 가져올 일정이 없습니다.';
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

String _stableExternalKey(String calendarPath, String uid) {
  return base64Url.encode(utf8.encode('$calendarPath::$uid'));
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
