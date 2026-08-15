import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/synced_public_holiday_visibility.dart';

EventModel _event({
  String title = '광복절',
  String? externalId = 'provider-event-1',
  String? externalCalendarId = 'google:holidays',
  DateTime? startAt,
}) {
  final holidayYear = DateTime.now().year;
  return EventModel(
    id: 'event-1',
    userId: 'user-1',
    title: title,
    startAt: startAt ?? DateTime(holidayYear, 8, 15, 9),
    externalId: externalId,
    externalCalendarId: externalCalendarId,
  );
}

void main() {
  test('hides an externally identified event matching the canonical holiday',
      () {
    expect(isSyncedPublicHolidayDuplicate(_event()), isTrue);
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(externalCalendarId: null),
      ),
      isTrue,
    );
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(externalId: null),
      ),
      isTrue,
    );
  });

  test('keeps manual or mismatched holiday-like events', () {
    final holidayYear = DateTime.now().year;
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(externalId: null, externalCalendarId: null),
      ),
      isFalse,
    );
    expect(
      isSyncedPublicHolidayDuplicate(_event(title: '광복절 행사')),
      isFalse,
    );
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(title: '광복절', startAt: DateTime(holidayYear, 8, 14, 9)),
      ),
      isFalse,
    );
  });

  test('filters only synced holiday duplicates from a mixed list', () {
    final visible = omitSyncedPublicHolidayDuplicates(<EventModel>[
      _event(),
      _event(title: '광복절 행사'),
      _event(title: '개인 약속', externalId: 'manual-external-id'),
    ]);
    expect(visible.map((event) => event.title), <String>[
      '광복절 행사',
      '개인 약속',
    ]);
  });
}
