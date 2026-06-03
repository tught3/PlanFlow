import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/widgets/recurrence_selector.dart';

void main() {
  test('RecurrenceSelection preserves advanced RRULE parts', () {
    final selection = RecurrenceSelection.fromRRule(
      'FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10;UNTIL=20260630T235959Z',
    );

    expect(selection.frequency, 'weekly');
    expect(selection.until, DateTime(2026, 6, 30));
    expect(selection.toRRule(), contains('BYDAY=MO,WE'));
    expect(selection.toRRule(), contains('COUNT=10'));
    expect(selection.toRRule(), contains('UNTIL=20260630T235959Z'));
  });

  test('RecurrenceSelection preserves monthly ordinal weekday rule', () {
    final selection = RecurrenceSelection.fromRRule(
      'FREQ=MONTHLY;BYDAY=1MO',
    );

    expect(selection.frequency, 'monthly');
    expect(selection.toRRule(), contains('BYDAY=1MO'));
  });
}
