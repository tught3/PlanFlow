import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/models/calendar_connection_model.dart';
import 'package:planflow/data/repositories/calendar_connection_repository.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/event_refresh_bus.dart';
import 'package:planflow/services/home_widget_service.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/smart_preparation_alarm_service.dart';
import 'package:planflow/services/korean_holidays.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';

void main() {
  // SharedPreferences mock 초기화: ApiUsageGuard가 내부적으로 SharedPreferences를 사용하므로
  // 테스트 시작 전 mock을 설정하고 싱글톤을 리셋한다.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiUsageGuard.resetForTesting();
    KoreanHolidays.applyLiveData(2026, {
      (8, 15): '광복절',
      (10, 3): '개천절',
    });
  });

  group('CalendarSyncService', () {
    test('returns setup states without requiring provider credentials',
        () async {
      final service = CalendarSyncService(
        naverStatusProvider: () async {
          return const NaverCalendarPermissionResult(
            status: NaverCalendarPermissionStatus.unknown,
            message: '네이버 권한 확인 필요',
          );
        },
      );

      final status = await service.fetchStatus();

      expect(status.google.status, CalendarIntegrationStatus.notConfigured);
      expect(status.google.provider, CalendarProvider.google);
      expect(status.naver.status, CalendarIntegrationStatus.signedOut);
      expect(status.naver.provider, CalendarProvider.naver);
    });

    test('exports upcoming PlanFlow events to Naver Calendar', () async {
      final requests = <http.Request>[];
      final event = EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '한강 피크닉',
        startAt: DateTime.now().add(const Duration(hours: 2)),
        endAt: DateTime.now().add(const Duration(hours: 3)),
        location: '한강',
        memo: '돗자리 챙기기',
      );

      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: _FakeEventRepository(events: <EventModel>[event]),
        naverStatusProvider: () async {
          return const NaverCalendarPermissionResult(
            status: NaverCalendarPermissionStatus.granted,
            message: '권한 확인',
          );
        },
        naverAccessTokenProvider: () async => 'naver-token',
        naverStatusSaver: (_) async {},
        httpClientFactory: () => MockClient((request) async {
          requests.add(request);
          return http.Response('{"result":"ok"}', 200);
        }),
      );

      final result = await service.syncNaverCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(result.syncedItems, 1);
      expect(requests, hasLength(1));
      expect(requests.single.url.toString(),
          'https://openapi.naver.com/calendar/createSchedule.json');
      expect(requests.single.headers['authorization'], 'Bearer naver-token');
      expect(requests.single.bodyFields['calendarId'], 'defaultCalendarId');
      expect(
        requests.single.bodyFields['scheduleIcalString'],
        contains('SUMMARY:한강 피크닉'),
      );
      expect(
        requests.single.bodyFields['scheduleIcalString'],
        contains('UID:planflow-event-1@planflow'),
      );
    });

    test('does not re-export imported external rows to Naver Calendar',
        () async {
      final requests = <http.Request>[];
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: _FakeEventRepository(events: <EventModel>[
          EventModel(
            id: 'google-1',
            userId: 'user-1',
            title: '구글에서 온 일정',
            startAt: DateTime.now().add(const Duration(hours: 2)),
            source: 'google',
          ),
          EventModel(
            id: 'naver-caldav-1',
            userId: 'user-1',
            title: '네이버에서 온 일정',
            startAt: DateTime.now().add(const Duration(hours: 3)),
            source: 'naver_caldav',
          ),
          EventModel(
            id: 'device-1',
            userId: 'user-1',
            title: '휴대폰 캘린더에서 온 일정',
            startAt: DateTime.now().add(const Duration(hours: 4)),
            source: 'naver_device',
          ),
        ]),
        naverStatusProvider: () async {
          return const NaverCalendarPermissionResult(
            status: NaverCalendarPermissionStatus.granted,
            message: '권한 확인',
          );
        },
        naverAccessTokenProvider: () async => 'naver-token',
        naverStatusSaver: (_) async {},
        httpClientFactory: () => MockClient((request) async {
          requests.add(request);
          return http.Response('{"result":"ok"}', 200);
        }),
      );

      final result = await service.syncNaverCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(result.syncedItems, 0);
      expect(requests, isEmpty);
    });

    test('does not export iOS device or Naver API rows to Naver Calendar',
        () async {
      final requests = <http.Request>[];
      final now = DateTime.now();
      final repo = _FakeEventRepository(events: <EventModel>[
        EventModel(
          id: 'ios-1',
          userId: 'user-1',
          title: 'iOS 캘린더 일정',
          source: 'ios_device',
          externalId: 'ios:cal-1:evt-1',
          externalCalendarId: 'ios:cal-1',
          startAt: now.add(const Duration(hours: 2)),
        ),
        EventModel(
          id: 'naver-api-1',
          userId: 'user-1',
          title: '네이버 API 일정',
          source: 'naver_api',
          externalId: 'naver-api:sched-1',
          externalCalendarId: 'naver-api:defaultCalendarId',
          startAt: now.add(const Duration(hours: 3)),
        ),
        EventModel(
          id: 'manual-1',
          userId: 'user-1',
          title: '직접 만든 일정',
          startAt: now.add(const Duration(hours: 4)),
        ),
      ]);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repo,
        naverStatusProvider: () async {
          return const NaverCalendarPermissionResult(
            status: NaverCalendarPermissionStatus.granted,
            message: '권한 확인',
          );
        },
        naverAccessTokenProvider: () async => 'naver-token',
        naverStatusSaver: (_) async {},
        httpClientFactory: () => MockClient((request) async {
          requests.add(request);
          return http.Response('{"result":"ok"}', 200);
        }),
      );

      final result = await service.syncNaverCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(result.syncedItems, 1);
      expect(requests, hasLength(1));
      expect(requests.single.bodyFields['scheduleIcalString'],
          contains('UID:planflow-manual-1@planflow'));
      expect(repo.updatedEvents.map((event) => event.id), equals(['manual-1']));
      expect(
          repo.events
              .singleWhere((event) => event.id == 'ios-1')
              .externalCalendarId,
          'ios:cal-1');
      expect(
          repo.events
              .singleWhere((event) => event.id == 'naver-api-1')
              .externalCalendarId,
          'naver-api:defaultCalendarId');
    });

    test('does not export ICS-imported rows to Naver Calendar', () async {
      final requests = <http.Request>[];
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: _FakeEventRepository(events: <EventModel>[
          EventModel(
            id: 'ics-import-1',
            userId: 'user-1',
            title: 'ICS 가져온 일정',
            startAt: DateTime.now().add(const Duration(hours: 2)),
            source: 'naver_ics',
          ),
          EventModel(
            id: 'manual-1',
            userId: 'user-1',
            title: '직접 만든 일정',
            startAt: DateTime.now().add(const Duration(hours: 3)),
          ),
        ]),
        naverStatusProvider: () async {
          return const NaverCalendarPermissionResult(
            status: NaverCalendarPermissionStatus.granted,
            message: '권한 확인',
          );
        },
        naverAccessTokenProvider: () async => 'naver-token',
        naverStatusSaver: (_) async {},
        httpClientFactory: () => MockClient((request) async {
          requests.add(request);
          return http.Response('{"result":"ok"}', 200);
        }),
      );

      final result = await service.syncNaverCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(result.syncedItems, 1);
      expect(requests, hasLength(1));
      expect(requests.single.bodyFields['scheduleIcalString'],
          contains('SUMMARY:직접 만든 일정'));
      expect(requests.single.bodyFields['scheduleIcalString'],
          isNot(contains('ICS 가져온 일정')));
    });

    test('does not call Naver API when calendar permission is missing',
        () async {
      var requestCount = 0;
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: _FakeEventRepository(events: const <EventModel>[]),
        naverStatusProvider: () async {
          return const NaverCalendarPermissionResult(
            status: NaverCalendarPermissionStatus.denied,
            message: '권한 없음',
          );
        },
        httpClientFactory: () => MockClient((request) async {
          requestCount += 1;
          return http.Response('{"result":"ok"}', 200);
        }),
      );

      final result = await service.syncNaverCalendar();

      expect(result.status, CalendarIntegrationStatus.signedOut);
      expect(requestCount, 0);
    });

    test('requires Naver re-consent when provider token is missing', () async {
      final connectionRepository = _FakeCalendarConnectionRepository();
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        calendarConnectionRepository: connectionRepository,
        naverStatusProvider: () async {
          return const NaverCalendarPermissionResult(
            status: NaverCalendarPermissionStatus.granted,
            message: '권한 확인',
          );
        },
        naverAccessTokenProvider: () async => null,
        naverStatusSaver: (_) async {},
      );

      final result = await service.getNaverStatus();

      expect(result.status, CalendarIntegrationStatus.signedOut);
      expect(result.message, contains('토큰'));
      expect(
        connectionRepository.connection?.status,
        CalendarConnectionStatus.reauthRequired,
      );
      expect(
        connectionRepository.connection?.lastError,
        'Naver provider token missing',
      );
    });

    test('builds an iCalendar payload for Naver createSchedule', () {
      final event = EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '회의, 준비',
        startAt: DateTime.utc(2026, 5, 5, 1),
        location: '서울;강남',
      );

      final ical = CalendarSyncService.buildNaverScheduleIcal(event);

      expect(ical, contains('BEGIN:VCALENDAR'));
      expect(ical, contains(r'SUMMARY:회의\, 준비'));
      expect(ical, contains(r'LOCATION:서울\;강남'));
      expect(ical, contains('END:VCALENDAR'));
    });

    test('Naver iCalendar payload stays VALARM-free', () {
      final ical = CalendarSyncService.buildNaverScheduleIcal(
        EventModel(
          id: 'event-1',
          userId: 'user-1',
          title: '외부 앱 알림 없이 보낼 일정',
          startAt: DateTime.utc(2026, 5, 5, 1),
          isCritical: true,
        ),
      );

      expect(ical, isNot(contains('BEGIN:VALARM')));
      expect(ical, isNot(contains('TRIGGER')));
    });

    test('does not call Google sign-in on unsupported platforms', () async {
      final service = CalendarSyncService(
        googleClientId: 'test-client-id',
        googlePlatformSupported: false,
        googleTargetPlatform: TargetPlatform.windows,
      );

      final status = await service.getGoogleStatus();
      final sync = await service.syncGoogleCalendar(interactive: false);

      expect(status.status, CalendarIntegrationStatus.unsupported);
      expect(sync.status, CalendarIntegrationStatus.unsupported);
      expect(status.provider, CalendarProvider.google);
      expect(sync.provider, CalendarProvider.google);
    });

    test('treats blank Google client configuration as not configured',
        () async {
      final service = CalendarSyncService(
        googleClientId: '   ',
        googleServerClientId: '',
        googlePlatformSupported: true,
      );

      final status = await service.getGoogleStatus();

      expect(status.status, CalendarIntegrationStatus.notConfigured);
      expect(status.provider, CalendarProvider.google);
    });

    test('treats existing Google connection without silent account as ready',
        () async {
      final googleSignIn = _FakeGoogleSignIn();
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googleSignIn: googleSignIn,
        calendarConnectionRepository: _FakeCalendarConnectionRepository(
          initial: CalendarConnectionModel(
            userId: 'user-1',
            provider: 'google',
            status: CalendarConnectionStatus.connected,
          ),
        ),
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
      );

      final status = await service.getGoogleStatus();

      expect(status.status, CalendarIntegrationStatus.ready);
      expect(status.message, contains('연결'));
      // signInSilently가 null을 반환하면 retry를 1회 더 시도하므로 총 2회 호출됨
      expect(googleSignIn.signInSilentCallCount, 2);
    });

    test(
        'returns notConfigured on Android when serverClientId is missing even if clientId exists',
        () async {
      final googleSignIn = _FakeGoogleSignIn();
      final service = CalendarSyncService(
        googleClientId: 'android-client-id',
        googleSignIn: googleSignIn,
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.notConfigured);
      expect(result.message, contains('Web OAuth Client ID'));
      expect(googleSignIn.signInCallCount, 0);
    });

    test('enters Google sign-in path on Android when serverClientId exists',
        () async {
      final googleSignIn = _FakeGoogleSignIn();
      final service = CalendarSyncService(
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googleSignIn: googleSignIn,
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.signedOut);
      expect(googleSignIn.signInCallCount, 1);
    });

    test('non-interactive Google sync keeps existing connection on token miss',
        () async {
      final connectionRepository = _FakeCalendarConnectionRepository(
        initial: const CalendarConnectionModel(
          userId: 'user-1',
          provider: 'google',
          status: CalendarConnectionStatus.connected,
          providerAccountEmail: 'user@example.com',
        ),
      );
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        calendarConnectionRepository: connectionRepository,
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) async => null,
      );

      final result = await service.syncGoogleCalendar(interactive: false);

      // 비대화형 모드에서 token이 없어도 일시적 Play Services 문제일 수 있으므로
      // 7a13836 수정 이후 status를 reauthRequired로 바꾸지 않고 ready로 반환함
      expect(result.status, CalendarIntegrationStatus.ready);
      // connection status는 기존 connected 유지 (오탐 방지)
      expect(connectionRepository.connection?.status,
          CalendarConnectionStatus.connected);
      expect(connectionRepository.connection?.providerAccountEmail,
          'user@example.com');
    });

    test('classifies Google sign-in cancellation with actionable message',
        () async {
      final service = CalendarSyncService(
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) {
          throw PlatformException(
            code: 'sign_in_canceled',
            message: 'The user canceled sign-in.',
          );
        },
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.failed);
      expect(result.message, contains('취소'));
      expect(result.message, contains('Calendar 권한'));
    });

    test('classifies Google OAuth configuration failures clearly', () async {
      final service = CalendarSyncService(
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) {
          throw PlatformException(
            code: 'sign_in_failed',
            message: 'ApiException: 10',
          );
        },
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.failed);
      expect(result.message, contains('OAuth 설정'));
      expect(result.message, contains('SHA-1'));
      expect(result.message, contains('com.fluxstudio.planflow'));
      expect(result.message, contains('google-services.json'));
    });

    test('imports events from non-primary Google calendars with calendar id',
        () async {
      final repository = _FakeEventRepository(events: const <EventModel>[]);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repository,
        calendarConnectionRepository: _FakeCalendarConnectionRepository(
          initial: const CalendarConnectionModel(
            userId: 'user-1',
            provider: 'google',
            status: CalendarConnectionStatus.connected,
          ),
        ),
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) async {
          return 'google-token';
        },
        googleCalendarEventsFetcher: (_) async {
          return <GoogleCalendarEventEntry>[
            GoogleCalendarEventEntry(
              calendarId: 'naver-calendar@example.com',
              event: gcal.Event(
                id: 'event-1',
                summary: '네이버에서 온 일정',
                updated: DateTime.utc(2026, 5, 5, 1),
                start: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 5, 5, 2),
                ),
                end: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 5, 5, 3),
                ),
              ),
            ),
          ];
        },
        httpClientFactory: () => MockClient((request) async {
          return http.Response(
            '{"id":"google-event-1","updated":"2026-05-08T08:00:00.000Z"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(repository.upsertedEvents, hasLength(1));
      expect(
        repository.upsertedEvents.single.externalId,
        'naver-calendar@example.com:event-1',
      );
      expect(
        repository.upsertedEvents.single.externalCalendarId,
        'google:naver-calendar@example.com',
      );
    });

    test('skips canonical public holidays from Google import', () async {
      final repository = _FakeEventRepository(events: const <EventModel>[]);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repository,
        calendarConnectionRepository: _FakeCalendarConnectionRepository(
          initial: const CalendarConnectionModel(
            userId: 'user-1',
            provider: 'google',
            status: CalendarConnectionStatus.connected,
          ),
        ),
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) async {
          return 'google-token';
        },
        googleCalendarEventsFetcher: (_) async {
          return <GoogleCalendarEventEntry>[
            GoogleCalendarEventEntry(
              calendarId: 'ko.south_korea#holiday@group.v.calendar.google.com',
              event: gcal.Event(
                id: 'holiday-1',
                summary: '광복절',
                updated: DateTime.utc(2026, 8, 15, 1),
                start: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 8, 15, 2),
                ),
                end: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 8, 15, 3),
                ),
              ),
            ),
          ];
        },
        httpClientFactory: () => MockClient((request) async {
          return http.Response(
            '{"id":"google-holiday-1","updated":"2026-08-15T08:00:00.000Z"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(repository.upsertedEvents, isEmpty);
    });

    test('keeps primary Google calendar keys stable when id is account email',
        () async {
      final entry = GoogleCalendarEventEntry(
        calendarId: 'tught3@gmail.com',
        isPrimaryCalendar: true,
        event: gcal.Event(id: 'primary-event-1'),
      );

      expect(entry.stableExternalId, 'primary-event-1');
      expect(entry.externalCalendarId, 'google:primary');
    });

    test('Google export payload disables external default reminders', () {
      final event = EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: 'PlanFlow 알림만 울릴 일정',
        startAt: DateTime.utc(2026, 5, 8, 9),
      );

      final googleEvent =
          CalendarSyncService.buildGoogleExportEventForTest(event);

      expect(googleEvent.reminders?.useDefault, isFalse);
      expect(googleEvent.reminders?.overrides, isEmpty);
      final payload =
          jsonDecode(jsonEncode(googleEvent)) as Map<String, dynamic>;
      expect(payload['reminders'], isA<Map<String, dynamic>>());
      expect(payload['reminders']['useDefault'], isFalse);
      expect(payload['reminders']['overrides'], isEmpty);
      expect(
        googleEvent.extendedProperties?.private?['planflow_event_id'],
        'event-1',
      );
      expect(
        payload['extendedProperties']['private']['planflow_event_id'],
        'event-1',
      );
    });

    test('Google import skips reflected PlanFlow event by private marker',
        () async {
      final existing = EventModel(
        id: 'manual-1',
        userId: 'user-1',
        title: '원주 출발',
        startAt: DateTime.utc(2026, 5, 8, 9),
      );
      final repository = _FakeEventRepository(events: <EventModel>[existing]);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repository,
        calendarConnectionRepository: _FakeCalendarConnectionRepository(
          initial: const CalendarConnectionModel(
            userId: 'user-1',
            provider: 'google',
            status: CalendarConnectionStatus.connected,
          ),
        ),
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) async {
          return 'google-token';
        },
        googleCalendarEventsFetcher: (_) async {
          return <GoogleCalendarEventEntry>[
            GoogleCalendarEventEntry(
              calendarId: 'work-calendar',
              event: gcal.Event(
                id: 'google-reflected-1',
                summary: '원주 출발',
                updated: DateTime.utc(2026, 5, 8, 8),
                extendedProperties: gcal.EventExtendedProperties(
                  private: <String, String>{
                    'planflow_event_id': 'manual-1',
                  },
                ),
                start: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 5, 8, 9),
                ),
                end: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 5, 8, 10),
                ),
              ),
            ),
          ];
        },
        httpClientFactory: () => MockClient((request) async {
          return http.Response('{"id":"google-reflected-1"}', 200);
        }),
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(repository.upsertedEvents, isEmpty);
      expect(repository.updatedEvents, hasLength(1));
      expect(repository.updatedEvents.single.id, 'manual-1');
      expect(repository.updatedEvents.single.externalId,
          'work-calendar:google-reflected-1');
      expect(repository.updatedEvents.single.externalCalendarId,
          'google:work-calendar');
    });

    test('Google import links same title/start duplicate instead of inserting',
        () async {
      final existing = EventModel(
        id: 'manual-1',
        userId: 'user-1',
        title: '원주 출발',
        startAt: DateTime.utc(2026, 5, 8, 9),
      );
      final repository = _FakeEventRepository(events: <EventModel>[existing]);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repository,
        calendarConnectionRepository: _FakeCalendarConnectionRepository(
          initial: const CalendarConnectionModel(
            userId: 'user-1',
            provider: 'google',
            status: CalendarConnectionStatus.connected,
          ),
        ),
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) async {
          return 'google-token';
        },
        googleCalendarEventsFetcher: (_) async {
          return <GoogleCalendarEventEntry>[
            GoogleCalendarEventEntry(
              calendarId: 'primary',
              isPrimaryCalendar: true,
              event: gcal.Event(
                id: 'google-event-1',
                summary: '원주 출발',
                updated: DateTime.utc(2026, 5, 8, 8),
                start: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 5, 8, 9),
                ),
                end: gcal.EventDateTime(
                  dateTime: DateTime.utc(2026, 5, 8, 10),
                ),
              ),
            ),
          ];
        },
        httpClientFactory: () => MockClient((request) async {
          return http.Response(
            '{"id":"google-event-1","updated":"2026-05-08T08:00:00.000Z"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      expect(repository.upsertedEvents, isEmpty);
      expect(repository.updatedEvents, isNotEmpty);
      final linkedEvent = repository.updatedEvents.first;
      expect(linkedEvent.id, 'manual-1');
      expect(linkedEvent.externalId, 'google-event-1');
      expect(
        linkedEvent.externalCalendarId,
        'google:primary',
      );
    });

    test('repairs a stale Google birthday multi-day flag from exclusive DTEND',
        () async {
      final existing = EventModel(
        id: 'birthday-local',
        userId: 'user-1',
        title: '생일 축하합니다',
        startAt: DateTime.utc(2026, 10, 3),
        endAt: DateTime.utc(2026, 10, 5),
        isAllDay: false,
        isMultiDay: true,
        source: 'google',
        externalId: 'birthday-1',
        externalCalendarId: 'google:primary',
      );
      final repository = _FakeEventRepository(events: <EventModel>[existing]);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repository,
        calendarConnectionRepository: _FakeCalendarConnectionRepository(
          initial: const CalendarConnectionModel(
            userId: 'user-1',
            provider: 'google',
            status: CalendarConnectionStatus.connected,
          ),
        ),
        googleServerClientId: 'web-client-id.apps.googleusercontent.com',
        googlePlatformSupported: true,
        googleTargetPlatform: TargetPlatform.android,
        googleAccessTokenProvider: ({required bool interactive}) async =>
            'google-token',
        googleCalendarEventsFetcher: (_) async {
          return <GoogleCalendarEventEntry>[
            GoogleCalendarEventEntry(
              calendarId: 'primary',
              isPrimaryCalendar: true,
              event: gcal.Event(
                id: 'birthday-1',
                summary: '생일 축하합니다',
                updated: DateTime.utc(2026, 10, 3, 1),
                start: gcal.EventDateTime(
                  date: DateTime(
                      2026, 10, 3), // banned-ok: fixed birthday fixture
                ),
                // Google date-only DTEND is exclusive (Oct 4).
                end: gcal.EventDateTime(
                  date: DateTime(
                      2026, 10, 4), // banned-ok: fixed birthday fixture
                ),
              ),
            ),
          ];
        },
      );

      final result = await service.syncGoogleCalendar();

      expect(result.status, CalendarIntegrationStatus.synced);
      final repaired = repository.updatedEvents.single;
      expect(repaired.isAllDay, isTrue);
      expect(repaired.isMultiDay, isFalse);
      expect(repaired.startAt, DateTime.utc(2026, 10, 2, 15));
      expect(repaired.endAt, DateTime.utc(2026, 10, 3, 15));
    });
  });

  // ------------------------------------------------------------------ //
  // ApiUsageGuard 주입 테스트
  // CalendarSyncService에 guard를 주입하면 rateLimit 초과 시 루프가 break되어
  // HTTP POST가 멈추는지 검증한다.
  // ------------------------------------------------------------------ //
  group('CalendarSyncService ApiUsageGuard 주입', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ApiUsageGuard.resetForTesting();
    });

    test(
      'Naver export: rateLimit(3) 초과 시 그 이후 HTTP POST는 전송되지 않는다',
      () async {
        // rateLimit=3으로 설정한 격리 가드: 3회 이후 차단
        final guard = ApiUsageGuard(
          configs: const <String, ApiRateConfig>{
            ApiName.naverCalendar: ApiRateConfig(
              windowSeconds: 60,
              rateLimit: 3,
            ),
          },
        );

        // 5개 이벤트를 export 시도
        final postCount = <int>[0];
        final events = List.generate(
          5,
          (i) => EventModel(
            id: 'event-$i',
            userId: 'user-1',
            title: '일정 $i',
            startAt: DateTime.now().add(Duration(hours: i + 1)),
          ),
        );

        final service = CalendarSyncService(
          currentUserId: 'user-1',
          eventRepository: _FakeEventRepository(events: events),
          naverStatusProvider: () async {
            return const NaverCalendarPermissionResult(
              status: NaverCalendarPermissionStatus.granted,
              message: '권한 확인',
            );
          },
          naverAccessTokenProvider: () async => 'naver-token',
          naverStatusSaver: (_) async {},
          httpClientFactory: () => MockClient((request) async {
            postCount[0] += 1;
            return http.Response('{"result":"ok"}', 200);
          }),
          usageGuard: guard,
        );

        final result = await service.syncNaverCalendar();

        // 가드 rateLimit=3 → POST는 최대 3회, 나머지는 차단됨
        expect(postCount[0], lessThanOrEqualTo(3),
            reason: 'rateLimit(3) 초과 시 루프를 break해 POST가 멈춰야 한다');
        expect(result.status, CalendarIntegrationStatus.synced,
            reason: '이미 보낸 것은 synced 처리, 부분 동기화는 정상 종료');
      },
    );

    test(
      'Naver export: guard 미주입(기본 instance) 시 기존 동작 유지 — 이벤트 1개 정상 전송',
      () async {
        // guard를 주입하지 않으면 기본 instance(rateLimit=30)를 사용,
        // 소량 이벤트에서는 차단 없이 정상 동작해야 한다.
        final requests = <http.Request>[];
        final event = EventModel(
          id: 'event-1',
          userId: 'user-1',
          title: '정상 동기화 일정',
          startAt: DateTime.now().add(const Duration(hours: 1)),
        );

        final service = CalendarSyncService(
          currentUserId: 'user-1',
          eventRepository: _FakeEventRepository(events: <EventModel>[event]),
          naverStatusProvider: () async {
            return const NaverCalendarPermissionResult(
              status: NaverCalendarPermissionStatus.granted,
              message: '권한 확인',
            );
          },
          naverAccessTokenProvider: () async => 'naver-token',
          naverStatusSaver: (_) async {},
          httpClientFactory: () => MockClient((request) async {
            requests.add(request);
            return http.Response('{"result":"ok"}', 200);
          }),
          // usageGuard 미주입 → ApiUsageGuard.instance(기본 rateLimit=30) 사용
        );

        final result = await service.syncNaverCalendar();

        expect(result.status, CalendarIntegrationStatus.synced);
        expect(result.syncedItems, 1);
        expect(requests, hasLength(1),
            reason: 'guard 미주입이어도 소량 이벤트는 그대로 전송되어야 한다');
      },
    );
  });

  group('disconnectProvider', () {
    List<EventModel> naverEvents() {
      final now = DateTime.now();
      return <EventModel>[
        EventModel(
          id: 'naver-1',
          userId: 'user-1',
          title: 'Naver event',
          source: 'naver',
          externalCalendarId: 'naver:default',
          startAt: now.add(const Duration(hours: 2)),
        ),
        EventModel(
          id: 'manual-linked',
          userId: 'user-1',
          title: 'Linked manual event',
          externalId: 'planflow-manual-linked@planflow',
          externalCalendarId: 'naver:default',
          startAt: now.add(const Duration(hours: 3)),
        ),
        EventModel(
          id: 'manual-plain',
          userId: 'user-1',
          title: 'Plain manual event',
          startAt: now.add(const Duration(hours: 4)),
        ),
        EventModel(
          id: 'ics-original',
          userId: 'user-1',
          title: 'Original ICS event',
          source: 'naver_ics',
          externalId: 'naver-ics:uid:orig',
          externalCalendarId: 'naver-ics',
          startAt: now.add(const Duration(hours: 5)),
        ),
        EventModel(
          id: 'ics-overwritten',
          userId: 'user-1',
          title: 'Overwritten ICS event',
          source: 'naver_ics',
          externalId: 'planflow-ics-overwritten@planflow',
          externalCalendarId: 'naver:default',
          startAt: now.add(const Duration(hours: 6)),
        ),
      ];
    }

    _FakeCalendarConnectionRepository connectionRepository(String provider) {
      return _FakeCalendarConnectionRepository(
        initial: CalendarConnectionModel(
          userId: 'user-1',
          provider: provider,
          status: CalendarConnectionStatus.connected,
        ),
      );
    }

    test('Naver disconnect with event deletion keeps ICS-imported rows',
        () async {
      final repo = _DeleteRecordingEventRepository(events: naverEvents());
      final connections = connectionRepository('naver');
      final cleanup = _RecordingBatchCleanup();
      final widget = _RecordingHomeWidget();
      final beforeSignal = EventRefreshBus.instance.latest.value?.sequence ?? 0;
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repo,
        calendarConnectionRepository: connections,
        manualEventSideEffectService: cleanup,
        homeWidgetService: widget,
      );

      await service.disconnectProvider(
        CalendarProvider.naver,
        deleteProviderEvents: true,
      );

      expect(repo.deletedIds, unorderedEquals(['naver-1', 'manual-linked']));
      expect(connections.connection, isNull);
      expect(cleanup.calls, 1);
      expect(cleanup.ids, unorderedEquals(['naver-1', 'manual-linked']));
      expect(cleanup.userId, 'user-1');
      expect(widget.calls, 1);
      expect(widget.payload!.rawEvents.map((e) => e['id']),
          containsAll(['manual-plain', 'ics-original', 'ics-overwritten']));
      expect(widget.payload!.rawEvents.map((e) => e['id']),
          isNot(contains('naver-1')));
      expect(EventRefreshBus.instance.latest.value!.sequence, beforeSignal + 1);
    });

    test('Naver disconnect without event deletion deletes no rows', () async {
      final repo = _DeleteRecordingEventRepository(events: naverEvents());
      final connections = connectionRepository('naver');
      final cleanup = _RecordingBatchCleanup();
      final widget = _RecordingHomeWidget();
      final beforeSignal = EventRefreshBus.instance.latest.value?.sequence ?? 0;
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repo,
        calendarConnectionRepository: connections,
        manualEventSideEffectService: cleanup,
        homeWidgetService: widget,
      );

      await service.disconnectProvider(
        CalendarProvider.naver,
        deleteProviderEvents: false,
      );

      expect(repo.deletedIds, isEmpty);
      expect(connections.connection, isNull);
      expect(cleanup.calls, 0);
      expect(widget.calls, 0);
      expect(
          EventRefreshBus.instance.latest.value?.sequence ?? 0, beforeSignal);
    });

    test('follow-up errors do not fail disconnect', () async {
      final repo = _DeleteRecordingEventRepository(events: naverEvents());
      final connections = connectionRepository('naver');
      final cleanup = _RecordingBatchCleanup(throws: true);
      final widget = _RecordingHomeWidget(throws: true);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repo,
        calendarConnectionRepository: connections,
        manualEventSideEffectService: cleanup,
        homeWidgetService: widget,
      );
      await service.disconnectProvider(CalendarProvider.naver,
          deleteProviderEvents: true);
      expect(connections.connection, isNull);
      expect(cleanup.calls, 1);
      expect(widget.calls, 1);
    });

    test('Google disconnect with event deletion keeps ICS-imported rows',
        () async {
      final now = DateTime.now();
      final repo = _DeleteRecordingEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'google-1',
            userId: 'user-1',
            title: 'Google event',
            source: 'google',
            externalCalendarId: 'google:primary',
            startAt: now.add(const Duration(hours: 2)),
          ),
          EventModel(
            id: 'ics-google-linked',
            userId: 'user-1',
            title: 'Defensive linked ICS event',
            source: 'naver_ics',
            externalId: 'naver-ics:uid:g',
            externalCalendarId: 'google:primary',
            startAt: now.add(const Duration(hours: 3)),
          ),
          EventModel(
            id: 'manual-plain',
            userId: 'user-1',
            title: 'Plain manual event',
            startAt: now.add(const Duration(hours: 4)),
          ),
        ],
      );
      final connections = connectionRepository('google');
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repo,
        calendarConnectionRepository: connections,
        googleSignIn: _FakeGoogleSignIn(),
      );

      await service.disconnectProvider(
        CalendarProvider.google,
        deleteProviderEvents: true,
      );

      expect(repo.deletedIds, equals(['google-1']));
    });
  });

  group('disconnectProvider Naver CalDAV', () {
    const path = '/calendars/user/default/';
    String calDavId(String uid, {String calendarPath = path}) =>
        'naver-caldav:${base64Url.encode(utf8.encode('$calendarPath::$uid'))}';
    const calId = 'naver-caldav:$path';

    List<EventModel> naverEvents(DateTime now) {
      return <EventModel>[
        EventModel(
          id: 'naver-1',
          userId: 'user-1',
          title: 'Naver event',
          source: 'naver',
          externalCalendarId: 'naver:default',
          startAt: now.add(const Duration(hours: 1)),
        ),
        EventModel(
          id: 'caldav-imported',
          userId: 'user-1',
          title: 'Imported CalDAV event',
          source: 'naver_caldav',
          externalId: calDavId('naver-uid-1'),
          externalCalendarId: calId,
          startAt: now.add(const Duration(hours: 2)),
        ),
        EventModel(
          id: 'manual-caldav-exported',
          userId: 'user-1',
          title: 'Exported manual event',
          externalId: calDavId('planflow-manual-caldav-exported@planflow'),
          externalCalendarId: calId,
          startAt: now.add(const Duration(hours: 3)),
        ),
        EventModel(
          id: 'manual-reflected-relabeled',
          userId: 'user-1',
          title: 'Reflected manual event',
          source: 'naver_caldav',
          externalId: calDavId('planflow-manual-reflected-relabeled@planflow'),
          externalCalendarId: calId,
          startAt: now.add(const Duration(hours: 4)),
        ),
        EventModel(
          id: 'caldav-with-people',
          userId: 'user-1',
          title: 'CalDAV event with participants',
          source: 'naver_caldav',
          externalId: calDavId('naver-uid-2'),
          externalCalendarId: calId,
          participants: ['엄마'],
          startAt: now.add(const Duration(hours: 5)),
        ),
        EventModel(
          id: 'caldav-group',
          userId: 'user-1',
          title: 'CalDAV group event',
          source: 'naver_caldav',
          externalId: calDavId('naver-uid-3'),
          externalCalendarId: calId,
          groupEventId: 'group-event-1',
          startAt: now.add(const Duration(hours: 6)),
        ),
        EventModel(
          id: 'caldav-strong-alarm',
          userId: 'user-1',
          title: 'CalDAV event with strong alarm',
          source: 'naver_caldav',
          externalId: calDavId('naver-uid-4'),
          externalCalendarId: calId,
          useStrongAlarm: true,
          startAt: now.add(const Duration(hours: 7)),
        ),
        EventModel(
          id: 'caldav-undecodable',
          userId: 'user-1',
          title: 'CalDAV event with invalid key',
          source: 'naver_caldav',
          externalId: 'naver-caldav:%%%not-base64',
          externalCalendarId: calId,
          startAt: now.add(const Duration(hours: 8)),
        ),
        EventModel(
          id: 'caldav-path-mismatch',
          userId: 'user-1',
          title: 'CalDAV event with mismatched path',
          source: 'naver_caldav',
          externalId: calDavId(
            'naver-uid-5',
            calendarPath: '/calendars/user/other/',
          ),
          externalCalendarId: calId,
          startAt: now.add(const Duration(hours: 9)),
        ),
        EventModel(
          id: 'caldav-no-calendar-id',
          userId: 'user-1',
          title: 'CalDAV event without calendar ID',
          source: 'naver_caldav',
          externalId: calDavId('naver-uid-6'),
          startAt: now.add(const Duration(hours: 10)),
        ),
        EventModel(
          id: 'ics-original',
          userId: 'user-1',
          title: 'Original ICS event',
          source: 'naver_ics',
          externalId: 'naver-ics:uid:orig',
          externalCalendarId: 'naver-ics',
          startAt: now.add(const Duration(hours: 11)),
        ),
        EventModel(
          id: 'manual-plain',
          userId: 'user-1',
          title: 'Plain manual event',
          startAt: now.add(const Duration(hours: 12)),
        ),
        EventModel(
          id: 'caldav-critical',
          userId: 'user-1',
          title: 'Critical CalDAV event',
          source: 'naver_caldav',
          externalId: calDavId('naver-uid-7'),
          externalCalendarId: calId,
          isCritical: true,
          startAt: now.add(const Duration(hours: 13)),
        ),
      ];
    }

    _FakeCalendarConnectionRepository connectionRepository(String provider) {
      return _FakeCalendarConnectionRepository(
        initial: CalendarConnectionModel(
          userId: 'user-1',
          provider: provider,
          status: CalendarConnectionStatus.connected,
        ),
      );
    }

    test(
      'Naver disconnect with event deletion removes only certain CalDAV imports',
      () async {
        final repo = _DeleteRecordingEventRepository(
          events: naverEvents(DateTime.now()),
        );
        final connections = connectionRepository('naver');
        final service = CalendarSyncService(
          currentUserId: 'user-1',
          eventRepository: repo,
          calendarConnectionRepository: connections,
        );

        await service.disconnectProvider(
          CalendarProvider.naver,
          deleteProviderEvents: true,
        );

        expect(
            repo.deletedIds, unorderedEquals(['naver-1', 'caldav-imported']));
        expect(connections.connection, isNull);
      },
    );

    test('Google disconnect with event deletion keeps Naver CalDAV imports',
        () async {
      final now = DateTime.now();
      final repo = _DeleteRecordingEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'google-1',
            userId: 'user-1',
            title: 'Google event',
            source: 'google',
            externalCalendarId: 'google:primary',
            startAt: now.add(const Duration(hours: 1)),
          ),
          naverEvents(now)
              .singleWhere((event) => event.id == 'caldav-imported'),
        ],
      );
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repo,
        calendarConnectionRepository: connectionRepository('google'),
        googleSignIn: _FakeGoogleSignIn(),
      );

      await service.disconnectProvider(
        CalendarProvider.google,
        deleteProviderEvents: true,
      );

      expect(repo.deletedIds, equals(['google-1']));
    });

    test('Naver disconnect without event deletion keeps Naver CalDAV imports',
        () async {
      final repo = _DeleteRecordingEventRepository(
        events: naverEvents(DateTime.now()),
      );
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repo,
        calendarConnectionRepository: connectionRepository('naver'),
      );

      await service.disconnectProvider(
        CalendarProvider.naver,
        deleteProviderEvents: false,
      );

      expect(repo.deletedIds, isEmpty);
    });

    test('CalDAV test external ids match the production key format', () {
      final event = NaverCalDavEvent(
        uid: 'naver-uid-1',
        href: '${path}event-1.ics',
        etag: '"e1"',
        icsData: '',
        title: '네이버 일정',
        startAt: DateTime.utc(2026, 12, 1, 1),
      ).toEventModel(
        userId: 'user-1',
        calendarPath: path,
        syncedAt: DateTime.utc(2026, 11, 6),
      );

      expect(event.externalId, calDavId('naver-uid-1'));
      expect(event.externalCalendarId, calId);
      expect(event.source, 'naver_caldav');
    });
  });
}

