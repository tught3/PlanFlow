import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/korean_clock_time.dart';

void main() {
  group('resolveKoreanClockTime', () {
    for (final (period, hour, minute, expected, nextDay) in [
      ('밤', 12, 0, 0, true),
      ('저녁', 12, 0, 0, true),
      ('오후', 12, 0, 12, false),
      ('낮', 12, 0, 12, false),
      ('점심', 12, 0, 12, false),
      (null, 12, 0, 12, false),
      ('오전', 12, 0, 0, false),
      ('아침', 12, 0, 0, false),
      ('새벽', 12, 0, 0, false),
      ('낮', 2, 0, 14, false),
      ('점심', 1, 0, 13, false),
      ('낮', 6, 0, 18, false),
      ('낮', 7, 0, 7, false),
      ('낮', 10, 0, 10, false),
      ('낮', 11, 0, 11, false),
      ('밤', 9, 0, 21, false),
      ('밤', 11, 30, 23, false),
      ('밤', 1, 0, 1, false),
      ('밤', 5, 0, 5, false),
      ('밤', 6, 0, 18, false),
      ('새벽', 2, 0, 2, false),
      ('저녁', 7, 0, 19, false),
      ('아침', 7, 0, 7, false),
      ('오전', 9, 0, 9, false),
      (null, 3, 0, 15, false),
      (null, 15, 0, 15, false),
      (null, 0, 0, 0, false),
      ('오후', 0, 0, 0, false),
      ('밤', 23, 59, 23, false),
    ]) {
      test('$period $hour:$minute', () {
        final time = resolveKoreanClockTime(
          period: period,
          hour: hour,
          minute: minute,
          unmarkedPmDefault: true,
        );

        expect(time, isNotNull);
        expect(time!.hour, expected);
        expect(time.minute, minute);
        expect(time.isEndOfDay, nextDay);
      });
    }

    test('an unmarked hour can remain literal', () {
      final time = resolveKoreanClockTime(
        period: null,
        hour: 3,
        minute: 0,
        unmarkedPmDefault: false,
      );

      expect(time?.hour, 3);
    });

    for (final (hour, minute) in [(25, 0), (3, 70), (-1, 0), (3, -1)]) {
      test('rejects $hour:$minute', () {
        expect(
          resolveKoreanClockTime(
            period: null,
            hour: hour,
            minute: minute,
            unmarkedPmDefault: true,
          ),
          isNull,
        );
      });
    }
  });

  group('koreanClockTimeParts', () {
    for (final (input, period, hour, minute) in [
      ('자정에', '자정', 0, 0),
      ('정오에', '정오', 12, 0),
      ('밤 열두 시 회식', '밤', 12, 0),
      ('밤열두시 회식', '밤', 12, 0),
      ('오늘3시에', null, 3, 0),
      ('네 시 사십오 분', null, 4, 45),
      ('오후 다섯 시 오십 분', '오후', 5, 50),
      ('오전 8시 오십오 분', '오전', 8, 55),
      ('여덟시 반에', null, 8, 30),
      ('8시 10에', null, 8, 10),
      ('밤 9시 11월 18일', '밤', 9, 0),
    ]) {
      test(input, () {
        final parts = koreanClockTimeParts(input).single;
        expect(parts, (period: period, hour: hour, minute: minute));
      });
    }

    test('does not read a Korean word suffix as a clock time', () {
      expect(koreanClockTimeParts('예약일시를 알려줘'), isEmpty);
    });

    test('does not read an hour duration as a clock time', () {
      expect(koreanClockTimeParts('3시간 뒤에'), isEmpty);
    });
  });
}
