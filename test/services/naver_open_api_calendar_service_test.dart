import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';
import 'package:planflow/services/naver_open_api_calendar_service.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
  });

  test('hasCalendarAccess checks actual Naver calendar permission status',
      () async {
    final permissionService = _FakeNaverPermissionService(
      const NaverCalendarPermissionResult(
        status: NaverCalendarPermissionStatus.denied,
        message: '권한 없음',
      ),
    );
    final service = NaverOpenApiCalendarService(
      permissionService: permissionService,
      accessTokenProvider: () async => 'stored-token-without-calendar-scope',
    );

    expect(await service.hasCalendarAccess(), isFalse);
    expect(permissionService.refreshCallCount, 1);
  });

  test('imports date-only Naver holidays on the same local date', () async {
    final repository = _FakeEventRepository();
    final requests = <http.Request>[];
    final service = NaverOpenApiCalendarService(
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'result': <String, dynamic>{
              'calScheduleList': <Map<String, dynamic>>[
                <String, dynamic>{
                  'calId': 'holiday-1',
                  'summary': '광복절',
                  'dtStart': '20260815',
                  'dtEnd': '20260816',
                  'allDay': true,
                  'uid': 'holiday-1',
                },
                <String, dynamic>{
                  'calId': 'holiday-2',
                  'summary': '개천절',
                  'dtStart': '20261003',
                  'dtEnd': '20261004',
                  'allDay': true,
                  'uid': 'holiday-2',
                },
              ],
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
      eventRepository: repository,
      currentUserId: 'user-1',
      accessTokenProvider: () async => 'naver-token',
      findSchedulesUri: Uri.parse(
        'https://openapi.naver.com/calendar/findSchedules.json',
      ),
    );

    final result = await service.syncAll(
      from: DateTime.utc(2026, 8, 14),
      to: DateTime.utc(2026, 10, 5),
    );

    expect(result.success, isTrue);
    expect(requests, isNotEmpty);
    expect(repository.upserted, hasLength(2));

    final byTitle = <String, EventModel>{
      for (final event in repository.upserted) event.title: event,
    };

    expect(byTitle['광복절'], isNotNull);
    expect(byTitle['광복절']!.isAllDay, isTrue);
    expect(byTitle['광복절']!.isMultiDay, isFalse);
    expect(planflowLocalDay(byTitle['광복절']!.startAt!).day, 15);
    expect(planflowLocalDay(byTitle['광복절']!.startAt!).month, 8);
    expect(planflowLocalDay(byTitle['광복절']!.endAt!).day, 16);

    expect(byTitle['개천절'], isNotNull);
    expect(byTitle['개천절']!.isAllDay, isTrue);
    expect(byTitle['개천절']!.isMultiDay, isFalse);
    expect(planflowLocalDay(byTitle['개천절']!.startAt!).day, 3);
    expect(planflowLocalDay(byTitle['개천절']!.startAt!).month, 10);
    expect(planflowLocalDay(byTitle['개천절']!.endAt!).day, 4);
  });
}

class _FakeNaverPermissionService extends NaverCalendarPermissionService {
  _FakeNaverPermissionService(this.result);

  final NaverCalendarPermissionResult result;
  int refreshCallCount = 0;

  @override
  Future<NaverCalendarPermissionResult> refreshStatus() async {
    refreshCallCount += 1;
    return result;
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository();

  final List<EventModel> upserted = <EventModel>[];

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => <EventModel>[];

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<EventModel?> fetchEventBySourceExternalId({
    required String source,
    required String externalId,
    String? userId,
  }) async {
    return null;
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    upserted.add(event);
    return event;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    upserted.add(event);
    return event;
  }

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) async {
    upserted.add(event);
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
}