class _RecordingBatchCleanup extends ManualEventSideEffectService {
  _RecordingBatchCleanup({this.throws = false});
  final bool throws;
  int calls = 0;
  List<String> ids = [];
  String? userId;

  @override
  Future<void> cleanupAfterBatchDelete(
    Iterable<String> eventIds, {
    String? userId,
    int prepTimeMin = SmartPreparationAlarmService.defaultPrepTimeMin,
    int prepPreAlarmOffset =
        SmartPreparationAlarmService.defaultPrepPreAlarmOffset,
    int departPreAlarmOffset =
        SmartPreparationAlarmService.defaultDepartPreAlarmOffset,
    Duration departureSafetyMargin = DepartureAlarmService.safetyMargin,
    String travelMode = 'car',
  }) async {
    calls++;
    ids = eventIds.toList();
    this.userId = userId;
    if (throws) throw StateError('cleanup failed');
  }
}

class _RecordingHomeWidget extends HomeWidgetService {
  _RecordingHomeWidget({this.throws = false});
  final bool throws;
  int calls = 0;
  HomeWidgetSchedulePayload? payload;

  @override
  Future<bool> updateSchedulePayload(
    HomeWidgetSchedulePayload payload, {
    String widgetName = HomeWidgetService.defaultWidgetName,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    calls++;
    this.payload = payload;
    if (throws) throw StateError('widget failed');
    return true;
  }
}

class _FakeGoogleSignIn extends GoogleSignIn {
  _FakeGoogleSignIn() : super(scopes: const <String>[]);

