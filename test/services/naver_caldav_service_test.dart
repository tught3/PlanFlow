import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/naver_caldav_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // ApiUsageGuard가 SharedPreferences를 사용하므로 mock prefs 필수.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiUsageGuard.resetForTesting();
  });

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

  test('testConnection tries home path after root and calendar path 404',
      () async {
    final client = _FakePropfindClient(responses: <int>[404, 404, 207]);
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(),
    );

    final result = await service.testConnection(
      naverId: 'tught3',
      appPassword: 'app-password',
    );

    expect(result.isSuccess, isTrue);
    expect(client.requests.map((request) => request.url.path), <String>[
      '/',
      '/calendars/tught3/',
      '/calendars/tught3/home/',
    ]);
  });

  test('getCalendars parses CalDAV calendar list', () async {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(
        responses: <int>[404, 207],
        bodies: <String>[_calendarListXml],
      ),
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final calendars = await service.getCalendars();

    expect(calendars, hasLength(1));
    expect(calendars.single.path, '/calendars/tught3/default/');
    expect(calendars.single.displayName, '내 캘린더');
    expect(calendars.single.ctag, '123');
  });

  test('getCalendars discovers calendar home before listing calendars',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[207, 207, 207],
      bodies: <String>[
        _principalDiscoveryXml,
        _calendarHomeDiscoveryXml,
        _calendarListXml,
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final calendars = await service.getCalendars();

    expect(calendars.single.path, '/calendars/tught3/default/');
    expect(client.requests.map((request) => request.url.path), <String>[
      '/',
      '/principals/users/tught3/',
      '/calendars/tught3/',
    ]);
  });

  test('getEvents parses CalDAV REPORT calendar data', () async {
    final client = _FakePropfindClient(
      responses: <int>[207],
      bodies: <String>[_eventReportXml],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final events = await service.getEvents(
      calendarPath: '/calendars/tught3/default/',
      from: DateTime.utc(2026, 5),
      to: DateTime.utc(2026, 6),
    );

    expect(events, hasLength(1));
    expect(events.single.uid, 'naver-event-1');
    expect(events.single.title, '한강 피크닉');
    expect(events.single.location, '한강');
    expect(events.single.startAt, DateTime.utc(2026, 5, 5, 1));
    expect(events.single.etag, '"etag-1"');
    expect(client.requests, hasLength(1));
    expect(client.requests.single.method, 'REPORT');
    expect(
      (client.requests.single as http.Request).body,
      contains('time-range'),
    );
  });

  test('getEvents retries with full report when ranged query is empty',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[207, 207],
      bodies: <String>[_emptyEventReportXml, _eventReportXml],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final events = await service.getEvents(
      calendarPath: '/calendars/tught3/default/',
      from: DateTime.utc(2026, 5),
      to: DateTime.utc(2026, 6),
    );

    expect(events, hasLength(1));
    expect(events.single.uid, 'naver-event-1');
    expect(client.requests, hasLength(2));
  });

  test('getEvents loads event resources when report queries stay empty',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[207, 207, 207, 200],
      bodies: <String>[
        _emptyEventReportXml,
        _emptyEventReportXml,
        _eventListXml,
        _eventIcs,
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final events = await service.getEvents(
      calendarPath: '/calendars/tught3/default/',
      from: DateTime.utc(2026, 5),
      to: DateTime.utc(2026, 6),
    );

    expect(events, hasLength(1));
    expect(events.single.uid, 'naver-event-1');
    expect(client.requests, hasLength(4));
    expect(client.requests[2].method, 'PROPFIND');
    expect(client.requests[3].method, 'GET');
    expect(
        client.requests[3].url.path, '/calendars/tught3/default/event-1.ics');
  });

  test('getEvents keeps zero-duration events exactly at range start', () async {
    final client = _FakePropfindClient(
      responses: <int>[207, 207],
      bodies: <String>[_emptyEventReportXml, _zeroDurationEventReportXml],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final events = await service.getEvents(
      calendarPath: '/calendars/tught3/default/',
      from: DateTime.utc(2026, 5, 5, 1),
      to: DateTime.utc(2026, 5, 6),
    );

    expect(events, hasLength(1));
    expect(events.single.uid, 'zero-duration-1');
  });

  test('quick sync diagnoses empty ranged report with fallback paths',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[207, 207, 207, 200],
      bodies: <String>[
        _emptyEventReportXml,
        _emptyEventReportXml,
        _eventListXml,
        _eventIcs,
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final events = await service.getEvents(
      calendarPath: '/calendars/tught3/default/',
      from: DateTime.utc(2026, 5),
      to: DateTime.utc(2026, 6),
      allowFullFallback: true,
      allowResourceFallback: true,
    );

    expect(events, hasLength(1));
    expect(client.requests.map((request) => request.method), <String>[
      'REPORT',
      'REPORT',
      'PROPFIND',
      'GET',
    ]);
  });

  test('parseIcal handles all-day dates and escaped text', () {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[207]),
      credentialStore: _FakeCredentialStore(),
    );

    final event = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:all-day-1
SUMMARY:어린이날\\, 쉬는 날
DTSTART;VALUE=DATE:20260505
DESCRIPTION:메모\\n두 번째 줄
END:VEVENT
END:VCALENDAR
''',
      etag: '"abc"',
      href: '/calendars/tught3/default/all-day-1.ics',
    );

    expect(event, isNotNull);
    expect(event!.isAllDay, isTrue);
    expect(event.title, '어린이날, 쉬는 날');
    expect(event.description, '메모\n두 번째 줄');
    expect(event.startAt, DateTime.utc(2026, 5, 4, 15));
    expect(planflowLocal(event.startAt).day, 5);
  });

  test('parseIcal keeps all-day DTEND as exclusive Seoul midnight', () {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[207]),
      credentialStore: _FakeCredentialStore(),
    );

    final event = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:all-day-exclusive
SUMMARY:하루 종일
DTSTART;VALUE=DATE:20260505
DTEND;VALUE=DATE:20260506
END:VEVENT
END:VCALENDAR
''',
      etag: '"all-day-etag"',
      href: '/calendars/tught3/default/all-day-exclusive.ics',
    );

    expect(event, isNotNull);
    expect(event!.isAllDay, isTrue);
    expect(event.startAt, DateTime.utc(2026, 5, 4, 15));
    expect(event.endAt, DateTime.utc(2026, 5, 5, 15));
    expect(planflowLocal(event.endAt!).day, 6);
    expect(planflowLocal(event.endAt!).hour, 0);
  });

  test('parseIcal maps DTSTART to startAt and DTEND to endAt', () {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[207]),
      credentialStore: _FakeCredentialStore(),
    );

    final event = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:range-1
