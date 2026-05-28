import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/device_calendar_service.dart';

void main() {
  test('detects Naver calendars by Korean and English names', () {
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(),
      eventRepository: _FakeEventRepository(),
      currentUserId: 'user-1',
    );

    final calendars = <DeviceCalendarInfo>[
      const DeviceCalendarInfo(id: '1', displayName: '개인 캘린더'),
      const DeviceCalendarInfo(id: '2', displayName: 'NAVER Calendar'),
      const DeviceCalendarInfo(id: '3', accountName: '네이버 일정'),
    ];

    expect(service.findNaverCalendars(calendars).map((item) => item.id), [
      '2',
      '3',
    ]);
  });

  test('imports Android Naver calendar events with stable external ids',
      () async {
    final repository = _FakeEventRepository();
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {
            'id': '7',
            'displayName': '네이버 캘린더',
            'accountName': 'tught3@naver.com',
          },
        ],
        events: [
          {
            'eventId': '42',
            'calendarId': '7',
            'title': '서초 미팅',
            'location': '서초',
            'description': '자료 챙기기',
            'beginMillis': DateTime(2026, 5, 6, 10).millisecondsSinceEpoch,
            'endMillis': DateTime(2026, 5, 6, 11).millisecondsSinceEpoch,
            'lastDateMillis': DateTime(2026, 5, 5, 9).millisecondsSinceEpoch,
          },
        ],
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.imported);
    expect(result.importedCount, 1);
    expect(result.message, '휴대폰 내부 캘린더 일정 1개를 PlanFlow로 가져왔습니다.');
    expect(repository.upserted, hasLength(1));
    expect(repository.upserted.single.source, 'naver_device');
    expect(repository.upserted.single.externalId, 'android:7:42');
    expect(repository.upserted.single.externalCalendarId, 'android:7');
    expect(repository.upserted.single.title, '서초 미팅');
  });

  test('marks events from Naver booking calendar as critical', () async {
    final repository = _FakeEventRepository();
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {
            'id': '7',
            'displayName': '네이버 예약',
            'accountName': 'tught3@naver.com',
          },
        ],
        events: [
          {
            'eventId': 'booking-1',
            'calendarId': '7',
            'title': '강릉 건도리횟집',
            'beginMillis': DateTime(2026, 5, 6, 18).millisecondsSinceEpoch,
          },
        ],
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.imported);
    expect(repository.upserted.single.isCritical, isTrue);
  });

  test('imports Android all-day holidays on the same local date', () async {
    final repository = _FakeEventRepository();
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {
            'id': '7',
            'displayName': '네이버 캘린더',
            'accountName': 'tught3@naver.com',
          },
        ],
        events: [
          {
            'eventId': 'memorial-day',
            'calendarId': '7',
            'title': '현충일',
            'beginMillis': DateTime.utc(2026, 6, 6).millisecondsSinceEpoch,
            'endMillis': DateTime.utc(2026, 6, 7).millisecondsSinceEpoch,
            'allDay': true,
          },
          {
            'eventId': 'liberation-day',
            'calendarId': '7',
            'title': '광복절',
            'beginMillis': DateTime.utc(2026, 8, 15).millisecondsSinceEpoch,
            'endMillis': DateTime.utc(2026, 8, 16).millisecondsSinceEpoch,
            'allDay': true,
          },
        ],
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.imported);
    final byTitle = <String, EventModel>{
      for (final event in repository.upserted) event.title: event,
    };
    expect(byTitle['현충일']!.isAllDay, isTrue);
    expect(byTitle['현충일']!.startAt, DateTime.utc(2026, 6, 5, 15));
    expect(byTitle['현충일']!.endAt, DateTime.utc(2026, 6, 6, 15));
    expect(byTitle['광복절']!.isAllDay, isTrue);
    expect(byTitle['광복절']!.startAt, DateTime.utc(2026, 8, 14, 15));
    expect(byTitle['광복절']!.endAt, DateTime.utc(2026, 8, 15, 15));
  });

  test('links reflected device calendar duplicate instead of inserting',
      () async {
    final repository = _FakeEventRepository(
      seedEvents: <EventModel>[
        EventModel(
          id: 'manual-1',
          userId: 'user-1',
          title: 'Team meeting',
          startAt: DateTime(2026, 5, 6, 10),
          participants: const <String>['leader'],
          targets: const <String>['director'],
        ),
      ],
    );
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {
            'id': '7',
            'displayName': 'Naver Calendar',
            'accountName': 'tught3@naver.com',
          },
        ],
        events: [
          {
            'eventId': '42',
            'calendarId': '7',
            'title': 'Team meeting',
            'beginMillis': DateTime(2026, 5, 6, 10).millisecondsSinceEpoch,
            'endMillis': DateTime(2026, 5, 6, 11).millisecondsSinceEpoch,
            'lastDateMillis': DateTime(2026, 5, 5, 9).millisecondsSinceEpoch,
          },
        ],
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.imported);
    expect(result.importedCount, 0);
    expect(repository.updated, hasLength(1));
    expect(repository.updated.single.id, 'manual-1');
    expect(repository.updated.single.externalId, 'android:7:42');
    expect(repository.updated.single.externalCalendarId, 'android:7');
    expect(repository.updated.single.participants, <String>['leader']);
    expect(repository.updated.single.targets, <String>['director']);
  });

  test('keeps people fields when reflected device calendar sync relinks',
      () async {
    final repository = _FakeEventRepository(
      seedEvents: <EventModel>[
        EventModel(
          id: 'manual-1',
          userId: 'user-1',
          title: 'Team meeting',
          startAt: DateTime(2026, 5, 6, 10),
          participants: const <String>['leader'],
          targets: const <String>['director'],
        ),
      ],
    );
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {
            'id': '7',
            'displayName': 'Naver Calendar',
            'accountName': 'tught3@naver.com',
          },
        ],
        events: [
          {
            'eventId': '42',
            'calendarId': '7',
            'title': 'Team meeting',
            'beginMillis': DateTime(2026, 5, 6, 10).millisecondsSinceEpoch,
            'endMillis': DateTime(2026, 5, 6, 11).millisecondsSinceEpoch,
            'lastDateMillis': DateTime(2026, 5, 5, 9).millisecondsSinceEpoch,
          },
        ],
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.imported);
    expect(result.importedCount, 0);
    expect(repository.updated, hasLength(1));
    expect(repository.updated.single.participants, <String>['leader']);
    expect(repository.updated.single.targets, <String>['director']);
  });

  test('skips reflected PlanFlow device calendar event by event key', () async {
    final repository = _FakeEventRepository(
      seedEvents: <EventModel>[
        EventModel(
          id: 'manual-1',
          userId: 'user-1',
          title: '서초 미팅',
          startAt: DateTime(2026, 5, 6, 10),
        ),
      ],
    );
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {
            'id': '7',
            'displayName': '네이버 캘린더',
            'accountName': 'tught3@naver.com',
          },
        ],
        events: [
          {
            'eventId': '42',
            'calendarId': '7',
            'eventKey': 'planflow:manual-1',
            'title': '서초 미팅',
            'beginMillis': DateTime(2026, 5, 6, 10).millisecondsSinceEpoch,
            'endMillis': DateTime(2026, 5, 6, 11).millisecondsSinceEpoch,
          },
        ],
      ),
      eventRepository: repository,
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.imported);
    expect(result.importedCount, 0);
    expect(repository.upserted, hasLength(1));
  });

  test('device calendar export gateway only writes events', () async {
    final gateway = _FakeDeviceCalendarGateway();
    final service = DeviceCalendarService(
      gateway: gateway,
      eventRepository: _FakeEventRepository(),
      currentUserId: 'user-1',
    );

    final exported = await service.exportEvent(
      EventModel(
        id: 'manual-1',
        userId: 'user-1',
        title: '외부 앱 알림 없이 보낼 일정',
        startAt: DateTime(2026, 5, 6, 10),
        isCritical: true,
      ),
    );

    expect(exported, isTrue);
    expect(gateway.exportedEvents, hasLength(1));
  });

  test('Android native device export keeps event-only policy', () {
    final nativeFile = File(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    );
    final source = nativeFile.readAsStringSync();
    final upsertStart = source.indexOf('private fun upsertDeviceCalendarEvent');
    final nextFunction = source.indexOf('\n    private fun ', upsertStart + 1);
    final upsertBody = source.substring(
      upsertStart,
      nextFunction == -1 ? source.length : nextFunction,
    );

    expect(upsertBody, contains('CalendarContract.Events.CONTENT_URI'));
    expect(upsertBody, contains('CalendarContract.Events.UID_2445'));
    expect(upsertBody, isNot(contains('CalendarContract.Reminders')));
  });

  test('returns distinct failure when calendar permission is denied', () async {
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(permissionGranted: false),
      eventRepository: _FakeEventRepository(),
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.permissionDenied);
    expect(
      result.message,
      '기기 캘린더 권한이 필요합니다. Android 앱 설정에서 캘린더 권한을 허용해 주세요.',
    );
  });

  test('returns distinct failure when no Naver calendar is found', () async {
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {'id': '1', 'displayName': 'Samsung Calendar'},
        ],
      ),
      eventRepository: _FakeEventRepository(),
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.noNaverCalendars);
    expect(result.calendars.single.label, 'Samsung Calendar');
    expect(
      result.message,
      contains('휴대폰 캘린더 저장소에서 내부 캘린더를 찾지 못했습니다.'),
    );
  });

  test('returns distinct failure when Naver calendar has no events', () async {
    final service = DeviceCalendarService(
      gateway: _FakeDeviceCalendarGateway(
        calendars: [
          {'id': '2', 'displayName': 'Naver Calendar'},
        ],
        events: const [],
      ),
      eventRepository: _FakeEventRepository(),
      currentUserId: 'user-1',
    );

    final result = await service.importNaverEvents();

    expect(result.status, DeviceCalendarImportStatus.noEvents);
    expect(result.message, contains('휴대폰 내부 캘린더는 보이지만 가져올 일정이 없습니다.'));
    expect(result.message, contains('Naver Calendar'));
  });
}

