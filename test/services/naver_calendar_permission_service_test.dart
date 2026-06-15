import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  group('NaverCalendarPermissionService', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    tearDown(() {
      SharedPreferencesAsyncPlatform.instance = null;
    });

    test(
        'classifies successful responses as granted and generic client errors as unknown',
        () {
      final ok = NaverCalendarPermissionService.classifyResponse(
        http.Response('{"result":"ok"}', 200),
      );
      final genericClientError =
          NaverCalendarPermissionService.classifyResponse(
        http.Response('invalid schedule payload', 400),
      );

      expect(ok.status, NaverCalendarPermissionStatus.granted);
      expect(genericClientError.status, NaverCalendarPermissionStatus.unknown);
    });

    test('classifies auth and scope errors as denied', () {
      final unauthorized = NaverCalendarPermissionService.classifyResponse(
        http.Response('unauthorized', 401),
      );
      final scope = NaverCalendarPermissionService.classifyResponse(
        http.Response('insufficient scope permission denied', 400),
      );

      expect(unauthorized.status, NaverCalendarPermissionStatus.denied);
      expect(scope.status, NaverCalendarPermissionStatus.denied);
    });

    test('classifies server errors as network error', () {
      final result = NaverCalendarPermissionService.classifyResponse(
        http.Response('temporary error', 503),
      );

      expect(result.status, NaverCalendarPermissionStatus.networkError);
    });

    test('refreshStatus probes read endpoint without creating dummy schedule',
        () async {
      Uri? requestedUri;
      String? requestedMethod;
      final service = NaverCalendarPermissionService(
        accessTokenProvider: () async => 'token',
        httpClient: MockClient((request) async {
          requestedUri = request.url;
          requestedMethod = request.method;
          return http.Response('{"schedules":[]}', 200);
        }),
      );

      final result = await service.refreshStatus();

      expect(result.status, NaverCalendarPermissionStatus.granted);
      expect(requestedMethod, 'GET');
      expect(requestedUri?.path, '/calendar/findSchedules.json');
      expect(requestedUri?.queryParameters['calendarId'], 'defaultCalendarId');
      expect(requestedUri?.queryParameters['count'], '1');
    });
  });
}
