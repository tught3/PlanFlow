import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/voice_command_pipeline.dart';
import 'package:planflow/services/voice_text_cleanup_service.dart';

void main() {
  group('VoiceCommandPipeline', () {
    const pipeline = VoiceCommandPipeline();

    test('장소 추가 명령은 대상 일정과 새 장소를 분리한다', () {
      final plan = pipeline.analyze(
        '내일 오후 1시에 실매출 확인 일정에 원주세브란스기독병원 장소 추가해줘',
        intent: VoiceCommandPipelineIntent.edit,
        context: VoiceTextCleanupContext.edit,
      );

      expect(plan.intent, VoiceCommandPipelineIntent.edit);
      expect(plan.targetText, contains('내일'));
      expect(plan.targetText, contains('실매출 확인'));
      expect(plan.targetText, isNot(contains('원주세브란스기독병원')));
      expect(plan.changeText, contains('원주세브란스기독병원'));
      expect(plan.requestedChanges, contains('location'));
      expect(plan.requestedFieldValues['location'], '원주세브란스기독병원');
      expect(plan.targetQuery, contains('실매출'));
      expect(plan.targetQuery, isNot(contains('원주세브란스기독병원')));
      expect(plan.safeDirectApply, isFalse);
    });

    test('삭제 명령은 바로 실행 가능한 명령으로 취급하지 않는다', () {
      final plan = pipeline.analyze(
        '내일 오전 10시 교보생명 시험 삭제',
        context: VoiceTextCleanupContext.delete,
      );

      expect(plan.intent, VoiceCommandPipelineIntent.delete);
      expect(plan.targetText, contains('교보생명'));
      expect(plan.targetText, contains('시험'));
      expect(plan.targetText, isNot(contains('삭제')));
      expect(plan.requiresUserChoice, isTrue);
      expect(plan.safeDirectApply, isFalse);
    });

    test('시간 변경 명령은 기존 일정 조건과 새 시간 값을 분리한다', () {
      final plan = pipeline.analyze(
        '내일 회의 다음 주 수요일 오전 9시로 변경',
        intent: VoiceCommandPipelineIntent.edit,
        context: VoiceTextCleanupContext.edit,
      );

      expect(plan.intent, VoiceCommandPipelineIntent.edit);
      expect(plan.targetText, contains('내일'));
      expect(plan.targetText, contains('회의'));
      expect(plan.targetText, isNot(contains('다음 주 수요일')));
      expect(plan.changeText, contains('다음 주 수요일'));
      expect(plan.changeText, contains('오전 9시'));
      expect(plan.requestedChanges, contains('start_at'));
      expect(plan.safeDirectApply, isTrue);
    });

    test('명확한 새 일정 추가와 조회 명령을 구분한다', () {
      final add = pipeline.analyze('내일 오후 3시 강남역 미팅 추가');
      final query = pipeline.analyze(
        '오늘 일정 알려줘',
        context: VoiceTextCleanupContext.query,
      );

      expect(add.intent, VoiceCommandPipelineIntent.add);
      expect(add.targetText, contains('강남역'));
      expect(query.intent, VoiceCommandPipelineIntent.query);
      expect(query.targetText, contains('오늘'));
    });
  });
}
