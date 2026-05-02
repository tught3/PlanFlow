import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';

void main() {
  test('EventModel serializes and deserializes snake_case payloads', () {
    final model = EventModel(
      id: 'event-1',
      userId: 'user-1',
      title: 'Team sync',
      startAt: DateTime.parse('2026-05-01T09:00:00Z'),
      endAt: DateTime.parse('2026-05-01T09:30:00Z'),
      location: 'Seoul',
      locationLat: 37.5665,
      locationLng: 126.978,
      memo: 'Weekly meeting',
      supplies: const <String>['laptop', 'notes'],
      isCritical: true,
      source: 'google',
      externalId: 'calendar-event-1',
      createdAt: DateTime.parse('2026-04-30T12:00:00Z'),
    );

    final json = model.toJson();
    final restored = EventModel.fromJson(json);

    expect(restored.id, model.id);
    expect(restored.userId, model.userId);
    expect(restored.title, model.title);
    expect(restored.startAt, model.startAt);
    expect(restored.endAt, model.endAt);
    expect(restored.location, model.location);
    expect(restored.locationLat, 37.5665);
    expect(restored.locationLng, 126.978);
    expect(restored.memo, model.memo);
    expect(restored.supplies, model.supplies);
    expect(restored.isCritical, isTrue);
    expect(restored.source, 'google');
    expect(restored.externalId, 'calendar-event-1');
    expect(restored.createdAt, model.createdAt);
    expect(json['location_lat'], 37.5665);
    expect(json['location_lng'], 126.978);
  });

  test('EventModel can omit id for inserts', () {
    const model = EventModel(
      id: '',
      userId: 'user-1',
      title: 'Draft event',
    );

    final json = model.toJson(includeId: false);

    expect(json.containsKey('id'), isFalse);
    expect(json['user_id'], 'user-1');
    expect(json['title'], 'Draft event');
    expect(json['source'], 'manual');
    expect(json['external_id'], isNull);
  });

  test('EventModel defaults source to manual when absent in JSON', () {
    final restored = EventModel.fromJson(<String, dynamic>{
      'id': 'event-2',
      'user_id': 'user-2',
      'title': 'Manual event',
      'start_at': '2026-05-01T10:00:00Z',
    });

    expect(restored.source, 'manual');
    expect(restored.externalId, isNull);
  });
}
