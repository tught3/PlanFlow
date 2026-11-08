import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';

class MemoryStore implements GuideProgressStore {
  GuideSnapshot? value;
  int saves = 0;
  bool failNextSave = false;
  @override
  Future<GuideSnapshot?> load(
          {required String uid, required String version}) async =>
      value;
  @override
  Future<void> save(GuideSnapshot snapshot) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('synthetic local progress write failure');
    }
    saves++;
    value = snapshot;
  }
}

class ProbeBackend implements GuideBackendPort {
  GuideBackendState? beginResult;
  bool beginThrows = false;
  Future<GuideBackendState?> Function()? beginHook;
  bool failDetail = false;
  int begins = 0, advances = 0, authorizes = 0;
  @override
  Future<GuideBackendState?> begin(
      {required String uid,
      required String version,
      required String requestId}) async {
    begins++;
    if (beginThrows) throw StateError('offline');
    if (beginHook != null) return await beginHook!();
    return beginResult;
  }

  @override
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal}) async {
    advances++;
    if (action == GuideBackendAction.detailAck && failDetail) {
      throw StateError('detail failed');
    }
    return GuideBackendState(
        sessionId: 's',
        serverRevision: snapshot.serverRevision + 1,
        step: action == GuideBackendAction.bindCreated
            ? GuideStep.savedDetail
            : GuideStep.queryMic,
        createdEventId: event?.id ?? snapshot.createdEventId);
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    authorizes++;
    return const GuideAccess(status: GuideAccessStatus.unavailable);
  }

  @override
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId}) async {}
}

GuideSnapshot saved(
        {GuideStep step = GuideStep.savedDetail,
        GuideRun run = GuideRun.active,
        String? created = 'A',
        String? error}) =>
    GuideSnapshot(
        uid: 'u',
        version: 'v',
        revision: 4,
        serverRevision: 3,
        sessionId: 's',
        step: step,
        run: run,
        createdEventId: created,
        savedCreateOperationId: created == null ? null : 'create-op',
        errorCode: error,
        // banned-ok: Fixed event fixture for the guide assertion.
        savedLocalDate: DateTime(2026, 10, 20),
        // banned-ok: Fixed event fixture for the guide assertion.
        originalStartLocal: DateTime(2026, 10, 20, 13),
        calendarSyncHeld: true);

GuideBackendState remoteState(
        {String session = 'actual',
        GuideStep step = GuideStep.intro,
        String? created}) =>
    GuideBackendState(
        sessionId: session,
        serverRevision: 11,
        step: step,
        createdEventId: created);

RealUiGuideCoordinator coord(ProbeBackend b, MemoryStore p) =>
    RealUiGuideCoordinator(backend: b, progress: p, version: 'v');

