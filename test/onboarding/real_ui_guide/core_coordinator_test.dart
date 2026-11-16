import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';

class FakeProgress implements GuideProgressStore {
  GuideSnapshot? value;
  @override
  Future<GuideSnapshot?> load(
          {required String uid, required String version}) async =>
      value?.uid == uid ? value : null;
  @override
  Future<void> save(GuideSnapshot snapshot) async {
    value = snapshot;
  }
}

class FakeBackend implements GuideBackendPort {
  int chargeCalls = 0;
  bool failBind = false;
  int bindCalls = 0;
  int previewCalls = 0;
  Future<void> Function(GuideSnapshot, GuideExit, String)? onFinish;
  GuideBackendState current = const GuideBackendState(
      sessionId: 's', serverRevision: 1, step: GuideStep.intro);
  @override
  Future<GuideBeginResult> begin(
          {required String uid,
          required String version,
          required String requestId}) async =>
      GuideBeginGranted(current);
  @override
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal}) async {
    if (action == GuideBackendAction.bindCreated) bindCalls++;
    if (action == GuideBackendAction.editPreview) previewCalls++;
    if (action == GuideBackendAction.bindCreated && failBind) {
      failBind = false;
      throw StateError('temporary checkpoint failure');
    }
    current = GuideBackendState(
        sessionId: 's',
        serverRevision: current.serverRevision + 1,
        step: action == GuideBackendAction.bindCreated
            ? GuideStep.savedDetail
            : action == GuideBackendAction.detailAck
                ? GuideStep.queryMic
                : current.step,
        createdEventId: event?.id ?? snapshot.createdEventId,
        savedLocalDate: event?.startAt);
    return current;
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    chargeCalls++;
    return const GuideAccess(status: GuideAccessStatus.unavailable);
  }

  @override
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId}) async {
    await onFinish?.call(snapshot, exit, requestId);
  }
}

class ReplayBackend extends FakeBackend implements GuideReplayBackendPort {
  final response = Completer<GuideBackendState?>();
  final requests = <String>[];
  Future<GuideBackendState?>? currentReply;

  @override
  Future<GuideBeginResult> begin({
    required String uid,
    required String version,
    required String requestId,
  }) async {
    final reply = currentReply;
    final result = reply != null ? await reply : current;
    if (result?.step == GuideStep.completed || result?.step == GuideStep.skipped) {
      return GuideBeginFailed(
        const GuideFailureDiagnostic(GuideFailureKind.terminal),
        terminalPredecessor: result,
      );
    }
    return result == null
        ? const GuideBeginFailed(
        GuideFailureDiagnostic(GuideFailureKind.backendUnavailable),
      )
        : GuideBeginGranted(result);
  }

  @override
  Future<GuideBackendState?> restart({
    required String uid,
    required String version,
    required String previousSessionId,
    required String requestId,
  }) {
    requests.add('$uid:$version:$previousSessionId:$requestId');
    return response.future;
  }
}

