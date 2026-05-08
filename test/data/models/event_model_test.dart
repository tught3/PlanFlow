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
      suppliesChecked: const <String>['notes'],
      isCritical: true,
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU',
      isAllDay: true,
      isMultiDay: true,
      parentEventId: 'parent-1',
      category: '업무',
      source: 'google',
      externalId: 'calendar-event-1',
      externalCalendarId: 'google:primary',
      externalEtag: '"etag-1"',
      externalUpdatedAt: DateTime.parse('2026-04-30T12:30:00Z'),
      lastSyncedAt: DateTime.parse('2026-04-30T12:31:00Z'),
      createdAt: DateTime.parse('2026-04-30T12:00:00Z'),
      updatedAt: DateTime.parse('2026-04-30T12:05:00Z'),
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
    expect(restored.suppliesChecked, model.suppliesChecked);
    expect(restored.isCritical, isTrue);
    expect(restored.recurrenceRule, 'FREQ=WEEKLY;BYDAY=TU');
    expect(restored.isAllDay, isTrue);
    expect(restored.isMultiDay, isTrue);
    expect(restored.parentEventId, 'parent-1');
    expect(restored.category, '업무');
    expect(restored.source, 'google');
    expect(restored.externalId, 'calendar-event-1');
    expect(restored.externalCalendarId, 'google:primary');
    expect(restored.externalEtag, '"etag-1"');
    expect(restored.externalUpdatedAt, model.externalUpdatedAt);
    expect(restored.lastSyncedAt, model.lastSyncedAt);
    expect(restored.createdAt, model.createdAt);
    expect(restored.updatedAt, model.updatedAt);
    expect(json['location_lat'], 37.5665);
    expect(json['location_lng'], 126.978);
    expect(json['external_etag'], '"etag-1"');
    expect(json['recurrence_rule'], 'FREQ=WEEKLY;BYDAY=TU');
    expect(json['is_all_day'], isTrue);
    expect(json['is_multi_day'], isTrue);
    expect(json['parent_event_id'], 'parent-1');
    expect(json['category'], '업무');
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
    expect(json['category'], '기타');
    expect(json['external_id'], isNull);
  });

  test('EventModel update payload excludes immutable row fields', () {
    final model = EventModel(
      id: 'event-1',
      userId: 'user-1',
      title: 'Updated event',
      startAt: DateTime.parse('2026-05-01T09:00:00Z'),
      externalEtag: '"etag-2"',
      category: '가족',
      lastSyncedAt: DateTime.parse('2026-05-01T09:01:00Z'),
      createdAt: DateTime.parse('2026-04-30T12:00:00Z'),
    );

    final json = model.toUpdateJson();

    expect(json.containsKey('id'), isFalse);
    expect(json.containsKey('user_id'), isFalse);
    expect(json.containsKey('created_at'), isFalse);
    expect(json['title'], 'Updated event');
    expect(json['source'], 'manual');
    expect(json['category'], '가족');
    expect(json['external_etag'], '"etag-2"');
    expect(json['last_synced_at'], '2026-05-01T09:01:00.000Z');
  });

  test('EventModel defaults source to manual when absent in JSON', () {
    final restored = EventModel.fromJson(<String, dynamic>{
      'id': 'event-2',
      'user_id': 'user-2',
      'title': 'Manual event',
      'start_at': '2026-05-01T10:00:00Z',
    });

    expect(restored.source, 'manual');
    expect(restored.category, '기타');
    expect(restored.externalId, isNull);
  });
}
