import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:planflow/services/naver_calendar_permission_service.dart';

void main() {
  group('NaverCalendarPermissionService', () {
    test('classifies successful or validation responses as granted', () {
      final ok = NaverCalendarPermissionService.classifyResponse(
        http.Response('{"result":"ok"}', 200),
      );
      final validation = NaverCalendarPermissionService.classifyResponse(
        http.Response('invalid schedule payload', 400),
      );

      expect(ok.status, NaverCalendarPermissionStatus.granted);
      expect(validation.status, NaverCalendarPermissionStatus.granted);
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
  });
}