void main() {
  test('backend_unavailable is cleared by canonical begin success', () async {
    final b = ProbeBackend(), p = MemoryStore();
    p.value = saved(step: GuideStep.intro, created: null);
    final c = coord(b, p);
    b.beginResult = null;
    var s = await c.start(uid: 'u');
    expect(s.errorCode, 'backend_unavailable');
    // A normal user action persists the degraded snapshot.
    s = await c.dispatch(IntroFinished(uid: 'u', expectedRevision: s.revision));
    expect(p.value!.errorCode, 'backend_unavailable');
    b.beginResult = remoteState();
    s = await c.start(uid: 'u');
    expect(s.errorCode, isNull);
    expect(s.run, GuideRun.active);
    expect(s.sessionId, 'actual');
    expect(s.step, GuideStep.homeMic);
    expect(p.value!.errorCode, isNull);
  });

  test('blocked guide_operation_failed resumes by read-only begin only',
      () async {
    final b = ProbeBackend()
          ..failDetail = true
          ..beginResult = remoteState(session: 's'),
        p = MemoryStore();
    final c = coord(b, p);
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
    final ev = EventModel(
        // banned-ok: Fixed event fixture for the guide assertion.
        id: 'A', userId: 'u', title: 't', startAt: DateTime(2026, 10, 20, 13));
    s = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: ev,
        operationId: 'create-op'));
    expect(s.step, GuideStep.savedDetail);
    s = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: ev,
        preparationResolved: true,
        departureResolved: true,
        setupHelpAcknowledged: true));
    expect(s.run, GuideRun.blocked);
    expect(s.errorCode, 'guide_operation_failed');
    final advancesBefore = b.advances;
    final beginsBefore = b.begins;
    b.beginResult = const GuideBackendState(
        sessionId: 's',
        serverRevision: 9,
        step: GuideStep.savedDetail,
        createdEventId: 'A');
    final r = await c.dispatch(ResumeRequested(
        uid: 'u', sessionId: 's', expectedRevision: s.revision));
    expect(r.run, GuideRun.active);
    expect(r.errorCode, isNull);
    expect(r.step, GuideStep.savedDetail);
    expect(r.createdEventId, 'A');
    expect(r.serverRevision, 9);
    expect(r.mayListenContinuously, isFalse);
    expect(b.advances, advancesBefore);
    expect(b.begins, beginsBefore + 1);
    expect(b.authorizes, 0);
  });

  test('blocked resume with unavailable backend stays blocked', () async {
    final b = ProbeBackend()
          ..failDetail = true
          ..beginResult = remoteState(session: 's'),
        p = MemoryStore();
    final c = coord(b, p);
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
    final ev = EventModel(
        // banned-ok: Fixed event fixture for the guide assertion.
        id: 'A', userId: 'u', title: 't', startAt: DateTime(2026, 10, 20, 13));
    s = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: ev,
        operationId: 'create-op'));
    s = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: ev,
        preparationResolved: true,
        departureResolved: true,
        setupHelpAcknowledged: true));
    expect(s.run, GuideRun.blocked);
    b.beginThrows = true;
    final r = await c.dispatch(ResumeRequested(
        uid: 'u', sessionId: 's', expectedRevision: s.revision));
    expect(r.run, GuideRun.blocked);
    expect(r.createdEventId, 'A');
  });

  test('start recovers local conflict when new server session is unbound',
      () async {
    final b = ProbeBackend()..beginResult = remoteState(session: 'new-session');
    final checkpoint =
        saved(run: GuideRun.paused, error: 'created_binding_conflict');
    final p = MemoryStore()..value = checkpoint;

    for (var attempt = 0; attempt < 2; attempt++) {
      final s = await coord(b, p).start(uid: 'u');
      expect(s.run, GuideRun.active);
      expect(s.errorCode, isNull);
      expect(s.step, checkpoint.step);
      expect(s.createdEventId, checkpoint.createdEventId);
      expect(s.savedCreateOperationId, checkpoint.savedCreateOperationId);
      expect(s.savedLocalDate, checkpoint.savedLocalDate);
      expect(s.sessionId, 'new-session');
      expect(s.serverRevision, 11);
      expect(s.mayListenContinuously, isFalse);
      expect(p.value, same(s));
    }
    expect(b.advances, 0);
    expect(b.authorizes, 0);
  });

  test('start keeps local conflict when the server names a different binding',
      () async {
    final b = ProbeBackend()
      ..beginResult = remoteState(session: 'new-session', created: 'B');
    final checkpoint =
        saved(run: GuideRun.paused, error: 'created_binding_conflict');
    final p = MemoryStore()..value = checkpoint;

    final s = await coord(b, p).start(uid: 'u');
    expect(s.run, GuideRun.blocked);
    expect(s.errorCode, checkpoint.errorCode);
    expect(s.step, checkpoint.step);
    expect(s.createdEventId, checkpoint.createdEventId);
    expect(s.sessionId, checkpoint.sessionId);
    expect(b.advances, 0);
    expect(b.authorizes, 0);
  });

  test('local A versus remote B fails closed without adopting remote',
      () async {
    final b = ProbeBackend(), p = MemoryStore();
    p.value = saved();
    b.beginResult = remoteState(
        session: 'remote', step: GuideStep.savedDetail, created: 'B');
    final c = coord(b, p);
    final s = await c.start(uid: 'u');
    expect(s.run, GuideRun.blocked);
    expect(s.errorCode, 'created_binding_conflict');
    expect(s.createdEventId, 'A');
    expect(s.savedCreateOperationId, 'create-op');
    expect(s.sessionId, 's');
    expect(s.serverRevision, 3);
    final access = await c.authorize(
        context: GuideChargeContext(
            uid: 'u',
            version: 'v',
            sessionId: 's',
            kind: GuideChargeKind.scheduleParse,
            operation: GuideOperation.createParse,
            phase: GuideStep.savedDetail,
            revision: s.revision,
            serverRevision: s.serverRevision,
            createdEventId: 'A'),
        operationId: 'x');
    expect(access.status, GuideAccessStatus.denied);
    expect(b.authorizes, 0);
    final r = await c.dispatch(ResumeRequested(
        uid: 'u', sessionId: 's', expectedRevision: s.revision));
    expect(r.run, GuideRun.blocked);
    expect(r.errorCode, 'created_binding_conflict');
    expect(r.createdEventId, 'A');
    expect(b.advances, 0);
  });

  test('pending unbound checkpoint keeps ID and op blocked across resume',
      () async {
    final b = ProbeBackend(), p = MemoryStore();
    p.value = saved(
        step: GuideStep.correctAndSave,
        run: GuideRun.blocked,
        error: 'created_checkpoint_pending');
    b.beginResult = remoteState(session: 'new-session');
    final c = coord(b, p);
    var s = await c.start(uid: 'u');
    expect(s.run, GuideRun.blocked);
    expect(s.errorCode, 'created_checkpoint_pending');
    expect(s.step, GuideStep.correctAndSave);
    expect(s.createdEventId, 'A');
    expect(s.savedCreateOperationId, 'create-op');
    expect(s.sessionId, 's');
    s = await c.dispatch(ResumeRequested(
        uid: 'u', sessionId: s.sessionId, expectedRevision: s.revision));
    expect(s.run, GuideRun.blocked);
    expect(s.errorCode, 'created_checkpoint_pending');
    expect(s.createdEventId, 'A');
    expect(s.savedCreateOperationId, 'create-op');
    expect(b.advances, 0);
    expect(b.authorizes, 0);
  });

  test('same canonical receipt is not a conflict and stays pending', () async {
    final b = ProbeBackend(), p = MemoryStore();
    p.value = saved(
        step: GuideStep.correctAndSave,
        run: GuideRun.blocked,
        error: 'created_checkpoint_pending');
    b.beginResult = remoteState(created: 'A');
    final s = await coord(b, p).start(uid: 'u');
    expect(s.errorCode, 'created_checkpoint_pending');
    expect(s.run, GuideRun.blocked);
    expect(s.createdEventId, 'A');
    expect(b.advances, 0);
  });
  test('active offline session recovers through root ResumeRequested',
      () async {
    final b = ProbeBackend(), p = MemoryStore();
    p.value = saved(step: GuideStep.homeMic, created: null);
    final c = coord(b, p);
    var s = await c.start(uid: 'u');
    expect(s.run, GuideRun.active);
    expect(s.sessionId, 's');
    expect(s.errorCode, 'backend_unavailable');
    final revision = s.revision;
    b.beginResult = remoteState(session: 's');
    s = await c.dispatch(ResumeRequested(
        uid: 'u', sessionId: s.sessionId, expectedRevision: s.revision));
    expect(s.run, GuideRun.active);
    expect(s.errorCode, isNull);
    expect(s.step, GuideStep.homeMic);
    expect(s.sessionId, 's');
    expect(s.serverRevision, 11);
    expect(s.revision, revision + 1);
    expect(p.value, same(s));
    expect(s.mayListenContinuously, isFalse);
    expect(b.begins, 2);
    expect(b.advances, 0);
    expect(b.authorizes, 0);
  });

  test('blocked timeout retry adopts advanced canonical queryMic', () async {
    final b = ProbeBackend()..failDetail = true, p = MemoryStore();
    p.value = saved();
    b.beginResult =
        remoteState(session: 's', step: GuideStep.savedDetail, created: 'A');
    final c = coord(b, p);
    var s = await c.start(uid: 'u');
    s = await c.dispatch(DetailObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: s.revision,
        persistedEvent: EventModel(
            id: 'A',
            userId: 'u',
            title: 't',
            // banned-ok: Fixed event fixture for the guide assertion.
            startAt: DateTime(2026, 10, 20, 13)),
        preparationResolved: true,
        departureResolved: true,
        setupHelpAcknowledged: false));
    expect(s.run, GuideRun.blocked);
    expect(s.errorCode, 'guide_operation_failed');
    final advances = b.advances;
    b.beginResult =
        remoteState(session: 's', step: GuideStep.queryMic, created: 'A');
    s = await c.dispatch(ResumeRequested(
        uid: 'u', sessionId: 's', expectedRevision: s.revision));
    expect(s.step, GuideStep.queryMic);
    expect(s.run, GuideRun.active);
    expect(s.errorCode, isNull);
    expect(s.createdEventId, 'A');
    expect(s.savedCreateOperationId, 'create-op');
    expect(s.mayListenContinuously, isFalse);
    expect(b.advances, advances);
    expect(b.authorizes, 0);
  });

  test('known saved old session cannot adopt new unbound create session',
      () async {
    // Exercise the same invariant on cold start and root retry.
    for (final retry in [false, true]) {
      final b = ProbeBackend(), p = MemoryStore();
      final checkpoint = saved();
      p.value = checkpoint;
      final c = coord(b, p);
      if (retry) {
        final offline = await c.start(uid: 'u');
        expect(offline.errorCode, 'backend_unavailable');
      }
      b.beginResult = remoteState(session: 'new-session');
      final s = retry
          ? await c.dispatch(ResumeRequested(
              uid: 'u',
              sessionId: 's',
              expectedRevision: c.state.value.revision))
          : await c.start(uid: 'u');
      expect(s.run, GuideRun.blocked);
      expect(s.errorCode, 'created_binding_conflict');
      expect(s.sessionId, 's');
      expect(s.serverRevision, checkpoint.serverRevision);
      expect(s.step, checkpoint.step);
      expect(s.createdEventId, 'A');
      expect(s.savedCreateOperationId, 'create-op');
      expect(s.originalStartLocal, checkpoint.originalStartLocal);
      expect(s.calendarSyncHeld, isTrue);
      expect(s.mayListenContinuously, isFalse);
      final stillBlocked = await c.dispatch(ResumeRequested(
          uid: 'u', sessionId: 's', expectedRevision: s.revision));
      expect(stillBlocked.run, GuideRun.blocked);
      expect(stillBlocked.sessionId, 's');
      expect(stillBlocked.errorCode, 'created_binding_conflict');
      expect(b.advances, 0);
      expect(b.authorizes, 0);
    }
  });

  test('same-session coarse create keeps saved checkpoint without conflict',
      () async {
    final b = ProbeBackend()..beginResult = remoteState(session: 's');
    final p = MemoryStore()..value = saved();
    final c = coord(b, p);
    final s = await c.start(uid: 'u');
    expect(s.run, GuideRun.active);
    expect(s.errorCode, isNull);
    expect(s.step, GuideStep.savedDetail);
    expect(s.createdEventId, 'A');
    expect(s.savedCreateOperationId, 'create-op');
    expect(b.advances, 0);
  });

  test('paused resume does not auto-enable continuous microphone', () async {
    final b = ProbeBackend()
      ..beginResult =
          remoteState(session: 's', step: GuideStep.changeSpeech, created: 'A');
    final p = MemoryStore()..value = saved(step: GuideStep.changeSpeech);
    final c = coord(b, p);
    var s = await c.start(uid: 'u');
    c.suspend(GuidePauseReason.userStop);
    s = c.state.value;
    final begins = b.begins;
    s = await c.dispatch(ResumeRequested(
        uid: 'u', sessionId: 's', expectedRevision: s.revision));
    expect(s.run, GuideRun.active);
    expect(s.step, GuideStep.changeSpeech);
    expect(s.mayListenContinuously, isFalse);
    expect(b.begins, begins);
    expect(b.advances, 0);
  });

  test('late retry cannot overwrite revision or epoch changes', () async {
    for (final interrupt in ['revision', 'suspend', 'terminate']) {
      final b = ProbeBackend(), p = MemoryStore();
      p.value = saved(step: GuideStep.intro, created: null);
      final c = coord(b, p);
      final offline = await c.start(uid: 'u');
      final entered = Completer<void>();
      final delayed = Completer<GuideBackendState?>();
      b.beginHook = () {
        entered.complete();
        return delayed.future;
      };
      final retry = c.dispatch(ResumeRequested(
          uid: 'u', sessionId: 's', expectedRevision: offline.revision));
      await entered.future;
      if (interrupt == 'revision') {
        await c.dispatch(
            IntroFinished(uid: 'u', expectedRevision: offline.revision));
      } else if (interrupt == 'suspend') {
        c.suspend(GuidePauseReason.background);
      } else {
        await c.terminate(GuideExit.cancel);
      }
      final accepted = c.state.value;
      final saves = p.saves;
      delayed.complete(remoteState(session: 's', step: GuideStep.queryMic));
      final result = await retry;
      expect(result, same(accepted));
      expect(c.state.value, same(accepted));
      expect(p.saves, saves);
      expect(b.advances, 0);
      expect(b.authorizes, 0);
    }
  });
  test('own published save still fails closed when progress persistence throws',
      () async {
    final b = ProbeBackend()
      ..beginResult = remoteState(session: 's', step: GuideStep.correctAndSave);
    final p = MemoryStore()
      ..value = saved(step: GuideStep.correctAndSave, created: null);
    final c = coord(b, p);
    final before = await c.start(uid: 'u');
    p.failNextSave = true;
    final persisted = EventModel(
        id: 'A',
        userId: 'u',
        title: 'Synthetic persisted fixture',
        // banned-ok: Fixed event fixture for the guide assertion.
        startAt: DateTime(2026, 10, 20, 13),
        // banned-ok: Fixed event fixture for the guide assertion.
        endAt: DateTime(2026, 10, 20, 14));
    final after = await c.dispatch(SaveObserved(
        uid: 'u',
        sessionId: 's',
        expectedRevision: before.revision,
        persistedEvent: persisted,
        operationId: 'actual-op-fixture'));
    expect(after.run, GuideRun.blocked);
    expect(after.errorCode, 'created_checkpoint_pending');
    expect(after.createdEventId, 'A');
    expect(after.savedCreateOperationId, 'actual-op-fixture');
    expect(p.value?.run, GuideRun.blocked);
    expect(b.advances, 1);
  });
}
