import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

class NaverCalendarPermissionService {
  NaverCalendarPermissionService({
    SupabaseClient? supabaseClient,
    http.Client? httpClient,
    SharedPreferencesAsync? preferences,
    NaverAccessTokenProvider? accessTokenProvider,
    Uri? probeUri,
  })  : _supabaseClient = supabaseClient,
        _httpClient = httpClient ?? http.Client(),
        _preferences = preferences ?? SharedPreferencesAsync(),
        _accessTokenProvider = accessTokenProvider,
        _probeUri = probeUri ??
            Uri.parse('https://openapi.naver.com/calendar/findSchedules.json');

  static const String _statusKey = 'naver_calendar_permission_status';
  static const String _lastCheckedAtKey =
      'naver_calendar_permission_checked_at';

  final SupabaseClient? _supabaseClient;
  final http.Client _httpClient;
  final SharedPreferencesAsync _preferences;
  final NaverAccessTokenProvider? _accessTokenProvider;
  final Uri _probeUri;

  Future<NaverCalendarPermissionStatus> loadStatus() async {
    final value = await _preferences.getString(_statusKey);
    return _parseStatus(value);
  }

  Future<void> saveStatus(NaverCalendarPermissionStatus status) async {
    await _preferences.setString(_statusKey, status.name);
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
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null || userId.trim().isEmpty) {
      return;
    }

    try {
      await client.from('user_settings').upsert(
        <String, dynamic>{
          'user_id': userId,
          'naver_calendar_token': null,
        },
        onConflict: 'user_id',
      );
    } catch (error, stackTrace) {
      debugPrint('Naver calendar token clear skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> clearConnectionState() async {
    await clearStatus();
    await clearStoredToken();
  }

  Future<bool> captureCurrentProviderToken() {
    return _persistCurrentProviderToken();
  }

  Future<String?> resolveAccessTokenForCalendar() {
    return _resolveAccessToken();
  }

  Future<NaverCalendarPermissionResult> refreshStatus() async {
    final accessToken = await _resolveAccessToken();
    if (accessToken == null || accessToken.trim().isEmpty) {
      const result = NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.unknown,
        message: '네이버 로그인 토큰을 확인하지 못했습니다.',
      );
      await saveStatus(result.status);
      return result;
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

      final result = _classifyResponse(response);
      debugPrint(
        'Naver calendar permission probe: status=${response.statusCode} result=${result.status.name}',
      );
      if (result.isGranted) {
        await _persistCurrentProviderToken();
      }
      await saveStatus(result.status);
      return result;
    } on TimeoutException catch (error) {
      final result = NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.networkError,
        message: '네이버 캘린더 권한 확인 중 연결 시간이 초과되었습니다.',
        error: error,
      );
      await saveStatus(result.status);
      return result;
    } on SocketException catch (error) {
      final result = NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.networkError,
        message: '네이버 캘린더 권한 확인 중 네트워크 문제가 발생했습니다.',
        error: error,
      );
      await saveStatus(result.status);
      return result;
    } catch (error) {
      final result = NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.unknown,
        message: '네이버 캘린더 권한 상태를 확인하지 못했습니다.',
        error: error,
      );
      await saveStatus(result.status);
      return result;
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

  Future<String?> _resolveAccessToken() async {
    final provider = _accessTokenProvider;
    if (provider != null) {
      return provider();
    }

    final providerToken = _currentProviderToken();
    if (providerToken != null && providerToken.trim().isNotEmpty) {
      return providerToken;
    }

    return _storedNaverCalendarToken();
  }

  String? _currentProviderToken() {
    return _clientOrNull?.auth.currentSession?.providerToken;
  }

  Future<String?> _storedNaverCalendarToken() async {
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null || userId.trim().isEmpty) {
      return null;
    }

    try {
      final row = await client
          .from('user_settings')
          .select('naver_calendar_token')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) {
        return null;
      }
      return row['naver_calendar_token']?.toString();
    } catch (error, stackTrace) {
      debugPrint('Stored Naver calendar token lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<bool> _persistCurrentProviderToken() async {
    final token = _currentProviderToken();
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    if (client == null ||
        userId == null ||
        userId.trim().isEmpty ||
        !isNaverSignedIn() ||
        token == null ||
        token.trim().isEmpty) {
      return false;
    }

    try {
      await client.from('user_settings').upsert(
        <String, dynamic>{
          'user_id': userId,
          'naver_calendar_token': token,
        },
        onConflict: 'user_id',
      );
      debugPrint('Naver calendar provider token captured.');
      return true;
    } catch (error, stackTrace) {
      debugPrint('Naver calendar token persistence skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

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

    if (statusCode >= 200 && statusCode < 300) {
      return NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.granted,
        statusCode: statusCode,
        message: '네이버 캘린더 권한을 확인했습니다.',
      );
    }

    if (statusCode >= 400 && statusCode < 500) {
      return NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.unknown,
        statusCode: statusCode,
        message: '네이버 캘린더 권한 확인 응답을 해석하지 못했습니다.',
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