SUMMARY:Range event
DTSTART;TZID=Asia/Seoul:20260501T140000
DTEND;TZID=Asia/Seoul:20260501T150000
END:VEVENT
END:VCALENDAR
''',
      etag: '"range-etag"',
      href: '/calendars/tught3/default/range-1.ics',
    );

    expect(event, isNotNull);
    expect(event!.startAt, DateTime.utc(2026, 5, 1, 5));
    expect(event.endAt, DateTime.utc(2026, 5, 1, 6));
  });

  test('parseIcal keeps priority and categories for critical import', () {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[207]),
      credentialStore: _FakeCredentialStore(),
    );

    final event = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:important-1
SUMMARY:VIP 상담
DTSTART;TZID=Asia/Seoul:20260501T140000
DTEND;TZID=Asia/Seoul:20260501T150000
PRIORITY:1
CATEGORIES:Important,네이버 예약
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
''',
      etag: '"important-etag"',
      href: '/calendars/tught3/booking/important-1.ics',
    );

    expect(event, isNotNull);
    expect(event!.priority, 1);
    expect(event.categories, containsAll(<String>['Important', '네이버 예약']));
    expect(
        event
            .toEventModel(
              userId: 'user-1',
              calendarPath: '/calendars/tught3/booking/',
              syncedAt: DateTime.utc(2026, 5, 1),
            )
            .isCritical,
        isTrue);
  });

  test('parseIcal treats floating Naver times as Asia Seoul wall time', () {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[207]),
      credentialStore: _FakeCredentialStore(),
    );

    final event = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:floating-1
