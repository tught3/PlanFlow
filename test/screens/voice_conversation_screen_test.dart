import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
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

class _FakeEventRepository extends EventRepository {
  const _FakeEventRepository(this.events);

  final List<EventModel> events;

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
  Future<void> deleteEvent(String eventId, {String? userId}) async {}
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
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
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
    await pumpConversation(
      tester,
      VoiceConversationScreen(sttService: stt),
    );

    await tester.tap(find.byTooltip('음성으로 말하기'));
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
    expect(find.text('계속 듣기'), findsOneWidget);
    expect(find.byTooltip('음성으로 말하기'), findsOneWidget);
    expect(find.text('전송'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 일정 대화는 initialText 결과 일정 카드를 렌더링한다', (tester) async {
    final friday = DateTime(2026, 5, 22, 18);
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
    expect(
        find.text(
            '일정 4개를 찾았어요. 이어서 “3번째 일정에 장소 추가”, “오후 6시 일정 삭제”처럼 말할 수 있어요.'),
        findsOneWidget);
    expect(find.text('금요일 일정 1'), findsOneWidget);
    expect(find.text('금요일 일정 4'), findsOneWidget);
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
}
