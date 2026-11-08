import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';

/// 저장 확인(서버 바인딩) 우회 경로 회귀 테스트.
///
/// 규칙:
///  - 실제 저장 응답으로 확인된 일정 ID/연산만 우회의 근거가 된다.
///    제목·시작시간 같은 모호한 값은 근거가 되지 않는다.
///  - 우회는 SaveObserved 가 실패해 체크포인트로 남은 뒤, 그때의 최신 리비전과
///    같은 세션으로만 동작한다.
///  - 우회 경로는 격리 QA 빌드(kDebugMode + PLANFLOW_GUIDE_QA +
///    PLANFLOW_ISOLATED_GUIDE_QA)에서만 열린다. 일반 빌드는 같은 신호를 거부한다.
///  - 서버 영수증/단계를 만들어내지 않으며, 과금이나 AI 권한을 요구하지 않는다.

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
  int bindCalls = 0;
  int detailAckCalls = 0;
  int authorizeCalls = 0;
  /// 앞으로 몇 번의 bindCreated 호출이 실패할지.
  int pendingBindFailures = 0;
  /// 서버가 다른 정식 ID를 답하도록 강제할 때 쓴다.
  String? bindCreatedIdOverride;

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
    if (action == GuideBackendAction.bindCreated) {
      bindCalls++;
      if (pendingBindFailures > 0) {
        pendingBindFailures--;
        throw StateError('temporary checkpoint failure');
      }
    }
    if (action == GuideBackendAction.detailAck) {
      detailAckCalls++;
    }
    current = GuideBackendState(
        sessionId: 's',
        serverRevision: current.serverRevision + 1,
        step: action == GuideBackendAction.bindCreated
            ? GuideStep.savedDetail
            : action == GuideBackendAction.detailAck
                ? GuideStep.queryMic
                : current.step,
        createdEventId:
            bindCreatedIdOverride ?? event?.id ?? snapshot.createdEventId,
        savedLocalDate: event?.startAt);
    return current;
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    authorizeCalls++;
    return const GuideAccess(status: GuideAccessStatus.unavailable);
  }

  @override
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId}) async {}
}

