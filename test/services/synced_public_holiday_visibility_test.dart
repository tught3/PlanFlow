import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/korean_holidays.dart';
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
  setUp(() {
    final year = DateTime.now().year;
    KoreanHolidays.applyLiveData(year, {
      (8, 15): '광복절',
      (10, 9): '한글날',
      (12, 25): '기독탄신일',
    });
    if (year == 2026) {
      KoreanHolidays.applyLiveData(year, {
        (8, 15): '광복절',
        (10, 9): '한글날',
        (12, 25): '기독탄신일',
        (10, 5): '대체공휴일(개천절)',
      });
    } else {
      KoreanHolidays.applyLiveData(2026, {
        (10, 5): '대체공휴일(개천절)',
      });
    }
  });

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

  test('hides provider generic holiday labels on canonical holiday dates', () {
    expect(isSyncedPublicHolidayDuplicate(_event(title: '공휴일')), isTrue);
    expect(isSyncedPublicHolidayDuplicate(_event(title: '휴일')), isTrue);
    expect(
      isSyncedPublicHolidayDuplicate(_event(title: '법정 공휴일')),
      isTrue,
    );
    expect(
      isSyncedPublicHolidayDuplicate(_event(title: '공휴일 안내')),
      isFalse,
    );
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(title: '공휴일', startAt: DateTime(DateTime.now().year, 8, 14)),
      ),
      isFalse,
    );
  });

  test('hides Christmas aliases only on Christmas day', () {
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(title: '크리스마스', startAt: DateTime(DateTime.now().year, 12, 25)),
      ),
      isTrue,
    );
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(title: '아무대나', startAt: DateTime(DateTime.now().year, 12, 25)),
      ),
      isFalse,
    );
  });

  test('keeps unknown titles on Hangeul Day and hides its provider copy', () {
    final year = DateTime.now().year;
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(title: '한글날', startAt: DateTime(year, 10, 9)),
      ),
      isTrue,
    );
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(title: '아무대나', startAt: DateTime(year, 10, 9)),
      ),
      isFalse,
    );
  });

  // banned-ok: Fixed 2026 legal-calendar regression fixture, not wall-clock logic.
  test('recognizes the KASI substitute title on its computed date', () {
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(
            title: '대체공휴일(개천절)',
            startAt: DateTime(
                2026, 10, 5)), // banned-ok: fixed statutory regression date.
      ),
      isTrue,
    );
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(
            title: '대체공휴일',
            startAt: DateTime(
                2026, 10, 5)), // banned-ok: fixed statutory regression date.
      ),
      isTrue,
    );
    expect(
      isSyncedPublicHolidayDuplicate(
        _event(
            title: '아무대나',
            startAt: DateTime(
                2026, 10, 5)), // banned-ok: fixed statutory regression date.
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