SUMMARY:Floating event
DTSTART:20260505T003000
DTEND:20260505T013000
END:VEVENT
END:VCALENDAR
''',
      etag: '"floating-etag"',
      href: '/calendars/tught3/default/floating-1.ics',
    );

    expect(event, isNotNull);
    expect(event!.startAt, DateTime.utc(2026, 5, 4, 15, 30));
    expect(planflowLocal(event.startAt).day, 5);
    expect(planflowLocal(event.startAt).hour, 0);
  });

  test('parseIcal recovers Naver placeholder DTSTART from DTEND', () {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[207]),
      credentialStore: _FakeCredentialStore(),
    );

    final event = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:naver-placeholder-start
SUMMARY:네이버 기존 일정
DTSTART:19700101T000000
DTEND;TZID=Asia/Seoul:20260508T093000
END:VEVENT
END:VCALENDAR
''',
      etag: '"placeholder-etag"',
      href: '/caldav/tught3/calendar/1691926/placeholder.ics',
    );

    expect(event, isNotNull);
    expect(event!.title, '네이버 기존 일정');
    expect(event.startAt, DateTime.utc(2026, 5, 8, 0, 30));
    expect(event.endAt, isNull);
  });

  test('parseIcal skips suspicious or invalid dates instead of saving', () {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(responses: <int>[207]),
      credentialStore: _FakeCredentialStore(),
    );

    final suspicious = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:suspicious-1
SUMMARY:Suspicious event
DTSTART:19700101T000000Z
DTEND:19700101T010000Z
END:VEVENT
END:VCALENDAR
''',
      etag: '"suspicious"',
      href: '/calendars/tught3/default/suspicious.ics',
    );

    final invalidEnd = service.parseIcal(
      '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:invalid-end-1
SUMMARY:Invalid end event
DTSTART;TZID=Asia/Seoul:20260501T140000
DTEND;TZID=Asia/Seoul:20260501T250000
END:VEVENT
END:VCALENDAR
''',
      etag: '"invalid-end"',
      href: '/calendars/tught3/default/invalid-end.ics',
    );

    expect(suspicious, isNull);
    expect(invalidEnd, isNull);
  });

  test('parsed CalDAV event maps etag and sync metadata to EventModel', () {
    final event = NaverCalDavEvent(
      uid: 'naver-event-1',
      href: '/calendars/tught3/default/event-1.ics',
      etag: '"etag-quick-1"',
      icsData: _eventIcs,
      title: 'Quick sync event',
      startAt: DateTime.utc(2026, 5, 5, 1),
      endAt: DateTime.utc(2026, 5, 5, 2),
      location: 'Seoul',
      description: 'Imported from Naver CalDAV',
      lastModifiedAt: DateTime.utc(2026, 5, 4, 12),
    );
    final syncedAt = DateTime.utc(2026, 5, 5, 3);

    final model = event.toEventModel(
      userId: 'user-1',
      calendarPath: '/calendars/tught3/default/',
      syncedAt: syncedAt,
    );

    expect(model.source, 'naver_caldav');
    expect(model.externalId, startsWith('naver-caldav:'));
    expect(model.externalId, isNot(contains('/calendars/tught3/default/')));
    expect(model.externalCalendarId, 'naver-caldav:/calendars/tught3/default/');
    expect(model.externalEtag, '"etag-quick-1"');
    expect(model.externalUpdatedAt, DateTime.utc(2026, 5, 4, 12));
    expect(model.lastSyncedAt, syncedAt);
  });

  test('syncAll skips unchanged events by etag and reports progress', () async {
    final incomingExternalId = _naverCalDavExternalId(
      uid: 'naver-event-1',
      calendarPath: '/calendars/tught3/default/',
    );
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _eventReportXml,
      ],
    );
    final repository = _FakeEventRepository(
      existing: incomingExternalId,
      initialExternalIds: <String>{incomingExternalId},
    );
    final progress = <NaverCalDavSyncProgress>[];
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(
      mode: NaverCalDavSyncMode.quick,
      onProgress: progress.add,
    );

    expect(result.success, isTrue);
    expect(result.createdOrUpdated, 0);
    expect(result.skipped, 1);
    expect(repository.upserted, isEmpty);
    expect(progress.map((item) => item.stage),
        contains(NaverCalDavSyncStage.saving));
    expect(result.diagnostics.rawEvents, 1);
    expect(result.diagnostics.parsedEvents, 1);
    expect(result.diagnostics.unchangedSkipped, 1);
    // 747c6ed 이후: initialExternalIds에 이미 있는 externalId는 캐시 체크에서 먼저 스킵됨.
    // 캐시 경로를 타면 etag 비교로 가지 않으므로 skip 이유는 '이미 가져온 일정 (캐시)'.
    // etag 비교 경로는 initialExternalIds가 비어있고 DB에 existing event가 있을 때 사용됨.
    expect(
      result.diagnostics.skipReasons.keys,
      contains('이미 가져온 일정 (캐시)'),
    );
    expect(result.diagnostics.samples.single.rawStart,
        'DTSTART;TZID=Asia/Seoul:20260505T100000');
  });

  test('syncAll links same title/start duplicate instead of inserting',
      () async {
    final incomingExternalId = _naverCalDavExternalId(
      uid: 'naver-event-1',
      calendarPath: '/calendars/tught3/default/',
    );
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _eventReportXml,
      ],
    );
    final repository = _FakeEventRepository(
      initialExternalIds: <String>{incomingExternalId},
      seedEvents: <EventModel>[
        EventModel(
          id: 'manual-1',
          userId: 'user-1',
          title: '한강 피크닉',
          startAt: DateTime.utc(2026, 5, 5, 1),
        ),
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.success, isTrue);
    expect(result.createdOrUpdated, 0);
    expect(result.skipped, 1);
    expect(repository.upserted, isEmpty);
    expect(repository.updated, hasLength(1));
    expect(repository.updated.single.id, 'manual-1');
    expect(repository.updated.single.externalId, startsWith('naver-caldav:'));
    expect(
      repository.updated.single.externalCalendarId,
      'naver-caldav:/calendars/tught3/default/',
    );
  });

  test('syncAll fast-paths new external ids after one prefetch', () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _eventReportXml,
      ],
    );
    // seed event 제목이 incoming 네이버 이벤트('한강 피크닉')와 다르게 설정해
    // 같은 제목+시간 duplicate 분기를 피하고 정상 upsert 경로를 테스트함
    final repository = _FakeEventRepository(
      seedEvents: <EventModel>[
        EventModel(
          id: 'manual-other',
          userId: 'user-1',
          title: '다른 일정',
          startAt: DateTime.utc(2026, 5, 5, 1),
          source: 'manual',
        ),
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.success, isTrue);
    expect(result.createdOrUpdated, 1);
    expect(result.skipped, 0);
    expect(repository.upserted, hasLength(1));
    // fetchExternalIdsBySource로 일괄 prefetch가 1회만 발생해야 함 (per-event DB 쿼리 제거)
    expect(repository.fetchExternalIdSetCalls, 1);
    // 메모리 인덱스 최적화: unchanged 체크와 title+start 중복 체크를 메모리로 처리하므로 0
    expect(repository.fetchByExternalIdCalls, 0);
    expect(repository.findTitleStartCalls, 0);
    expect(repository.externalIdSet,
        contains(repository.upserted.single.externalId));
  });

  test('syncAll skips reflected PlanFlow CalDAV event by UID marker', () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _reflectedPlanFlowEventReportXml,
      ],
    );
    final repository = _FakeEventRepository(
      seedEvents: <EventModel>[
        EventModel(
          id: 'manual-1',
          userId: 'user-1',
          title: '원주 출발',
          startAt: DateTime.utc(2026, 5, 8),
          externalId: 'google-event-1',
          externalCalendarId: 'google:primary',
        ),
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.success, isTrue);
    expect(result.createdOrUpdated, 0);
    expect(result.diagnostics.duplicateSkipped, 1);
    expect(repository.upserted, isEmpty);
    expect(repository.updated, isEmpty);
  });

  test(
      'syncAll updates existing event when content changed despite older updated timestamp',
      () async {
    final incomingExternalId = NaverCalDavEvent(
      uid: 'naver-event-1',
      href: '/calendars/tught3/default/event-1.ics',
      etag: '"etag-1"',
      icsData: _eventIcs,
      title: '한강 피크닉',
      startAt: DateTime.utc(2026, 5, 5, 1),
    )
        .toEventModel(
          userId: 'user-1',
          calendarPath: '/calendars/tught3/default/',
          syncedAt: DateTime.utc(2026, 5, 5, 3),
        )
        .externalId!;
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _eventReportXml,
      ],
    );
    final repository = _FakeEventRepository(
      existingEvent: EventModel(
        id: 'existing-1',
        userId: 'user-1',
        title: '한강 피크닉',
        startAt: DateTime.utc(2026, 5, 4, 1),
        source: 'naver_caldav',
        externalId: incomingExternalId,
        externalUpdatedAt: DateTime.utc(2026, 5, 7),
      ),
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.createdOrUpdated, 1);
    expect(result.skipped, 0);
    expect(result.diagnostics.saveCandidates, 1);
    expect(result.diagnostics.unchangedSkipped, 0);
    // 메모리 인덱스 최적화: existingEvent를 인덱스에서 찾아 updateEvent로 처리
    final savedEvent = repository.updated.isNotEmpty
        ? repository.updated.single
        : repository.upserted.single;
    expect(savedEvent.startAt, DateTime.utc(2026, 5, 5, 1));
  });

  test('syncAll imports a personal in-range event after noisy range report',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _oldBroadcastEventReportXml,
        _personalInRangeEventReportXml,
      ],
    );
    final repository = _FakeEventRepository();
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(
      mode: NaverCalDavSyncMode.custom,
      from: DateTime.utc(2026, 5),
      to: DateTime.utc(2026, 6),
    );

    expect(result.success, isTrue);
    expect(result.events, 1);
    expect(result.createdOrUpdated, 1);
    expect(result.diagnostics.rawEvents, 2);
    expect(result.diagnostics.parsedEvents, 2);
    expect(result.diagnostics.saveCandidates, 1);
    expect(repository.upserted.single.title, 'Personal in range');
    expect(repository.upserted.single.startAt, DateTime.utc(2026, 5, 8, 0, 30));
  });

  test('syncAll saves recovered placeholder DTSTART event as open-ended',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _oldBroadcastEventReportXml,
        _placeholderPersonalEventReportXml,
      ],
    );
    final repository = _FakeEventRepository();
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(
      mode: NaverCalDavSyncMode.custom,
      from: DateTime.utc(2026, 5),
      to: DateTime.utc(2026, 6),
    );

    expect(result.createdOrUpdated, 1);
    expect(result.diagnostics.saveCandidates, 1);
    expect(repository.upserted.single.title, 'Naver placeholder personal');
    expect(repository.upserted.single.startAt, DateTime.utc(2026, 5, 8, 0, 30));
    expect(repository.upserted.single.endAt, isNull);
  });

  test('syncAll diagnostic import bypasses broad title and start duplicate',
      () async {
    final broadDuplicate = EventModel(
      id: 'manual-1',
      userId: 'user-1',
      title: '한강 피크닉',
      startAt: DateTime.utc(2026, 5, 5, 1),
      source: 'manual',
    );
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _eventReportXml,
      ],
    );
    final repository = _FakeEventRepository(
      seedEvents: <EventModel>[broadDuplicate],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(
      mode: NaverCalDavSyncMode.quick,
      diagnosticImport: true,
    );

    expect(result.success, isTrue);
    expect(result.events, 1);
    expect(result.createdOrUpdated, 1);
    expect(result.skipped, 0);
    expect(repository.upserted, hasLength(1));
    expect(result.diagnostics.saveCandidates, 1);
    expect(result.diagnostics.saved, 1);
    expect(result.diagnostics.duplicateSkipped, 0);
  });

  test('syncAll normal import records broad duplicate skip separately',
      () async {
    final incomingExternalId = _naverCalDavExternalId(
      uid: 'naver-event-1',
      calendarPath: '/calendars/tught3/default/',
    );
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _eventReportXml,
      ],
    );
    final repository = _FakeEventRepository(
      initialExternalIds: <String>{incomingExternalId},
      seedEvents: <EventModel>[
        EventModel(
          id: 'manual-1',
          userId: 'user-1',
          title: '한강 피크닉',
          startAt: DateTime.utc(2026, 5, 5, 1),
          source: 'manual',
        ),
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.success, isTrue);
    expect(result.createdOrUpdated, 0);
    expect(result.skipped, 1);
    expect(repository.upserted, isEmpty);
    expect(repository.updated, hasLength(1));
    expect(result.diagnostics.duplicateSkipped, 1);
    expect(result.diagnostics.skipReasons['기존 일정에 네이버 연결 정보 반영'], 1);
  });

  test('syncAll diagnostics only keeps samples inside selected sync range',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        _emptyEventReportXml,
        _oldBroadcastEventReportXml,
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: _FakeEventRepository(),
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(
      mode: NaverCalDavSyncMode.quick,
      diagnosticImport: true,
    );

    expect(result.success, isTrue);
    expect(result.events, 0);
    expect(result.diagnostics.rawEvents, 2);
    expect(result.diagnostics.parsedEvents, 2);
    expect(result.diagnostics.samples, isEmpty);
  });

  test('syncAll diagnostics records invalid event samples with reasons',
      () async {
    final service = NaverCalDavService(
      httpClient: _FakePropfindClient(
        responses: <int>[404, 207, 207],
        bodies: <String>[
          _emptyEventReportXml,
          _calendarListXml,
          _invalidEventReportXml,
        ],
      ),
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: _FakeEventRepository(),
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.diagnostics.rawEvents, 6);
    expect(result.diagnostics.parsedEvents, 0);
    expect(result.diagnostics.invalidEvents, 6);
    expect(result.diagnostics.invalidSamples, hasLength(5));
    expect(
      result.diagnostics.invalidSamples.map((sample) => sample.reason),
      containsAll(<String>['DTSTART 없음', 'DTSTART 파싱 실패']),
    );
    expect(
      result.diagnostics.invalidSamples.map((sample) => sample.title),
      containsAll(<String>['시작 없는 네이버 일정', '이상한 날짜 네이버 일정']),
    );
  });

  test('syncAll deletes suspicious imported events before re-syncing',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 404, 404],
      bodies: <String>[''],
    );
    final repository = _FakeEventRepository(
      seedEvents: <EventModel>[
        EventModel(
          id: 'bad-1',
          userId: 'user-1',
          title: 'Bad imported event',
          startAt: DateTime.utc(1969, 12, 31, 15),
          source: 'naver_caldav',
        ),
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.success, isFalse);
    expect(repository.deletedIds, contains('bad-1'));
  });

  test('syncAll N개 신규 일정 저장 시 DB read 호출이 N에 비례하지 않고 상수(0)임 (N² 제거)', () async {
    // 20개의 서로 다른 신규 이벤트를 CalDAV에서 반환하는 XML 생성
    const n = 20;
    final eventXmlItems = StringBuffer();
    for (var i = 1; i <= n; i++) {
      final uid = 'batch-event-$i';
      // 날짜를 분 단위로 다르게 설정해 title+시각 충돌 없게 함
      final hour = 10 + (i - 1) ~/ 60;
      final minute = (i - 1) % 60;
      final minuteStr = minute.toString().padLeft(2, '0');
      eventXmlItems.write('''
  <d:response>
    <d:href>/calendars/tught3/default/$uid.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-$i"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:$uid
SUMMARY:일정 $i
DTSTART;TZID=Asia/Seoul:20260505T$hour${minuteStr}00
DTEND;TZID=Asia/Seoul:20260505T$hour${minuteStr}30
LAST-MODIFIED:20260504T120000Z
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>''');
    }
    final batchEventReportXml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
$eventXmlItems
</d:multistatus>
''';

    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        batchEventReportXml,
      ],
    );
    // seedEvents는 비어있고 externalIds도 비어있어 모든 이벤트가 신규로 저장됨
    final repository = _FakeEventRepository();
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    expect(result.success, isTrue);
    expect(result.createdOrUpdated, n);
    expect(result.skipped, 0);
    expect(repository.upserted, hasLength(n));
    // N² 제거 핵심 단언: DB read 호출이 N에 비례하지 않고 상수(0)
    // 메모리 인덱스가 fetchByExternalId/findTitleStart를 루프 내부에서 대체한다
    expect(
      repository.fetchByExternalIdCalls,
      0,
      reason: 'fetchByExternalId는 메모리 인덱스로 대체되어 루프 내에서 0번 호출되어야 한다',
    );
    expect(
      repository.findTitleStartCalls,
      0,
      reason: 'findTitleStart는 메모리 인덱스로 대체되어 루프 내에서 0번 호출되어야 한다',
    );
    // listEvents는 1회 호출로 스냅샷 (fetchExternalIdsBySource도 1회)
    expect(repository.fetchExternalIdSetCalls, 1);
  });

  test('syncAll 대량 저장 시 ApiUsageGuard 한도 초과하면 배치 루프가 중단된다', () async {
    // saveBatchSize=8 기준으로, rateLimit=1이면 첫 배치(8개)만 소비 통과하고
    // 두 번째 배치부터 tryConsume이 false를 반환해 루프가 break된다.
    // 이미 저장된 첫 배치는 유지되고, 남은 후보는 다음 동기화가 멱등 처리한다.
    const n = 20;
    final eventXmlItems = StringBuffer();
    for (var i = 1; i <= n; i++) {
      final uid = 'guard-event-$i';
      final hour = 10 + (i - 1) ~/ 60;
      final minute = (i - 1) % 60;
      final minuteStr = minute.toString().padLeft(2, '0');
      eventXmlItems.write('''
  <d:response>
    <d:href>/calendars/tught3/default/$uid.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-$i"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:$uid
SUMMARY:가드 일정 $i
DTSTART;TZID=Asia/Seoul:20260505T$hour${minuteStr}00
DTEND;TZID=Asia/Seoul:20260505T$hour${minuteStr}30
LAST-MODIFIED:20260504T120000Z
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>''');
    }
    final batchEventReportXml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
$eventXmlItems
</d:multistatus>
''';

    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        batchEventReportXml,
      ],
    );
    final repository = _FakeEventRepository();
    // rateLimit=1: 첫 배치만 통과, 두 번째 배치부터 차단.
    final guard = ApiUsageGuard(
      configs: const <String, ApiRateConfig>{
        ApiName.naverCalendar: ApiRateConfig(windowSeconds: 60, rateLimit: 1),
      },
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
      usageGuard: guard,
    );

    final result = await service.syncAll(mode: NaverCalDavSyncMode.quick);

    // 첫 배치(8개)만 저장되고 나머지는 가드가 막아 저장되지 않는다.
    expect(result.success, isTrue);
    expect(result.createdOrUpdated, lessThan(n),
        reason: '가드 차단으로 전체 $n개가 아닌 일부만 저장되어야 한다');
    expect(repository.upserted, hasLength(8),
        reason: 'saveBatchSize=8 · rateLimit=1 → 첫 배치 8개만 저장');
    // 가드가 없으면 전체가 저장됨을 대조 검증.
    ApiUsageGuard.resetForTesting();
    final client2 = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _calendarListXml,
        batchEventReportXml,
      ],
    );
    final repository2 = _FakeEventRepository();
    final service2 = NaverCalDavService(
      httpClient: client2,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository2,
      currentUserId: 'user-1',
      usageGuard: ApiUsageGuard(
        configs: const <String, ApiRateConfig>{
          ApiName.naverCalendar:
              ApiRateConfig(windowSeconds: 60, rateLimit: 1000),
        },
      ),
    );
    final result2 = await service2.syncAll(mode: NaverCalDavSyncMode.quick);
    expect(result2.createdOrUpdated, n,
        reason: '넉넉한 rateLimit에서는 전체 $n개가 저장되어야 한다');
    expect(repository2.upserted, hasLength(n));
  });

  test('exportEvent writes metadata and keeps exported ICS VALARM-free',
      () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 201],
      bodies: <String>[
        '',
        _calendarListXml,
        '',
      ],
    );
    final repository = _FakeEventRepository();
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );
    final event = EventModel(
      id: 'manual-1',
      userId: 'user-1',
      title: '네이버로 보낼 일정',
      startAt: DateTime.utc(2026, 5, 8, 9),
      isCritical: true,
    );

    final result = await service.exportEvent(event);

    expect(result, isTrue);
    final putRequest = client.requests.last as http.Request;
    expect(putRequest.method, 'PUT');
    expect(putRequest.body, isNot(contains('BEGIN:VALARM')));
    expect(repository.updated, hasLength(1));
    expect(repository.updated.single.id, 'manual-1');
    expect(repository.updated.single.externalId, startsWith('naver-caldav:'));
    expect(
      repository.updated.single.externalCalendarId,
      'naver-caldav:/calendars/tught3/default/',
    );
  });

  test('getCalendars tries home path when calendar root is empty', () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 207],
      bodies: <String>[
        _emptyEventReportXml,
        _emptyEventReportXml,
        _calendarListXml,
      ],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final calendars = await service.getCalendars();

    expect(calendars, hasLength(1));
    expect(client.requests.map((request) => request.url.path), <String>[
      '/',
      '/calendars/tught3/',
      '/calendars/tught3/home/',
    ]);
  });

  test('getCalendars 2회 연속 호출 시 PROPFIND HTTP 요청이 1회만 발생 (캐시 적중)', () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207],
      bodies: <String>[_calendarListXml],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    final first = await service.getCalendars();
    final second = await service.getCalendars();

    // 두 번째 호출은 캐시 적중 → 네트워크 요청 없음
    expect(first, hasLength(1));
    expect(second, hasLength(1));
    expect(second.single.path, first.single.path);
    // PROPFIND 요청은 최초 1회(첫 번째 404는 path 탐색)만 발생
    expect(client.requests, hasLength(2));
  });

  test('invalidateCalendarCache 후 재호출 시 네트워크를 다시 요청한다', () async {
    final client = _FakePropfindClient(
      responses: <int>[404, 207, 404, 207],
      bodies: <String>[_calendarListXml, _calendarListXml],
    );
    final service = NaverCalDavService(
      httpClient: client,
      credentialStore: _FakeCredentialStore(
        savedId: 'tught3',
        savedPassword: 'app-password',
      ),
    );

    // 1차 호출: 캐시 채움
    await service.getCalendars();
    final requestsAfterFirst = client.requests.length;

    // 캐시 무효화
    service.invalidateCalendarCache();

    // 2차 호출: 캐시 없으므로 네트워크 재요청
    await service.getCalendars();

    expect(client.requests.length, greaterThan(requestsAfterFirst));
  });
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({
    this.existing,
    this.existingEvent,
    Set<String> initialExternalIds = const <String>{},
    List<EventModel> seedEvents = const <EventModel>[],
  })  : externalIdSet = Set<String>.from(initialExternalIds),
        events = List<EventModel>.from(seedEvents);

  final String? existing;
  final EventModel? existingEvent;
  final Set<String> externalIdSet;
  final List<EventModel> events;
  final List<EventModel> upserted = <EventModel>[];
  final List<EventModel> updated = <EventModel>[];
  final List<String> deletedIds = <String>[];
  int fetchExternalIdSetCalls = 0;
  int fetchByExternalIdCalls = 0;
  int findTitleStartCalls = 0;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in events) {
      if (event.id == eventId && (userId == null || event.userId == userId)) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<EventModel?> fetchEventBySourceExternalId({
    required String source,
    required String externalId,
    String? userId,
  }) async {
    fetchByExternalIdCalls += 1;
    final seededExisting = existingEvent;
    if (seededExisting != null && externalId == seededExisting.externalId) {
      return seededExisting;
    }
    if (externalId != existing) {
      return null;
    }
    return EventModel(
      id: 'existing-1',
      userId: userId ?? 'user-1',
      title: 'Existing',
      source: source,
      externalId: externalId,
      externalEtag: '"etag-1"',
      externalUpdatedAt: DateTime.utc(2026, 5, 4, 12),
    );
  }

  @override
  Future<Set<String>> fetchExternalIdsBySource({
    required String source,
    String? userId,
  }) async {
    fetchExternalIdSetCalls += 1;
    return Set<String>.from(externalIdSet);
  }

  @override
  Future<EventModel?> findEventByTitleAndStart({
    required String title,
    required DateTime startAt,
    String? userId,
    Duration tolerance = const Duration(minutes: 1),
    Set<String> excludedSources = const <String>{},
  }) async {
    findTitleStartCalls += 1;
    return super.findEventByTitleAndStart(
      title: title,
      startAt: startAt,
      userId: userId,
      tolerance: tolerance,
      excludedSources: excludedSources,
    );
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    upserted.add(event);
    final externalId = event.externalId;
    if (externalId != null && externalId.trim().isNotEmpty) {
      externalIdSet.add(externalId);
    }
    return event;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    updated.add(event);
    final index = events.indexWhere((existing) => existing.id == event.id);
    if (index >= 0) {
      events[index] = event;
    }
    return event;
  }

  @override
  Future<EventModel> upsertEvent(EventModel event) async {
    upserted.add(event);
    return event;
  }

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) async {
    upserted.add(event);
    final externalId = event.externalId;
    if (externalId != null && externalId.trim().isNotEmpty) {
      externalIdSet.add(externalId);
    }
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedIds.add(eventId);
    events.removeWhere((event) => event.id == eventId);
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    // existingEvent(fetchEventBySourceExternalId 픽스처)도 인덱스에 포함
    final seededExisting = existingEvent;
    final all = <EventModel>[
      ...events,
      if (seededExisting != null &&
          !events.any((e) => e.id == seededExisting.id))
        seededExisting,
    ];
    return all
        .where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }
}