/// intro -> homeMic -> createSpeech -> correctAndSave 까지만 전진한다.
Future<GuideSnapshot> reachCorrectAndSave(RealUiGuideCoordinator c) async {
  var s = await c.start(uid: 'u');
  s = await c.dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
  s = await c.dispatch(
      HomeMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  s = await c.dispatch(ParseConfirmed(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      operationId: 'create-parse'));
  return s;
}

void main() {
  final saved = EventModel(
      id: 'created-1',
      userId: 'u',
      title: 'actual title',
      // banned-ok: Fixed event fixture for the guide assertion.
      startAt: DateTime(2026, 10, 20, 13));

  test('QA continuation needs the fresh revision and the same saved identity',
      () async {
    final b = FakeBackend()..pendingBindFailures = 1;
    final p = FakeProgress();
    final c =
        RealUiGuideCoordinator(backend: b, progress: p, version: 'real_ui_v1');
    final at = await reachCorrectAndSave(c);
    expect(at.step, GuideStep.correctAndSave);

    final failed = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: at.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    // 서버 바인딩 실패는 체크포인트로 남고 리비전이 올라간다.
    expect(failed.run, GuideRun.blocked);
    expect(failed.errorCode, guideCreatedCheckpointPendingCode);
    expect(failed.createdEventId, 'created-1');
    expect(failed.savedCreateOperationId, 'create-op');
    expect(failed.revision, at.revision + 1);

    // 실패 전 리비전(오래된 세션 상태)은 거부된다.
    final stale = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: at.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    expect(stale.step, GuideStep.correctAndSave);
    expect(stale.revision, failed.revision);

    // 다른 사용자의 일정으로는 넘어가지 않는다.
    final wrongUser = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved.copyWith(userId: 'other'),
        operationId: 'create-op'));
    expect(wrongUser.step, GuideStep.correctAndSave);
    expect(wrongUser.createdEventId, 'created-1');

    // 다른 일정 ID로는 넘어가지 않는다.
    final wrongId = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved.copyWith(id: 'other-id'),
        operationId: 'create-op'));
    expect(wrongId.step, GuideStep.correctAndSave);

    // 다른 연산 ID로는 넘어가지 않는다.
    final wrongOp = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved,
        operationId: 'other-op'));
    expect(wrongOp.step, GuideStep.correctAndSave);

    // 다른 세션으로는 넘어가지 않는다.
    final wrongSession = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 'other-session',
        expectedRevision: failed.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    expect(wrongSession.step, GuideStep.correctAndSave);
    expect(wrongSession.createdEventId, 'created-1');

    // 반복 일정/다중 날짜는 개인 단일 일정 저장이 아니므로 대상이 아니다.
    final recurring = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved.copyWith(recurrenceRule: 'FREQ=DAILY'),
        operationId: 'create-op'));
    expect(recurring.step, GuideStep.correctAndSave);
    final multiDay = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved.copyWith(isMultiDay: true),
        operationId: 'create-op'));
    expect(multiDay.step, GuideStep.correctAndSave);

    // 최신 리비전 + 동일 신원일 때만 진행된다.
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
      expect(advanced.errorCode, guideQaSavedBindingUnconfirmedCode);
    } else {
      // 일반 빌드에서는 동일한 신호도 거부되어야 한다.
      expect(advanced.step, GuideStep.correctAndSave);
      expect(advanced.run, GuideRun.blocked);
      expect(advanced.errorCode, guideCreatedCheckpointPendingCode);
      expect(advanced.createdEventId, 'created-1');
    }
    // 서버 바인딩을 새로 시도하지 않는다. 과금/AI 권한도 만들지 않는다.
    expect(b.bindCalls, 1);
    expect(b.authorizeCalls, 0);
  });

  test('later DetailObserved reconnects the same saved binding before ack',
      () async {
    final b = FakeBackend()..pendingBindFailures = 1;
    final p = FakeProgress();
    final c =
        RealUiGuideCoordinator(backend: b, progress: p, version: 'real_ui_v1');
    final at = await reachCorrectAndSave(c);
    final failed = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: at.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    final advanced = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    if (!guideQaAdvanceEnabled) {
      expect(advanced.step, GuideStep.correctAndSave);
      expect(b.detailAckCalls, 0);
      return;
    }
    expect(advanced.step, GuideStep.savedDetail);
    final detail = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: advanced.revision,
        persistedEvent: saved,
        preparationResolved: true,
        departureResolved: true,
        setupHelpAcknowledged: true));
    // 같은 저장 ID/연산으로 재연결이 확인된 뒤에만 detailAck 로 넘어간다.
    expect(detail.step, GuideStep.queryMic);
    expect(detail.run, GuideRun.active);
    expect(detail.errorCode, isNull);
    expect(detail.createdEventId, 'created-1');
    expect(b.bindCalls, 2);
    expect(b.detailAckCalls, 1);
    expect(b.authorizeCalls, 0);
  });

  test('a bind that names another event never acks the detail step', () async {
    final b = FakeBackend()
      ..pendingBindFailures = 1
      ..bindCreatedIdOverride = 'other-id';
    final p = FakeProgress();
    final c =
        RealUiGuideCoordinator(backend: b, progress: p, version: 'real_ui_v1');
    final at = await reachCorrectAndSave(c);
    final failed = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: at.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    final advanced = await c.dispatch(SaveUnconfirmedObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: failed.revision,
        persistedEvent: saved,
        operationId: 'create-op'));
    if (!guideQaAdvanceEnabled) {
      expect(advanced.step, GuideStep.correctAndSave);
      expect(b.detailAckCalls, 0);
      return;
    }
    expect(advanced.step, GuideStep.savedDetail);
    final detail = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: advanced.revision,
        persistedEvent: saved,
        preparationResolved: true,
        departureResolved: true,
        setupHelpAcknowledged: true));
    // 다른 ID를 답한 서버 바인딩은 확인으로 치지 않는다. 멈춘 채로 남는다.
    expect(detail.step, GuideStep.savedDetail);
    expect(detail.run, GuideRun.blocked);
    expect(detail.errorCode, guideQaSavedBindingUnconfirmedCode);
    expect(detail.createdEventId, 'created-1');
    expect(b.detailAckCalls, 0);
    expect(b.authorizeCalls, 0);
  });
}
