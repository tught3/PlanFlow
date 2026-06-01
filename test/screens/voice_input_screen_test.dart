import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:planflow/services/voice_command_analysis_service.dart';
import 'package:planflow/screens/voice/voice_conversation_screen.dart';
import 'package:planflow/screens/voice/voice_input_screen.dart';

class _FakeDraftAnalysisService extends VoiceCommandAnalysisService {
  _FakeDraftAnalysisService({required this.parsedSchedule})
      : super(endpoint: Uri.parse('https://example.com'));

  final Map<String, dynamic> parsedSchedule;
  int analyzeCalls = 0;

  @override
  Future<VoiceCommandAnalysisResult> analyze(
    String rawText, {
    VoiceCommandAnalysisStage stage = VoiceCommandAnalysisStage.partial,
    dynamic context,
    Iterable<dynamic> candidates = const [],
    VoiceAnalysisRequestBudget? budget,
    VoiceCommandAnalysisResult? previousDraft,
  }) async {
    analyzeCalls += 1;
    return VoiceCommandAnalysisResult(
      rawText: rawText,
      cleanedText: rawText,
      normalizedText: rawText,
      intent: VoiceCommandIntent.add,
      confidence: 0.92,
      uncertainFields: const <String>[],
      scheduleFields: <String, dynamic>{
        ...parsedSchedule,
        'title': parsedSchedule['title'] ?? rawText,
      },
      targetEventHint: null,
      requestedChanges: const <String>[],
      method: VoiceCommandAnalysisMethod.ai,
      stage: stage,
      analysisSignature: 'fake',
      fromCache: false,
    );
  }
}

class _FakeIntentAnalysisService extends VoiceCommandAnalysisService {
  _FakeIntentAnalysisService({required this.intent})
      : super(endpoint: Uri.parse('https://example.com'));

  final VoiceCommandIntent intent;

  @override
  Future<VoiceCommandAnalysisResult> analyze(
    String rawText, {
    VoiceCommandAnalysisStage stage = VoiceCommandAnalysisStage.partial,
    dynamic context,
    Iterable<dynamic> candidates = const [],
    VoiceAnalysisRequestBudget? budget,
    VoiceCommandAnalysisResult? previousDraft,
  }) async {
    return VoiceCommandAnalysisResult(
      rawText: rawText,
      cleanedText: rawText,
      normalizedText: rawText,
      intent: intent,
      confidence: 0.91,
      uncertainFields: const <String>[],
      scheduleFields: <String, dynamic>{
        'title': rawText,
        'supplies': <String>[],
        'is_critical': false,
        'pre_actions': <Map<String, dynamic>>[],
        'voice_intent': intent.name,
      },
      targetEventHint: null,
      requestedChanges: const <String>[],
      method: VoiceCommandAnalysisMethod.ai,
      stage: stage,
      analysisSignature: 'fake-intent',
      fromCache: false,
    );
  }
}

class _FakeSttService extends SttService {
  Completer<SttListenResult>? _listenCompleter;
  ValueChanged<String>? _onPartialResult;
  String _latestText = '';
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) {
    listenCalls += 1;
    _onPartialResult = onPartialResult;
    _listenCompleter = Completer<SttListenResult>();
    return _listenCompleter!.future;
  }

  void emitPartial(String text) {
    _latestText = text;
    _onPartialResult?.call(text);
  }

  void completeFailure({
    SttListenFailure failure = SttListenFailure.silence,
    String message = 'no speech',
  }) {
    if (_listenCompleter != null && !_listenCompleter!.isCompleted) {
      _listenCompleter!.complete(
        SttListenResult.failure(
          failure: failure,
          message: message,
          text: _latestText,
        ),
      );
    }
  }

  @override
  Future<void> stopActiveListen() async {
    stopCalls += 1;
    if (_listenCompleter != null && !_listenCompleter!.isCompleted) {
      _listenCompleter!.complete(SttListenResult.success(_latestText));
    }
  }

  @override
  Future<void> cancelActiveListen() async {
    cancelCalls += 1;
    if (_listenCompleter != null && !_listenCompleter!.isCompleted) {
      _listenCompleter!.complete(
        SttListenResult.failure(
          failure: SttListenFailure.unavailable,
          message: 'cancelled',
          text: _latestText,
        ),
      );
    }
  }

  @override
  Future<String> undoLastSpeechSegment() async {
    final words = _latestText.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || words.first.isEmpty) {
      return '';
    }
    words.removeLast();
    _latestText = words.join(' ');
    return _latestText;
  }

  @override
  Future<String> clearActiveTranscript() async {
    _latestText = '';
    return '';
  }
}

