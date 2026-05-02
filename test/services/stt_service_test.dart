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
}
