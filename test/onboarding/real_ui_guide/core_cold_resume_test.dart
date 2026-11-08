import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';
import 'package:planflow/services/real_ui_guide_grant_service.dart';

class ColdProgress implements GuideProgressStore {
  GuideSnapshot? value;
  Future<GuideSnapshot?> Function(String)? loader;
  int saves = 0;
  @override
  Future<GuideSnapshot?> load(
          {required String uid, required String version}) async =>
      loader == null ? value : await loader!(uid);
  @override
  Future<void> save(GuideSnapshot snapshot) async {
    saves++;
    value = snapshot;
  }
}

class ColdBackend implements GuideBackendPort {
  int begins = 0;
  Future<GuideBackendState?> Function(String)? responder;
  @override
  Future<GuideBackendState?> begin(
      {required String uid,
      required String version,
      required String requestId}) async {
    begins++;
    return responder == null ? null : await responder!(uid);
  }

  @override
  Future<GuideBackendState> advance(
          {required GuideSnapshot snapshot,
          required GuideBackendAction action,
          required String requestId,
          EventModel? event,
          DateTime? expectedStartLocal}) =>
      throw StateError('unexpected advance');
  @override
  Future<GuideAccess> authorize(
          {required GuideChargeContext context, required String operationId}) =>
      throw StateError('unexpected quota');
  @override
  Future<void> finish(
          {required GuideSnapshot snapshot,
          required GuideExit exit,
          required String requestId}) =>
      throw StateError('unexpected finish');
}

GuideSnapshot local(
        {String uid = 'u',
        String version = 'v',
        GuideStep step = GuideStep.homeMic,
        GuideRun run = GuideRun.active,
        String? created,
        String? error}) =>
    GuideSnapshot(
        uid: uid,
        version: version,
        revision: 7,
        serverRevision: 3,
        sessionId: 'old',
        step: step,
        run: run,
        createdEventId: created,
        savedCreateOperationId: created == null ? null : 'create-op',
        errorCode: error,
        // banned-ok: Fixed event fixture for the guide assertion.
        savedLocalDate: DateTime(2026, 10, 20),
        // banned-ok: Fixed event fixture for the guide assertion.
        originalStartLocal: DateTime(2026, 10, 20, 13),
        // banned-ok: Fixed event fixture for the guide assertion.
        expectedUpdatedStartLocal: DateTime(2026, 10, 20, 14),
        dateTimeZone: 'Asia/Seoul',
        calendarSyncHeld: true);
const intro = GuideBackendState(
    sessionId: 'actual', serverRevision: 11, step: GuideStep.intro);
