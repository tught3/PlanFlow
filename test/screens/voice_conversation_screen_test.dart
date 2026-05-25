import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/voice/voice_conversation_screen.dart';
import 'package:planflow/services/location_lookup_service.dart';
import 'package:planflow/services/stt_service.dart';

class _FakeSttService extends SttService {
  Completer<SttListenResult>? _completer;
  ValueChanged<String>? _onPartialResult;
  int cancelCalls = 0;

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
    cancelCalls += 1;
    if (_completer != null && !_completer!.isCompleted) {
      completeFailure('취소됐어요.');
    }
  }
}

class _FakeEventRepository extends EventRepository {
  _FakeEventRepository(this.events);

  final List<EventModel> events;
  final List<String> deletedIds = <String>[];

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => events;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in events) {
      if (event.id == eventId) {
        return event;
      }
    }
    return null;
  }

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedIds.add(eventId);
  }
}

class _SlowSecondListEventRepository extends EventRepository {
  _SlowSecondListEventRepository();

  final Completer<List<EventModel>> secondListCompleter =
      Completer<List<EventModel>>();
  int _listCallCount = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) {
    _listCallCount += 1;
    if (_listCallCount == 1) {
      return Future<List<EventModel>>.value(const <EventModel>[]);
    }
    return secondListCompleter.future;
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async =>
      null;

  @override
  Future<EventModel> createEvent(EventModel event) async => event;

  @override
  Future<EventModel> updateEvent(EventModel event) async => event;

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
}

class _FakeLocationLookupService extends LocationLookupService {
  @override
  Future<List<LocationLookupResult>> search(String query) async {
    return <LocationLookupResult>[
      LocationLookupResult(
        name: query,
        address: query,
        latitude: 37.7519,
        longitude: 128.8761,
      ),
    ];
  }
}

