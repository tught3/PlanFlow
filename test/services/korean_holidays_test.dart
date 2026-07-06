import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/korean_holidays.dart';

void main() {
  group('KoreanHolidays.isHoliday', () {
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

  group('KoreanHolidays.holidayName', () {
    test('returns correct name for 제헌절', () {
      expect(
        KoreanHolidays.holidayName(DateTime(2026, 7, 17)),
        '제헌절',
      );
    });

    test('returns null for ordinary day', () {
      expect(
        KoreanHolidays.holidayName(DateTime(2026, 7, 16)),
        isNull,
      );
    });
  });
}