class _FakeDeviceCalendarGateway implements DeviceCalendarGateway {
  _FakeDeviceCalendarGateway({
    this.permissionGranted = true,
    this.calendars = const [],
    this.events = const [],
  });

  final bool permissionGranted;
  final List<Map<Object?, Object?>> calendars;
  final List<Map<Object?, Object?>> events;
  final List<EventModel> exportedEvents = <EventModel>[];

  @override
  Future<bool> checkCalendarPermission() async => permissionGranted;

  @override
  Future<bool> requestCalendarPermission() async => permissionGranted;

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendars() async => calendars;

  @override
  Future<List<Map<Object?, Object?>>> listDeviceCalendarEvents({
    required List<String> calendarIds,
    required DateTime startAt,
    required DateTime endAt,
  }) async {
    return events
        .where((event) => calendarIds.contains(event['calendarId'].toString()))
        .toList(growable: false);
  }

  @override
  Future<bool> upsertDeviceCalendarEvent(EventModel event) async {
    exportedEvents.add(event);
    return true;
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository({List<EventModel> seedEvents = const <EventModel>[]})
      : upserted = List<EventModel>.from(seedEvents);

  final List<EventModel> upserted;
  final List<EventModel> updated = <EventModel>[];

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in upserted) {
      if (event.id == eventId && (userId == null || event.userId == userId)) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => upserted;

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    updated.add(event);
    final index = upserted.indexWhere((existing) => existing.id == event.id);
    if (index >= 0) {
      upserted[index] = event;
    }
    return event;
  }

  @override
  Future<EventModel> upsertEventBySourceExternalId(EventModel event) async {
    upserted.removeWhere(
      (existing) =>
          existing.source == event.source &&
          existing.externalId == event.externalId,
    );
    upserted.add(event);
    return event;
  }
}
