import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/voice/voice_conversation_screen.dart';
import 'package:planflow/services/stt_service.dart';

class _FakeSttService extends SttService {
  Completer<SttListenResult>? _completer;
  ValueChanged<String>? _onPartialResult;

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
  }) {
    _onPartialResult = onPartialResult;
    _completer = Completer<SttListenResult>();
    return _completer!.future;
  }

  void emitPartial(String text) {
    _onPartialResult?.call(text);
  }

  void completeSuccess(String text) {
    _completer?.complete(SttListenResult.success(text));
  }

  void completeFailure(String message) {
    _completer?.complete(
      SttListenResult.failure(
        failure: SttListenFailure.silence,
        message: message,
      ),
    );
  }

  @override
  Future<void> cancelActiveListen() async {
    if (_completer != null && !_completer!.isCompleted) {
      completeFailure('취소됐어요.');
    }
  }
}

void main() {
  testWidgets('AI 일정 대화는 STT partial을 입력창에 즉시 보여준다', (tester) async {
    final stt = _FakeSttService();
    await tester.pumpWidget(
      MaterialApp(
        home: VoiceConversationScreen(sttService: stt),
      ),
    );

    await tester.tap(find.byTooltip('음성으로 말하기'));
    await tester.pump();

    expect(find.text('듣고 있어요...'), findsOneWidget);

    stt.emitPartial('이번주 금요일 일정');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '이번주 금요일 일정');
  });

  testWidgets('AI 일정 대화는 STT 성공 후 사용자 말과 응답을 표시한다', (tester) async {
    final stt = _FakeSttService();
    await tester.pumpWidget(
      MaterialApp(
        home: VoiceConversationScreen(sttService: stt),
      ),
    );

    await tester.tap(find.byTooltip('음성으로 말하기'));
    await tester.pump();

    stt.completeSuccess('오늘 일정 알려줘');
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
  });

  testWidgets('AI 일정 대화는 STT 실패도 화면에 안내로 남긴다', (tester) async {
    final stt = _FakeSttService();
    await tester.pumpWidget(
      MaterialApp(
        home: VoiceConversationScreen(sttService: stt),
      ),
    );

    await tester.tap(find.byTooltip('음성으로 말하기'));
    await tester.pump();

    stt.completeFailure('음성을 알아듣지 못했어요.');
    await tester.pumpAndSettle();

    expect(find.text('음성을 알아듣지 못했어요.'), findsWidgets);
  });

  testWidgets('AI 일정 대화는 initialText를 자동 제출한다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
  });
}