void main() {
  test('restart opens a single fresh run without issuing free permits',
      () async {
    final backend = ReplayBackend()
      ..current = const GuideBackendState(
          sessionId: 'old', serverRevision: 6, step: GuideStep.completed);
    final progress = FakeProgress()
      ..value = const GuideSnapshot(
        uid: 'u',
        version: 'real_ui_v1',
        sessionId: 'old',
        revision: 8,
        serverRevision: 6,
        step: GuideStep.completed,
        run: GuideRun.terminal,
        createdEventId: 'old-event',
      );
    final c = RealUiGuideCoordinator(
        backend: backend, progress: progress, version: 'real_ui_v1');
    await c.start(uid: 'u');
    expect(await c.restartCompletedGuide(uid: 'another-user'), isFalse);
    final restart = c.restartCompletedGuide(uid: 'u');
    expect(await c.restartCompletedGuide(uid: 'u'), isFalse);
    expect(backend.requests, ['u:real_ui_v1:old:restart:old']);
    backend.response.complete(const GuideBackendState(
        sessionId: 'new', serverRevision: 0, step: GuideStep.intro, isReplay: true));
    expect(await restart, isTrue);
    final replay = c.state.value;
    expect(replay, same(progress.value));
    expect(replay.sessionId, 'new');
    expect(replay.run, GuideRun.active);
    expect(replay.step, GuideStep.homeMic);
    expect(replay.createdEventId, isNull);
    expect(replay.calendarSyncHeld, isTrue);
    expect(
        await c.dispatch(HomeMicTapped(
            uid: 'u', sessionId: 'old', expectedRevision: replay.revision)),
        same(replay));
    final speech = await c.dispatch(HomeMicTapped(
        uid: 'u', sessionId: 'new', expectedRevision: replay.revision));
    final access = await c.authorize(
        context: GuideChargeContext(
            uid: 'u',
            version: 'real_ui_v1',
            sessionId: 'new',
            kind: GuideChargeKind.scheduleParse,
            operation: GuideOperation.createParse,
            phase: speech.step,
            revision: speech.revision,
            serverRevision: speech.serverRevision),
        operationId: 'parse');
    expect(access.reasonCode, 'ordinary_quota_required');
    expect(backend.chargeCalls, 0);
    backend.current = const GuideBackendState(
        sessionId: 'new', serverRevision: 0, step: GuideStep.intro, isReplay: true);
    final reopened = RealUiGuideCoordinator(
        backend: backend, progress: progress, version: 'real_ui_v1');
    expect((await reopened.start(uid: 'u')).isReplay, isTrue);
  });

  group('restart reconciles the current account session', () {
    late ReplayBackend backend;
    late RealUiGuideCoordinator c;
    late FakeProgress progress;
    const old = GuideSnapshot(
      uid: 'u',
      version: 'real_ui_v1',
      sessionId: 'old',
      revision: 8,
      serverRevision: 6,
      step: GuideStep.completed,
      run: GuideRun.terminal,
      createdEventId: 'old-event',
    );
    const activeSuccessor = GuideBackendState(
      sessionId: 'successor',
      serverRevision: 5,
      step: GuideStep.queryMic,
      isReplay: true,
      createdEventId: 'bound-successor',
    );

    setUp(() async {
      backend = ReplayBackend();
      progress = FakeProgress()..value = old;
      c = RealUiGuideCoordinator(
          backend: backend, progress: progress, version: old.version);
      await c.start(uid: 'u');
    });

    test('joins the active successor already opened on another device',
        () async {
      backend.current = activeSuccessor;
      expect(await c.restartCompletedGuide(uid: 'u'), isTrue);
      expect(backend.requests, isEmpty);
      expect(c.state.value.sessionId, 'successor');
      expect(c.state.value.createdEventId, 'bound-successor');
      expect(c.state.value.step, GuideStep.queryMic);
      expect(c.state.value.run, GuideRun.active);
    });

    test('restarts from the current terminal successor', () async {
      backend.current = const GuideBackendState(
        sessionId: 'successor',
        serverRevision: 8,
        step: GuideStep.completed,
        isReplay: true,
      );
      final started = c.restartCompletedGuide(uid: 'u');
      await Future<void>.delayed(Duration.zero);
      expect(backend.requests, ['u:real_ui_v1:successor:restart:successor']);
      backend.response.complete(const GuideBackendState(
        sessionId: 'next',
        serverRevision: 0,
        step: GuideStep.intro,
        isReplay: true,
      ));
      expect(await started, isTrue);
      expect(c.state.value.sessionId, 'next');
      expect(c.state.value.createdEventId, isNull);
    });

    test('re-reads the winner when a concurrent restart wins', () async {
      backend.current = const GuideBackendState(
          sessionId: 'old', serverRevision: 6, step: GuideStep.completed);
      final started = c.restartCompletedGuide(uid: 'u');
      await Future<void>.delayed(Duration.zero);
      backend.current = activeSuccessor;
      backend.response.complete(null);
      expect(await started, isTrue);
      expect(backend.requests, ['u:real_ui_v1:old:restart:old']);
      expect(c.state.value.sessionId, 'successor');
    });

    test('rejects an unrelated active non-replay and a stale UID result',
        () async {
      expect(await c.restartCompletedGuide(uid: 'u'), isFalse);
      expect(c.state.value, same(old));
      expect(backend.requests, isEmpty);
      final lookup = Completer<GuideBackendState?>();
      backend.currentReply = lookup.future;
      final started = c.restartCompletedGuide(uid: 'u');
      backend.currentReply = null;
      await c.start(uid: 'other');
      lookup.complete(activeSuccessor);
      expect(await started, isFalse);
      expect(c.state.value.uid, 'other');
      expect(backend.requests, isEmpty);
    });
  });

  test('a fresh local store restores a terminal account and lets it restart',
      () async {
    final backend = ReplayBackend()
      ..current = const GuideBackendState(
          sessionId: 'old', serverRevision: 6, step: GuideStep.completed);
    final progress = FakeProgress();
    final c = RealUiGuideCoordinator(
        backend: backend, progress: progress, version: 'real_ui_v1');
    final restored = await c.start(uid: 'u');
    expect(restored.run, GuideRun.terminal);
    expect(restored.sessionId, 'old');
    expect(restored, same(progress.value));
    final restart = c.restartCompletedGuide(uid: 'u');
    backend.response.complete(const GuideBackendState(
        sessionId: 'new', serverRevision: 0, step: GuideStep.intro, isReplay: true));
    expect(await restart, isTrue);
    expect(c.state.value.step, GuideStep.homeMic);
  });

  test('sync choice saves locally before finishing the same session remotely',
      () async {
    final backend = FakeBackend()
      ..current = const GuideBackendState(
        sessionId: 's',
        serverRevision: 6,
        step: GuideStep.updatedDetail,
        createdEventId: 'bound',
      );
    final progress = FakeProgress();
    final finishRequests = <String>[];
    final finishReply = Completer<void>();
    backend.onFinish = (snapshot, exit, requestId) async {
      expect(progress.value, same(snapshot));
      expect(snapshot.uid, 'u');
      expect(snapshot.sessionId, 's');
      expect(snapshot.step, GuideStep.completed);
      expect(snapshot.createdEventId, 'bound');
      expect(exit, GuideExit.completed);
      finishRequests.add(requestId);
      await finishReply.future;
    };
    final c = RealUiGuideCoordinator(
        backend: backend, progress: progress, version: 'real_ui_v1');
    final updated = await c.start(uid: 'u');
    final choice = await c.dispatch(SyncChoicePresented(
        uid: 'u', sessionId: 's', expectedRevision: updated.revision));
    expect(choice.step, GuideStep.syncChoice);
    expect(finishRequests, isEmpty);

    final close = SyncChoiceClosed(
        uid: 'u', sessionId: 's', expectedRevision: choice.revision);
    final completed = await c.dispatch(close);
    expect(completed.run, GuideRun.terminal);
    expect(completed.calendarSyncHeld, isFalse);
    expect(finishReply.isCompleted, isFalse);
    expect(await c.dispatch(close), same(completed));
    expect(finishRequests, ['finish:s:completed']);
    finishReply.complete();
  });

  test(
      'save confirms an already accepted preview locally and verifies readback',
      () async {
    final originalStart = DateTime.utc(2031, 6, 12, 5);
    final changedStart = DateTime.utc(2031, 6, 12, 8);
    final b = FakeBackend()
      ..current = const GuideBackendState(
        sessionId: 's',
        serverRevision: 3,
        step: GuideStep.changeSpeech,
        createdEventId: 'bound',
      );
    final p = FakeProgress()
      ..value = GuideSnapshot(
        uid: 'u',
        version: 'real_ui_v1',
        sessionId: 's',
        revision: 4,
        serverRevision: 3,
        step: GuideStep.changeSpeech,
        run: GuideRun.active,
        createdEventId: 'bound',
        originalStartLocal: originalStart,
      );
    final c =
        RealUiGuideCoordinator(backend: b, progress: p, version: 'real_ui_v1');
    final ready = await c.start(uid: 'u');
    final preview = await c.dispatch(EditPreviewObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: ready.revision,
      targetEventId: 'bound',
      requestedStartLocal: changedStart,
    ));
    expect(preview.step, GuideStep.editPreview);
    expect(b.previewCalls, 1);
    final wrong = await c.dispatch(EditConfirmed(
      uid: 'u',
      sessionId: 's',
      expectedRevision: preview.revision,
      operationId: 'wrong-save',
      confirmedStartLocal: originalStart,
    ));
    expect(wrong, same(preview));
    final confirmed = await c.dispatch(EditConfirmed(
      uid: 'u',
      sessionId: 's',
      expectedRevision: preview.revision,
      operationId: 'save',
      confirmedStartLocal: changedStart,
    ));
    expect(confirmed.revision, preview.revision + 1);
    expect(confirmed.serverRevision, preview.serverRevision);
    expect(b.previewCalls, 1);
    final updated = await c.dispatch(UpdateObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: confirmed.revision,
      operationId: 'verified',
      persistedEvent: EventModel(
          id: 'bound', userId: 'u', title: 'schedule', startAt: changedStart),
    ));
    expect(updated.step, GuideStep.updatedDetail);
  });
  test(
      'start, accepted intro, stale UID/revision fencing, and fail-closed missing permission',
      () async {
    final b = FakeBackend(), p = FakeProgress();
    final c =
        RealUiGuideCoordinator(backend: b, progress: p, version: 'real_ui_v1');
    final started = await c.start(uid: 'u');
    expect(started.uid, 'u');
    final moved = await c
        .dispatch(IntroFinished(uid: 'u', expectedRevision: started.revision));
    expect(moved.step, GuideStep.homeMic);
    final stale = await c.dispatch(HomeMicTapped(
        uid: 'other', sessionId: 's', expectedRevision: moved.revision));
    expect(stale.step, GuideStep.homeMic);
    final access = await c.authorize(
        context: GuideChargeContext(
            uid: 'u',
            version: 'real_ui_v1',
            sessionId: 's',
            kind: GuideChargeKind.scheduleParse,
            operation: GuideOperation.createParse,
            phase: GuideStep.homeMic,
            revision: moved.revision,
            serverRevision: moved.serverRevision),
        operationId: 'x');
    expect(access.status, GuideAccessStatus.denied);
    expect(b.chargeCalls, 0);
  });
  test('checkpoint retry retains saved ID and never changes create identity',
      () async {
    final b = FakeBackend()..failBind = true;
    final p = FakeProgress();
    final c =
        RealUiGuideCoordinator(backend: b, progress: p, version: 'real_ui_v1');
    var s = await c.start(uid: 'u');
    s = await c.dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
    s = await c.dispatch(
        HomeMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
    final beforeCapture = s;
    s = await c.dispatch(
        CaptureStarted(uid: 'u', sessionId: 's', expectedRevision: s.revision));
    expect(identical(s, beforeCapture), isTrue);
    s = await c.dispatch(ParseConfirmed(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        operationId: 'create-parse'));
    final saved = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'actual',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 13));
    s = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    expect(s.run, GuideRun.blocked);
    expect(s.createdEventId, 'created-1');
    expect(s.savedCreateOperationId, 'create-op');
    final retry = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    expect(retry.step, GuideStep.savedDetail);
    expect(retry.run, GuideRun.active);
    expect(b.bindCalls, 2);
    final wrong = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: retry.revision,
        persistedEvent: EventModel(
            id: 'other',
            userId: 'u',
            title: 'other',
            // banned-ok: Fixed event fixture for the guide assertion.
            startAt: DateTime(2026, 10, 20, 13)),
        operationId: 'other-op'));
    expect(wrong.createdEventId, 'created-1');
    expect(b.bindCalls, 2);
  });
  test('QA unconfirmed save moves to the next step without a backend bind',
      () async {
    final b = FakeBackend()..failBind = true;
    final p = FakeProgress();
    final c =
        RealUiGuideCoordinator(backend: b, progress: p, version: 'real_ui_v1');
    var s = await c.start(uid: 'u');
    s = await c.dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
    s = await c.dispatch(
        HomeMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
    s = await c.dispatch(ParseConfirmed(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        operationId: 'create-parse'));
    expect(s.step, GuideStep.correctAndSave);
    final saved = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'actual',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 13));
    // 먼저 실제 저장 신호를 보내 서버 바인딩 실패를 그대로 남긴다.
    final failed = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    expect(failed.run, GuideRun.blocked);
    expect(failed.errorCode, guideCreatedCheckpointPendingCode);
    final bindsBefore = b.bindCalls;
    // 실패로 올라간 최신 리비전 + 같은 세션 + 같은 저장 신원이어야 한다.
    final advanced = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    if (guideQaAdvanceEnabled) {
      expect(advanced.step, GuideStep.savedDetail);
      expect(advanced.run, GuideRun.active);
      expect(advanced.createdEventId, 'created-1');
      expect(advanced.savedCreateOperationId, 'create-op');
    } else {
      // 일반 빌드에서는 같은 신호도 거부된다.
      expect(advanced.step, GuideStep.correctAndSave);
      expect(advanced.run, GuideRun.blocked);
    }
    // 서버 바인딩을 시도하지 않는다.
    expect(b.bindCalls, bindsBefore);
    // 다른 사용자의 일정으로는 넘기지 않는다.
    final wrongUser = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: advanced.revision,
        persistedEvent: EventModel(
            id: 'x', userId: 'other', title: 'x', startAt: DateTime(2026)),
        operationId: 'other-op'));
    expect(wrongUser.createdEventId, 'created-1');
    expect(wrongUser.step, advanced.step);
  });
}
