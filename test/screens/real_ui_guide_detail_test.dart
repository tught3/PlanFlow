// Module C: real-ui-guide detail hooks. The screen must:
//  - Not auto-leave on load.
//  - Keep prep/departure/setup-help visible until the user taps an explicit
//    in-card ack button.
//  - Dispatch DetailObserved only with truthful flags derived from the
//    actually loaded EventModel — never a fabricated ETA.

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';

class _FakeProgress implements GuideProgressStore {
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

class _FakeBackend implements GuideBackendPort {
  int detailAckCalls = 0;
  GuideBackendState current = const GuideBackendState(
      sessionId: 's',
      serverRevision: 1,
      step: GuideStep.savedDetail,
      createdEventId: 'created-1');
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
    if (action == GuideBackendAction.detailAck) detailAckCalls++;
    current = GuideBackendState(
        sessionId: 's',
        serverRevision: current.serverRevision + 1,
        step: action == GuideBackendAction.detailAck
            ? GuideStep.queryMic
            : snapshot.step,
        createdEventId: snapshot.createdEventId);
    return current;
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    return const GuideAccess(status: GuideAccessStatus.unavailable);
  }

  @override
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId}) async {}
}

Future<RealUiGuideCoordinator> _bootAtSavedDetail(
    _FakeBackend backend, _FakeProgress progress) async {
  backend.current = GuideBackendState(
      sessionId: 's',
      serverRevision: 1,
      step: GuideStep.intro,
      createdEventId: 'created-1');
  final c = RealUiGuideCoordinator(
      backend: backend, progress: progress, version: 'real_ui_v1');
  var s = await c.start(uid: 'u');
  s = await c.dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
  s = await c.dispatch(HomeMicTapped(
      uid: 'u', sessionId: 's', expectedRevision: s.revision));
  s = await c.dispatch(CaptureStarted(
      uid: 'u', sessionId: 's', expectedRevision: s.revision));
  // CaptureStarted is a recognizer-open no-op; SaveObserved is only honoured
  // from correctAndSave, so the fixture must confirm the parse first.
  s = await c.dispatch(ParseConfirmed(
      uid: 'u', sessionId: 's', expectedRevision: s.revision,
      operationId: 'create-parse'));
  // SaveObserved only fires in real UI from the confirm screen. Here we
  // bootstrap the created event ID so the detail screen has something to
  // verify against.
  final persisted = EventModel(
      id: 'created-1',
      userId: 'u',
      title: 'real',
      // banned-ok: Fixed event fixture for the guide assertion.
      startAt: DateTime(2026, 10, 20, 13));
  s = await c.dispatch(SaveObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      persistedEvent: persisted,
      operationId: 'create-op'));
  return c;
}

void main() {
  test('DetailObserved advances savedDetail → queryMic when prep/departure '
      'are resolved or setup help is acknowledged', () async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    final c = await _bootAtSavedDetail(backend, progress);
    expect(c.state.value.step, GuideStep.savedDetail);

    final loaded = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 13));
    // setupHelpAcknowledged path: we did not actually resolve prep or
    // departure data, but acknowledging the existing setup-help text is
    // enough to advance per the contract.
    final s = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: c.state.value.revision,
        persistedEvent: loaded,
        preparationResolved: false,
        departureResolved: false,
        setupHelpAcknowledged: true));
    expect(s.step, GuideStep.queryMic);
    expect(backend.detailAckCalls, 1);
  });

  test('DetailObserved with neither prep nor departure nor setup ack is '
      'rejected (no FSM advancement)', () async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    final c = await _bootAtSavedDetail(backend, progress);
    final loaded = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 13));
    final s = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: c.state.value.revision,
        persistedEvent: loaded,
        preparationResolved: false,
        departureResolved: false,
        setupHelpAcknowledged: false));
    expect(s.step, GuideStep.savedDetail);
    expect(backend.detailAckCalls, 0);
  });

  test('DetailObserved for a foreign createdEventId is rejected (ID guard)',
      () async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    final c = await _bootAtSavedDetail(backend, progress);
    final foreign = EventModel(
        id: 'foreign-id',
        userId: 'u',
        title: 'real',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 13));
    final s = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: c.state.value.revision,
        persistedEvent: foreign,
        preparationResolved: true,
        departureResolved: true,
        setupHelpAcknowledged: true));
    expect(s.step, GuideStep.savedDetail);
    expect(backend.detailAckCalls, 0);
  });
}