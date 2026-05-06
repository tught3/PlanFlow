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
  Future<bool> upsertDeviceCalendarEvent(EventModel event) async => true;
}

class _FakeEventRepository extends EventRepository {
  final List<EventModel> upserted = <EventModel>[];

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return null;
  }

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => upserted;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;

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