String _naverCalDavExternalId({
  required String uid,
  required String calendarPath,
}) {
  return NaverCalDavEvent(
    uid: uid,
    href: '$calendarPath$uid.ics',
    etag: '"etag"',
    icsData: '',
    title: 'event',
    startAt: DateTime.utc(2026),
  )
      .toEventModel(
        userId: 'user-1',
        calendarPath: calendarPath,
        syncedAt: DateTime.utc(2026),
      )
      .externalId!;
}

class _FakePropfindClient extends http.BaseClient {
  _FakePropfindClient({
    required this.responses,
    this.bodies = const <String>[],
  });

  final List<int> responses;
  final List<String> bodies;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  var _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final index = _index;
    final statusCode = responses[index.clamp(0, responses.length - 1)];
    final body = bodies.isEmpty
        ? '<multistatus />'
        : bodies[index.clamp(0, bodies.length - 1)];
    _index += 1;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        utf8.encode(body),
      ]),
      statusCode,
    );
  }
}

class _FakeCredentialStore extends NaverCalDavCredentialStore {
  _FakeCredentialStore({
    this.savedId,
    this.savedPassword,
  });

  String? savedId;
  String? savedPassword;
  bool cleared = false;

  @override
  Future<NaverCalDavCredentials?> readCredentials() async {
    final id = savedId;
    final password = savedPassword;
    if (id == null || password == null) {
      return null;
    }
    return NaverCalDavCredentials(naverId: id, appPassword: password);
  }

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

const String _calendarListXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>내 캘린더</d:displayname>
        <cs:getctag>123</cs:getctag>
        <d:resourcetype>
          <d:collection/>
          <c:calendar/>
        </d:resourcetype>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _principalDiscoveryXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:current-user-principal>
          <d:href>/principals/users/tught3/</d:href>
        </d:current-user-principal>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _calendarHomeDiscoveryXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/principals/users/tught3/</d:href>
    <d:propstat>
      <d:prop>
        <c:calendar-home-set>
          <d:href>/calendars/tught3/</d:href>
        </c:calendar-home-set>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _eventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/event-1.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-1"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:naver-event-1
SUMMARY:한강 피크닉
DTSTART;TZID=Asia/Seoul:20260505T100000
DTEND;TZID=Asia/Seoul:20260505T110000
LOCATION:한강
DESCRIPTION:도시락 챙기기
LAST-MODIFIED:20260504T120000Z
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _emptyEventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
</d:multistatus>
''';

const String _zeroDurationEventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/zero-duration-1.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-zero-1"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:zero-duration-1
SUMMARY:범위 시작 일정
DTSTART:20260505T010000Z
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _oldBroadcastEventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/broadcast-2013.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-broadcast-2013"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:broadcast-2013
SUMMARY:[방송]학교 2013
DTSTART;TZID=Asia/Seoul:20130112T220000
DTEND;TZID=Asia/Seoul:20130112T230000
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _personalInRangeEventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/personal-in-range.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-personal-in-range"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:personal-in-range
SUMMARY:Personal in range
DTSTART;TZID=Asia/Seoul:20260508T093000
DTEND;TZID=Asia/Seoul:20260508T103000
LAST-MODIFIED:20260504T120000Z
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _placeholderPersonalEventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/placeholder-personal.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-placeholder-personal"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:placeholder-personal
SUMMARY:Naver placeholder personal
DTSTART:19700101T000000
DTEND;TZID=Asia/Seoul:20260508T093000
LAST-MODIFIED:20260504T120000Z
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _reflectedPlanFlowEventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/planflow-manual-1.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-planflow-manual-1"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:planflow-manual-1@planflow
SUMMARY:원주 출발
DTSTART;TZID=Asia/Seoul:20260508T090000
DTEND;TZID=Asia/Seoul:20260508T100000
LAST-MODIFIED:20260504T120000Z
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _invalidEventReportXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/no-start.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-no-start"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-start
SUMMARY:시작 없는 네이버 일정
DTEND;TZID=Asia/Seoul:20260505T110000
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/calendars/tught3/default/bad-date.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-bad-date"</d:getetag>
        <c:calendar-data><![CDATA[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:bad-date
SUMMARY:이상한 날짜 네이버 일정
DTSTART;TZID=Asia/Seoul:2026-05-05 10:00
DTEND;TZID=Asia/Seoul:20260505T110000
END:VEVENT
END:VCALENDAR
        ]]></c:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _eventListXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/tught3/default/event-1.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-1"</d:getetag>
        <d:getcontenttype>text/calendar; charset=utf-8</d:getcontenttype>
        <d:resourcetype>
          <d:collection/>
          <c:calendar-object/>
        </d:resourcetype>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

const String _eventIcs = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:naver-event-1
SUMMARY:Fallback Event
DTSTART;TZID=Asia/Seoul:20260505T100000
DTEND;TZID=Asia/Seoul:20260505T110000
LOCATION:Seoul
DESCRIPTION:Fallback import
LAST-MODIFIED:20260504T120000Z
END:VEVENT
END:VCALENDAR
''';
