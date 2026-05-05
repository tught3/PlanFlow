import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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

abstract class NaverCalDavCredentialStore {
  const NaverCalDavCredentialStore();

  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  });

  Future<void> clearCredentials();
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
    Duration timeout = const Duration(seconds: 10),
    Uri? baseUri,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _credentialStore = credentialStore,
        _timeout = timeout,
        _baseUri = baseUri ??
            Uri(
              scheme: 'https',
              host: 'caldav.calendar.naver.com',
            );

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final NaverCalDavCredentialStore _credentialStore;
  final Duration _timeout;
  final Uri _baseUri;

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

  Map<String, String> _authHeaders(String naverId, String appPassword) {
    final encoded = base64Encode(utf8.encode('$naverId:$appPassword'));
    return <String, String>{
      HttpHeaders.authorizationHeader: 'Basic $encoded',
      HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
      'Depth': '1',
    };
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
}
