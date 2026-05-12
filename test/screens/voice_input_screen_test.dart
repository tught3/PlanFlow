import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:planflow/services/voice_command_analysis_service.dart';
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

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
  }) {
    _onPartialResult = onPartialResult;
    _listenCompleter = Completer<SttListenResult>();
    return _listenCompleter!.future;
  }

  void emitPartial(String text) {
    _latestText = text;
    _onPartialResult?.call(text);
  }

  @override
  Future<void> stopActiveListen() async {
    if (_listenCompleter != null && !_listenCompleter!.isCompleted) {
      _listenCompleter!.complete(SttListenResult.success(_latestText));
    }
  }

  @override
  Future<void> cancelActiveListen() async {
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

void main() {
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
    await tester.tap(find.text('음성으로 일정 입력하기'));
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
    await tester.tap(find.text('음성으로 일정 입력하기'));
    await tester.pump();

    fakeStt.emitPartial('내일 오전 10시 정장집 방문');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('준비됨'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '내일 오전 11시 정장집 방문');
    await tester.pump();
    expect(find.text('준비됨'), findsNothing);

    await tester.tap(find.text('완료'));
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
    await tester.tap(find.text('음성으로 일정 입력하기'));
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

    await tester.tap(
      find.byKey(const ValueKey('voice-input-confirm-current-text-button')),
    );
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
    expect(find.textContaining('내일 오전 10시 정장집 방문'), findsOneWidget);
    expect(find.textContaining('5월 10일 하루종일 휴가'), findsOneWidget);
    expect(find.textContaining('매주 화요일 팀 미팅'), findsOneWidget);
    expect(find.textContaining('언제 일정을 다음주로 변경해'), findsOneWidget);
    expect(find.textContaining('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('병원 진료는 건강'), findsOneWidget);
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
    await tester.tap(find.text('현재 내용으로 입력'));
    await tester.pumpAndSettle();

    expect(find.textContaining('일정 확인:'), findsOneWidget);
    expect(find.textContaining('5분 뒤 요미 허리 약 주기'), findsOneWidget);
    expect(find.textContaining('T'), findsOneWidget);
    expect(find.text('음성 관리 화면'), findsNothing);
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

    expect(find.textContaining('음성 관리: query'), findsOneWidget);
    expect(find.textContaining('내일 일정 확인해줘'), findsOneWidget);
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

    expect(find.textContaining('음성 관리: query'), findsOneWidget);
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

    expect(find.textContaining('음성 관리: query'), findsOneWidget);
    expect(find.text('일정 확인 화면'), findsNothing);
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
    await tester.tap(find.text('음성으로 일정 입력하기'));
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
}