void main() {
  for (final step in [GuideStep.completed, GuideStep.skipped]) {
    for (final throws in [false, true]) {
      test(
          'terminal ${step.name} bypasses ${throws ? 'throwing' : 'null'} backend without persistence',
          () async {
        final saved = local(
            step: step,
            run: GuideRun.terminal,
            created: 'created',
            error: 'retained');
        final p = ColdProgress()..value = saved;
        final b = ColdBackend()
          ..responder = (_) async {
            if (throws) throw StateError('offline');
            return null;
          };
        final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
        final s = await c.start(uid: 'u');
        expect(identical(s, saved), isTrue);
        expect(s.run, GuideRun.terminal);
        expect(s.mayListenContinuously, isFalse);
        expect(b.begins, 0);
        expect(p.saves, 0);
      });
    }
  }
  test('literal begin create phase keeps intro visible until real mic tap',
      () async {
    final progress = ColdProgress();
    const sessionId = '22e85d71-39de-44e8-8f9f-58d26bebaf22';
    final backend = SupabaseRealUiGuideGrantService.forTesting(
      currentUid: () => 'u',
      rpc: (name, params) async => <String, Object?>{
        'status': 'granted',
        'session_id': sessionId,
        'phase': 'create',
        'revision': 0,
        'event_id': null,
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 2))
            .toIso8601String(),
      },
    );
    final coordinator = RealUiGuideCoordinator(
        backend: backend, progress: progress, version: 'real_ui_v1');
    final store = GuideAccountFeatureTourStore(
        uidProvider: () => 'u', progress: progress);
    final started = await coordinator.start(uid: 'u');
    expect(started.step, GuideStep.intro);
    expect(await store.shouldShow(), isTrue);
    final introFinished = await coordinator
        .dispatch(const IntroFinished(uid: 'u', expectedRevision: 0));
    expect(introFinished.step, GuideStep.homeMic);
    expect(await store.shouldShow(), isFalse);
    final micTapped = await coordinator.dispatch(HomeMicTapped(
        uid: 'u',
        sessionId: sessionId,
        expectedRevision: introFinished.revision));
    expect(micTapped.step, GuideStep.createSpeech);
    expect(micTapped.createdEventId, isNull);
  });

  for (final interruptedStep in [
    GuideStep.createSpeech,
    GuideStep.correctAndSave
  ]) {
    test(
        'cold start normalizes unbound ${interruptedStep.name} to actionable home mic',
        () async {
      final saved = local(step: interruptedStep).copyWith(sessionId: 'actual');
      final p = ColdProgress()..value = saved;
      final b = ColdBackend()..responder = (_) async => intro;
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      final s = await c.start(uid: 'u');
      expect(s.step, GuideStep.homeMic);
      expect(s.uid, saved.uid);
      expect(s.version, saved.version);
      expect(s.sessionId, 'actual');
      expect(s.revision, saved.revision);
      expect(s.serverRevision, 11);
      expect(s.createdEventId, isNull);
      expect(s.savedCreateOperationId, isNull);
      expect(s.run, GuideRun.active);
      expect(s.mayListenContinuously, isFalse);
      expect(b.begins, 1);
      expect(p.saves, 1);
    });

    test(
        'retry reconciliation normalizes unbound ${interruptedStep.name} to home mic',
        () async {
      final saved = local(step: interruptedStep).copyWith(sessionId: 'actual');
      final p = ColdProgress()..value = saved;
      final b = ColdBackend()..responder = (_) async => null;
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      var initial = await c.start(uid: 'u');
      expect(initial.step, GuideStep.homeMic);
      initial = await c.dispatch(HomeMicTapped(
          uid: 'u', sessionId: 'actual', expectedRevision: initial.revision));
      if (interruptedStep == GuideStep.correctAndSave) {
        initial = await c.dispatch(ParseConfirmed(
            uid: 'u',
            sessionId: 'actual',
            expectedRevision: initial.revision,
            operationId: 'parse-op'));
      }
      expect(initial.step, interruptedStep);
      b.responder = (_) async => intro;
      final resumed = await c.dispatch(ResumeRequested(
          uid: 'u', sessionId: 'actual', expectedRevision: initial.revision));
      expect(resumed.step, GuideStep.homeMic);
      expect(resumed.uid, saved.uid);
      expect(resumed.version, saved.version);
      expect(resumed.sessionId, 'actual');
      expect(resumed.revision, initial.revision + 1);
      expect(resumed.serverRevision, 11);
      expect(resumed.createdEventId, isNull);
      expect(resumed.savedCreateOperationId, isNull);
      expect(resumed.run, GuideRun.active);
      expect(resumed.mayListenContinuously, isFalse);
      expect(b.begins, 2);
    });
  }
  test('offline cold start normalizes an unbound create checkpoint to home mic',
      () async {
    final p = ColdProgress()
      ..value = local(step: GuideStep.correctAndSave).copyWith(sessionId: 'actual');
    final b = ColdBackend()..responder = (_) async => null;
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
    final s = await c.start(uid: 'u');
    expect(s.step, GuideStep.homeMic);
    expect(s.errorCode, 'backend_unavailable');
    expect(s.createdEventId, isNull);
    expect(s.mayListenContinuously, isFalse);
  });

  test('backend begin failure keeps a fresh local intro eligible', () async {
    final p = ColdProgress();
    final b = ColdBackend()..responder = (_) async => null;
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
    final s = await c.start(uid: 'u');
    expect(s.step, GuideStep.intro);
    expect(s.errorCode, 'backend_unavailable');
    expect(s.run, GuideRun.active);
  });
  test('bound ID from a different unbound session remains blocked', () async {
    final saved = local(step: GuideStep.createSpeech, created: 'bound-event');
    final p = ColdProgress()..value = saved;
    final b = ColdBackend()..responder = (_) async => intro;
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
    final s = await c.start(uid: 'u');
    expect(s.step, GuideStep.createSpeech);
    expect(s.createdEventId, 'bound-event');
    expect(s.run, GuideRun.blocked);
    expect(s.errorCode, 'created_binding_conflict');
  });
  test(
      'intro-seen home mic survives coarse intro and takes real server identity',
      () async {
    final saved = local();
    final p = ColdProgress()..value = saved;
    final b = ColdBackend()..responder = (_) async => intro;
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
    final s = await c.start(uid: 'u');
    expect(s.step, GuideStep.homeMic);
    expect(s.sessionId, 'actual');
    expect(s.serverRevision, 11);
    expect(s.revision, saved.revision);
    expect(s.createdEventId, isNull);
    expect(s.mayListenContinuously, isFalse);
    expect(p.saves, 1);
  });
  for (final offline in [false, true]) {
    test('bound pending checkpoint survives cold start offline=$offline',
        () async {
      final saved = local(
          step: GuideStep.correctAndSave,
          run: GuideRun.blocked,
          created: 'created',
          error: 'created_checkpoint_pending');
      final p = ColdProgress()..value = saved;
      final b = ColdBackend()..responder = (_) async => offline ? null : intro;
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      final s = await c.start(uid: 'u');
      expect(s.createdEventId, 'created');
      expect(s.savedCreateOperationId, 'create-op');
      expect(s.step, GuideStep.correctAndSave);
      expect(s.run, GuideRun.blocked);
      expect(s.errorCode, 'created_checkpoint_pending');
      expect(s.originalStartLocal, saved.originalStartLocal);
      expect(s.expectedUpdatedStartLocal, saved.expectedUpdatedStartLocal);
      expect(s.calendarSyncHeld, isTrue);
      expect(s.mayListenContinuously, isFalse);
    });
  }
  for (final invalid in [
    local(
        uid: 'other',
        step: GuideStep.completed,
        run: GuideRun.terminal,
        created: 'foreign'),
    local(
        version: 'other',
        step: GuideStep.skipped,
        run: GuideRun.terminal,
        created: 'foreign')
  ]) {
    test('mismatched storage ${invalid.uid}/${invalid.version} is discarded',
        () async {
      final p = ColdProgress()..value = invalid;
      final b = ColdBackend()..responder = (_) async => intro;
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      final s = await c.start(uid: 'u');
      expect(s.uid, 'u');
      expect(s.version, 'v');
      expect(s.step, GuideStep.intro);
      expect(s.createdEventId, isNull);
      expect(s.revision, 0);
      expect(b.begins, 1);
    });
  }
  test('delayed old-user local load cannot publish or call backend', () async {
    final delayed = Completer<GuideSnapshot?>();
    final p = ColdProgress()
      ..loader = (uid) => uid == 'old' ? delayed.future : Future.value(null);
    final b = ColdBackend()..responder = (_) async => intro;
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
    final old = c.start(uid: 'old');
    await c.start(uid: 'new');
    delayed.complete(
        local(uid: 'old', step: GuideStep.completed, run: GuideRun.terminal));
    await old;
    expect(c.state.value.uid, 'new');
    expect(b.begins, 1);
    expect(p.saves, 1);
  });
  test('delayed old-user remote completion cannot publish or save', () async {
    final delayed = Completer<GuideBackendState?>();
    final entered = Completer<void>();
    final p = ColdProgress();
    final b = ColdBackend()
      ..responder = (uid) {
        if (uid == 'old') {
          entered.complete();
          return delayed.future;
        }
        return Future.value(intro);
      };
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
    final old = c.start(uid: 'old');
    await entered.future;
    await c.start(uid: 'new');
    delayed.complete(const GuideBackendState(
        sessionId: 'stale', serverRevision: 99, step: GuideStep.completed));
    await old;
    expect(c.state.value.uid, 'new');
    expect(c.state.value.sessionId, 'actual');
    expect(p.saves, 1);
  });
  for (final failsClosed in <(GuideStep, String)>[
    (GuideStep.correctAndSave, 'created_checkpoint_pending'),
    (GuideStep.createSpeech, 'created_binding_conflict'),
  ]) {
    final step = failsClosed.$1;
    final code = failsClosed.$2;
    test(
        'offline retry preserves fail-closed $code on a stored checkpoint without a created binding',
        () async {
      final saved = local(step: step, run: GuideRun.blocked, error: code)
          .copyWith(sessionId: 'actual');
      final p = ColdProgress()..value = saved;
      final b = ColdBackend()..responder = (_) async => null;
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      final before = await c.start(uid: 'u');
      // The cold-start path already keeps the fail-closed run and errorCode.
      // An offline retry on the same checkpoint must not silently overwrite
      // them with backend_unavailable/active, which would discard the
      // evidence that kept the guide from advancing.
      final begins = b.begins;
      final saves = p.saves;
      final resumed = await c.dispatch(ResumeRequested(
          uid: before.uid,
          sessionId: before.sessionId,
          expectedRevision: before.revision));
      expect(resumed.run, GuideRun.blocked);
      expect(resumed.errorCode, code);
      expect(resumed.mayListenContinuously, isFalse);
      expect(b.begins, begins + 1);
      expect(p.saves, saves);
    });
  }
}
