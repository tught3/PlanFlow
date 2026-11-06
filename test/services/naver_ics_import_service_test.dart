import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/naver_ics_import_service.dart';
import 'package:planflow/services/korean_holidays.dart';

void main() {
  group('NaverIcsImportService', () {
    test('imports a UTF-8 BOM file without retaining the BOM', () async {
      final directory = await Directory.systemTemp.createTemp();
      addTearDown(() => directory.delete(recursive: true));
      final repository = _FakeEventRepository();
      final service = NaverIcsImportService(eventRepository: repository);
      final file = File('${directory.path}${Platform.pathSeparator}bom.ics');
      await file.writeAsBytes(
          <int>[0xef, 0xbb, 0xbf, ...utf8.encode(_sampleIcs(uid: 'bom-uid'))]);

      final result = await service.importFile(file.path, userId: 'user-1');

      expect(result.imported, 1);
      expect(repository.events.single.title, '공임나라 방문');
    });

    test('rejects non-UTF-8 ICS bytes with a safe message', () async {
      final directory = await Directory.systemTemp.createTemp();
      addTearDown(() => directory.delete(recursive: true));
      final repository = _FakeEventRepository();
      final service = NaverIcsImportService(eventRepository: repository);
      final content =
          _sampleIcs(uid: 'bad-encoding').replaceFirst('공임나라 방문', '');
      final summaryKeyIndex = content.indexOf('SUMMARY:');
      expect(summaryKeyIndex, greaterThanOrEqualTo(0));
      final summaryValueStart = summaryKeyIndex + 'SUMMARY:'.length;
      final bytes = <int>[
        ...utf8.encode(content.substring(0, summaryValueStart)),
        0xb0,
        0xa1,
        ...utf8.encode(content.substring(summaryValueStart)),
      ];
      expect(
        utf8.decode(bytes, allowMalformed: true),
        contains('SUMMARY:\uFFFD'),
      );
      final file =
          File('${directory.path}${Platform.pathSeparator}invalid.ics');
      await file.writeAsBytes(bytes);

      final result = await service.importFile(file.path, userId: 'user-1');

      expect(result.success, isFalse);
      expect(result.message, naverIcsUnsupportedEncodingMessage);
      expect(repository.createCount, 0);
    });

    test('decodes UTF-8 and rejects UTF-16 BOM bytes', () {
      expect(decodeIcsBytes(<int>[0xff, 0xfe, 0x41, 0]), isNull);
      expect(decodeIcsBytes(utf8.encode('ICS text')), 'ICS text');
      expect(
          decodeIcsBytes(<int>[0xef, 0xbb, 0xbf, ...utf8.encode('ICS text')]),
          'ICS text');
    });

    test('keeps the missing-file failure message', () async {
      final service =
          NaverIcsImportService(eventRepository: _FakeEventRepository());
      final result = await service
          .importFile('missing-${DateTime.now().microsecondsSinceEpoch}.ics');
      expect(result.message, 'ICS 파일을 찾지 못했습니다.');
    });

    test('merge preserves a failure message when no events were imported', () {
      const seed =
          NaverIcsImportResult(success: false, message: '아직 가져온 일정이 없습니다.');
      final failure = seed.merge(const NaverIcsImportResult.failure(
          message: naverIcsUnsupportedEncodingMessage));
      expect(failure.message, naverIcsUnsupportedEncodingMessage);
      expect(failure.success, isFalse);
      expect(
          seed
              .merge(const NaverIcsImportResult(
                  success: true, message: 'x', imported: 2, total: 2))
              .message,
          '네이버 ICS에서 2개를 가져왔어요. 중복 0개는 건너뛰었습니다.');
    });

    test('merge reports failed files after a partial import', () {
      const seed =
          NaverIcsImportResult(success: false, message: '아직 가져온 일정이 없습니다.');
      const encFail = NaverIcsImportResult.failure(
          message: naverIcsUnsupportedEncodingMessage);
      const imported = NaverIcsImportResult(
          success: true, message: 'x', imported: 2, total: 2);
      const expected =
          '네이버 ICS에서 2개를 가져왔어요. 중복 0개는 건너뛰었습니다. 파일 1개는 가져오지 못했습니다.';

      final failureFirst = seed.merge(encFail).merge(imported);
      final successFirst = seed.merge(imported).merge(encFail);

      expect(failureFirst.message, expected);
      expect(failureFirst.success, isTrue);
      expect(failureFirst.failed, 0);
      expect(successFirst.message, expected);
      expect(successFirst.success, isTrue);
      expect(successFirst.failed, 0);
    });

    test('merge appends failed files after event save failures', () {
      const seed =
          NaverIcsImportResult(success: false, message: '아직 가져온 일정이 없습니다.');
      const encFail = NaverIcsImportResult.failure(
          message: naverIcsUnsupportedEncodingMessage);

      final result = seed
          .merge(const NaverIcsImportResult(
              success: true, message: 'x', imported: 1, failed: 2, total: 3))
          .merge(encFail);

      expect(result.message,
          '네이버 ICS에서 1개를 가져오고, 0개는 중복이라 건너뛰었어요. 2개는 저장하지 못했습니다. 파일 1개는 가져오지 못했습니다.');
      expect(result.failed, 2);
    });

    test('merge counts a file with no events as a failed file', () {
      const seed =
          NaverIcsImportResult(success: false, message: '아직 가져온 일정이 없습니다.');

      final result = seed
          .merge(const NaverIcsImportResult(
              success: true, message: 'x', imported: 1, total: 1))
          .merge(const NaverIcsImportResult(
              success: false, message: 'ICS 파일에서 가져올 일정을 찾지 못했습니다.'));

      expect(result.message,
          '네이버 ICS에서 1개를 가져왔어요. 중복 0개는 건너뛰었습니다. 파일 1개는 가져오지 못했습니다.');
    });

    test('merge does not count a file whose events failed to save as a failed file',
        () {
      const seed =
          NaverIcsImportResult(success: false, message: '아직 가져온 일정이 없습니다.');

      final result = seed
          .merge(const NaverIcsImportResult(
              success: true, message: 'x', imported: 1, total: 1))
          .merge(const NaverIcsImportResult(
              success: false, message: 'y', failed: 2, total: 2));

      expect(result.message,
          '네이버 ICS에서 1개를 가져오고, 0개는 중복이라 건너뛰었어요. 2개는 저장하지 못했습니다.');
    });

    test('merge counts failed files separately from failed events', () {
      const seed =
          NaverIcsImportResult(success: false, message: '아직 가져온 일정이 없습니다.');
      const encFail = NaverIcsImportResult.failure(
          message: naverIcsUnsupportedEncodingMessage);

      final partial = seed.merge(encFail).merge(const NaverIcsImportResult(
          success: true, message: 'x', imported: 2, total: 2));
      expect(partial.failedFiles, 1);
      expect(partial.failed, 0);

      final allFailed = seed.merge(encFail).merge(
          const NaverIcsImportResult.failure(message: naverIcsReadFailedMessage));
      expect(allFailed.message, naverIcsReadFailedMessage);
      expect(allFailed.failedFiles, 2);
      expect(allFailed.success, isFalse);
    });

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
      expect(planflowLocal(events.single.startAt).year, 2026);
      expect(planflowLocal(events.single.startAt).month, 5);
      expect(planflowLocal(events.single.startAt).day, 6);
      expect(planflowLocal(events.single.startAt).hour, 11);
    });

    test('skips suspicious or invalid ICS dates before import', () {
      final service = NaverIcsImportService(
        eventRepository: _FakeEventRepository(),
      );

      final suspicious = service.parseEvents(_sampleIcsWithDate(
        uid: 'suspicious-uid',
        startLine: 'DTSTART:19700101T000000Z',
        endLine: 'DTEND:19700101T010000Z',
      ));

      final invalidEnd = service.parseEvents(_sampleIcsWithDate(
        uid: 'invalid-end-uid',
        startLine: 'DTSTART;TZID=Asia/Seoul:20260506T110000',
        endLine: 'DTEND;TZID=Asia/Seoul:20260506T250000',
      ));

      expect(suspicious, isEmpty);
      expect(invalidEnd, isEmpty);
    });

    test('treats floating ICS times as Asia Seoul wall time', () {
      final service = NaverIcsImportService(
        eventRepository: _FakeEventRepository(),
      );

      final events = service.parseEvents(_sampleIcsWithDate(
        uid: 'floating-ics',
        startLine: 'DTSTART:20260505T003000',
        endLine: 'DTEND:20260505T013000',
      ));

      expect(events, hasLength(1));
      expect(events.single.startAt, DateTime.utc(2026, 5, 4, 15, 30));
      expect(planflowLocal(events.single.startAt).day, 5);
      expect(planflowLocal(events.single.startAt).hour, 0);
    });

    test('marks date-only events all-day with exclusive end dates', () {
      final service = NaverIcsImportService(
        eventRepository: _FakeEventRepository(),
      );

      final singleDay = service
          .parseEvents(_sampleIcsWithDate(
            uid: 'single-day',
            startLine: 'DTSTART;VALUE=DATE:20260815',
            endLine: 'DTEND;VALUE=DATE:20260816',
          ))
          .single;
      final threeDays = service
          .parseEvents(_sampleIcsWithDate(
            uid: 'three-days',
            startLine: 'DTSTART;VALUE=DATE:20260815',
            endLine: 'DTEND;VALUE=DATE:20260818',
          ))
          .single;
      final noEnd = service
          .parseEvents(_sampleIcsWithDate(
            uid: 'no-end',
            startLine: 'DTSTART:20260815',
            endLine: '',
          ))
          .single;
      final sameEnd = service
          .parseEvents(_sampleIcsWithDate(
            uid: 'same-end',
            startLine: 'DTSTART:20260815',
            endLine: 'DTEND:20260815',
          ))
          .single;
      final dateTime = service
          .parseEvents(_sampleIcsWithDate(
            uid: 'date-time',
            startLine: 'DTSTART;VALUE=DATE-TIME:20260815T100000',
            endLine: 'DTEND;VALUE=DATE-TIME:20260816T110000',
          ))
          .single;

      expect(singleDay.isAllDay, isTrue);
      expect(singleDay.isMultiDay, isFalse);
      expect(singleDay.startAt, DateTime.utc(2026, 8, 14, 15));
      expect(singleDay.endAt, DateTime.utc(2026, 8, 15, 15));
      expect(threeDays.isAllDay, isTrue);
      expect(threeDays.isMultiDay, isTrue);
      expect(threeDays.endAt, DateTime.utc(2026, 8, 17, 15));
      expect(noEnd.isAllDay, isTrue);
      expect(noEnd.endAt, DateTime.utc(2026, 8, 15, 15));
      expect(noEnd.isMultiDay, isFalse);
      expect(sameEnd.endAt, DateTime.utc(2026, 8, 15, 15));
      expect(dateTime.isAllDay, isFalse);
      expect(dateTime.isMultiDay, isFalse);
    });

    test('marks important ICS buckets as critical', () {
      final service = NaverIcsImportService(
        eventRepository: _FakeEventRepository(),
      );

      final events = service.parseEvents('''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:important-ics
SUMMARY:VIP 상담
DTSTART;TZID=Asia/Seoul:20260506T110000
DTEND;TZID=Asia/Seoul:20260506T113000
PRIORITY:1
CATEGORIES:Important,네이버 예약
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
''');

      expect(events, hasLength(1));
      expect(events.single.isCritical, isTrue);
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

    test('persists all-day flags on imported events', () async {
      final repository = _FakeEventRepository();
      final service = NaverIcsImportService(eventRepository: repository);

      final result = await service.importContent(
        _sampleIcsWithDate(
          uid: 'persisted-all-day',
          startLine: 'DTSTART;VALUE=DATE:20260815',
          endLine: 'DTEND;VALUE=DATE:20260818',
        ),
        userId: 'user-1',
      );

      expect(result.imported, 1);
      expect(repository.events.single.isAllDay, isTrue);
      expect(repository.events.single.isMultiDay, isTrue);
    });

    test('skips canonical public holidays but keeps personal events', () async {
      KoreanHolidays.applyLiveData(2026, {(8, 15): '광복절'});
      final repository = _FakeEventRepository();
      final service = NaverIcsImportService(
        eventRepository: repository,
        now: () => DateTime.utc(2026, 8, 15),
      );

      final result = await service.importContent('''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:holiday-ics
SUMMARY:광복절
DTSTART;TZID=Asia/Seoul:20260815T000000
DTEND;TZID=Asia/Seoul:20260815T010000
END:VEVENT
BEGIN:VEVENT
UID:personal-holiday-ics
SUMMARY:광복절 행사
DTSTART;TZID=Asia/Seoul:20260815T100000
DTEND;TZID=Asia/Seoul:20260815T110000
END:VEVENT
END:VCALENDAR
''', userId: 'user-1');

      expect(result.imported, 1);
      expect(result.skipped, 1);
      expect(repository.events, hasLength(1));
      expect(repository.events.single.title, '광복절 행사');
    });

    test('deletes suspicious imported rows before re-importing', () async {
      final repository = _FakeEventRepository(
        events: <EventModel>[
          EventModel(
            id: 'bad-1',
            userId: 'user-1',
            title: 'Bad imported event',
            startAt: DateTime.utc(1969, 12, 31, 15),
            source: 'naver_ics',
          ),
        ],
      );
      final service = NaverIcsImportService(
        eventRepository: repository,
      );

      final result = await service.importContent(
        _sampleIcs(uid: 'stable-uid'),
        userId: 'user-1',
      );

      expect(result.success, isTrue);
      expect(repository.deletedIds, contains('bad-1'));
      expect(repository.events.any((event) => event.id == 'bad-1'), isFalse);
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

String _sampleIcsWithDate({
  required String? uid,
  required String startLine,
  required String endLine,
}) {
  return '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//NAVER Calendar//PlanFlow Test//KO
BEGIN:VEVENT
${uid == null ? '' : 'UID:$uid'}
SUMMARY:Test event
$startLine
$endLine
LOCATION:Seoul
DESCRIPTION:Test description
LAST-MODIFIED:20260505T120000Z
END:VEVENT
END:VCALENDAR
''';
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({List<EventModel> events = const <EventModel>[]})
      : events = List<EventModel>.from(events);

  final List<EventModel> events;
  final List<String> deletedIds = <String>[];
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
      isAllDay: event.isAllDay,
      isMultiDay: event.isMultiDay,
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
    deletedIds.add(eventId);
    events.removeWhere((event) => event.id == eventId);
    return Future<void>.value();
  }
}
