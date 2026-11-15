import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/voice/voice_conversation_screen.dart';
import 'package:planflow/services/api_usage_guard.dart';
import 'package:planflow/services/manual_event_side_effect_service.dart';
import 'package:planflow/services/stt_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _eventId = 'event-a';

class _DeleteRepository extends EventRepository {
  _DeleteRepository(EventModel event) : events = [event];

  final List<EventModel> events;
  final List<String> deletedIds = [];
  final List<Completer<void>> pendingDeletes = [];

  @override
  Future<List<EventModel>> listEvents({String? userId}) async => [...events];

  @override
  Future<EventModel> createEvent(EventModel event) async {
    events.add(event);
    return event;
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    for (final event in events) {
      if (event.id == eventId) return event;
    }
    return null;
  }

  @override
  Future<EventModel> updateEvent(EventModel event) async {
    final index = events.indexWhere((existing) => existing.id == event.id);
    if (index >= 0) events[index] = event;
    return event;
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) async {
    deletedIds.add(eventId);
    final completion = Completer<void>();
    pendingDeletes.add(completion);
    await completion.future;
    events.removeWhere((event) => event.id == eventId);
  }
}

class _DeleteSideEffects extends ManualEventSideEffectService {
  _DeleteSideEffects({this.fail = false});

  final bool fail;
  final List<String> cleanedIds = [];

  @override
  Future<void> cleanupAfterDelete(
    String eventId, {
    String? userId,
    int prepTimeMin = 60,
    int prepPreAlarmOffset = 30,
    int departPreAlarmOffset = 30,
    Duration departureSafetyMargin = const Duration(minutes: 1),
    String travelMode = 'car',
  }) async {
    cleanedIds.add(eventId);
    if (fail) throw StateError('cleanup failed');
  }
}

class _IdleSttService extends SttService {
  @override
  Future<void> cancelActiveListen() async {}

  @override
  Future<String> clearActiveTranscript() async => '';
}

Future<void> _submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('전송'));
  await tester.pumpAndSettle();
}

Finder get _deleteButton => find.ancestor(
      of: find.text('삭제 확인'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );

Future<_DeleteRepository> _requestDelete(
  WidgetTester tester,
  _DeleteSideEffects sideEffects,
) async {
  tester.view.physicalSize = const Size(384, 823);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final now = planflowNow();
  final day = DateTime(now.year, now.month, now.day + 2, 15);
  final repository = _DeleteRepository(EventModel(
    id: _eventId,
    userId: 'user-1',
    title: '테스트 일정',
    startAt: planflowLocalDateTimeToUtc(day),
    endAt: planflowLocalDateTimeToUtc(day.add(const Duration(hours: 1))),
  ));
  await tester.pumpWidget(MaterialApp(
    theme: buildPlanFlowTheme(),
    home: VoiceConversationScreen(
      repository: repository,
      sideEffectService: sideEffects,
      sttService: _IdleSttService(),
      initialText: '${day.year}년 ${day.month}월 ${day.day}일 일정 다 보여 줘',
    ),
  ));
  await tester.pumpAndSettle();
  await _submit(tester, '첫번째 일정 삭제해줘');
  expect(_deleteButton, findsOneWidget);
  return repository;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiUsageGuard.resetForTesting();
  });

  testWidgets('같은 이벤트를 연속 확정해도 삭제와 정리를 한 번만 실행한다', (tester) async {
    final sideEffects = _DeleteSideEffects();
    final repository = await _requestDelete(tester, sideEffects);

    final confirm = tester.widget<FilledButton>(_deleteButton).onPressed!;
    confirm();
    confirm();
    await tester.pump();

    expect(repository.deletedIds, [_eventId]);
    expect(sideEffects.cleanedIds, isEmpty);
    repository.pendingDeletes.single.complete();
    await tester.pumpAndSettle();

    expect(sideEffects.cleanedIds, [_eventId]);
    expect(find.text('일정을 삭제했어요.'), findsOneWidget);
  });

  testWidgets('정리 오류가 발생해도 완료된 삭제를 성공으로 표시한다', (tester) async {
    final sideEffects = _DeleteSideEffects(fail: true);
    final repository = await _requestDelete(tester, sideEffects);

    tester.widget<FilledButton>(_deleteButton).onPressed!();
    repository.pendingDeletes.single.complete();
    await tester.pumpAndSettle();

    expect(repository.deletedIds, [_eventId]);
    expect(repository.events, isEmpty);
    expect(sideEffects.cleanedIds, [_eventId]);
    expect(find.text('일정을 삭제했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('삭제가 실패한 경우 정리 없이 같은 일정을 다시 시도할 수 있다', (tester) async {
    final sideEffects = _DeleteSideEffects();
    final repository = await _requestDelete(tester, sideEffects);

    final confirm = tester.widget<FilledButton>(_deleteButton).onPressed!;
    confirm();
    repository.pendingDeletes.single.completeError(StateError('delete failed'));
    await tester.pumpAndSettle();

    expect(sideEffects.cleanedIds, isEmpty);
    confirm();
    repository.pendingDeletes.last.complete();
    await tester.pumpAndSettle();

    expect(repository.deletedIds, [_eventId, _eventId]);
    expect(sideEffects.cleanedIds, [_eventId]);
  });

  testWidgets('음성 거절 뒤에는 이전 삭제 확인 버튼으로 실행할 수 없다', (tester) async {
    final sideEffects = _DeleteSideEffects();
    final repository = await _requestDelete(tester, sideEffects);
    final staleConfirm = tester.widget<FilledButton>(_deleteButton).onPressed!;

    await _submit(tester, '아냐 삭제하지 마');
    staleConfirm();
    await tester.pumpAndSettle();

    expect(repository.deletedIds, isEmpty);
    expect(sideEffects.cleanedIds, isEmpty);
  });
}