GoRoute _voiceConversationTestRoute() {
  return GoRoute(
    path: AppRoutes.voiceConversation,
    builder: (context, state) {
      final extra = state.extra as Map<String, dynamic>;
      return Text(
        '음성 대화: ${extra['initial_text']}',
        textDirection: TextDirection.ltr,
      );
    },
  );
}

void main() {
  testWidgets('위젯 자동 시작은 초기 무음 실패 시 한 번 다시 시도한다', (tester) async {
    final fakeStt = _FakeSttService();

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: true,
          sttService: fakeStt,
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 590));
    expect(fakeStt.listenCalls, 0);

    await tester.pump(const Duration(milliseconds: 20));
    expect(fakeStt.listenCalls, 1);

    fakeStt.completeFailure();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 650));

    expect(fakeStt.listenCalls, 2);
    expect(find.text('완료'), findsOneWidget);
  });

  testWidgets('partial 결과로 준비된 draft가 완료 시 우선 전달된다', (tester) async {
    final fakeStt = _FakeSttService();
    final fakeAnalysis = _FakeDraftAnalysisService(
      parsedSchedule: <String, dynamic>{
        'title': '내일 오전 10시 정장집 방문',
        'start_at': '2026-05-13T10:00:00.000',
        'end_at': null,
        'supplies': <String>[],
        'is_critical': false,
        'pre_actions': <Map<String, dynamic>>[],
        'parse_failed': false,
      },
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
            voiceAnalysisService: fakeAnalysis,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              'draft:${extra['title']}|pending:${extra['parse_pending'] == true}|manual:${extra['manual_text_confirmed'] == true}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();
    expect(find.text('일정 분석 중'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('준비됨'), findsOneWidget);

    await tester.tap(find.text('완료'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('draft:내일 오전 10시 정장집 방문|pending:false|manual:false'),
      findsOneWidget,
    );
    expect(fakeAnalysis.analyzeCalls, 1);
  });

  testWidgets('직접 수정하면 준비된 draft를 덮어쓰지 않는다', (tester) async {
    final fakeStt = _FakeSttService();
    final fakeAnalysis = _FakeDraftAnalysisService(
      parsedSchedule: <String, dynamic>{
        'title': '내일 오전 10시 정장집 방문',
        'start_at': '2026-05-13T10:00:00.000',
        'end_at': null,
        'supplies': <String>[],
        'is_critical': false,
        'pre_actions': <Map<String, dynamic>>[],
        'parse_failed': false,
      },
    );

    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
            voiceAnalysisService: fakeAnalysis,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              'manual:${extra['manual_text_confirmed'] == true}|pending:${extra['parse_pending'] == true}|raw:${extra['raw_text']}|memo:${extra['memo']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('준비됨'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '내일 오전 11시 정장집 방문');
    await tester.pump();
    expect(find.text('준비됨'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('voice-input-confirm-current-text-button')),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('manual:true|pending:true'), findsOneWidget);
    expect(find.textContaining('내일 오전 11시 정장집 방문'), findsOneWidget);
  });

  testWidgets('직접 수정 뒤 늦게 들어온 partial STT가 수정값을 덮지 않는다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              'manual:${extra['manual_text_confirmed'] == true}|pending:${extra['parse_pending'] == true}|memo:${extra['memo']}|raw:${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '내일 오전 11시 정장집 방문');
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.text('완료'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('manual:true'), findsOneWidget);
    expect(find.textContaining('정장집 방문'), findsOneWidget);
    expect(find.textContaining('내일 오전 10시 정장집 방문'), findsNothing);
  });

  testWidgets('현재 내용으로 입력 버튼은 수정한 텍스트를 그대로 확인 화면으로 보낸다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              'manual:${extra['manual_text_confirmed'] == true}|pending:${extra['parse_pending'] == true}|raw:${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '내일 오전 11시 정장집 방문');
    await tester.pump();

    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('manual:true'), findsOneWidget);
    expect(find.textContaining('pending:true'), findsOneWidget);
    expect(find.textContaining('memo:내일 오전 11시 정장집 방문'), findsNothing);
    expect(find.textContaining('정장집 방문'), findsOneWidget);
  });

  testWidgets('현재 내용으로 입력 버튼은 텍스트가 비었을 때 비활성이다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VoiceInputScreen(autoStartOverride: false),
      ),
    );

    final button = tester.widgetList(
      find.byKey(const ValueKey('voice-input-confirm-current-text-button')),
    );
    final confirmButton = button.first as FilledButton;
    expect(confirmButton.onPressed, isNull);

    expect(
      find.text('현재 내용으로 입력하려면 텍스트를 먼저 입력해 주세요.'),
      findsOneWidget,
    );
  });

  testWidgets('음성 입력 화면은 짧은 사용 예시를 보여준다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VoiceInputScreen(autoStartOverride: false),
      ),
    );

    expect(find.text('말하거나 직접 입력한 뒤 바로 확인하세요.'), findsNothing);
    expect(find.text('이렇게 말해보세요'), findsOneWidget);
    expect(
      find.textContaining('매주 화요일 오전 10시 강남역에서 팀장님 면접 준비'),
      findsOneWidget,
    );
    expect(
      find.textContaining('제어: 다시=전체삭제 · 아니=교정 · 마지막삭제=일부삭제 · 취소=종료'),
      findsOneWidget,
    );
  });

  testWidgets('음성 입력 화면은 AI 대화 모드와 별도 이어 명령 버튼을 숨긴다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VoiceInputScreen(autoStartOverride: false),
      ),
    );

    expect(find.text('AI 일정 대화 모드'), findsNothing);
    expect(
      find.byKey(const ValueKey('voice-conversation-mode-button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('voice-continue-listening-button')),
      findsNothing,
    );

    await tester.enterText(find.byType(TextField), '내일 오전 10시');
    await tester.pumpAndSettle();

    expect(find.text('이어서 명령하기'), findsNothing);
    expect(
      find.byKey(const ValueKey('voice-continue-listening-button')),
      findsNothing,
    );
  });

  testWidgets('텍스트가 있을 때 음성 버튼은 이어말하기 선택 후 기존 텍스트에 붙인다', (tester) async {
    final fakeStt = _FakeSttService();

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: false,
          sttService: fakeStt,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '내일 오전 10시');
    await tester.pump();

    expect(find.text('음성으로 다시 입력하기'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pumpAndSettle();

    expect(find.text('현재 입력된 내용이 있어요'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('voice-append-existing-text-button')));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '내일 오전 10시',
    );
    expect(find.text('완료'), findsOneWidget);

    fakeStt.emitPartial('정장집 방문');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '내일 오전 10시 정장집 방문',
    );
    expect(
      find.byKey(const ValueKey('voice-continue-listening-button')),
      findsNothing,
    );
  });

  testWidgets('텍스트가 있을 때 지우고 다시 입력을 고르면 기존 텍스트를 비우고 새 STT를 시작한다',
      (tester) async {
    final fakeStt = _FakeSttService();

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: false,
          sttService: fakeStt,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '내일 오전 10시');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey('voice-restart-with-empty-text-button')));
    await tester.pump();

    expect(fakeStt.listenCalls, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(find.text('완료'), findsOneWidget);
  });

  testWidgets('텍스트가 있을 때 취소를 고르면 기존 텍스트를 보존하고 STT를 시작하지 않는다', (tester) async {
    final fakeStt = _FakeSttService();

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: false,
          sttService: fakeStt,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '내일 오전 10시');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('voice-keep-existing-text-button')));
    await tester.pumpAndSettle();

    expect(fakeStt.listenCalls, 0);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '내일 오전 10시',
    );
  });

  testWidgets('텍스트가 있을 때 다시 입력 버튼은 tertiary accent 색상을 쓴다', (tester) async {
    final fakeStt = _FakeSttService();

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: false,
          sttService: fakeStt,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '내일 오전 10시');
    await tester.pump();

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('voice-primary-button')),
    );
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      PlanFlowColors.tertiaryAccent,
    );
  });

  testWidgets('텍스트가 없어도 음성 시작 버튼은 tertiary accent 색상을 쓴다', (tester) async {
    final fakeStt = _FakeSttService();

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: false,
          sttService: fakeStt,
        ),
      ),
    );

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('voice-primary-button')),
    );
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      PlanFlowColors.tertiaryAccent,
    );
  });

  testWidgets('직접 입력을 반복해도 TextStyle 보간/GlobalKey 오류가 없다', (tester) async {
    final fakeStt = _FakeSttService();
    final capturedErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = capturedErrors.add;
    addTearDown(() {
      FlutterError.onError = previousOnError;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: false,
          sttService: fakeStt,
        ),
      ),
    );

    final field = find.byType(TextField);
    for (var index = 0; index < 4; index += 1) {
      await tester.enterText(field, '테스트 $index');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.enterText(field, '');
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pumpAndSettle();

    final relevantErrors = capturedErrors.where((details) {
      final text = details.exceptionAsString();
      return text.contains('Failed to interpolate TextStyle') ||
          text.contains('GlobalKey') ||
          text.contains('Multiple widgets used the same GlobalKey');
    });
    expect(relevantErrors, isEmpty);
  });

  testWidgets('제출 후 이어 말하기는 이전 조회 문장에 새 명령을 붙이지 않는다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        _voiceConversationTestRoute(),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();
    expect(find.text('음성 대화: 오늘 일정 알려줘'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('voice-append-existing-text-button')));
    await tester.pump();

    fakeStt.emitPartial('3번째 일정 삭제');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '3번째 일정 삭제',
    );
  });

  testWidgets('AI 일정 대화 종료 결과는 부모 음성입력의 잔여 문장을 초기화한다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => TextButton(
            onPressed: () => context.pop(voiceConversationClosedResult),
            child: const Text('AI 대화 종료'),
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '삭제 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.text('AI 대화 종료'), findsOneWidget);

    await tester.tap(find.text('AI 대화 종료'));
    await tester.pumpAndSettle();

    expect(find.textContaining('AI 일정 대화를 종료했어요'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );

    await tester.enterText(find.byType(TextField), '응 삭제');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '응 삭제',
    );
    expect(find.text('삭제 화면'), findsNothing);
    expect(find.textContaining('오늘 일정 알려줘 응 삭제'), findsNothing);
  });

  testWidgets('부분 인식에서 전체삭제가 오면 현재 입력을 즉시 비운다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문 전체 삭제');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '');
    expect(find.text('전체 입력을 지웠어요.'), findsOneWidget);
  });

  testWidgets('부분 인식에서 취소가 오면 듣기가 중단되고 명령어가 사라진다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();
    fakeStt.emitPartial('취소');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '');
    expect(find.text('음성 입력을 취소했어요. 다시 시작할 수 있습니다.'), findsOneWidget);
    expect(find.text('완료'), findsNothing);
  });

  testWidgets('일반 음성 문장은 일정 확인 화면으로 바로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '일정 확인: ${extra['raw_text']} / ${extra['start_at']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '5분 뒤 요미 허리 약 주기');
    await tester.pumpAndSettle();

    expect(find.text('현재 내용으로 입력'), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('일정 확인:'), findsOneWidget);
    expect(find.textContaining('5분 뒤 요미 허리 약 주기'), findsOneWidget);
    expect(find.textContaining('T'), findsOneWidget);
    expect(find.text('음성 관리 화면'), findsNothing);
  });

  testWidgets('대상과 장소가 분리된 장소 추가 명령은 수정 화면으로 바로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        _voiceConversationTestRoute(),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(
      find.byType(TextField),
      '이번 주 금요일 6시에 있는 일정에 강릉 건도리 횟집 장소 추가',
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('voice-input-confirm-current-text-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('어떤 뜻인가요?'), findsNothing);
    expect(find.textContaining('음성 관리: edit'), findsOneWidget);
    expect(find.textContaining('강릉 건도리 횟집'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('대상과 장소가 분리되지 않는 장소 추가 명령은 뜻을 먼저 묻는다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '내일 오전 10시 일정 장소 추가');
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('voice-input-confirm-current-text-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('어떤 뜻인가요?'), findsOneWidget);
    expect(find.text('기존 일정에 내용 추가'), findsOneWidget);
    expect(find.text('새 일정으로 추가'), findsOneWidget);

    await tester.tap(find.text('기존 일정에 내용 추가'));
    await tester.pumpAndSettle();
    expect(find.textContaining('음성 관리: edit'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('수동 제출과 STT 완료가 겹쳐도 한 번만 이동한다', (tester) async {
    final fakeStt = _FakeSttService();
    var confirmBuildCount = 0;
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            confirmBuildCount += 1;
            return Text(
              '일정 확인 $confirmBuildCount',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await fakeStt.stopActiveListen();
    await tester.pumpAndSettle();

    expect(find.text('일정 확인 1'), findsOneWidget);
    expect(confirmBuildCount, 1);
  });

  testWidgets('음성 입력 중 화면 이동 전 STT를 종료한다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.text('완료'));
    await tester.pumpAndSettle();

    expect(fakeStt.stopCalls, greaterThanOrEqualTo(1));
    expect(find.text('일정 확인'), findsOneWidget);
  });

  testWidgets('완료 이후 늦게 도착한 partial은 제출 텍스트에 붙지 않는다', (tester) async {
    final fakeStt = _FakeSttService();
    Object? confirmExtra;
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            confirmExtra = state.extra;
            return const Text(
              '일정 확인',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.text('완료'));
    fakeStt.emitPartial('이거 왜 이래');
    await tester.pumpAndSettle();

    expect(fakeStt.stopCalls, greaterThanOrEqualTo(1));
    expect(find.text('일정 확인'), findsOneWidget);
    expect(confirmExtra, isA<Map<String, dynamic>>());
    final payload = confirmExtra! as Map<String, dynamic>;
    expect(payload['raw_text'], contains('정장집 방문'));
    expect(payload['raw_text'], isNot(contains('이거 왜 이래')));
  });

  testWidgets('음성 입력 중 화면을 벗어나면 STT 세션을 취소한다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const Text(
            '홈',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    router.go(AppRoutes.home);
    await tester.pumpAndSettle();
    fakeStt.emitPartial('이전 세션 늦은 결과');
    await tester.pump();

    expect(fakeStt.cancelCalls, 1);
    expect(find.text('홈'), findsOneWidget);
    expect(find.text('이전 세션 늦은 결과'), findsNothing);
  });

  testWidgets('듣는 중 앱바 뒤로가기는 stop 없이 STT를 취소하고 홈으로 나간다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const Text(
            '홈',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();

    expect(fakeStt.cancelCalls, 1);
    expect(fakeStt.stopCalls, 0);
    expect(find.text('홈'), findsOneWidget);
  });

  testWidgets('하단 탭 이동은 STT를 취소하고 늦은 partial을 다음 화면에 붙이지 않는다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const Text(
            '홈',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.calendar,
          builder: (context, state) => const Text(
            '일정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (context, state) => const Text(
            '설정 탭',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice-bottom-calendar-tab')));
    await tester.pumpAndSettle();
    fakeStt.emitPartial('이전 세션 늦은 결과');
    await tester.pump();

    expect(fakeStt.cancelCalls, 1);
    expect(fakeStt.stopCalls, 0);
    expect(find.text('일정 탭'), findsOneWidget);
    expect(find.text('이전 세션 늦은 결과'), findsNothing);
  });

  testWidgets('직접입력 전환 후 재진입해도 새 음성 입력을 시작한다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const Text(
            '홈',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(fakeStt.stopCalls, 1);

    router.go(AppRoutes.home);
    await tester.pumpAndSettle();
    router.go(AppRoutes.voice);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    expect(fakeStt.listenCalls, 2);
  });

  testWidgets('듣는 중 텍스트를 탭하면 자동 제출 대신 키보드 수정으로 전환한다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();
    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(fakeStt.stopCalls, 1);
    expect(find.text('일정 확인'), findsNothing);
    expect(
      find.text('음성 인식을 잠시 멈췄어요. 키보드로 수정해 주세요.'),
      findsOneWidget,
    );
    expect(tester.testTextInput.isVisible, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '내일 오전 10시 정장집 방문',
    );
  });

  testWidgets('이동 표현은 후보 선택이 아니라 수정 화면으로 간다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              'action:${extra['action']}|raw:${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '내일 팀장님 동행방문 다음 주 수요일로 이동');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('action:edit'), findsOneWidget);
    expect(find.textContaining('내일 팀장님 동행방문 다음 주 수요일로 이동'), findsOneWidget);
  });

  testWidgets(
    '오늘 오후 3시에서 4시 사이에 팀장님한테 내일 오는 시간 확인하기는 추가로 분류된다',
    (tester) async {
      final router = GoRouter(
        initialLocation: AppRoutes.voice,
        routes: [
          GoRoute(
            path: AppRoutes.voice,
            builder: (context, state) =>
                const VoiceInputScreen(autoStartOverride: false),
          ),
          GoRoute(
            path: AppRoutes.confirm,
            builder: (context, state) {
              final extra = state.extra as Map<String, dynamic>;
              return Text(
                '일정 확인: ${extra['raw_text']}',
                textDirection: TextDirection.ltr,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.voiceAction,
            builder: (context, state) => const Text(
              '음성 관리 화면',
              textDirection: TextDirection.ltr,
            ),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.enterText(
        find.byType(TextField),
        '오늘 오후 3시에서 4시 사이에 팀장님한테 내일 오는 시간 확인하기',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('현재 내용으로 입력'));
      await tester.pumpAndSettle();

      expect(find.textContaining('일정 확인:'), findsOneWidget);
      expect(
        find.textContaining('오늘 오후 3시에서 4시 사이에 팀장님한테 내일 오는 시간 확인하기'),
        findsOneWidget,
      );
      expect(find.text('음성 관리 화면'), findsNothing);
    },
  );

  testWidgets('수정 의도가 명확하면 음성 관리 화면으로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '한강 피크닉 수정해줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.text('음성 관리: edit'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('일정 변경 표현도 수정 화면으로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '한강 피크닉 내일 열두시반으로 미뤄줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 관리: edit'), findsOneWidget);
    expect(find.textContaining('열두시반으로 미뤄줘'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('중복 인식된 문장은 정리해서 다음 화면으로 전달한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '일정 확인: ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(
      find.byType(TextField),
      '내일 열두시반 병원 내일 열두시반 병원',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.text('일정 확인: 내일 열두시반 병원'), findsOneWidget);
    expect(find.textContaining('내일 열두시반 병원 내일'), findsNothing);
  });

  testWidgets(
    '부분/직접 입력 문장도 inline 제어어로 정규화된 텍스트를 제출한다',
    (tester) async {
      final router = GoRouter(
        initialLocation: AppRoutes.voice,
        routes: [
          GoRoute(
            path: AppRoutes.voice,
            builder: (context, state) => const VoiceInputScreen(
              autoStartOverride: false,
            ),
          ),
          GoRoute(
            path: AppRoutes.confirm,
            builder: (context, state) {
              final extra = state.extra as Map<String, dynamic>;
              return Text(
                '일정 확인: ${extra['raw_text']}',
                textDirection: TextDirection.ltr,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.voiceAction,
            builder: (context, state) => const Text(
              '음성 관리 화면',
              textDirection: TextDirection.ltr,
            ),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.enterText(find.byType(TextField), '내일 오전 9시 아니 오후 2시 회의');
      await tester.pumpAndSettle();

      await tester.tap(find.text('현재 내용으로 입력'));
      await tester.pumpAndSettle();

      expect(find.textContaining('일정 확인:'), findsOneWidget);
      expect(find.textContaining('일정 확인: 내일 오후 2시 회의'), findsOneWidget);
      expect(find.text('음성 관리 화면'), findsNothing);
    },
  );

  testWidgets('partial 문장 속 취소는 일반 일정 내용이면 입력을 유지한다', (tester) async {
    final fakeStt = _FakeSttService();
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '일정 확인: ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) => const Text(
            '음성 관리 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    fakeStt.emitPartial('계약');
    await tester.pump();
    fakeStt.emitPartial('계약 취소');
    await tester.pump();
    fakeStt.emitPartial('계약 취소 확인 전화');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '계약 취소 확인 전화');
    expect(find.textContaining('음성 입력을 취소했어요'), findsNothing);
    expect(find.text('완료'), findsOneWidget);
  });

  testWidgets('내일 일정 확인해줘는 음성 조회 화면으로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        _voiceConversationTestRoute(),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '내일 일정 확인해줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 대화:'), findsOneWidget);
    expect(find.textContaining('내일 일정 확인해줘'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('오늘 일정 알려줘는 음성 조회 화면으로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        _voiceConversationTestRoute(),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 대화:'), findsOneWidget);
    expect(find.textContaining('오늘 일정 알려줘'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('저장된 일정 찾아줘는 음성 조회 화면으로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        _voiceConversationTestRoute(),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '저장된 일정 찾아줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 대화:'), findsOneWidget);
    expect(find.textContaining('저장된 일정 찾아줘'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('내일 일정 확인하기는 일정 추가가 아니라 조회로 분류한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        _voiceConversationTestRoute(),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '내일 일정 확인하기');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 대화:'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('저장된 일정 보여줘는 저장 명령이 아니라 조회로 분류한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        _voiceConversationTestRoute(),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '저장된 일정 보여줘');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 대화:'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
  });

  testWidgets('조회 단독 표현은 조회 화면으로 직행하지 않고 관리 선택으로 이동한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => const Text(
            '일정 확인 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']} / ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '일정 조회');
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성 관리: choose'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
    expect(find.textContaining('음성 관리: query'), findsNothing);
  });

  testWidgets('확인하기로 저장은 조회가 아니라 일정 추가로 분류한다', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) =>
              const VoiceInputScreen(autoStartOverride: false),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '일정 확인: ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(
      find.byType(TextField),
      '내일 오전 원주 세브란스 병원 약재과 방문해서 제 2 세덱스 통과됐는지 확인하기로 저장',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('일정 확인:'), findsOneWidget);
    expect(find.textContaining('확인하기로 저장'), findsOneWidget);
    expect(find.textContaining('음성 관리:'), findsNothing);
  });

  testWidgets('사전분석이 조회로 잘못 봐도 저장 의도가 있으면 추가를 우선한다', (tester) async {
    final fakeStt = _FakeSttService();
    final fakeAnalysis = _FakeIntentAnalysisService(
      intent: VoiceCommandIntent.query,
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => VoiceInputScreen(
            autoStartOverride: false,
            sttService: fakeStt,
            voiceAnalysisService: fakeAnalysis,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '일정 확인: ${extra['raw_text']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.voiceAction,
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              '음성 관리: ${extra['action']}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pump();

    fakeStt.emitPartial('내일 세브란스 방문해서 확인하기로 저장');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('완료'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('일정 확인:'), findsOneWidget);
    expect(find.textContaining('음성 관리:'), findsNothing);
  });

  testWidgets('기존 음성 버튼의 이어말하기 선택은 기존 문장을 유지한 채 음성 인식을 다시 시작한다',
      (tester) async {
    final fakeStt = _FakeSttService();
    await tester.pumpWidget(
      MaterialApp(
        home: VoiceInputScreen(
          autoStartOverride: false,
          sttService: fakeStt,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '이번 주 금요일 6시 일정에');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('voice-continue-listening-button')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('voice-primary-button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('voice-append-existing-text-button')));
    await tester.pump();

    expect(fakeStt.listenCalls, 1);
    expect(find.text('완료'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice-continue-listening-button')),
      findsNothing,
    );

    fakeStt.emitPartial('강릉 건도리 횟집 장소 추가');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(
      textField.controller?.text,
      '이번 주 금요일 6시 일정에 강릉 건도리 횟집 장소 추가',
    );
  });


  testWidgets('?? ?? ? ???? ?? ??? ?? ?? ???', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoutes.voice,
      routes: [
        GoRoute(
          path: AppRoutes.voice,
          builder: (context, state) => const VoiceInputScreen(
            autoStartOverride: false,
          ),
        ),
        GoRoute(
          path: AppRoutes.confirm,
          builder: (context, state) => TextButton(
            onPressed: () => context.pop(),
            child: const Text('??'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(
      find.byType(TextField),
      '?? ?? 7?? ??? ??? ??',
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('voice-input-confirm-current-text-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('??'), findsOneWidget);

    await tester.tap(find.text('??'));
    await tester.pumpAndSettle();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, isEmpty);
    expect(find.text('?? ?? 7?? ??? ??? ??'), findsNothing);
  });

}
