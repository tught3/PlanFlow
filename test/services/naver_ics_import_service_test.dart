import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/naver_ics_import_service.dart';

void main() {
  group('NaverIcsImportService', () {
    test('parses ICS event fields into a PlanFlow event draft', () {
      final service = NaverIcsImportService(
        eventRepository: _FakeEventRepository(),
      );

      final events = service.parseEvents(_sampleIcs(uid: 'naver-1'));

      expect(events, hasLength(1));
      expect(events.single.uid, 'naver-1');
      expect(events.single.title, '공임나라 방문');
      expect(events.single.location, '대전');
      expect(events.single.description, '엔진오일 교체');
      expect(events.single.startAt.toLocal().year, 2026);
      expect(events.single.startAt.toLocal().month, 5);
      expect(events.single.startAt.toLocal().day, 6);
      expect(events.single.startAt.toLocal().hour, 11);
    });

    test('imports ICS events and uses UID based stable external id', () async {
      final repository = _FakeEventRepository();
      final service = NaverIcsImportService(
        eventRepository: repository,
        now: () => DateTime.utc(2026, 5, 6, 0),
      );

      final result = await service.importContent(
        _sampleIcs(uid: 'stable-uid'),
        userId: 'user-1',
      );

      expect(result.success, isTrue);
      expect(result.imported, 1);
      expect(repository.events.single.source, 'naver_ics');
      expect(repository.events.single.externalId, 'naver-ics:uid:stable-uid');
    });

    test('skips duplicate events by same local date and title', () async {
      final repository = _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'existing-1',
            userId: 'user-1',
            title: '공임나라 방문',
            startAt: DateTime(2026, 5, 6, 9),
          ),
        ],
      );
      final service = NaverIcsImportService(eventRepository: repository);

      final result = await service.importContent(
        _sampleIcs(uid: 'other-uid'),
        userId: 'user-1',
      );

      expect(result.imported, 0);
      expect(result.skipped, 1);
      expect(repository.createCount, 0);
    });

    test('builds a stable date-title external id when UID is missing', () {
      final service = NaverIcsImportService(
        eventRepository: _FakeEventRepository(),
      );

      final first = service.parseEvents(_sampleIcs(uid: null)).single;
      final second = service.parseEvents(_sampleIcs(uid: null)).single;

      expect(first.externalId, startsWith('naver-ics:date-title:'));
      expect(first.externalId, second.externalId);
    });
  });
}

String _sampleIcs({required String? uid}) {
  return '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//NAVER Calendar//PlanFlow Test//KO
BEGIN:VEVENT
${uid == null ? '' : 'UID:$uid'}
SUMMARY:공임나라 방문
DTSTART;TZID=Asia/Seoul:20260506T110000
DTEND;TZID=Asia/Seoul:20260506T113000
LOCATION:대전
DESCRIPTION:엔진오일 교체
LAST-MODIFIED:20260505T120000Z
END:VEVENT
END:VCALENDAR
''';
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({List<EventModel> events = const <EventModel>[]})
      : events = List<EventModel>.from(events);

  final List<EventModel> events;
  int createCount = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    return events
        .where((event) => userId == null || event.userId == userId)
        .toList(growable: false);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return events
        .where((event) => event.id == eventId)
        .cast<EventModel?>()
        .firstOrNull;
  }

  @override
  Future<EventModel?> fetchEventBySourceExternalId({
    required String source,
    required String externalId,
    String? userId,
  }) async {
    return events
        .where(
          (event) =>
              event.source == source &&
              event.externalId == externalId &&
              (userId == null || event.userId == userId),
        )
        .cast<EventModel?>()
        .firstOrNull;
  }

  @override
  Future<EventModel> createEvent(EventModel event) async {
    createCount += 1;
    final saved = EventModel(
      id: 'event-${events.length + 1}',
      userId: event.userId,
      title: event.title,
      startAt: event.startAt,
      endAt: event.endAt,
      location: event.location,
      memo: event.memo,
      source: event.source,
      externalId: event.externalId,
      externalCalendarId: event.externalCalendarId,
      externalEtag: event.externalEtag,
      externalUpdatedAt: event.externalUpdatedAt,
      lastSyncedAt: event.lastSyncedAt,
    );
    events.add(saved);
    return saved;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnimplementedError();
  }
}
