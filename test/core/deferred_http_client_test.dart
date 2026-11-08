import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/core/deferred_http_client.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:planflow/services/naver_open_api_calendar_service.dart';

/// 어떤 클라이언트 생성도 허용하지 않는 격리 정책 흉내.
class _ThrowingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw StateError('Bad state: UnscopedIOdenied');
  }
}

/// close 호출 횟수를 기록하는 내부 클라이언트.
class _RecordingClient extends http.BaseClient {
  _RecordingClient();

  int closeCount = 0;
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount += 1;
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      200,
      request: request,
    );
  }

  @override
  void close() {
    closeCount += 1;
  }
}

http.Request _request() => http.Request('GET', Uri.parse('https://example.com'));

void main() {
  group('DeferredHttpClient', () {
    test('construct and close never create the inner client', () async {
      var created = 0;
      final client = DeferredHttpClient(
        factory: () {
          created += 1;
          return MockClient((_) async => http.Response('ok', 200));
        },
      );

      expect(created, 0);
      expect(client.isClosed, isFalse);

      client.close();

      expect(created, 0, reason: 'close must not create the inner client');
      expect(client.isClosed, isTrue);
    });

    test('first send creates the inner client exactly once', () async {
      var created = 0;
      final client = DeferredHttpClient(
        factory: () {
          created += 1;
          return MockClient((_) async => http.Response('ok', 200));
        },
      );

      await client.send(_request());
      expect(created, 1);

      await client.send(_request());
      expect(created, 1, reason: 'repeated sends must reuse the same client');

      client.close();
    });

    test('send delegates to the inner client and returns its response',
        () async {
      final client = DeferredHttpClient(
        factory: () => MockClient(
          (request) async => http.Response(
            'delegated:${request.method}:${request.url.path}',
            200,
          ),
        ),
      );

      final response = await client.send(
        http.Request('GET', Uri.parse('https://example.com/path')),
      );

      expect(response.statusCode, 200);
      expect(
        await http.Response.fromStream(response).then((r) => r.body),
        'delegated:GET:/path',
      );

      client.close();
    });

    test('close is idempotent and closes the inner client only once', () async {
      final inner = _RecordingClient();
      final client = DeferredHttpClient(factory: () => inner);

      await client.send(_request());
      expect(inner.sendCount, 1);

      client.close();
      client.close();
      client.close();

      expect(inner.closeCount, 1);
    });

    test('a closed client is not resurrected by later sends', () async {
      var created = 0;
      final client = DeferredHttpClient(
        factory: () {
          created += 1;
          return MockClient((_) async => http.Response('ok', 200));
        },
      );

      client.close();

      Object? caught;
      try {
        await client.send(_request());
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<http.ClientException>());
      expect(created, 0, reason: 'a closed client must not create a new one');
    });

    test('inner client failures propagate to the caller', () async {
      final client = DeferredHttpClient(
        factory: () => MockClient(
          (_) async => throw StateError('boom'),
        ),
      );

      Object? caught;
      try {
        await client.send(_request());
      } catch (error) {
        caught = error;
      }

      expect(caught, isStateError);
      client.close();
    });

    test('factory failures propagate to the caller', () async {
      final client = DeferredHttpClient(
        factory: () => throw StateError('factory failed'),
      );

      Object? caught;
      try {
        await client.send(_request());
      } catch (error) {
        caught = error;
      }

      expect(caught, isStateError);
      client.close();
    });
  });

  group('Naver services default client construction', () {
    test('default services construct and dispose without creating a client',
        () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _ThrowingHttpOverrides();

      Object? caught;
      try {
        final calDav = NaverCalDavService();
        await calDav.dispose();

        final openApi = NaverOpenApiCalendarService();
        openApi.dispose();
      } catch (error) {
        caught = error;
      } finally {
        HttpOverrides.global = previous;
      }

      expect(
        caught,
        isNull,
        reason: 'default construction must not perform any IO',
      );
    });

    test('explicit requests are still denied by the IO fence', () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _ThrowingHttpOverrides();

      final client = DeferredHttpClient();
      Object? caught;
      try {
        await client.get(Uri.parse('https://example.com'));
      } catch (error) {
        caught = error;
      } finally {
        HttpOverrides.global = previous;
      }

      expect(caught, isA<StateError>());
      expect(caught.toString(), contains('UnscopedIOdenied'));
    });
  });
}
