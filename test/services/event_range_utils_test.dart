import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/event_range_utils.dart';

void main() {
  group('shiftEventEndWhenStartChanges', () {
    test('start-only edit defaults end to one hour after new start', () {
      final start = DateTime(2026, 10, 17, 9);
      expect(
        shiftEventEndWhenStartChanges(
          previousStart: start,
          newStart: DateTime(2026, 10, 17, 13),
          currentEnd: DateTime(2026, 10, 17, 10),
          endEditedByUser: false,
        ),
        DateTime(2026, 10, 17, 14),
      );
    });

    test('repairs stale overnight, null, and invalid ends on start edit', () {
      final start = DateTime(2026, 10, 17, 9);
      final nextStart = DateTime(2026, 10, 17, 13);
      for (final end in <DateTime?>[
        DateTime(2026, 10, 18, 9),
        null,
        DateTime(2026, 10, 17, 8),
      ]) {
        expect(
          shiftEventEndWhenStartChanges(
            previousStart: start,
            newStart: nextStart,
            currentEnd: end,
            endEditedByUser: false,
          ),
          DateTime(2026, 10, 17, 14),
        );
      }
    });

    test('keeps explicitly edited end, including a cleared end', () {
      final start = DateTime(2026, 10, 17, 9);
      expect(
        shiftEventEndWhenStartChanges(
          previousStart: start,
          newStart: DateTime(2026, 10, 17, 13),
          currentEnd: DateTime(2026, 10, 17, 15),
          endEditedByUser: true,
        ),
        DateTime(2026, 10, 17, 15),
      );
      expect(
        shiftEventEndWhenStartChanges(
          previousStart: start,
          newStart: DateTime(2026, 10, 17, 13),
          currentEnd: null,
          endEditedByUser: true,
        ),
        isNull,
      );
    });

    test('one-hour duration may cross midnight', () {
      final start = DateTime(2026, 10, 17, 23, 30);
      expect(
        shiftEventEndWhenStartChanges(
          previousStart: DateTime(2026, 10, 17, 9),
          newStart: start,
          currentEnd: DateTime(2026, 10, 17, 10),
          endEditedByUser: false,
        ),
        DateTime(2026, 10, 18, 0, 30),
      );
    });

    test('unchanged start preserves end for title-only edits', () {
      final start = DateTime(2026, 10, 17, 9);
      final end = DateTime(2026, 10, 18, 9);
      expect(
        shiftEventEndWhenStartChanges(
          previousStart: start,
          newStart: start,
          currentEnd: end,
          endEditedByUser: false,
        ),
        end,
      );
    });
  });

  group('utteranceHasExplicitEndOrDurationCue', () {
    test('detects end/range/duration/all-day/overnight', () {
      for (final t in [
        '내일 9시부터 11시까지로 변경',
        '아홉시부터 열한시까지',
        '9시~11시',
        '2시간 동안',
        '종료 시간 11시',
        '1박 2일',
        '종일로',
        '이박삼일'
      ]) {
        expect(utteranceHasExplicitEndOrDurationCue(t), isTrue, reason: t);
      }
    });
    test('relative offsets and plain start are not end cues', () {
      for (final t in [
        '한시간 뒤로 미뤄',
        '30분 늦춰줘',
        '내일 오후 3시로 변경',
        '다음 주로 옮겨',
        ''
      ]) {
        expect(utteranceHasExplicitEndOrDurationCue(t), isFalse, reason: t);
      }
      expect(utteranceHasExplicitEndOrDurationCue(null), isFalse);
    });
  });
}
