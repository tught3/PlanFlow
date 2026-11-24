import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum NaverCalendarPermissionStatus {
  granted,
  denied,
  unknown,
  networkError,
}

class NaverCalendarPermissionResult {
  const NaverCalendarPermissionResult({
    required this.status,
    required this.message,
    this.statusCode,
    this.error,
  });

  final NaverCalendarPermissionStatus status;
  final String message;
  final int? statusCode;
  final Object? error;

  bool get isGranted => status == NaverCalendarPermissionStatus.granted;
  bool get isDenied => status == NaverCalendarPermissionStatus.denied;
  bool get isNetworkError =>
      status == NaverCalendarPermissionStatus.networkError;
}

typedef NaverAccessTokenProvider = Future<String?> Function();

/// Credentials issued to a verified Naver OAuth attempt, keyed by PlanFlow UID.
class NaverCalendarOAuthTokenStore {
  const NaverCalendarOAuthTokenStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;
  static Future<void> _operations = Future<void>.value();

  static String _key(String userId) => 'planflow_naver_calendar_oauth_v1:$userId';

  static Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String?> readForUser(String userId) =>
      _serialize(() => _storage.read(key: _key(userId)));

  Future<void> deleteForUser(String userId) =>
      _serialize(() => _storage.delete(key: _key(userId)));

  Future<bool> saveVerifiedCallbackToken({
    required String userId,
    required String? token,
    required bool Function() stillCurrent,
    required bool replaceExisting,
  }) async {
    final value = token?.trim();
    if (userId.isEmpty || value == null || value.isEmpty) return false;

    return _serialize(() async {
      if (!stillCurrent()) return false;
      final key = _key(userId);
      final previous = await _storage.read(key: key);
      if (!stillCurrent()) return false;
      if (!replaceExisting && previous != null) return true;

      await _storage.write(key: key, value: value);
      if (stillCurrent()) return true;

      if (previous == null) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: previous);
      }
      return false;
    });
  }
}

class NaverCalendarPermissionService {
  NaverCalendarPermissionService({
    SupabaseClient? supabaseClient,
    http.Client? httpClient,
    SharedPreferencesAsync? preferences,
    NaverAccessTokenProvider? accessTokenProvider,
    NaverCalendarOAuthTokenStore tokenStore = const NaverCalendarOAuthTokenStore(),
    Uri? probeUri,
  })  : _supabaseClient = supabaseClient,
        _httpClient = httpClient ?? http.Client(),
        _preferences = preferences ?? SharedPreferencesAsync(),
        _accessTokenProvider = accessTokenProvider,
        _tokenStore = tokenStore,
        _probeUri = probeUri ??
            Uri.parse('https://openapi.naver.com/calendar/findSchedules.json');

  static const String _statusKey = 'naver_calendar_permission_status';
  static const String _lastCheckedAtKey =
      'naver_calendar_permission_checked_at';

  final SupabaseClient? _supabaseClient;
  final http.Client _httpClient;
  final SharedPreferencesAsync _preferences;
  final NaverAccessTokenProvider? _accessTokenProvider;
  final NaverCalendarOAuthTokenStore _tokenStore;
  final Uri _probeUri;

  Future<NaverCalendarPermissionStatus> loadStatus() async {
    final value = await _preferences.getString(_statusKey);
    return _parseStatus(value);
  }

  Future<void> saveStatus(NaverCalendarPermissionStatus status) =>
      _saveStatus(status);

