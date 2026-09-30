import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/features/groups/models/group_event_model.dart';

void main() {
  test('linked event mirror fields round-trip through database JSON', () {
    final source = GroupEventModel(
      id: 'group-event-1',
      groupId: 'group-1',
      title: '반복 일정',
      startAt: DateTime.utc(2026, 9, 1, 1),
      endAt: DateTime.utc(2026, 9, 1, 2),
      allDay: true,
      isMultiDay: true,
      isCritical: true,
      useStrongAlarm: true,
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261231T150000Z',
      personalEventId: 'personal-1',
    );

    final restored = GroupEventModel.fromJson(source.toJson());
    expect(restored.isMultiDay, isTrue);
    expect(restored.isCritical, isTrue);
    expect(restored.useStrongAlarm, isTrue);
    expect(restored.recurrenceRule, source.recurrenceRule);
    expect(restored.personalEventId, 'personal-1');
    expect(restored.toUpdateJson()['recurrence_rule'], source.recurrenceRule);
  });
}
