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
      memo: 'Weekly meeting',
      supplies: const <String>['laptop', 'notes'],
      isCritical: true,
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
    expect(restored.memo, model.memo);
    expect(restored.supplies, model.supplies);
    expect(restored.isCritical, isTrue);
    expect(restored.createdAt, model.createdAt);
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
  });
}
