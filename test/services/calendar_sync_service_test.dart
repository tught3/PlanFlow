import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/models/calendar_connection_model.dart';
import 'package:planflow/data/repositories/calendar_connection_repository.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/calendar_sync_service.dart';

void main() {
  group('CalendarSyncService', () {
    test('returns setup states without requiring provider credentials',
        () async {
      final service = CalendarSyncService();

      final status = await service.fetchStatus();

      expect(status.google.status, CalendarIntegrationStatus.notConfigured);
      expect(status.google.provider, CalendarProvider.google);
      expect(status.naver.status, CalendarIntegrationStatus.notConfigured);
      expect(status.naver.provider, CalendarProvider.naver);
    });

    test('Naver sync is unsupported in CalendarSyncService', () async {
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        eventRepository: _FakeEventRepository(events: const <EventModel>[]),
      );

      final result = await service.syncNaverCalendar();

      expect(result.status, CalendarIntegrationStatus.unsupported);
      expect(result.message, contains('CalDAV'));
    });

    test('Naver status reports ready only for CalDAV connection', () async {
      final service = CalendarSyncService(
        currentUserId: 'user-1',
        calendarConnectionRepository: _FakeCalendarConnectionRepository(
          initial: CalendarConnectionModel(
            userId: 'user-1',
            provider: 'naver',
            status: CalendarConnectionStatus.connected,
            lastSyncedAt: DateTime.utc(2026, 5, 1),
          ),
        ),
      );

      final result = await service.getNaverStatus();

      expect(result.status, CalendarIntegrationStatus.ready);
      expect(result.message, contains('CalDAV'));
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

      expect(result.status, CalendarIntegrationStatus.ready);
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
  });
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
