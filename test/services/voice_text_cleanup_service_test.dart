import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/services/voice_text_cleanup_service.dart';

void main() {
  group('VoiceTextCleanupService', () {
    test('repairs split location particles only when a candidate supports it',
        () {
      final result = VoiceTextCleanupService.cleanLocally(
        '내일 서울에서 성남에서 아이스크림 전달일정 이번주 목요일 오전9시로 변경',
        context: VoiceTextCleanupContext.edit,
        candidates: const [
          VoiceTextCleanupCandidate(
            title: '서울성남 아이스크림 전달',
            location: '서울성남',
          ),
        ],
      );

      expect(result.changed, isTrue);
      expect(result.method, VoiceTextCleanupMethod.local);
      expect(
        result.cleanedText,
        '내일 서울성남에서 아이스크림 전달일정 이번주 목요일 오전9시로 변경',
      );
    });

    test('keeps natural departure and arrival expressions unchanged', () {
      final result = VoiceTextCleanupService.cleanLocally(
        '서울에서 출발해서 부산에서 도착',
        context: VoiceTextCleanupContext.add,
      );

      expect(result.cleanedText, '서울에서 출발해서 부산에서 도착');
      expect(result.changed, isFalse);
    });

    test('marks suspicious repeated particles for AI cleanup', () {
      expect(
        VoiceTextCleanupService.shouldAskAi('내일 서울에서 성남에서 미팅 변경'),
        isTrue,
      );
      expect(
        VoiceTextCleanupService.shouldAskAi('서울에서 출발해서 부산에서 도착'),
        isFalse,
      );
    });
  });
}
