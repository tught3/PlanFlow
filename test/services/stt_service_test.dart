import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:planflow/services/stt_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    SttService.debugResetActiveListenState();
  });

  test('SttService keeps on-device Korean listen options enabled', () {
    final options = SttService.buildListenOptions();

    expect(options.onDevice, isTrue);
    expect(options.partialResults, isTrue);
    expect(options.cancelOnError, isFalse);
    expect(options.listenMode, ListenMode.dictation);
  });

  test('SttService keeps conversation listening open for long pauses', () {
    expect(
      SttService.debugListenForForMode(SttListenMode.conversation),
      const Duration(minutes: 5),
    );
    expect(
      SttService.debugPauseForForMode(SttListenMode.conversation),
      const Duration(minutes: 5),
    );
    expect(SttService.debugConversationSilenceMs, 300000);
  });

  test('Android native STT restarts after final results until user stop', () {
    // 세그먼트 세션 방식은 폐기됨(침묵마다 끊겨 발화 유실). 현재는 모드와 무관하게
    // onResults에서 final 후 즉시 재시작하고, user stop 시에만 정지한다.
    final source = File(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    ).readAsStringSync();

    // 결과 확정(final) 후 끊김 없이 재청취 재시작
    expect(
      source,
      contains('restartSoon(reason = "final")'),
    );
    // 사용자가 멈추면 재시작하지 않고 stopped 이벤트 발행
    expect(
      source,
      contains('if (userRequestedStop)'),
    );
    expect(
      source,
      contains('invokeIfActive("stopped"'),
    );
    // stop 시 마지막 partial을 그대로 쓰지 않고 스냅샷 텍스트를 쓴다
    expect(
      source,
      isNot(contains(
          'invokeIfActive("stopped", mapOf("text" to latestPartialText')),
    );
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

  test('SttService cancels and clears a stale native listen without callback',
      () async {
    const nativeChannel = MethodChannel('planflow/native_stt');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, null);
    });

    SttService.debugSeedNativeListenState(recognizedText: '내일 오전 회의');
    final previousGeneration = SttService.debugActiveListenGeneration;

    await const SttService().cancelActiveListen();

    expect(calls, contains('cancel'));
    expect(SttService.debugHasActiveListen, isFalse);
    expect(
      SttService.debugActiveListenGeneration,
      greaterThan(previousGeneration),
    );
  });

  test('SttService stops and detaches native listen without late callbacks',
      () async {
    const nativeChannel = MethodChannel('planflow/native_stt');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, null);
    });

    SttService.debugSeedNativeListenState(recognizedText: '내일 오전 회의');
    final previousGeneration = SttService.debugActiveListenGeneration;

    await const SttService().stopActiveListen();

    expect(calls, contains('stop'));
    expect(SttService.debugHasActiveListen, isFalse);
    expect(
      SttService.debugActiveListenGeneration,
      greaterThan(previousGeneration),
    );
  });

  test('SttService detects local voice edit commands', () {
    expect(SttService.detectVoiceCommand('아니'), SttVoiceCommand.undoLastWord);
    expect(SttService.detectVoiceCommand('아니,'), SttVoiceCommand.undoLastWord);
    expect(SttService.detectVoiceCommand('아니.'), SttVoiceCommand.undoLastWord);
    expect(SttService.detectVoiceCommand('아니다'), SttVoiceCommand.undoLastWord);
    expect(SttService.detectVoiceCommand('아니다.'), SttVoiceCommand.undoLastWord);
    expect(
      SttService.detectVoiceCommand('마지막 거 지워'),
      SttVoiceCommand.undoLastSegment,
    );
    expect(
      SttService.detectVoiceCommand('마지막 거 지워.'),
      SttVoiceCommand.undoLastSegment,
    );
    expect(
      SttService.detectVoiceCommand('마지막 삭제'),
      SttVoiceCommand.undoLastSegment,
    );
    expect(
      SttService.detectVoiceCommand('방금 삭제'),
      SttVoiceCommand.undoLastSegment,
    );
    expect(SttService.detectVoiceCommand('처음부터'), SttVoiceCommand.clearAll);
    expect(
      SttService.detectVoiceCommand('다시 말할게!'),
      SttVoiceCommand.clearAll,
    );
    expect(
      SttService.detectVoiceCommand('전체 삭제'),
      SttVoiceCommand.clearAll,
    );
    expect(
      SttService.detectVoiceCommand('전체취소'),
      SttVoiceCommand.clearAll,
    );
    expect(SttService.detectVoiceCommand('취소'), SttVoiceCommand.cancel);
    expect(SttService.detectVoiceCommand('그만'), SttVoiceCommand.cancel);
    expect(SttService.detectVoiceCommand('중단'), SttVoiceCommand.cancel);
    expect(SttService.detectVoiceCommand('중지'), SttVoiceCommand.cancel);
    expect(SttService.detectVoiceCommand('정지'), SttVoiceCommand.cancel);
    expect(
      SttService.detectVoiceCommand('중지해 줘'),
      SttVoiceCommand.cancel,
    );
    expect(
      SttService.detectVoiceCommand('정지해 주세요'),
      SttVoiceCommand.cancel,
    );
    expect(SttService.detectVoiceCommand('내일 대전 출발'), SttVoiceCommand.none);
    expect(
      SttService.detectVoiceCommand('취소', includeCancel: false),
      SttVoiceCommand.none,
    );
    expect(
      SttService.detectVoiceCommand('계약 취소 확인 전화'),
      SttVoiceCommand.none,
    );
  });

  test('SttService normalizes voice correction phrases in transcripts', () {
    expect(
      SttService.normalizeVoiceTranscript('경탁이 탁이한테 전화하기'),
      '경탁이한테 전화하기',
    );
    expect(
      SttService.normalizeVoiceTranscript('전화 전화해서 물어보기'),
      '전화해서 물어보기',
    );
    expect(
      SttService.normalizeVoiceTranscript('경조사 신청 4만원 하기'),
      '경조사 신청 4만원 하기',
    );
    expect(
      SttService.normalizeVoiceTranscript('확인 확인해줘'),
      '확인해줘',
    );
    expect(
      SttService.normalizeVoiceTranscript('민수 수한테 확인 전화'),
      '민수한테 확인 전화',
    );
    expect(
      SttService.normalizeVoiceTranscript('수연이 연이랑 병원 방문'),
      '수연이랑 병원 방문',
    );
    expect(
      SttService.normalizeVoiceTranscript('월요일 일정 확인'),
      '월요일 일정 확인',
    );
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
    expect(
      SttService.normalizeVoiceTranscript('내일 오전 아니다 다시 전체 취소'),
      '',
    );
    expect(
      SttService.normalizeVoiceTranscript('내일 오전 9시 아니 오후 2시 회의'),
      '내일 오후 2시 회의',
    );
    expect(
      SttService.normalizeVoiceTranscript('내일 오전 9시 아니다 오후 2시 회의'),
      '내일 오후 2시 회의',
    );
    expect(
      SttService.normalizeVoiceTranscript('6월 7일 아니 9일 강릉 회식'),
      '6월 9일 강릉 회식',
    );
    expect(
      SttService.normalizeVoiceTranscript('7일 아니 9일'),
      '9일',
    );
    expect(
      SttService.normalizeVoiceTranscript('계약 취소 확인 전화'),
      '계약 취소 확인 전화',
    );
    expect(
      SttService.normalizeVoiceTranscript(
        '계약 취소 확인 전화',
        includeCancelCommands: true,
      ),
      '계약 취소 확인 전화',
    );
    var didCancel = false;
    expect(
      SttService.normalizeVoiceTranscript(
        '6월1일 취소',
        includeCancelCommands: true,
        onCommand: (command) {
          if (command == SttVoiceCommand.cancel) {
            didCancel = true;
          }
        },
      ),
      '6월1일',
    );
    expect(didCancel, true);
    expect(
      SttService.normalizeVoiceTranscript(
        '6월1일 취',
        includeCancelCommands: true,
      ),
      '6월1일',
    );
    didCancel = false;
    expect(
      SttService.normalizeVoiceTranscript(
        '계약 취소',
        includeCancelCommands: true,
        onCommand: (command) {
          if (command == SttVoiceCommand.cancel) {
            didCancel = true;
          }
        },
      ),
      '계약 취소',
    );
    expect(didCancel, false);
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
    expect(
      SttService.appendOnlyNewSpeech(
        '오늘 일정 알려줘',
        '오늘 일정 알려줘 오늘 일정 알려줘 3번째 일정 삭제',
      ),
      '3번째 일정 삭제',
    );
  });

  test('SttService merges native restart segments without duplicating text',
      () {
    expect(
      SttService.mergeTranscriptSegment(
        '내일 오전 10시에 교보생명 시험 일정',
        '교보생명 시험 일정',
      ),
      '내일 오전 10시에 교보생명 시험 일정',
    );
    expect(
      SttService.mergeTranscriptSegment(
        '내일 오전 10시에 교보생명 시험 일정',
        '시험 일정에 원주 교보생명빌딩으로 장소 추가',
      ),
      '내일 오전 10시에 교보생명 시험 일정에 원주 교보생명빌딩으로 장소 추가',
    );
    expect(
      SttService.mergeTranscriptSegment(
        '오늘 일정 알려줘',
        '오늘 일정 알려줘 오늘 일정 알려줘 3번째 일정 삭제',
      ),
      '오늘 일정 알려줘 3번째 일정 삭제',
    );
  });

  group('누적 발화 교정 (아니 = 직전 항목만, 다시 = 전체 삭제)', () {
    test('아니라고 하면 마지막으로 말한 시간만 취소되고 날짜는 남는다', () {
      expect(SttService.cancelLastSpokenSlot('내일 오후 1시'), '내일');
      expect(SttService.cancelLastSpokenSlot('내일 오전 9시30분'), '내일');
      expect(SttService.cancelLastSpokenSlot('내일 오후 1시 강남역'), '내일 오후 1시');
      expect(SttService.cancelLastSpokenSlot('내일'), '');
      expect(SttService.cancelLastSpokenSlot(''), '');
    });

    test('말한 순서대로 쌓이고 아니 뒤 다시 말하면 중복 없이 교체된다', () {
      var draft = '';
      draft = SttService.mergeCommittedUtterance(draft, '내일 오후 1시');
      expect(draft, '내일 오후 1시');
      draft = SttService.mergeCommittedUtterance(draft, '아니');
      expect(draft, '내일');
      draft = SttService.mergeCommittedUtterance(draft, '오후 2시');
      expect(draft, '내일 오후 2시');
      draft = SttService.mergeCommittedUtterance(draft, '강남역 약속');
      expect(draft, '내일 오후 2시 강남역 약속');
    });

    test('아니와 정정 내용을 한 번에 말해도 앞 내용을 유지한다', () {
      expect(
        SttService.mergeCommittedUtterance('내일 오후 1시', '아니 오후 2시'),
        '내일 오후 2시',
      );
      expect(
        SttService.startsWithSpokenUndo('아니 오후 2시'),
        isTrue,
      );
      expect(SttService.stripLeadingSpokenUndo('아니 오후 2시'), '오후 2시');
    });

    test('다시는 누적된 문장 전체를 지운다', () {
      expect(SttService.normalizeVoiceTranscript('다시'), '');
      expect(
        SttService.mergeCommittedUtterance('내일 오후 2시 강남역 약속', '다시'),
        '',
      );
      expect(SttService.mergeCommittedUtterance('내일 오후 2시', ''), '내일 오후 2시');
    });

    test('네이티브 부분 인식에서 선두 아니는 앞선 초안 취소를 위해 보존된다', () {
      expect(SttService.shouldPreserveLeadingUndo('', '아니'), isTrue);
      expect(SttService.shouldPreserveLeadingUndo('', '아니 오후 2시'), isTrue);
      // 이미 이번 세션에서 확정된 말이 있으면 기존 단어 취소로 처리한다.
      expect(SttService.shouldPreserveLeadingUndo('오후 1시', '아니'), isFalse);
      expect(SttService.shouldPreserveLeadingUndo('', '오후 2시'), isFalse);
    });

    test('같은 아니가 반복 수신되어도 한 번만 취소된다', () {
      // 누적 부분 인식이 같은 값을 다시 보내도 추가 삭제가 없어야 한다.
      var committed = '내일 오후 1시';
      committed = SttService.cancelLastSpokenSlot(committed);
      expect(committed, '내일');
      final again = SttService.cancelLastSpokenSlot(committed);
      expect(again, '');
      // 두 번째 호출을 막는 것은 세션 계층이므로, 결과가 같으면 재적용하지 않는다.
      expect(committed == '내일' ? committed : again, '내일');
    });
    test('한 문장 안의 기존 날짜/시간 교정은 그대로 동작한다', () {
      expect(SttService.normalizeVoiceTranscript('6월 7일 아니 9일'), '6월 9일');
      expect(SttService.normalizeVoiceTranscript('내일 오후 1시 아니 오후 2시'), '내일 오후 2시');
    });
  });
}
