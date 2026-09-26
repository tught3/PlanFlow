import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:planflow/services/ios_app_store_update_service.dart';

void main() {
  group('IosAppStoreUpdateService', () {
    test('returns a newer version from a trusted Apple listing', () async {
      final client = _FakeHttpClient(
        response: _lookupResponse(version: '1.2.0'),
      );
      final service = IosAppStoreUpdateService(clientFactory: () => client);

      final update = await service.findUpdate(
        bundleId: 'com.example.app',
        installedVersion: '1.1.9',
      );

      expect(update?.version, '1.2.0');
      expect(update?.storeUri.host, 'apps.apple.com');
      expect(client.requestedUri?.host, 'itunes.apple.com');
      expect(
          client.requestedUri?.queryParameters['bundleId'], 'com.example.app');
      expect(client.closeCount, 1);
    });

    test('does not report equal or older versions', () async {
      for (final version in <String>['1.1.0', '1.0.9']) {
        final service = IosAppStoreUpdateService(
          clientFactory: () =>
              _FakeHttpClient(response: _lookupResponse(version: version)),
        );

        expect(
          await service.findUpdate(
            bundleId: 'com.example.app',
            installedVersion: '1.1.0',
          ),
          isNull,
        );
      }
    });

    test('fails closed for malformed JSON, response shape, and URL', () async {
      final malformedBodies = <String>[
        '{not-json',
        jsonEncode(<String, Object>{'resultCount': 0, 'results': <Object>[]}),
        _lookupBody(version: '2.0', trackViewUrl: 'http://apps.apple.com/app'),
        _lookupBody(
          version: '2.0',
          trackViewUrl: 'https://apps.apple.com.evil.example/app',
        ),
      ];

      for (final body in malformedBodies) {
        final service = IosAppStoreUpdateService(
          clientFactory: () =>
              _FakeHttpClient(response: http.Response(body, 200)),
        );
        expect(
          await service.findUpdate(
            bundleId: 'com.example.app',
            installedVersion: '1.0',
          ),
          isNull,
          reason: 'Rejected malformed or untrusted response: $body',
        );
      }
    });

    test('fails closed on HTTP errors, network errors, and timeout', () async {
      final httpErrorService = IosAppStoreUpdateService(
        clientFactory: () => _FakeHttpClient(response: http.Response('', 503)),
      );
      expect(
        await httpErrorService.findUpdate(
          bundleId: 'com.example.app',
          installedVersion: '1.0',
        ),
        isNull,
      );

      final networkErrorService = IosAppStoreUpdateService(
        clientFactory: () => _FakeHttpClient(error: StateError('offline')),
      );
      expect(
        await networkErrorService.findUpdate(
          bundleId: 'com.example.app',
          installedVersion: '1.0',
        ),
        isNull,
      );

      final timeoutClient =
          _FakeHttpClient(pending: Completer<http.Response>());
      final timeoutService = IosAppStoreUpdateService(
        clientFactory: () => timeoutClient,
      );
      expect(
        await timeoutService.findUpdate(
          bundleId: 'com.example.app',
          installedVersion: '1.0',
          timeout: const Duration(milliseconds: 5),
        ),
        isNull,
      );
      expect(timeoutClient.closeCount, 1);
    });
  });
}

http.Response _lookupResponse({required String version}) =>
    http.Response(_lookupBody(version: version), 200);

String _lookupBody({
  required String version,
  String trackViewUrl = 'https://apps.apple.com/kr/app/planflow/id123456789',
}) =>
    jsonEncode(<String, Object>{
      'resultCount': 1,
      'results': <Object>[
        <String, Object>{'version': version, 'trackViewUrl': trackViewUrl},
      ],
    });

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient({this.response, this.error, this.pending});

  final http.Response? response;
  final Object? error;
  final Completer<http.Response>? pending;
  Uri? requestedUri;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestedUri = request.url;
    final requestError = error;
    if (requestError != null) throw requestError;
    final response = this.response ?? await pending!.future;
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() {
    closeCount += 1;
  }
}
