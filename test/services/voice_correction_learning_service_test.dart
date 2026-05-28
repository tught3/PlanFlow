import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/voice_correction_rule.dart';
import 'package:planflow/services/voice_correction_learning_service.dart';

void main() {
  group('VoiceCorrectionLearningService', () {
    const service = VoiceCorrectionLearningService();

    test('extracts a minimal STT correction rule without storing full text',
        () {
      final rules = service.extractRules(
        originalText: '조사신청 4만원 하기',
        correctedText: '경조사 신청 4만원 하기',
        stage: VoiceCorrectionStage.stt,
        field: VoiceCorrectionField.transcript,
      );

      expect(rules, hasLength(1));
      final rule = rules.single;
      expect(rule.fromText, '조사');
      expect(rule.toText, '경조사');
      expect(rule.contextAfter, '신청 4만원');
      expect(rule.rawText, isNull);
      expect(rule.memoText, isNull);
    });

    test('applies trusted personal transcript rules only when context matches',
        () {
      final rule = VoiceCorrectionRule(
        id: 'rule-1',
        userId: 'user-1',
        stage: VoiceCorrectionStage.stt,
        field: VoiceCorrectionField.transcript,
        fromText: '조사',
        toText: '경조사',
        contextAfter: '신청 4만원 하기',
        confidenceCount: 2,
      );

      expect(
        service
            .applyRules(
              '내일 오전에 조사신청 4만원 하기',
              rules: [rule],
              stage: VoiceCorrectionStage.stt,
              field: VoiceCorrectionField.transcript,
            )
            .text,
        '내일 오전에 경조사 신청 4만원 하기',
      );
      expect(
        service
            .applyRules(
              '조사신청 서류 찾기',
              rules: [rule],
              stage: VoiceCorrectionStage.stt,
              field: VoiceCorrectionField.transcript,
            )
            .text,
        '조사신청 서류 찾기',
      );
    });

    test('uses single-use corrections as suggestions instead of auto applying',
        () {
      final rule = VoiceCorrectionRule(
        id: 'rule-1',
        userId: 'user-1',
        stage: VoiceCorrectionStage.parse,
        field: VoiceCorrectionField.title,
        fromText: '월요일 계기판 찍기 반복 설정',
        toText: '태블릿 계기판 찍기',
        confidenceCount: 1,
      );

      final result = service.applyRules(
        '월요일 계기판 찍기 반복 설정',
        rules: [rule],
        stage: VoiceCorrectionStage.parse,
        field: VoiceCorrectionField.title,
      );

      expect(result.text, '월요일 계기판 찍기 반복 설정');
      expect(result.suggestions.single.toText, '태블릿 계기판 찍기');
    });

    test('marks person and location fields as personal-only sensitive rules',
        () {
      final titleRules = service.extractRules(
        originalText: '삼성서비스센터 방문',
        correctedText: '삼성전자서비스센터 성남점 방문',
        stage: VoiceCorrectionStage.parse,
        field: VoiceCorrectionField.location,
      );

      expect(titleRules.single.isSensitive, isTrue);
      expect(titleRules.single.canContributeToCommon, isFalse);
    });
  });
}
