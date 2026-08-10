import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/voice_schedule_structure_service.dart';
import 'package:planflow/services/voice_date_range_parser.dart';

void main() {
  group('VoiceScheduleStructureService date parsing', () {
    test('day-only date resolves to current month', () {
      final service = VoiceScheduleStructureService();
      final result = service.extractDateRange(
        '28일 계룡으로 엄마만나러가기',
        now: DateTime(2026, 6, 11),
      );

      expect(result, isNotNull);
      expect(result!.startAt.year, 2026);
      expect(result.startAt.month, 6);
      expect(result.startAt.day, 28);
      expect(result.isAllDay, isTrue);
    });

    test('absolute month/day stays intact', () {
      final service = VoiceScheduleStructureService();
      final result = service.extractDateRange(
        '7월 19일 김창민 만나기',
        now: DateTime(2026, 6, 11),
      );

      expect(result, isNotNull);
      expect(result!.startAt.year, 2026);
      expect(result.startAt.month, 7);
      expect(result.startAt.day, 19);
      expect(result.isAllDay, isTrue);
    });

    test('내일모래/내일모레(STT 오인식 포함) resolves to 2 days later', () {
      final now = DateTime(2026, 6, 11);
      expect(
        VoiceDateRangeParser.parse('내일모래 엄마 만나러 가기', now: now)!.start.day,
        13,
      );
      expect(
        VoiceDateRangeParser.parse('내일모레 약속', now: now)!.start.day,
        13,
      );
    });

    test(
      'single dates keep a query boundary separate from multi-day intent',
      () {
        final testYear = DateTime.now().year + 1;
        final single = VoiceDateRangeParser.parse(
          '9월 12일 일정으로 저장',
          now: DateTime(testYear, 8, 10),
        )!;
        expect(single.start, DateTime(testYear, 9, 12));
        expect(single.end, DateTime(testYear, 9, 13));
        expect(single.isMultiDay, isFalse);

        final multi = VoiceDateRangeParser.parse(
          '9월 12일부터 13일까지 제주 여행',
          now: DateTime(testYear, 8, 10),
        )!;
        expect(multi.isMultiDay, isTrue);
        expect(multi.start, DateTime(testYear, 9, 12));
        expect(multi.end, DateTime(testYear, 9, 13));

        final sameDayExplicit = VoiceDateRangeParser.parse(
          '9월 12일부터 12일까지 일정',
          now: DateTime(testYear, 8, 10),
        )!;
        expect(sameDayExplicit.isMultiDay, isFalse);
        expect(sameDayExplicit.end, DateTime(testYear, 9, 13));
      },
    );

    test('수식어 없는 요일은 가장 빨리 돌아오는 그 요일로 해석한다', () {
      // 2026-06-11은 목요일.
      final thursday =
          DateTime(2026, 6, 11); // banned-ok: now: 주입값, 실제 시계 아님(2026-08-08)

      // 아직 안 지난 이번 주 금요일 -> 이번 주 금요일(6/12).
      final friday = VoiceDateRangeParser.parse('금요일 일정 보여줘', now: thursday)!;
      expect(friday.start,
          DateTime(2026, 6, 12)); // banned-ok: 결정론적 기대값, 시계 아님(2026-08-08)

      // 이미 지난 월요일(이번 주 6/8) -> 다음 주 월요일(6/15).
      final monday = VoiceDateRangeParser.parse('월요일 일정 보여줘', now: thursday)!;
      expect(monday.start,
          DateTime(2026, 6, 15)); // banned-ok: 결정론적 기대값, 시계 아님(2026-08-08)

      // 오늘과 같은 요일(목요일) -> 오늘.
      final today = VoiceDateRangeParser.parse('목요일 일정 보여줘', now: thursday)!;
      expect(today.start,
          DateTime(2026, 6, 11)); // banned-ok: 결정론적 기대값, 시계 아님(2026-08-08)
    });

    test('수식어 없는 날짜(N일)는 이미 지났으면 다음 달로 해석한다', () {
      // 2026-08-19에 "17일" -> 이번 달 17일은 이미 지남 -> 다음 달(9/17).
      final aug19 =
          DateTime(2026, 8, 19); // banned-ok: now: 주입값, 실제 시계 아님(2026-08-08)
      final next = VoiceDateRangeParser.parse('17일 일정 보여줘', now: aug19)!;
      expect(next.start,
          DateTime(2026, 9, 17)); // banned-ok: 결정론적 기대값, 시계 아님(2026-08-08)

      // 2026-08-08에 "17일" -> 이번 달 17일이 아직 안 지남 -> 이번 달(8/17).
      final aug8 =
          DateTime(2026, 8, 8); // banned-ok: now: 주입값, 실제 시계 아님(2026-08-08)
      final same = VoiceDateRangeParser.parse('17일 일정 보여줘', now: aug8)!;
      expect(same.start,
          DateTime(2026, 8, 17)); // banned-ok: 결정론적 기대값, 시계 아님(2026-08-08)

      // 12월에 지난 날짜 -> 다음 해 1월로 롤오버.
      final dec20 =
          DateTime(2026, 12, 20); // banned-ok: now: 주입값, 실제 시계 아님(2026-08-08)
      final rollYear = VoiceDateRangeParser.parse('5일 일정 보여줘', now: dec20)!;
      expect(rollYear.start,
          DateTime(2027, 1, 5)); // banned-ok: 결정론적 기대값, 시계 아님(2026-08-08)
    });
  });
}
