import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/reminder_model.dart';

void main() {
  test('ReminderModel round-trips snake_case payloads', () {
    final model = ReminderModel(
      id: 'reminder-1',
      eventId: 'event-1',
      userId: 'user-1',
      type: 'push',
      notifyAt: DateTime.parse('2026-05-01T08:00:00Z'),
      isSent: true,
      createdAt: DateTime.parse('2026-04-30T12:00:00Z'),
    );

    final restored = ReminderModel.fromJson(model.toJson());

    expect(restored.id, model.id);
    expect(restored.eventId, model.eventId);
    expect(restored.userId, model.userId);
    expect(restored.type, model.type);
    expect(restored.notifyAt, model.notifyAt);
    expect(restored.isSent, isTrue);
    expect(restored.createdAt, model.createdAt);
  });
}
