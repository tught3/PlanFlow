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
  GuideBackendState current = const GuideBackendState(
      sessionId: 's', serverRevision: 1, step: GuideStep.intro);
  @override
  Future<GuideBackendState?> begin(
          {required String uid,
          required String version,
          required String requestId}) async =>
      current;
  @override
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal}) async {
    if (action == GuideBackendAction.bindCreated) bindCalls++;
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
      required String requestId}) async {}
}

void main() {
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
        uid: 'u', sessionId: 's', expectedRevision: s.revision,
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
