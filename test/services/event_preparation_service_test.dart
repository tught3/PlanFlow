import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/event_preparation_service.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/map_service.dart';
import 'package:planflow/services/travel_time_buffer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // [PREVENT] 유령 장소 주입 회귀 방지 (2026-07-16).
  // 실증 버그: 사용자가 장소를 말하지 않고 "회의" 같은 일정을 저장하면, 저장 후
  // 백그라운드로 실행되는 _ensureLocationCoordinates가 event.location이 비어
  // 있으니 event.title/event.memo를 대신 장소 검색어로 써서(과거 로직) 현재 GPS
  // 근접 편향으로 뽑힌 무관한 POI(예: "성남 청년회의소")를 개인 일정 location에
  // 기록했다(팀일정은 이 경로를 안 타 정상). 이제는 event.location이 비어있으면
  // 좌표 해석 자체를 하지 않아야 하며, title에 실제 장소명이 포함돼 있어도
  // (mock LocationLookupService가 그 title과 부분일치하는 결과를 반환하더라도)
  // location이 채워지거나 updateEvent가 호출되면 안 된다.
  test(
      'prepareAfterSave does NOT geocode from title/memo when location is '
      'missing (ghost location injection prevention)', () async {
    final repository = _FakeEventRepository();
    final lookup = _FakeLocationLookupService(
      result: const LocationLookupResult(
        name: '성남 청년회의소',
        address: 'Gyeonggi-do Seongnam-si',
        latitude: 37.4201,
        longitude: 127.1261,
      ),
    );
    final service = EventPreparationService(
      eventRepository: repository,
      locationLookupService: lookup,
      departureAlarmService: _FakeDepartureAlarmService(),
      travelTimeBufferService: _FakeTravelTimeBufferService(),
    );

    final result = await service.prepareAfterSave(
      EventModel(
        id: 'title-only-event',
        userId: 'user-1',
        title: '회의',
        startAt: DateTime(2026, 5, 8, 10),
        // location: null — 사용자가 장소를 적지 않음
      ),
    );

    expect(
      lookup.searchQueries,
      isEmpty,
      reason: 'location이 비어있으면 title/memo를 장소 검색어로 쓰면 안 됩니다. '
          '좌표 해석 자체를 시도하지 않아야 합니다.',
    );
    expect(result.locationResolved, false);
    expect(
      repository.updatedEvents,
      isEmpty,
      reason: 'location이 비어있는 이벤트에 유령 장소를 기록하면 안 됩니다.',
    );
    expect(result.event.location, isNull);
    expect(result.event.locationLat, isNull);
    expect(result.event.locationLng, isNull);
  });

  test('prepareAfterSave geocodes coordinates using event.location text only',
      () async {
    final repository = _FakeEventRepository();
    final lookup = _FakeLocationLookupService(
      result: const LocationLookupResult(
        name: 'Wonju Severance Christian Hospital',
        address: 'Gangwon-do Wonju-si',
        latitude: 37.3421,
        longitude: 127.9421,
      ),
    );
    final service = EventPreparationService(
      eventRepository: repository,
      locationLookupService: lookup,
      departureAlarmService: _FakeDepartureAlarmService(),
      travelTimeBufferService: _FakeTravelTimeBufferService(),
    );

    final result = await service.prepareAfterSave(
      EventModel(
        id: 'location-event',
        userId: 'user-1',
        title: '회의',
        location: 'Wonju Severance Christian Hospital',
        memo: 'Totally unrelated memo text',
        startAt: DateTime(2026, 5, 8, 10),
      ),
    );

    expect(
      lookup.searchQueries,
      <String>['Wonju Severance Christian Hospital'],
      reason: 'title/memo는 검색 쿼리로 전달되면 안 되고, location 텍스트만 써야 합니다.',
    );
    expect(result.locationResolved, true);
    expect(repository.updatedEvents, hasLength(1));
    expect(repository.updatedEvents.single.locationLat, 37.3421);
    expect(repository.updatedEvents.single.locationLng, 127.9421);
    // 사용자가 적은 location 원문은 유지되고(POI 공식명으로 덮어쓰지 않음).
    expect(
      repository.updatedEvents.single.location,
      'Wonju Severance Christian Hospital',
    );
  });

  test('prepareAfterSave forwards safety margin override to departure alarm',
      () async {
    final repository = _FakeEventRepository();
    final lookup = _FakeLocationLookupService(
      result: const LocationLookupResult(
        name: 'Wonju Severance Christian Hospital',
        address: 'Gangwon-do Wonju-si',
        latitude: 37.3421,
        longitude: 127.9421,
      ),
    );
    final departure = _FakeDepartureAlarmService();
    final service = EventPreparationService(
      eventRepository: repository,
      locationLookupService: lookup,
      departureAlarmService: departure,
      travelTimeBufferService: _FakeTravelTimeBufferService(),
    );

    await service.prepareAfterSave(
      EventModel(
        id: 'title-only-event',
        userId: 'user-1',
        title: 'Wonju Severance Christian Hospital visit',
        startAt: DateTime(2026, 5, 8, 10),
      ),
      departureSafetyMargin: const Duration(minutes: 27),
    );

    expect(departure.lastSafetyMarginOverride, const Duration(minutes: 27));
  });

  // [PREVENT] 백그라운드 알람 재계산에서 TMAP POI 검색 금지 회귀 테스트
  // 실증: 좌표 없는 일정에 대해 백그라운드 동기화(calendar_auto_sync)가 매번
  // _ensureLocationCoordinates → _locations.search(TMAP POI)를 호출하고, 해석
  // 실패 시 좌표를 저장하지 않아 다음 동기화에서 또 검색 → POI API 하루 16,000회+
  // 폭주 → 삼성 네트워크/CPU excessive kill로 앱 종료 → 알람 미발생.
  // resolveCoordinates: false이면 POI 검색을 0회 호출해야 한다.
  test(
      'prepareAfterSave with resolveCoordinates:false does NOT call POI search',
      () async {
    final repository = _FakeEventRepository();
    final lookup = _FakeLocationLookupService(
      result: const LocationLookupResult(
        name: 'Wonju Severance Christian Hospital',
        address: 'Gangwon-do Wonju-si',
        latitude: 37.3421,
        longitude: 127.9421,
      ),
    );
    final service = EventPreparationService(
      eventRepository: repository,
      locationLookupService: lookup,
      departureAlarmService: _FakeDepartureAlarmService(),
      travelTimeBufferService: _FakeTravelTimeBufferService(),
    );

    final result = await service.prepareAfterSave(
      EventModel(
        id: 'title-only-event',
        userId: 'user-1',
        title: 'Wonju Severance Christian Hospital visit',
        startAt: DateTime(2026, 5, 8, 10),
        // 좌표 없음 → 평소라면 POI 검색을 트리거하는 일정
      ),
      resolveCoordinates: false,
    );

    expect(
      lookup.searchQueries,
      isEmpty,
      reason: '백그라운드 경로(resolveCoordinates:false)는 TMAP POI 검색을 호출하면 안 됩니다. '
          '좌표 해석은 foreground 사용자 저장에서만 수행되어야 합니다.',
    );
    expect(
      result.locationResolved,
      false,
      reason: 'POI 검색을 건너뛰었으므로 좌표는 해석되지 않아야 합니다.',
    );
    expect(
      repository.updatedEvents,
      isEmpty,
      reason: 'POI 검색 없이 일정 좌표를 업데이트하면 안 됩니다.',
    );
  });

  // [PREVENT] 이벤트 1건의 좌표 미해결 검색이 tmap POI 레이트리밋(60/60s)을
  // 혼자 잡아먹는 폭주 회귀 테스트 (2026-07-04, 2026-07-16 갱신).
  // 과거: location/title/memo가 전부 다른 텍스트인 일정을 저장하면
  // _buildDestinationSearchQueries가 최대 6개 쿼리(단독 3 + 조합 3)를 만들어
  // 이벤트 1건 저장만으로 tmap POI가 최대 36콜까지 치솟았다(2026-07-04 실측:
  // window_count=60 폭주 신고). 2026-07-16 유령 장소 주입 수정으로 title/memo가
  // 검색 쿼리에서 완전히 제거되어, 이제 이 함수는 location 단독 쿼리 1개만
  // 만든다 — _maxDestinationQueries=3 캡은 여전히 방어선으로 남지만(레이스에
  // 안전), title/memo발 조합 폭발 자체가 구조적으로 불가능해졌다.
  test(
      'prepareAfterSave never queries title/memo text even when all are '
      'distinct (rate-limit storm prevention + ghost location prevention)',
      () async {
    final repository = _FakeEventRepository();
    final lookup = _FakeLocationLookupService(
      result: const LocationLookupResult(
        name: '', // 사용하지 않음 — search()가 항상 빈 리스트를 반환하도록 override
        address: '',
        latitude: 0,
        longitude: 0,
      ),
      alwaysEmpty: true,
    );
    final service = EventPreparationService(
      eventRepository: repository,
      locationLookupService: lookup,
      departureAlarmService: _FakeDepartureAlarmService(),
      travelTimeBufferService: _FakeTravelTimeBufferService(),
    );

    await service.prepareAfterSave(
      EventModel(
        id: 'unresolvable-event',
        userId: 'user-1',
        title: 'Totally Unrelated Title Text',
        location: 'Totally Unrelated Location Text',
        memo: 'Totally Unrelated Memo Text',
        startAt: DateTime(2026, 5, 8, 10),
      ),
    );

    expect(
      lookup.searchQueries.length,
      lessThanOrEqualTo(3),
      reason: '목적지 쿼리는 최대 3개(_maxDestinationQueries) 캡을 넘으면 안 된다.',
    );
    expect(
      lookup.searchQueries,
      <String>['Totally Unrelated Location Text'],
      reason: 'location만 쿼리로 쓰여야 하며, title/memo 및 이들의 조합 쿼리는 '
          '전혀 시도되면 안 된다.',
    );
    expect(
      lookup.searchQueries,
      isNot(contains('Totally Unrelated Title Text')),
    );
    expect(
      lookup.searchQueries,
      isNot(contains('Totally Unrelated Memo Text')),
    );
    expect(
      lookup.searchQueries,
      isNot(
          contains('Totally Unrelated Location Text Totally Unrelated Title Text')),
    );
  });
}

