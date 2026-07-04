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

  test('prepareAfterSave geocodes title text when location is missing',
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
      ),
    );

    expect(
        lookup.searchQueries.first, 'Wonju Severance Christian Hospital visit');
    expect(result.locationResolved, true);
    expect(repository.updatedEvents, hasLength(1));
    expect(repository.updatedEvents.single.locationLat, 37.3421);
    expect(repository.updatedEvents.single.locationLng, 127.9421);
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
  // 혼자 잡아먹는 폭주 회귀 테스트.
  // 실증: location/title/memo가 전부 다른 텍스트인 일정을 저장하면
  // _buildDestinationSearchQueries가 최대 6개 쿼리(단독 3 + 조합 3)를 만들고,
  // 전부 미해결이면 쿼리마다 LocationLookupService 내부 fallback이 tmap POI를
  // 최대 6콜씩 써 이벤트 1건 저장만으로 최대 36콜까지 치솟는다(2026-07-04
  // 실측: window_count=60 폭주 신고). _maxDestinationQueries=3 캡으로
  // 단독 쿼리(location/title/memo)까지만 시도하고 조합형 3개는 건너뛰어야 한다.
  test(
      'prepareAfterSave caps destination search queries when all variants '
      'are unresolvable (rate-limit storm prevention)', () async {
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
        // location/title/memo가 전부 달라 _buildDestinationSearchQueries가
        // 6개(단독 3 + 조합 3)의 서로 다른 쿼리를 만들어낸다.
      ),
    );

    expect(
      lookup.searchQueries.length,
      lessThanOrEqualTo(3),
      reason: '목적지 쿼리는 최대 3개(단독 location/title/memo)까지만 시도해야 한다. '
          '조합형 쿼리 3개까지 전부 시도하면 이벤트 1건만으로 tmap POI가 '
          '최대 36콜까지 치솟아 60/60s 레이트리밋을 혼자 소진한다.',
    );
    expect(
      lookup.searchQueries,
      isNot(contains('Totally Unrelated Location Text Totally Unrelated Title Text')),
      reason: '조합형(location+title) 쿼리는 캡을 넘으므로 시도되면 안 된다.',
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
