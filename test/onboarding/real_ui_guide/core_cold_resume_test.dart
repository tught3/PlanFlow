import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_route_recovery.dart';
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
  final finishes = <(String?, GuideExit)>[];
  Future<GuideBackendState?> Function(String)? responder;
  @override
  Future<GuideBeginResult> begin(
      {required String uid,
      required String version,
      required String requestId}) async {
    begins++;
    final result = await responder?.call(uid);
    return result == null
        ? const GuideBeginFailed(
        GuideFailureDiagnostic(GuideFailureKind.backendUnavailable),
      )
        : GuideBeginGranted(result);
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
          required String requestId}) async {
    finishes.add((snapshot.sessionId, exit));
  }
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
  test('product cold start skips stored incomplete bound progress', () async {
    final p = ColdProgress()
      ..value = local(step: GuideStep.editPreview, created: 'event');
    final b = ColdBackend();
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');

    final state = await c.start(uid: 'u', skipIncompleteOnColdStart: true);

    expect(state.run, GuideRun.terminal);
    expect(state.step, GuideStep.skipped);
    expect(state.sessionId, 'old');
    expect(state.createdEventId, 'event');
    expect(state.calendarSyncHeld, isFalse);
    expect(p.value, same(state));
    expect(b.begins, 0);
    expect(b.finishes, [('old', GuideExit.skip)]);
  });

  test('cold start without a grant records no invented session', () async {
    final p = ColdProgress()
      ..value = local(run: GuideRun.blocked).copyWith(clearSessionId: true);
    final b = ColdBackend();
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');

    final state = await c.start(uid: 'u', skipIncompleteOnColdStart: true);

    expect(state.run, GuideRun.terminal);
    expect(state.step, GuideStep.skipped);
    expect(state.sessionId, isNull);
    expect(b.begins, 1);
    expect(b.finishes, isEmpty);
  });

  test('cold-start opt-in starts a fresh guide when no checkpoint exists',
      () async {
    final p = ColdProgress();
    final b = ColdBackend()..responder = (_) async => intro;
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');

    final state = await c.start(uid: 'u', skipIncompleteOnColdStart: true);

    expect(state.run, GuideRun.active);
    expect(state.step, GuideStep.intro);
    expect(b.begins, 1);
    expect(b.finishes, isEmpty);
  });

  for (final step in [GuideStep.editPreview, GuideStep.updatedDetail]) {
    test('cold ${step.name} restores accepted time with no preferences',
        () async {
      // banned-ok: Fixed date for the accepted preview fixture.
      final accepted = DateTime.utc(2026, 11, 16, 8);
      final p = ColdProgress();
      final b = ColdBackend()
        ..responder = (_) async => GuideBackendState(
              sessionId: 'owned-session',
              serverRevision: 6,
              step: step,
              createdEventId: 'bound',
              expectedStartAt: accepted,
              expectedStartAtReported: true,
            );
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');

      final restored = await c.start(uid: 'u');

      expect(restored.step, step);
      expect(restored.run, GuideRun.active);
      expect(restored.uid, 'u');
      expect(restored.sessionId, 'owned-session');
      expect(restored.createdEventId, 'bound');
      expect(restored.expectedUpdatedStartLocal, accepted);
      expect(p.value, same(restored));
      expect(b.begins, 1);
    });
  }

  for (final (label, sessionId, eventId, revision) in [
    ('accepted retry', 'old', 'bound', 4),
    ('different session', 'new', 'bound', 4),
    ('different event', 'old', 'foreign', 4),
    ('missing event', 'old', null, 4),
    ('stale revision', 'old', 'bound', 2),
  ]) {
    test('explicit preview recovery validates $label', () async {
      final saved = local(step: GuideStep.editPreview, created: 'bound')
          .copyWith(clearExpectedUpdatedStartLocal: true);
      final p = ColdProgress()..value = saved;
      final b = ColdBackend()
        ..responder = (_) async => const GuideBackendState(
              sessionId: 'old',
              serverRevision: 3,
              step: GuideStep.editPreview,
              createdEventId: 'bound',
            );
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      final started = await c.start(uid: 'u');
      expect(started.run, GuideRun.active);
      expect(started.expectedUpdatedStartLocal, isNull);
      // banned-ok: Fixed date for the accepted preview fixture.
      final accepted = DateTime.utc(2026, 11, 16, 8);
      b.responder = (_) async => GuideBackendState(
            sessionId: sessionId,
            serverRevision: revision,
            step: GuideStep.editPreview,
            createdEventId: eventId,
            expectedStartAt: accepted,
            expectedStartAtReported: true,
          );

      final result = await c.dispatch(ResumeRequested(
          uid: started.uid,
          sessionId: started.sessionId,
          expectedRevision: started.revision));

      final valid = label == 'accepted retry';
      expect(result.run, valid ? GuideRun.active : GuideRun.blocked);
      expect(result.step, GuideStep.editPreview);
      expect(result.sessionId, 'old');
      expect(result.createdEventId, 'bound');
      expect(result.serverRevision, valid ? 4 : 3);
      expect(result.expectedUpdatedStartLocal, valid ? accepted : null);
      expect(b.begins, 2);
    });
  }

  for (final (label, revision, reported, retainsLocalTime) in [
    ('legacy same revision', 3, false, true),
    ('legacy newer revision', 4, false, false),
    ('explicit invalid time', 3, true, false),
  ]) {
    test('preview reconciles $label', () async {
      final saved = local(step: GuideStep.editPreview, created: 'bound');
      final p = ColdProgress()..value = saved;
      final b = ColdBackend()
        ..responder = (_) async => GuideBackendState(
              sessionId: 'old',
              serverRevision: revision,
              step: GuideStep.editPreview,
              createdEventId: 'bound',
              expectedStartAtReported: reported,
            );
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      final restored = await c.start(uid: 'u');
      expect(restored.expectedUpdatedStartLocal,
          retainsLocalTime ? saved.expectedUpdatedStartLocal?.toUtc() : null);
    });
  }

  testWidgets('timed out cold start permits retry and ignores late result',
      (tester) async {
    final progress = ColdProgress();
    final stalled = Completer<GuideBackendState?>();
    final backend = ColdBackend()..responder = (_) => stalled.future;
    final coordinator = RealUiGuideCoordinator(
        backend: backend, progress: progress, version: 'v');
    final first = coordinator.start(uid: 'u');
    await tester.pump();
    await tester.pump(guideBeginTimeout);
    expect((await first).errorCode, 'timeout');
    backend.responder = (_) async => intro;
    final recovered = await coordinator.start(uid: 'u');
    expect(recovered.run, GuideRun.active);
    expect(recovered.errorCode, isNull);
    stalled.complete(const GuideBackendState(
        sessionId: 'late', serverRevision: 1, step: GuideStep.intro));
    await tester.pump();
    expect(coordinator.state.value, same(recovered));
  });

  testWidgets('timed-out preview refresh persists the failure and allows a fresh retry',
      (tester) async {
    final progress = ColdProgress();
    const initial = GuideBackendState(
        sessionId: 'owned-session',
        serverRevision: 6,
        step: GuideStep.editPreview,
        createdEventId: 'bound');
    final backend = ColdBackend()..responder = (_) async => initial;
    final coordinator = RealUiGuideCoordinator(
        backend: backend, progress: progress, version: 'v');
    final started = await coordinator.start(uid: 'u');
    final signal = ResumeRequested(
        uid: started.uid,
        sessionId: started.sessionId,
        expectedRevision: started.revision);
    final stalled = Completer<GuideBackendState?>();
    backend.responder = (_) => stalled.future;
    final first = coordinator.dispatch(signal);

    await tester.pump(guideBeginTimeout);
    final failed = await first;
    expect(failed.failureDiagnostic?.kind, GuideFailureKind.timeout);
    expect(failed.createdEventId, started.createdEventId);
    expect(failed.serverRevision, started.serverRevision);
    expect(progress.saves, 2);

    // banned-ok: Fixed instant for preview-recovery assertions.
    final accepted = DateTime.utc(2026, 11, 16, 8);
    backend.responder = (_) async => GuideBackendState(
          sessionId: initial.sessionId,
          serverRevision: initial.serverRevision,
          step: initial.step,
          createdEventId: initial.createdEventId,
          expectedStartAt: accepted,
          expectedStartAtReported: true,
        );
    final restored = await coordinator.dispatch(ResumeRequested(
        uid: failed.uid,
        sessionId: failed.sessionId,
        expectedRevision: failed.revision));
    expect(backend.begins, 3);
    expect(restored.expectedUpdatedStartLocal, accepted);
    expect(restored.revision, failed.revision + 1);
    expect(restored.failureDiagnostic, isNull);

    stalled.complete(GuideBackendState(
        sessionId: initial.sessionId,
        serverRevision: initial.serverRevision + 1,
        step: initial.step,
        createdEventId: initial.createdEventId,
        expectedStartAt: accepted.add(const Duration(hours: 1)),
        expectedStartAtReported: true));
    await tester.pump();
    expect(coordinator.state.value, same(restored));
    expect(progress.value, same(restored));
    expect(progress.saves, 3);
  });

  for (final (label, sessionId, eventId, revision, explicitInvalid, blocked)
      in [
    ('same binding and revision', 'old', 'bound', 3, false, false),
    ('different session', 'new', 'bound', 3, false, true),
    ('different event', 'old', 'other', 3, false, true),
    ('stale server revision', 'old', 'bound', 2, false, true),
    ('newer server revision', 'old', 'bound', 4, false, false),
    ('explicit invalid time', 'old', 'bound', 3, true, false),
  ]) {
    test('legacy updated reply reconciles sync choice with $label', () async {
      final saved = local(step: GuideStep.syncChoice, created: 'bound');
      final progress = ColdProgress()..value = saved;
      final backend = SupabaseRealUiGuideGrantService.forTesting(
        currentUid: () => saved.uid,
        rpc: (name, _) async {
          expect(name, kRpcBegin);
          return <String, Object?>{
            'status': 'granted',
            'session_id': sessionId,
            'phase': 'updated',
            'event_id': eventId,
            'revision': revision,
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 2))
                .toIso8601String(),
            if (explicitInvalid) 'expected_start_at': 'invalid',
          };
        },
      );
      final coordinator = RealUiGuideCoordinator(
          backend: backend, progress: progress, version: saved.version);
      final restored = await coordinator.start(uid: saved.uid);

      expect(restored.sessionId, saved.sessionId);
      expect(restored.createdEventId, saved.createdEventId);
      expect(restored.run, blocked ? GuideRun.blocked : GuideRun.active);
      if (blocked) {
        expect(restored.step, GuideStep.syncChoice);
        expect(restored.serverRevision, saved.serverRevision);
        expect(GuideRouteRecovery.supports(restored), isFalse);
      } else {
        expect(restored.step, GuideStep.updatedDetail);
        expect(restored.serverRevision, revision);
        expect(restored.expectedUpdatedStartLocal,
            revision == saved.serverRevision && !explicitInvalid
                ? saved.expectedUpdatedStartLocal?.toUtc()
                : null);
      }
    });
  }

  test('explicit missing preview refresh does not reopen voice change',
      () async {
    final p = ColdProgress();
    final b = ColdBackend()
      ..responder = (_) async => const GuideBackendState(
            sessionId: 'owned-session',
            serverRevision: 6,
            step: GuideStep.editPreview,
            createdEventId: 'bound',
          );
    final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
    final s = await c.start(uid: 'u');
    b.responder = (_) async => const GuideBackendState(
          sessionId: 'owned-session',
          serverRevision: 6,
          step: GuideStep.changeSpeech,
          createdEventId: 'bound',
        );

    final result = await c.dispatch(ResumeRequested(
        uid: s.uid, sessionId: s.sessionId, expectedRevision: s.revision));

    expect(result, same(s));
    expect(p.saves, 1);
    expect(b.begins, 2);
  });

  for (final phase in ['edit', 'preview']) {
    test('legacy preview without a start resumes safely from wire $phase',
        () async {
      final saved = local(step: GuideStep.editPreview, created: 'created')
          .copyWith(clearExpectedUpdatedStartLocal: true);
      final progress = ColdProgress()..value = saved;
      final calls = <String>[];
      final backend = SupabaseRealUiGuideGrantService.forTesting(
        currentUid: () => saved.uid,
        rpc: (name, _) async {
          calls.add(name);
          expect(name, kRpcBegin);
          return {
            'status': 'granted',
            'session_id': saved.sessionId,
            'event_id': saved.createdEventId,
            'revision': saved.serverRevision,
            'phase': phase,
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 2))
                .toIso8601String(),
          };
        },
      );
      final c = RealUiGuideCoordinator(
          backend: backend, progress: progress, version: saved.version);

      final snapshot = await c.start(uid: saved.uid);
      expect(snapshot.expectedUpdatedStartLocal, isNull);
      final recovery = GuideRouteRecovery.load(
        coordinator: c,
        currentUid: () => saved.uid,
        attachedToRoute: () => true,
        read: (uid, id) async {
          expect(id, saved.createdEventId);
          expect(uid, saved.uid);
          return [EventModel(id: id, userId: uid, title: 'saved')];
        },
      );
      if (phase == 'edit') {
        expect(snapshot.step, GuideStep.changeSpeech);
        expect((await recovery)?.restoresResults, isTrue);
      } else {
        expect(snapshot.step, GuideStep.editPreview);
        await expectLater(
            recovery,
            throwsA(isA<StateError>().having((error) => error.message,
                'message', 'missing_preview_requires_same_phase_refresh')));
      }
      expect(calls, [kRpcBegin]);
      expect(progress.value, same(snapshot));
      expect(snapshot.createdEventId, saved.createdEventId);
      expect(snapshot.serverRevision, saved.serverRevision);
    });
  }

  for (final (caseName, sessionId, eventId, revision, hasAcceptedStart) in [
    ('different session', 'other-session', 'created', 3, false),
    ('different event', 'old', 'other-event', 3, false),
    ('missing event', 'old', null, 3, false),
    ('stale revision', 'old', 'created', 2, false),
    ('existing accepted start', 'old', 'created', 3, true),
  ]) {
    test('wire edit cannot replace a preview with $caseName', () async {
      final saved = local(step: GuideStep.editPreview, created: 'created')
          .copyWith(clearExpectedUpdatedStartLocal: !hasAcceptedStart);
      final progress = ColdProgress()..value = saved;
      final backend = ColdBackend()
        ..responder = (_) async => GuideBackendState(
            sessionId: sessionId,
            createdEventId: eventId,
            serverRevision: revision,
            step: GuideStep.changeSpeech);
      final c = RealUiGuideCoordinator(
          backend: backend, progress: progress, version: saved.version);

      final snapshot = await c.start(uid: saved.uid);
      expect(snapshot.run, GuideRun.blocked);
      expect(snapshot.step, GuideStep.editPreview);
      expect(snapshot.sessionId, saved.sessionId);
      expect(snapshot.createdEventId, saved.createdEventId);
      expect(snapshot.serverRevision, saved.serverRevision);
      expect(snapshot.expectedUpdatedStartLocal,
          saved.expectedUpdatedStartLocal);
      expect(GuideRouteRecovery.supports(snapshot), isFalse);
    });
  }

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
        backend: backend, progress: progress, version: realUiGuideVersion);
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
  for (final awaitingLoad in [true, false]) {
    final stage = awaitingLoad ? 'load' : 'begin';
    test('suspending a cold start during $stage cannot publish or save',
        () async {
      final entered = Completer<void>();
      final load = Completer<GuideSnapshot?>();
      final begin = Completer<GuideBackendState?>();
      final p = ColdProgress();
      final b = ColdBackend();
      if (awaitingLoad) {
        p.loader = (_) {
          entered.complete();
          return load.future;
        };
      } else {
        b.responder = (_) {
          entered.complete();
          return begin.future;
        };
      }
      final c = RealUiGuideCoordinator(backend: b, progress: p, version: 'v');
      final initial = c.state.value;
      final starting = c.start(uid: 'u');
      await entered.future;

      c.suspend(GuidePauseReason.interrupted);
      if (awaitingLoad) {
        load.complete(local(step: GuideStep.completed, run: GuideRun.terminal));
      } else {
        begin.complete(intro);
      }

      expect(await starting, same(initial));
      expect(c.state.value, same(initial));
      expect(b.begins, awaitingLoad ? 0 : 1);
      expect(p.saves, 0);
    });
  }

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
      expect(p.saves, saves + 1);
      expect(resumed.failureDiagnostic?.kind, GuideFailureKind.backendUnavailable);
    });
  }
}