void main() {
  Future<void> pumpConversation(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(384, 823),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPlanFlowTheme(),
        home: child,
      ),
    );
  }

  testWidgets('AI 일정 대화는 STT partial을 입력창에 즉시 보여준다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byTooltip('음성 입력 다시 시작'));
    await tester.pump();

    expect(find.text('듣는 중...'), findsOneWidget);

    stt.emitPartial('이번주 금요일 일정');
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '이번주 금요일 일정');
  });

  testWidgets('AI 일정 대화는 STT 성공 후 사용자 말과 응답을 표시한다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byTooltip('음성 입력 다시 시작'));
    await tester.pump();

    stt.completeSuccess('오늘 일정 알려줘');
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
  });

  testWidgets('AI 일정 대화는 STT 실패도 화면에 안내로 남긴다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byTooltip('음성 입력 다시 시작'));
    await tester.pump();

    stt.completeFailure('음성을 알아듣지 못했어요.');
    await tester.pumpAndSettle();

    expect(find.text('음성을 알아듣지 못했어요.'), findsWidgets);
  });

  testWidgets('AI 일정 대화는 initialText를 자동 제출한다', (tester) async {
    await pumpConversation(
      tester,
      const VoiceConversationScreen(initialText: '오늘 일정 알려줘'),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 일정 알려줘'), findsOneWidget);
    expect(find.textContaining('일정'), findsWidgets);
  });

  testWidgets('AI 일정 대화는 모바일 크기에서 기본 메시지와 입력바를 렌더링한다', (tester) async {
    await pumpConversation(
      tester,
      const VoiceConversationScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화'), findsOneWidget);
    expect(find.textContaining('일정을 이어서 말해도 돼요'), findsOneWidget);
    expect(find.text('계속 듣기'), findsNothing);
    expect(find.text('Supabase 설정을 확인하지 못했어요.'), findsOneWidget);
    expect(find.byTooltip('음성 입력 다시 시작'), findsOneWidget);
    expect(find.text('전송'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 initialText 결과 일정 카드를 렌더링한다', (tester) async {
    final friday = DateTime(2026, 5, 29, 18);
    final events = List<EventModel>.generate(
      4,
      (index) => EventModel(
        id: 'event-$index',
        userId: 'user-1',
        title: '금요일 일정 ${index + 1}',
        startAt: friday.add(Duration(minutes: index * 30)).toUtc(),
      ),
    );

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: _FakeEventRepository(events),
        initialText: '이번 주 금요일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('이번 주 금요일 일정 다 보여 줘'), findsOneWidget);
    expect(find.textContaining('일정 4개를 찾았어요'), findsOneWidget);
    expect(find.text('금요일 일정 1'), findsOneWidget);
    expect(find.text('금요일 일정 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 조회 결과 카드를 눌러 수정 모달을 열고 편집으로 이동한다', (tester) async {
    final event = EventModel(
      id: 'event-edit',
      userId: 'user-1',
      title: '금요일 상담',
      startAt: DateTime(2026, 5, 29, 18).toUtc(),
    );
    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            repository: _FakeEventRepository(<EventModel>[event]),
            initialText: '이번 주 금요일 일정 다 보여 줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) => const Text(
            '편집 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('금요일 상담'));
    await tester.pumpAndSettle();

    expect(find.text('이 일정으로 무엇을 할까요?'), findsOneWidget);
    expect(find.text('수정하기'), findsOneWidget);
    expect(find.text('삭제하기'), findsOneWidget);

    await tester.tap(find.text('수정하기'));
    await tester.pumpAndSettle();

    expect(find.text('편집 화면'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 조회 결과 카드 삭제를 확인 후 실행한다', (tester) async {
    final event = EventModel(
      id: 'event-delete',
      userId: 'user-1',
      title: '삭제할 일정',
      startAt: DateTime(2026, 5, 29, 18).toUtc(),
    );
    final repository = _FakeEventRepository(<EventModel>[event]);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '이번 주 금요일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('삭제할 일정'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제하기'));
    await tester.pumpAndSettle();

    expect(find.text('이 일정을 삭제할까요?'), findsOneWidget);

    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(repository.deletedIds, contains('event-delete'));
    expect(find.text('삭제할 일정 일정을 삭제했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 삭제 확인 대기 중 붙은 이전 명령을 잘라낸다', (tester) async {
    final friday = DateTime(2026, 5, 29, 18);
    final events = List<EventModel>.generate(
      5,
      (index) => EventModel(
        id: 'event-$index',
        userId: 'user-1',
        title: '금요일 일정 ${index + 1}',
        startAt: friday.add(Duration(minutes: index * 30)).toUtc(),
      ),
    );
    final repository = _FakeEventRepository(events);

    await pumpConversation(
      tester,
      VoiceConversationScreen(
        repository: repository,
        initialText: '이번 주 금요일 일정 다 보여 줘',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '5번 일정 삭제해 줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(find.textContaining('금요일 일정 5 일정을 삭제할까요?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '5번 일정 삭제해 줘 응 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(repository.deletedIds, contains('event-4'));
    expect(find.text('응 삭제해줘'), findsOneWidget);
    expect(find.text('5번 일정 삭제해 줘 응 삭제해줘'), findsNothing);

    await tester.enterText(find.byType(TextField), '응 삭제해줘');
    await tester.tap(find.text('전송'));
    await tester.pumpAndSettle();

    expect(repository.deletedIds.where((id) => id == 'event-4'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 뒤로가기 확인 후에만 대화 세션을 종료한다', (tester) async {
    final stt = _FakeSttService();
    final popResults = <Object?>[];
    final router = GoRouter(
      initialLocation: '/voice-host',
      routes: [
        GoRoute(
          path: '/voice-host',
          builder: (context, state) => TextButton(
            onPressed: () {
              unawaited(
                context.push<Object?>(AppRoutes.voiceConversation).then(
                      popResults.add,
                    ),
              );
            },
            child: const Text('대화 열기'),
          ),
        ),
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            sttService: stt,
            repository: _FakeEventRepository(const <EventModel>[]),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('대화 열기'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화 페이지를 나가겠습니까?'), findsOneWidget);

    await tester.tap(find.text('계속 대화하기'));
    await tester.pumpAndSettle();

    expect(find.text('AI 일정 대화'), findsOneWidget);
    expect(popResults, isEmpty);

    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();

    expect(find.text('대화 열기'), findsOneWidget);
    expect(popResults, contains(voiceConversationClosedResult));
    expect(stt.cancelCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 듣는 중 정지 후 마이크로 다시 시작할 수 있다', (tester) async {
    final stt = _FakeSttService();
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byTooltip('음성 입력 다시 시작'));
    await tester.pump();

    expect(find.text('듣는 중...'), findsOneWidget);
    expect(find.text('정지'), findsOneWidget);

    await tester.tap(find.text('정지'));
    await tester.pumpAndSettle();

    expect(find.textContaining('음성입력이 중지되었습니다'), findsOneWidget);
    expect(find.byTooltip('음성 입력 다시 시작'), findsOneWidget);
    expect(stt.cancelCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 전송 처리 중 문맥 분석 로더를 보여준다', (tester) async {
    final repository = _SlowSecondListEventRepository();
    await pumpConversation(
      tester,
      VoiceConversationScreen(repository: repository),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '오늘 일정 알려줘');
    await tester.tap(find.text('전송'));
    await tester.pump();

    expect(find.text('AI 문맥 분석중이에요...'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    repository.secondListCompleter.complete(const <EventModel>[]);
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 편집 화면으로 이동하기 전 STT를 종료한다', (tester) async {
    final stt = _FakeSttService();
    final events = <EventModel>[
      EventModel(
        id: 'event-1',
        userId: 'user-1',
        title: '방문 일정',
        startAt: DateTime(2026, 5, 22, 9).toUtc(),
      ),
    ];

    final router = GoRouter(
      initialLocation: AppRoutes.voiceConversation,
      routes: [
        GoRoute(
          path: AppRoutes.voiceConversation,
          builder: (context, state) => VoiceConversationScreen(
            sttService: stt,
            repository: _FakeEventRepository(events),
            locationLookupService: _FakeLocationLookupService(),
            initialText: '5월 22일 일정 보여줘',
          ),
        ),
        GoRoute(
          path: AppRoutes.eventEditWithId,
          builder: (context, state) => const Text(
            '편집 화면',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildPlanFlowTheme(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('음성 입력 다시 시작'));
    await tester.pump();
    stt.completeSuccess('그 일정에 강릉 건도리횟집 장소추가');
    await tester.pumpAndSettle();

    expect(stt.cancelCalls, greaterThanOrEqualTo(1));
    expect(find.text('듣고 있어요...'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