  Future<void> _saveStatus(
    NaverCalendarPermissionStatus status, {
    bool Function()? ownsSession,
  }) async {
    if (ownsSession?.call() == false) return;
    await _preferences.setString(_statusKey, status.name);
    if (ownsSession?.call() == false) return;
    await _preferences.setString(
      _lastCheckedAtKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> clearStatus() async {
    await _preferences.remove(_statusKey);
    await _preferences.remove(_lastCheckedAtKey);
  }

  Future<void> clearStoredToken() async {
    final userId = _clientOrNull?.auth.currentSession?.user.id;
    if (userId == null || userId.isEmpty) return;
    try {
      await _tokenStore.deleteForUser(userId);
    } catch (error) {
      debugPrint('Naver calendar token clear skipped: ${error.runtimeType}');
    }
  }

  Future<void> clearConnectionState() async {
    await clearStoredToken();
    await clearStatus();
  }

  /// Compatibility for auth listeners. Generic session tokens have no issuer
  /// provenance. The PKCE callback is responsible for capturing Naver tokens.
  Future<bool> captureCurrentProviderToken() async => false;

  Future<String?> resolveAccessTokenForCalendar() async {
    final client = _clientOrNull;
    final session = client?.auth.currentSession;
    final token = await _resolveAccessToken(session);
    return _ownsSession(client, session) ? token : null;
  }

  Future<NaverCalendarPermissionResult> refreshStatus() =>
      _checkStatus(persistResult: true);

  Future<NaverCalendarPermissionResult> probeStatus() =>
      _checkStatus(persistResult: false);

  Future<NaverCalendarPermissionResult> _checkStatus({
    required bool persistResult,
  }) async {
    final client = _clientOrNull;
    final session = client?.auth.currentSession;
    bool ownsSession() => _ownsSession(client, session);
    const sessionChanged = NaverCalendarPermissionResult(
      status: NaverCalendarPermissionStatus.unknown,
      message: '로그인 세션이 변경되어 네이버 캘린더 권한을 확인하지 못했습니다.',
    );

    Future<NaverCalendarPermissionResult> finish(
      NaverCalendarPermissionResult result,
    ) async {
      if (!ownsSession()) return sessionChanged;
      if (persistResult) {
        await _saveStatus(result.status, ownsSession: ownsSession);
      }
      return ownsSession() ? result : sessionChanged;
    }

    final accessToken = await _resolveAccessToken(session);
    if (!ownsSession()) return sessionChanged;
    if (accessToken == null || accessToken.trim().isEmpty) {
      return finish(const NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.unknown,
        message: '네이버 로그인 토큰을 확인하지 못했습니다.',
      ));
    }

    try {
      final now = DateTime.now().toUtc();
      final probeUri = _probeUri.replace(
        queryParameters: <String, String>{
          'startDateTime': _formatNaverProbeDateTime(now),
          'endDateTime': _formatNaverProbeDateTime(
            now.add(const Duration(days: 1)),
          ),
          'calendarId': 'defaultCalendarId',
          'startIndex': '1',
          'count': '1',
        },
      );
      final response = await _httpClient.get(
        probeUri,
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer $accessToken',
          HttpHeaders.acceptHeader: 'application/json',
        },
      ).timeout(const Duration(seconds: 8));

      if (!ownsSession()) return sessionChanged;
      final result = _classifyResponse(response);
      debugPrint(
        'Naver calendar permission probe: status=${response.statusCode} result=${result.status.name}',
      );
      return finish(result);
    } on TimeoutException catch (error) {
      if (!ownsSession()) return sessionChanged;
      return NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.networkError,
        message: '네이버 캘린더 권한 확인 중 연결 시간이 초과되었습니다.',
        error: error,
      );
    } on SocketException catch (error) {
      return finish(NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.networkError,
        message: '네이버 캘린더 권한 확인 중 네트워크 문제가 발생했습니다.',
        error: error,
      ));
    } catch (error) {
      return finish(NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.unknown,
        message: '네이버 캘린더 권한 상태를 확인하지 못했습니다.',
        error: error,
      ));
    }
  }

  bool isNaverSignedIn() {
    final user = _clientOrNull?.auth.currentUser;
    final appProvider = user?.appMetadata['provider']?.toString() ?? '';
    if (appProvider.toLowerCase().contains('naver')) {
      return true;
    }

    final identities = user?.identities ?? const <UserIdentity>[];
    return identities.any((identity) {
      final provider = identity.provider.toLowerCase();
      return provider.contains('naver');
    });
  }

  Future<String?> _resolveAccessToken(Session? session) async {
    final provider = _accessTokenProvider;
    if (provider != null) {
      return provider();
    }

    final userId = session?.user.id;
    if (userId == null || userId.isEmpty) return null;
    try {
      return await _tokenStore.readForUser(userId);
    } catch (error) {
      debugPrint('Naver calendar token read skipped: ${error.runtimeType}');
      return null;
    }
  }

  bool _ownsSession(SupabaseClient? client, Session? session) =>
      identical(_clientOrNull, client) &&
      identical(client?.auth.currentSession, session);

  SupabaseClient? get _clientOrNull {
    if (_supabaseClient != null) {
      return _supabaseClient;
    }

    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static NaverCalendarPermissionResult classifyResponse(
    http.Response response,
  ) {
    return _classifyResponse(response);
  }

  static NaverCalendarPermissionResult _classifyResponse(
    http.Response response,
  ) {
    final body = response.body.toLowerCase();
    final statusCode = response.statusCode;
    if (statusCode == 401 ||
        statusCode == 403 ||
        body.contains('permission') ||
        body.contains('scope') ||
        body.contains('unauthorized') ||
        body.contains('forbidden') ||
        body.contains('권한')) {
      return NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.denied,
        statusCode: statusCode,
        message: '네이버 캘린더 권한이 연결되지 않았습니다.',
      );
    }

    if (statusCode >= 500) {
      return NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.networkError,
        statusCode: statusCode,
        message: '네이버 캘린더 서버 응답이 불안정합니다. 잠시 후 다시 시도해 주세요.',
      );
    }

    if (statusCode >= 200 && statusCode < 500) {
      return NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.granted,
        statusCode: statusCode,
        message: '네이버 캘린더 권한을 확인했습니다.',
      );
    }

    return NaverCalendarPermissionResult(
      status: NaverCalendarPermissionStatus.unknown,
      statusCode: statusCode,
      message: '네이버 캘린더 권한 상태를 확인하지 못했습니다.',
    );
  }

  static String _formatNaverProbeDateTime(DateTime value) {
    final utc = value.toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}T'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  static NaverCalendarPermissionStatus _parseStatus(String? value) {
    for (final status in NaverCalendarPermissionStatus.values) {
      if (status.name == value) {
        return status;
      }
    }
    return NaverCalendarPermissionStatus.unknown;
  }
}
