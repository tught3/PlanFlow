import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/pre_action_model.dart';

void main() {
  test('PreActionModel calculates notifyAt from event start and offset', () {
    final eventStartAt = DateTime.parse('2026-05-01T10:00:00Z');

    expect(
      PreActionModel.calculateNotifyAt(
        eventStartAt: eventStartAt,
        offsetHours: 2,
      ),
      DateTime.parse('2026-05-01T08:00:00Z'),
    );
  });

  test('PreActionModel prefers explicit notifyAt over calculated value', () {
    final model = PreActionModel(
      id: 'pre-action-1',
      eventId: 'event-1',
      userId: 'user-1',
      title: 'Prepare materials',
      notifyAt: DateTime.parse('2026-05-01T07:15:00Z'),
      offsetHours: 2,
    );

    expect(
      model.resolveNotifyAt(DateTime.parse('2026-05-01T10:00:00Z')),
      model.notifyAt,
    );
  });

  test('PreActionModel round-trips snake_case payloads', () {
    final model = PreActionModel(
      id: 'pre-action-1',
      eventId: 'event-1',
      userId: 'user-1',
      title: 'Prepare materials',
      notifyAt: DateTime.parse('2026-05-01T08:00:00Z'),
      isDone: true,
      offsetHours: 2,
      createdAt: DateTime.parse('2026-04-30T12:00:00Z'),
    );

    final restored = PreActionModel.fromJson(model.toJson());

    expect(restored.id, model.id);
    expect(restored.eventId, model.eventId);
    expect(restored.userId, model.userId);
    expect(restored.title, model.title);
    expect(restored.notifyAt, model.notifyAt);
    expect(restored.isDone, isTrue);
    expect(restored.offsetHours, model.offsetHours);
    expect(restored.createdAt, model.createdAt);
  });
}
