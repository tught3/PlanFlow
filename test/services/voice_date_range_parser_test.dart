import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/voice_schedule_structure_service.dart';

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
  });
}
