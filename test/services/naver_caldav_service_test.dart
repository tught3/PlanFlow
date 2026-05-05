import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:planflow/services/naver_caldav_service.dart';

void main() {
  test('testConnection saves credentials only after successful PROPFIND',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[207],
    );
    final store = _FakeCredentialStore();
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: store,
    );

    final result = await service.testConnection(
      naverId: 'tught3',
      appPassword: 'app-password',
      saveOnSuccess: true,
    );

    expect(result.isSuccess, isTrue);
    expect(result.statusCode, 207);
    expect(store.savedId, 'tught3');
    expect(store.savedPassword, 'app-password');
    expect(client.requests.single.method, 'PROPFIND');
    expect(
      client.requests.single.headers['authorization'],
      'Basic ${base64Encode(utf8.encode('tught3:app-password'))}',
    );
  });

  test('testConnection maps 401 without saving credentials', () async {
    final client = _FakePropfindClient(responses: <int>[401]);
    final store = _FakeCredentialStore();
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: store,
    );

    final result = await service.testConnection(
      naverId: 'tught3',
      appPassword: 'wrong',
      saveOnSuccess: true,
    );

    expect(result.status, NaverCalDavConnectionStatus.unauthorized);
    expect(result.message, contains('앱 비밀번호'));
    expect(store.savedId, isNull);
  });

  test('testConnection maps 403 as policy/access denial', () async {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[403]),
      credentialStore: _FakeCredentialStore(),
    );

    final result = await service.testConnection(
      naverId: 'tught3',
      appPassword: 'app-password',
    );

    expect(result.status, NaverCalDavConnectionStatus.forbidden);
    expect(result.message, contains('정책상 막혔을 수 있습니다'));
  });

  test('testConnection tries calendar path after root 404', () async {
    final client = _FakePropfindClient(responses: <int>[404, 207]);
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(),
    );

    final result = await service.testConnection(
      naverId: 'tught3',
      appPassword: 'app-password',
    );

    expect(result.isSuccess, isTrue);
    expect(client.requests, hasLength(2));
    expect(client.requests.last.url.path, '/calendars/tught3/');
  });
}

class _FakePropfindClient extends http.BaseClient {
  _FakePropfindClient({required this.responses});

  final List<int> responses;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  var _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final statusCode = responses[_index.clamp(0, responses.length - 1)];
    _index += 1;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        utf8.encode('<multistatus />'),
      ]),
      statusCode,
    );
  }
}

class _FakeCredentialStore extends NaverCalDavCredentialStore {
  String? savedId;
  String? savedPassword;
  bool cleared = false;

  @override
  Future<void> clearCredentials() async {
    cleared = true;
    savedId = null;
    savedPassword = null;
  }

  @override
  Future<void> saveCredentials({
    required String naverId,
    required String appPassword,
  }) async {
    savedId = naverId;
    savedPassword = appPassword;
  }
}
