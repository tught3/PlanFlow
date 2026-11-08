import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';

class CoordinateRepository extends EventRepository {
  EventModel? written;
  @override
  Future<EventModel> updateEvent(EventModel event) async {
    written = event;
    return event;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final original = EventModel(
      id: 'saved',
      userId: 'user',
      title: 'meeting',
      startAt: DateTime.utc(2026, 10, 29, 5),
      location: 'station',
      locationLat: 37.4979,
      locationLng: 127.0276);
  EventModel imported(String location, {double? lat, double? lng}) =>
      EventModel(
          id: '',
          userId: 'user',
          title: 'meeting',
          startAt: original.startAt,
          location: location,
          locationLat: lat,
          locationLng: lng,
          externalId: 'external',
          externalCalendarId: 'calendar',
          source: 'naver_caldav');
  test(
      'external metadata merge preserves saved pair on same location and roundtrip',
      () async {
    final repo = CoordinateRepository();
    await repo.attachExternalSyncMetadataIfCompatible(
        existing: original, incoming: imported('station'));
    final reloaded = EventModel.fromJson(repo.written!.toJson());
    expect(reloaded.locationLat, original.locationLat);
    expect(reloaded.locationLng, original.locationLng);
    expect(reloaded.hasResolvedLocation, isTrue);
  });
  test('changed location never inherits old coordinates', () async {
    final repo = CoordinateRepository();
    await repo.attachExternalSyncMetadataIfCompatible(
        existing: original, incoming: imported('different station'));
    expect(repo.written!.locationLat, isNull);
    expect(repo.written!.locationLng, isNull);
  });
  test('explicit newly resolved pair replaces old coordinates', () async {
    final repo = CoordinateRepository();
    await repo.attachExternalSyncMetadataIfCompatible(
        existing: original,
        incoming: imported('different station', lat: 37.55, lng: 126.97));
    expect(repo.written!.locationLat, 37.55);
    expect(repo.written!.locationLng, 126.97);
  });
  test(
      'partial imported pair keeps both old values together for unchanged location',
      () async {
    final repo = CoordinateRepository();
    await repo.attachExternalSyncMetadataIfCompatible(
        existing: original, incoming: imported('station', lat: 38));
    expect(repo.written!.locationLat, original.locationLat);
    expect(repo.written!.locationLng, original.locationLng);
  });
  test('non-finite, out-of-range and single-sided pairs are invalid', () {
    expect(
        EventModel.hasValidCoordinatePair(lat: double.nan, lng: 127), isFalse);
    expect(EventModel.hasValidCoordinatePair(lat: 37, lng: double.infinity),
        isFalse);
    expect(EventModel.hasValidCoordinatePair(lat: 91, lng: 127), isFalse);
    expect(EventModel.hasValidCoordinatePair(lat: 37, lng: -181), isFalse);
    expect(EventModel.hasValidCoordinatePair(lat: 37), isFalse);
    expect(EventModel.hasValidCoordinatePair(lat: 0, lng: 0), isTrue);
  });
}