class _FakeLocationLookupService extends LocationLookupService {
  _FakeLocationLookupService({required this.result, this.alwaysEmpty = false});

  final LocationLookupResult result;
  final bool alwaysEmpty;
  final searchQueries = <String>[];

  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    searchQueries.add(query);
    if (alwaysEmpty) {
      return const <LocationLookupResult>[];
    }
    return <LocationLookupResult>[result];
  }
}

class _FakeEventRepository extends EventRepository {
  final updatedEvents = <EventModel>[];

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async =>
      const <EventModel>[];

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    updatedEvents.add(event);
    return event;
  }
}

class _FakeTravelTimeBufferService extends TravelTimeBufferService {}

class _FakeDepartureAlarmService extends DepartureAlarmService {
  Duration? lastSafetyMarginOverride;

  @override
  Future<DepartureAlarmScheduleResult> scheduleForEvent(
    EventModel event, {
    bool rescheduleMonitor = true,
    Duration? safetyMarginOverride,
    MapTravelMode? travelModeOverride,
    bool fireDueDeparture = false,
    bool cacheOnlyLocation = false,
  }) async {
    lastSafetyMarginOverride = safetyMarginOverride;
    return DepartureAlarmScheduleResult.scheduled(
      notifyAt: DateTime(2026, 5, 8, 8),
      travelMinutes: 30,
    );
  }
}