  int signInCallCount = 0;
  int signInSilentCallCount = 0;

  @override
  Future<GoogleSignInAccount?> signIn() async {
    signInCallCount += 1;
    return null;
  }

  @override
  Future<GoogleSignInAccount?> signInSilently({
    bool reAuthenticate = false,
    bool suppressErrors = true,
  }) async {
    signInSilentCallCount += 1;
    return null;
  }

  @override
  Future<GoogleSignInAccount?> signOut() async => null;
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({required this.events});

  final List<EventModel> events;
  final List<EventModel> upsertedEvents = <EventModel>[];
  final List<EventModel> updatedEvents = <EventModel>[];

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => events;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in events) {
      if (event.id == eventId) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    updatedEvents.add(event);
    final index = events.indexWhere((existing) => existing.id == event.id);
    if (index >= 0) {
      events[index] = event;
    }
    return event;
  }

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) async {
    upsertedEvents.add(event);
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
}

class _FakeCalendarConnectionRepository extends CalendarConnectionRepository {
  _FakeCalendarConnectionRepository({CalendarConnectionModel? initial})
      : _connection = initial;

  CalendarConnectionModel? _connection;
  CalendarConnectionModel? get connection => _connection;

  @override
  Future<CalendarConnectionModel?> fetchConnection({
    required String userId,
    required String provider,
  }) async {
    final connection = _connection;
    if (connection == null ||
        connection.userId != userId ||
        connection.provider != provider) {
      return null;
    }
    return connection;
  }

  @override
  Future<CalendarConnectionModel> upsertConnection(
    CalendarConnectionModel connection,
  ) async {
    _connection = connection;
    return connection;
  }

  @override
  Future<void> markDisconnected({
    required String userId,
    required String provider,
    String? lastError,
  }) async {
    _connection = CalendarConnectionModel(
      userId: userId,
      provider: provider,
      status: CalendarConnectionStatus.disconnected,
      lastError: lastError,
    );
  }

  @override
  Future<void> deleteConnection({
    required String userId,
    required String provider,
  }) async {
    _connection = null;
  }
}

class _DeleteRecordingEventRepository extends _FakeEventRepository {
  _DeleteRecordingEventRepository({required super.events});

  final List<String> deletedIds = <String>[];

  @override
  Future<List<EventModel>> listEvents({String? userId}) async =>
      List<EventModel>.of(events);

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedIds.add(eventId);
    events.removeWhere((event) => event.id == eventId);
  }
}
