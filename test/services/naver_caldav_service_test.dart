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
    expect(event.startAt, DateTime.utc(2026, 5, 5));
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
    expect(model.externalId, 'naver-caldav:naver-event-1');
    expect(model.externalCalendarId, 'naver-caldav:/calendars/tught3/default/');
    expect(model.externalEtag, '"etag-quick-1"');
    expect(model.externalUpdatedAt, DateTime.utc(2026, 5, 4, 12));
    expect(model.lastSyncedAt, syncedAt);
  });
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
