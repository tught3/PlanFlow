import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/local_time.dart';
import 'package:planflow/core/theme.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
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
  final List<EventModel> updatedEvents = [];
  final List<Completer<List<EventModel>>> pendingListReads = [];
  bool holdListReads = false;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    if (holdListReads) {
      final completion = Completer<List<EventModel>>();
      pendingListReads.add(completion);
      return completion.future;
    }
    return [...events];
  }

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
    updatedEvents.add(event);
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
  _DeleteSideEffects({this.fail = false, this.completion});

  final bool fail;
  final Completer<void>? completion;
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
    await completion?.future;
    if (fail) throw StateError('cleanup failed');
  }
}

class _DeleteGuide extends Fake implements GuideCoordinator {
  @override
  final ValueNotifier<GuideSnapshot> state = ValueNotifier(const GuideSnapshot(
    uid: 'user-1',
    version: 'test',
    revision: 0,
    serverRevision: 0,
    step: GuideStep.skipped,
    run: GuideRun.terminal,
  ));
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
  _DeleteSideEffects sideEffects, {
  _DeleteGuide? guide,
  bool recurring = false,
  List<String> additionalEventTitles = const [],
}) async {
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
    recurrenceRule: recurring ? 'FREQ=DAILY' : null,
  ));
  for (final (index, title) in additionalEventTitles.indexed) {
    final start = day.add(Duration(hours: index + 2));
    repository.events.add(EventModel(
      id: 'extra-event-$index',
      userId: 'user-1',
      title: title,
      startAt: planflowLocalDateTimeToUtc(start),
      endAt: planflowLocalDateTimeToUtc(start.add(const Duration(hours: 1))),
    ));
  }
  final datePhrase = '${day.year}년 ${day.month}월 ${day.day}일';
  final screen = VoiceConversationScreen(
    repository: repository,
    sideEffectService: sideEffects,
    sttService: _IdleSttService(),
    initialText: '$datePhrase 일정 다 보여 줘',
  );
  await tester.pumpWidget(MaterialApp(
    theme: buildPlanFlowTheme(),
    home: guide == null ? screen : GuideScope(coordinator: guide, child: screen),
  ));
  await tester.pumpAndSettle();
  await _submit(
    tester,
    recurring ? '$datePhrase 테스트 일정 삭제해줘' : '첫번째 일정 삭제해줘',
  );
  expect(
    recurring ? find.text('이 회차만 삭제') : _deleteButton,
    findsOneWidget,
  );
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

  testWidgets('알림 정리가 끝나기 전에 삭제 결과를 화면에 반영한다', (tester) async {
    final cleanup = Completer<void>();
    final sideEffects = _DeleteSideEffects(completion: cleanup);
    final repository = await _requestDelete(tester, sideEffects);
    expect(find.text('테스트 일정'), findsOneWidget);

    tester.widget<FilledButton>(_deleteButton).onPressed!();
    repository.pendingDeletes.single.complete();

    try {
      await tester.pumpAndSettle();
      expect(sideEffects.cleanedIds, [_eventId]);
      expect(cleanup.isCompleted, isFalse);
      expect(find.text('테스트 일정'), findsNothing);
      expect(find.text('일정을 삭제했어요.'), findsOneWidget);
    } finally {
      cleanup.complete();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('가이드가 시작되면 이전 삭제 확인으로 삭제나 정리를 하지 않는다',
      (tester) async {
    final guide = _DeleteGuide();
    addTearDown(guide.state.dispose);
    final sideEffects = _DeleteSideEffects();
    final repository = await _requestDelete(tester, sideEffects, guide: guide);
    final confirm = tester.widget<FilledButton>(_deleteButton).onPressed!;

    guide.state.value = guide.state.value.copyWith(
      step: GuideStep.queryResults,
      run: GuideRun.active,
    );
    await tester.pumpAndSettle();
    confirm();
    await tester.pumpAndSettle();

    expect(repository.deletedIds, isEmpty);
    expect(sideEffects.cleanedIds, isEmpty);
    expect(repository.events.single.id, _eventId);
  });

  testWidgets('삭제 후 목록 조회가 지연되어도 성공 표시와 알림 정리를 진행한다',
      (tester) async {
    final sideEffects = _DeleteSideEffects();
    final repository = await _requestDelete(
      tester,
      sideEffects,
      additionalEventTitles: ['남은 일정'],
    );
    repository.holdListReads = true;
    final confirm = tester.widget<FilledButton>(_deleteButton).onPressed!;
    expect(find.text('테스트 일정'), findsOneWidget);

    confirm();
    repository.pendingDeletes.single.complete();

    try {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.pendingListReads.single.isCompleted, isFalse);
      expect(find.text('일정을 삭제했어요.'), findsOneWidget);
      expect(find.text('테스트 일정'), findsNothing);
      expect(sideEffects.cleanedIds, [_eventId]);

      confirm();
      await tester.pump();
      expect(repository.deletedIds, [_eventId]);

      await _submit(tester, '첫번째 일정 삭제해줘');
      expect(find.textContaining('남은 일정 일정을 삭제할까요?'), findsOneWidget);
    } finally {
      repository.holdListReads = false;
      for (final read in repository.pendingListReads) {
        if (!read.isCompleted) read.complete([...repository.events]);
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets('이전 삭제 후 조회가 늦게 끝나도 최신 일정 제목을 유지한다',
      (tester) async {
    final repository = await _requestDelete(
      tester,
      _DeleteSideEffects(),
      additionalEventTitles: ['두 번째 삭제 일정', '변경 전 제목'],
    );
    repository.holdListReads = true;

    try {
      tester.widget<FilledButton>(_deleteButton).onPressed!();
      repository.pendingDeletes.single.complete();
      await tester.pumpAndSettle();

      final olderRead = repository.pendingListReads.single;
      final olderSnapshot = [...repository.events];
      await repository.updateEvent(
        olderSnapshot.last.copyWith(title: '변경 후 제목'),
      );

      await _submit(tester, '첫번째 일정 삭제해줘');
      tester.widget<FilledButton>(_deleteButton).onPressed!();
      repository.pendingDeletes.last.complete();
      await tester.pumpAndSettle();

      expect(repository.pendingListReads, hasLength(2));
      repository.pendingListReads.last.complete([...repository.events]);
      await tester.pumpAndSettle();
      olderRead.complete(olderSnapshot);
      await tester.pumpAndSettle();

      final day = planflowLocal(repository.events.single.startAt!);
      await _submit(tester, '${day.year}년 ${day.month}월 ${day.day}일 일정 다 보여 줘');

      expect(find.text('변경 후 제목'), findsOneWidget);
    } finally {
      repository.holdListReads = false;
      for (final read in repository.pendingListReads) {
        if (!read.isCompleted) read.complete([...repository.events]);
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets('같은 회차를 연속 확정해도 회차 제외를 한 번만 저장한다', (tester) async {
    final sideEffects = _DeleteSideEffects();
    final repository = await _requestDelete(tester, sideEffects, recurring: true);
    final start = planflowLocal(repository.events.single.startAt!);
    final occurrenceButton = find.ancestor(
      of: find.text('이 회차만 삭제'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    final confirm = tester.widget<FilledButton>(occurrenceButton).onPressed!;

    confirm();
    confirm();
    await tester.pumpAndSettle();
    confirm();
    await tester.pumpAndSettle();

    expect(repository.deletedIds, isEmpty);
    expect(repository.updatedEvents.single.id, _eventId);
    expect(repository.events.single.deletedOccurrenceDates, [
      DateTime(start.year, start.month, start.day),
    ]);
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
