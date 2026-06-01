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
}

class _FakeLocationLookupService extends LocationLookupService {
  _FakeLocationLookupService({required this.result});

  final LocationLookupResult result;
  final searchQueries = <String>[];

  @override
  Future<List<LocationLookupResult>> search(
    String query, {
    GeoPoint? origin,
    LocationLookupProvider? preferredProvider,
  }) async {
    searchQueries.add(query);
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
  }) async {
    lastSafetyMarginOverride = safetyMarginOverride;
    return DepartureAlarmScheduleResult.scheduled(
      notifyAt: DateTime(2026, 5, 8, 8),
      travelMinutes: 30,
    );
  }
}
