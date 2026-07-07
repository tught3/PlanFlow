import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/korean_holidays.dart';

void main() {
  group('KoreanHolidays.isHoliday (fixed)', () {
    for (final entry in {
      '신정': DateTime(2026, 1, 1),
      '삼일절': DateTime(2026, 3, 1),
      '어린이날': DateTime(2026, 5, 5),
      '현충일': DateTime(2026, 6, 6),
      '제헌절': DateTime(2026, 7, 17),
      '광복절': DateTime(2026, 8, 15),
      '개천절': DateTime(2026, 10, 3),
      '한글날': DateTime(2026, 10, 9),
      '성탄절': DateTime(2026, 12, 25),
    }.entries) {
      test('${entry.key} is a public holiday', () {
        expect(KoreanHolidays.isHoliday(entry.value), isTrue,
            reason: '${entry.key}(${entry.value}) should be a holiday');
      });
    }

    test('ordinary day is not a holiday', () {
      expect(KoreanHolidays.isHoliday(DateTime(2026, 7, 16)), isFalse);
      expect(KoreanHolidays.isHoliday(DateTime(2026, 7, 18)), isFalse);
      expect(KoreanHolidays.isHoliday(DateTime(2026, 6, 7)), isFalse);
    });
  });

  group('KoreanHolidays.isHoliday (lunar)', () {
    for (final entry in {
      '설날연휴 첫날(2026)': DateTime(2026, 2, 16),
      '설날(2026)': DateTime(2026, 2, 17),
      '설날연휴 마지막날(2026)': DateTime(2026, 2, 18),
      '추석연휴 첫날(2026)': DateTime(2026, 9, 24),
      '추석(2026)': DateTime(2026, 9, 25),
      '추석연휴 마지막날(2026)': DateTime(2026, 9, 26),
      '부처님오신날(2026)': DateTime(2026, 5, 24),
      '설날(2027)': DateTime(2027, 2, 7),
      '설날(2028)': DateTime(2028, 1, 27),
      '추석(2028)': DateTime(2028, 10, 3),
      '부처님오신날(2027)': DateTime(2027, 5, 13),
    }.entries) {
      test('${entry.key} is a public holiday', () {
        expect(KoreanHolidays.isHoliday(entry.value), isTrue,
            reason: '${entry.key} should be a holiday');
      });
    }
  });

  group('KoreanHolidays.isHoliday (substitute)', () {
    // 2027 설날(2/7, 일) → 3일 연휴(2/6토, 2/7일, 2/8월)
    // 일요일이 연휴에 포함 → 대체공휴일 = 2/9(화)?
    // 실제: 2/6(토)는 주말, 2/7(일)은 설날 당일, 2/8(월)은 연휴
    // → 2/9(화)가 대체공휴일 (연휴 끝 2/8 다음 첫 평일)
    test('2027 설날 substitute (Seollal on Sunday)', () {
      // 2/7(일)이 설날 당일, 2/8(월)은 연휴
      // 연휴가 일요일을 포함 → 대체공휴일은 2/9(화)
      expect(KoreanHolidays.isHoliday(DateTime(2027, 2, 9)), isTrue,
          reason: '2027 설날 대체공휴일 (2/9)');
    });

    // 2026 어린이날(5/5, 화) → 평일, 대체 불필요
    test('2026 Childrens Day on weekday needs no substitute', () {
      expect(KoreanHolidays.isHoliday(DateTime(2026, 5, 5)), isTrue);
      // 어린이날이 화요일이므로 대체공휴일 없음
      expect(KoreanHolidays.isHoliday(DateTime(2026, 5, 6)), isFalse);
    });

    // 2026 부처님오신날(5/24, 일) → 다음날? 5/25(월)은 이미 공휴일 없음
    // 부처님오신날(5/24, 일)이 일요일 → 대체공휴일 = 5/26(수)?
    // Wait: 5/25(월)이 첫 평일 → but check if it's taken
    // Actually, 부처님오신날(5/24, 일) → 다음 평일 5/25(월)
    // But it might also have 설날? No, 설날은 2월
    // 5/25(월) is not a holiday. So substitute = 5/25(월)
    // Wait, is 5/25 already a holiday? Let me check... no it's not.
    test('2026 Buddhas Birthday on Sunday has substitute', () {
      expect(KoreanHolidays.isHoliday(DateTime(2026, 5, 24)), isTrue);
      // 부처님오신날이 일요일(5/24) → 다음 평일 5/25(월)이 대체
      expect(KoreanHolidays.isHoliday(DateTime(2026, 5, 25)), isTrue,
          reason: '2026 부처님오신날 대체공휴일 (5/25)');
    });
  });

  group('KoreanHolidays.holidayName', () {
    test('returns correct name for 제헌절', () {
      expect(
        KoreanHolidays.holidayName(DateTime(2026, 7, 17)),
        '제헌절',
      );
    });

    test('returns correct name for lunar holiday', () {
      expect(
        KoreanHolidays.holidayName(DateTime(2026, 2, 17)),
        '설날',
      );
    });

    test('returns 대체공휴일 for substitute day', () {
      final name = KoreanHolidays.holidayName(DateTime(2027, 2, 9));
      expect(name, '대체공휴일');
    });

    test('returns null for ordinary day', () {
      expect(
        KoreanHolidays.holidayName(DateTime(2026, 7, 16)),
        isNull,
      );
    });
  });

  group('KoreanHolidays.isHolidayOrWeekend', () {
    test('holiday is true', () {
      expect(KoreanHolidays.isHolidayOrWeekend(DateTime(2026, 7, 17)),
          isTrue);
    });

    test('weekend is true', () {
      expect(KoreanHolidays.isHolidayOrWeekend(DateTime(2026, 7, 18)),
          isTrue);
    });

    test('ordinary weekday is false', () {
      expect(KoreanHolidays.isHolidayOrWeekend(DateTime(2026, 7, 16)),
          isFalse);
    });
  });
}
