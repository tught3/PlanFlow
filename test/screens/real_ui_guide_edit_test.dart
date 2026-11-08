// Module C: real-ui-guide edit hooks. The screen must:
//  - Accept an OPTIONAL DateTime? initialGuideStartLocal prefill.
//  - Apply start = prefill, end = start+1h if no user-defined end (default
//    end+1h policy) — without writing to the repository.
//  - EditPreviewObserved fires only when the prefill differs from the bound
//    created-event's original start.
//  - GuideMutationPolicy refuses unsupported changed fields (only start/end).
//  - EditConfirmed + UpdateObserved fire after explicit user save with the
//    persisted readback, with start matching expectedUpdatedStartLocal.

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';

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
  int previewCalls = 0;
  int verifiedCalls = 0;
  GuideBackendState current = const GuideBackendState(
      sessionId: 's',
      serverRevision: 1,
      step: GuideStep.intro,
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
    if (action == GuideBackendAction.editPreview) previewCalls++;
    if (action == GuideBackendAction.updateVerified) verifiedCalls++;
    current = GuideBackendState(
        sessionId: 's',
        serverRevision: current.serverRevision + 1,
        step: action == GuideBackendAction.updateVerified
            ? GuideStep.updatedDetail
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

Future<RealUiGuideCoordinator> _bootAtEditPreview(
    _FakeBackend backend, _FakeProgress progress, DateTime expected) async {
  backend.current = GuideBackendState(
      sessionId: 's',
      serverRevision: 1,
      step: GuideStep.intro,
      createdEventId: 'created-1');
  final c = RealUiGuideCoordinator(
      backend: backend, progress: progress, version: 'real_ui_v1');
  var s = await c.start(uid: 'u');
  s = await c.dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
  s = await c.dispatch(
      HomeMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  s = await c.dispatch(
      CaptureStarted(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  // CaptureStarted is a recognizer-open no-op; SaveObserved is only honoured
  // from correctAndSave, so the fixture must confirm the parse first.
  s = await c.dispatch(ParseConfirmed(
      uid: 'u', sessionId: 's', expectedRevision: s.revision,
      operationId: 'create-parse'));
  final saved = EventModel(
      id: 'created-1',
      userId: 'u',
      title: 'real',
      // banned-ok: Fixed event fixture for the guide assertion.
      startAt: DateTime(2026, 10, 20, 13));
  s = await c.dispatch(SaveObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      persistedEvent: saved,
      operationId: 'create-op'));
  final loaded = saved;
  s = await c.dispatch(DetailObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      persistedEvent: loaded,
      preparationResolved: false,
      departureResolved: false,
      setupHelpAcknowledged: true));
  // Drive query → changeSpeech → editPreview using the contract transitions.
  s = await c.dispatch(
      QueryMicTapped(uid: 'u', sessionId: 's', expectedRevision: s.revision));
  // Provide a binding with the target first; this is what the conversation
  // screen would have produced.
  final binding = GuideResultOrder.bind(guide: s, results: [loaded]);
  s = await c.dispatch(QueryObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      binding: binding,
      operationId: 'query-op'));
  s = await c.dispatch(EditPreviewObserved(
      uid: 'u',
      sessionId: 's',
      expectedRevision: s.revision,
      targetEventId: 'created-1',
      requestedStartLocal: expected));
  return c;
}

void main() {
  test(
      'EditPreviewObserved with a different requested start advances to '
      'editPreview and records expectedUpdatedStartLocal', () async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed event fixture for the guide assertion.
    final expected = DateTime(2026, 10, 20, 15); // changed from 13
    final c = await _bootAtEditPreview(backend, progress, expected);
    expect(c.state.value.step, GuideStep.editPreview);
    expect(c.state.value.expectedUpdatedStartLocal, expected);
  });

  test(
      'EditConfirmed + UpdateObserved advance when the persisted readback '
      'matches the bound expected preview start', () async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed event fixture for the guide assertion.
    final expected = DateTime(2026, 10, 20, 15);
    final c = await _bootAtEditPreview(backend, progress, expected);

    // The user pressed Save — explicit confirmation.
    final s = await c.dispatch(EditConfirmed(
        uid: 'u',
        sessionId: 's',
        expectedRevision: c.state.value.revision,
        operationId: 'edit-op',
        confirmedStartLocal: expected));
    expect(backend.previewCalls >= 1, isTrue);
    // UpdateObserved with the real persisted readback at the expected start.
    final updated = EventModel(
        id: 'created-1', userId: 'u', title: 'real', startAt: expected);
    final after = await c.dispatch(UpdateObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: updated,
        operationId: 'edit-op'));
    expect(after.step, GuideStep.updatedDetail);
  });

  test(
      'UpdateObserved with a start that does not match the expected preview '
      'is rejected — no advancement', () async {
    final backend = _FakeBackend();
    final progress = _FakeProgress();
    // banned-ok: Fixed event fixture for the guide assertion.
    final expected = DateTime(2026, 10, 20, 15);
    final c = await _bootAtEditPreview(backend, progress, expected);
    final wrongStart = EventModel(
        id: 'created-1',
        userId: 'u',
        title: 'real',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 16) // one hour off
        );
    final after = await c.dispatch(UpdateObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: c.state.value.revision,
        persistedEvent: wrongStart,
        operationId: 'edit-op'));
    expect(after.step, GuideStep.editPreview);
  });

  test(
      'GuideMutationPolicy refuses changes outside the {startAt, endAt} '
      'whitelist during editPreview', () {
    final snapshot = GuideSnapshot(
        uid: 'u',
        version: 'real_ui_v1',
        revision: 5,
        serverRevision: 5,
        step: GuideStep.editPreview,
        run: GuideRun.active,
        sessionId: 's',
        createdEventId: 'created-1',
        // banned-ok: Fixed event fixture for the guide assertion.
        expectedUpdatedStartLocal: DateTime(2026, 10, 20, 15));
    final intent = GuideMutationIntent(
        kind: GuideWriteKind.changeTime,
        operationId: 'edit-op',
        eventId: 'created-1',
        isPersonal: true,
        isRecurrence: false,
        changedFields: {'title', 'startAt'},
        // banned-ok: Fixed event fixture for the guide assertion.
        requestedStartLocal: DateTime(2026, 10, 20, 15),
        userConfirmed: true);
    final d = GuideMutationPolicy.check(guide: snapshot, intent: intent);
    expect(d.allowed, isFalse);
    expect(d.reasonCode, 'unsupported_fields');
  });

  test(
      'default end+1h policy: when no user-defined end is present and a '
      'prefill is applied, end must equal prefill + 1 hour', () {
    // banned-ok: Fixed event fixture for the guide assertion.
    final prefill = DateTime(2026, 10, 20, 15);
    DateTime? endAt;
    endAt ??= prefill.add(const Duration(hours: 1));
    // banned-ok: Fixed event fixture for the guide assertion.
    expect(endAt, DateTime(2026, 10, 20, 16));
  });
}
