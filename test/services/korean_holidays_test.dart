import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/korean_holidays.dart';

void main() {
  test('unloaded years fail closed instead of using calculated holidays', () {
    const unloadedYear = 2091;
    expect(KoreanHolidays.isDayOff(DateTime(unloadedYear, 10, 3)), isFalse);
    expect(KoreanHolidays.holidayName(DateTime(unloadedYear, 12, 25)), isNull);
  });

  test('only KASI-confirmed dates are official days off', () {
    const confirmedYear = 2092;
    KoreanHolidays.applyLiveData(confirmedYear, {
      (10, 3): '개천절',
      (10, 5): '대체공휴일(개천절)',
    });

    expect(KoreanHolidays.isDayOff(DateTime(confirmedYear, 10, 3)), isTrue);
    expect(
      KoreanHolidays.holidayName(DateTime(confirmedYear, 10, 5)),
      '대체공휴일(개천절)',
    );
    expect(KoreanHolidays.isDayOff(DateTime(confirmedYear, 10, 9)), isFalse);
  });

  test('valid empty KASI data is distinct from unloaded data', () {
    const emptyYear = 2093;
    KoreanHolidays.applyLiveData(emptyYear, const {});
    expect(KoreanHolidays.isDayOff(DateTime(emptyYear, 1, 1)), isFalse);
    expect(KoreanHolidays.holidayName(DateTime(emptyYear, 1, 1)), isNull);
  });

  test('aliases are derived only from a KASI-confirmed title', () {
    const aliasYear = 2094;
    expect(
      KoreanHolidays.holidayTitleAliases(DateTime(aliasYear, 12, 25)),
      isEmpty,
    );
    KoreanHolidays.applyLiveData(aliasYear, {
      (12, 25): '기독탄신일',
      (10, 5): '대체공휴일(개천절)',
    });
    expect(
      KoreanHolidays.holidayTitleAliases(DateTime(aliasYear, 12, 25)),
      containsAll(<String>['성탄절', '기독탄신일', '크리스마스']),
    );
    expect(
      KoreanHolidays.holidayTitleAliases(DateTime(aliasYear, 10, 5)),
      containsAll(<String>['대체공휴일(개천절)', '대체공휴일']),
    );
  });

  test('weekends remain weekends without becoming official holidays', () {
    const weekendYear = 2095;
    expect(
        KoreanHolidays.isHolidayOrWeekend(DateTime(weekendYear, 1, 8)), isTrue);
    expect(
      KoreanHolidays.isHolidayOrWeekend(DateTime(weekendYear, 1, 10)),
      isFalse,
    );
  });
}
