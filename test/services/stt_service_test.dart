import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:planflow/services/stt_service.dart';

void main() {
  test('SttService keeps on-device Korean listen options enabled', () {
    final options = SttService.buildListenOptions();

    expect(options.onDevice, isTrue);
    expect(options.partialResults, isTrue);
    expect(options.cancelOnError, isFalse);
    expect(options.listenMode, ListenMode.dictation);
  });

  test('SttService prefers ko_KR and falls back to other Korean locale ids',
      () {
    expect(
      SttService.resolveKoreanLocaleId(const <String>['en_US', 'ko_KR']),
      'ko_KR',
    );
    expect(
      SttService.resolveKoreanLocaleId(const <String>['en_US', 'ko']),
      'ko',
    );
    expect(
      SttService.resolveKoreanLocaleId(const <String>['en_US', 'ko-KP']),
      'ko-KP',
    );
    expect(
      SttService.resolveKoreanLocaleId(const <String>['en_US', 'ja_JP']),
      isNull,
    );
  });

  test('SttListenResult exposes success and failure states', () {
    final success = SttListenResult.success('  내일 미팅  ');
    expect(success.isSuccess, isTrue);
    expect(success.text, '내일 미팅');

    final failure = SttListenResult.failure(
      failure: SttListenFailure.silence,
      message: '음성이 인식되지 않았어요.',
    );
    expect(failure.isSuccess, isFalse);
    expect(failure.hasText, isFalse);
    expect(failure.failure, SttListenFailure.silence);
  });

  test('SttService detects local voice edit commands', () {
    expect(SttService.detectVoiceCommand('아니'), SttVoiceCommand.undoLastWord);
    expect(SttService.detectVoiceCommand('아니,'), SttVoiceCommand.undoLastWord);
    expect(SttService.detectVoiceCommand('아니.'), SttVoiceCommand.undoLastWord);
    expect(
      SttService.detectVoiceCommand('마지막 거 지워'),
      SttVoiceCommand.undoLastSegment,
    );
    expect(
      SttService.detectVoiceCommand('마지막 거 지워.'),
      SttVoiceCommand.undoLastSegment,
    );
    expect(SttService.detectVoiceCommand('처음부터'), SttVoiceCommand.clearAll);
    expect(
      SttService.detectVoiceCommand('다시 말할게!'),
      SttVoiceCommand.clearAll,
    );
    expect(SttService.detectVoiceCommand('취소'), SttVoiceCommand.cancel);
    expect(SttService.detectVoiceCommand('내일 대전 출발'), SttVoiceCommand.none);
  });

  test('SttService normalizes voice correction phrases in transcripts', () {
    expect(
      SttService.normalizeVoiceTranscript('내일 오전 9시 아니 오전 10시에 대전으로 출발'),
      '내일 오전 10시에 대전으로 출발',
    );
    expect(
      SttService.normalizeVoiceTranscript('내일 오전 9시 아니 오전10시에 대전으로 출발'),
      '내일 오전10시에 대전으로 출발',
    );
    expect(
      SttService.normalizeVoiceTranscript('내일 미팅 마지막 거 지워 오후 3시에'),
      '내일 오후 3시에',
    );
    expect(
      SttService.normalizeVoiceTranscript(
        '요미 허리 약5 요미 허리 약 5분 뒤에 주 요미 허리 약 5분 뒤에 주기',
      ),
      '요미 허리 약 5분 뒤에 주기',
    );
    expect(
      SttService.normalizeVoiceTranscript('내일 열두시반 병원 내일 열두시반 병원'),
      '내일 열두시반 병원',
    );
    expect(
      SttService.normalizeVoiceTranscript(
        '내일 서울에서 성남에서 아이스크림 전달일정 이번주 목요일 오전9시로 변경',
      ),
      '내일 서울에서 성남에서 아이스크림 전달일정 이번주 목요일 오전9시로 변경',
    );
  });

  test('SttService appends only new speech when Android partials overlap', () {
    expect(
      SttService.appendOnlyNewSpeech('내일 오전 9시에 대전으로', '대전으로 출발'),
      '출발',
    );
    expect(
      SttService.appendOnlyNewSpeech('내일 오전 9시에 대전으로 출발', '대전으로 출발'),
      '',
    );
    expect(
      SttService.appendOnlyNewSpeech('', '내일 오전 9시에'),
      '내일 오전 9시에',
    );
  });
}
