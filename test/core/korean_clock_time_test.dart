import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/korean_clock_time.dart';

void main() {
  group('resolveKoreanClockTime', () {
    for (final (period, hour, minute, expected, nextDay) in [
      ('밤', 12, 0, 0, true),
      ('저녁', 12, 0, 0, true),
      ('자정', 0, 0, 0, true),
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
      ('3시반이야', null, 3, 30),
      ('세시반인데', null, 3, 30),
      ('3시반입니다', null, 3, 30),
      ('3시반정도', null, 3, 30),
      ('3시반도', null, 3, 30),
      ('3시 반려동물 진료', null, 3, 0),
      ('8시 10에', null, 8, 10),
      ('밤 9시 11월 18일', '밤', 9, 0),
    ]) {
      test(input, () {
        final parts = koreanClockTimeParts(input).single;
        expect((parts.period, parts.hour, parts.minute), (period, hour, minute));
      });
    }

    test('does not read a Korean word suffix as a clock time', () {
      expect(koreanClockTimeParts('예약일시를 알려줘'), isEmpty);
    });

    test('P6d reads standalone Korean hours before common endings', () {
      for (final (input, hour) in [('세시엔', 3), ('다섯시가', 5), ('세시요', 3)]) {
        expect(
          koreanClockTimeParts(input).map((parts) => parts.hour),
          [hour],
          reason: input,
        );
      }
      expect(koreanClockTimeParts('오시는 분 일정 삭제해줘'), isEmpty);
      expect(koreanClockTimeParts('일시 확인해줘'), isEmpty);
    });

    test('P6c ordinary Korean words are not clock times', () {
      for (final input in [
        '오시는 분 일정 삭제해줘',
        '일시 확인해줘',
        '한시라도 빨리 알려줘',
        '세시풍속 행사',
        '춘분과추분정오표 확인해줘',
      ]) {
        expect(koreanClockTimeParts(input), isEmpty, reason: input);
      }
    });

    test('P6c round7 한시나마 is not a clock time', () {
      expect(koreanClockTimeParts('한시나마 도와줘'), isEmpty);
    });

    test('P6c round8 detects alternative dates with a particle', () {
      expect(
        hasAmbiguousKoreanClockEditDestination('내일 또는 모레에 자정으로 옮겨줘'),
        isTrue,
      );
    });

    test('P6c generic request requires an explicit start time field', () {
      for (final form in ['시작시간', '시작 시간을']) {
        expect(
          koreanClockEditDestinationText('1번 일정 $form 8시반으로 해줘'),
          '8시반으로 해줘',
        );
      }
      for (final input in [
        '1번 일정 8시반으로 해줘',
        '1번 일정 미시작시간 8시반으로 해줘',
        '1번 일정 시작시간 8시반 또는 9시로 해줘',
      ]) {
        expect(koreanClockEditDestinationText(input), isNull, reason: input);
      }
    });

    test('P6c round19 rejects unsupported clocks in an edit destination', () {
      for (final input in [
        '팀 회의를 내일 25:00로 옮겨줘',
        '팀 회의를 내일 2500로 옮겨줘',
        '팀 회의를 내일 밤 2400로 옮겨줘',
        '팀 회의를 내일 오전 1270으로 옮겨줘',
        '1번 일정 시작시간 25:00으로 해줘',
      ]) {
        expect(hasInvalidKoreanClockEditDestination(input), isTrue,
            reason: input);
      }
      for (final input in [
        '오늘 24:00 일정을 정오로 옮겨줘',
        '내일 밤 2400 회의를 모레로 옮겨줘',
        '팀 회의를 내일로 옮겨줘',
        '팀 회의를 내일 밤 12시로 옮겨줘',
      ]) {
        expect(hasInvalidKoreanClockEditDestination(input), isFalse,
            reason: input);
      }
    });

    for (final input in ['9:70', '970']) {
      test('P6c round20 rejects a single-digit hour with invalid minutes: $input',
          () {
        expect(
          hasInvalidKoreanClockEditDestination('팀 회의를 내일 $input로 옮겨줘'),
          isTrue,
        );
      });
    }

    test('P6c round20 keeps a compact numeric title and a date-only edit', () {
      expect(
        hasInvalidKoreanClockEditDestination('내일 970 회의를 모레로 옮겨줘'),
        isFalse,
      );
      expect(
        hasInvalidKoreanClockEditDestination('팀 회의를 내일로 옮겨줘'),
        isFalse,
      );
    });

    test('P6c words beginning with 반 do not add thirty minutes', () {
      for (final word in ['반상회', '반환', '반차', '반나절', '반바지', '반팔', '반성']) {
        final clock = koreanClockTimeParts('3시 $word').single;
        expect(clock.minute, 0, reason: word);
        expect(clock.hasExplicitMinute, isFalse, reason: word);
      }
    });

    test('does not read an hour duration as a clock time', () {
      expect(koreanClockTimeParts('3시간 뒤에'), isEmpty);
    });
  });
}
