import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/calendar_sync_service.dart';
import 'package:planflow/services/naver_calendar_permission_service.dart';

void main() {
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
      expect(result.message, contains('Android SHA'));
    });

    test('imports events from non-primary Google calendars with calendar id',
        () async {
      final repository = _FakeEventRepository(events: const <EventModel>[]);
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: repository,
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
  });
}

class _FakeGoogleSignIn extends GoogleSignIn {
  _FakeGoogleSignIn() : super(scopes: const <String>[]);

  int signInCallCount = 0;

  @override
  Future<GoogleSignInAccount?> signIn() async {
    signInCallCount += 1;
    return null;
  }

  @override
  Future<GoogleSignInAccount?> signOut() async => null;
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({required this.events});

  final List<EventModel> events;
  final List<EventModel> upsertedEvents = <EventModel>[];

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
  Future<EventModel> updateEvent(EventModel event) async => event;

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) async {
    upsertedEvents.add(event);
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
}
