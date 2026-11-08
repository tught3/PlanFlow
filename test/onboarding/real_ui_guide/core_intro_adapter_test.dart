import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_guards.dart';

class FakeProgress implements GuideProgressStore {
  GuideSnapshot? value;
  Object? saveError;
  int saveCalls = 0;
  int loadCalls = 0;

  @override
  Future<GuideSnapshot?> load(
      {required String uid, required String version}) async {
    loadCalls++;
    return value?.uid == uid ? value : null;
  }

  @override
  Future<void> save(GuideSnapshot snapshot) async {
    saveCalls++;
    if (saveError != null) {
      throw saveError!;
    }
    value = snapshot;
  }
}

void main() {
  group('GuideAccountFeatureTourStore', () {
    test(
        'markCompleted records intro seen for active intro state without '
        'requiring terminal/ASR/backend session, then shouldShow returns false',
        () async {
      final progress = FakeProgress();
      progress.value = GuideSnapshot(
        uid: 'u',
        version: 'real_ui_v1',
        revision: 0,
        serverRevision: 0,
        step: GuideStep.intro,
        run: GuideRun.active,
      );
      final store = GuideAccountFeatureTourStore(
        uidProvider: () => 'u',
        progress: progress,
      );

      await store.markCompleted();
      final after = await store.shouldShow();

      expect(after, isFalse,
          reason: 'shouldShow must return false after intro is recorded');
      expect(progress.value?.step, GuideStep.homeMic,
          reason:
              'marker step must advance past intro without claiming terminal completion');
      expect(progress.value?.run, GuideRun.active,
          reason: 'marker must not be marked completed/skipped');
      expect(progress.value?.uid, 'u');
      expect(progress.value?.version, 'real_ui_v1');
    });

    test(
        'markCompleted works without any prior progress and writes a safe '
        'intro-only snapshot for the captured UID/version', () async {
      final progress = FakeProgress();
      final store = GuideAccountFeatureTourStore(
        uidProvider: () => 'fresh-user',
        progress: progress,
      );

      await store.markCompleted();

      expect(progress.value, isNotNull);
      expect(progress.value!.uid, 'fresh-user');
      expect(progress.value!.version, 'real_ui_v1');
      expect(progress.value!.step, GuideStep.homeMic);
      expect(progress.value!.run, GuideRun.active);
      expect(progress.value!.sessionId, isNull,
          reason: 'no backend session must be claimed');
      expect(progress.value!.serverRevision, 0);
      expect(progress.value!.errorCode, isNull);
      expect(await store.shouldShow(), isFalse);
    });

    test(
        'markCompleted preserves later real guide progress and leaves it '
        'untouched when the snapshot is already past intro', () async {
      final progress = FakeProgress();
      final laterStep = GuideStep.createSpeech;
      final existing = GuideSnapshot(
        uid: 'u',
        version: 'real_ui_v1',
        sessionId: 'session-1',
        revision: 7,
        serverRevision: 3,
        step: laterStep,
        run: GuideRun.active,
        createdEventId: 'evt-1',
        savedCreateOperationId: 'op-1',
        // banned-ok: Fixed event fixture for the guide assertion.
        originalStartLocal: DateTime(2026, 10, 20, 13),
        // banned-ok: Fixed event fixture for the guide assertion.
        savedLocalDate: DateTime(2026, 10, 20, 13),
        dateTimeZone: 'Asia/Seoul',
        calendarSyncHeld: true,
        mayListenContinuously: true,
      );
      progress.value = existing;
      final store = GuideAccountFeatureTourStore(
        uidProvider: () => 'u',
        progress: progress,
      );

      await store.markCompleted();

      expect(progress.value, equals(existing),
          reason:
              'later real guide progress must not be regressed or overwritten');
      expect(progress.value!.sessionId, 'session-1');
      expect(progress.value!.step, laterStep);
      expect(progress.value!.createdEventId, 'evt-1');
      expect(progress.value!.savedCreateOperationId, 'op-1');
      expect(progress.value!.calendarSyncHeld, isTrue);
      expect(progress.value!.mayListenContinuously, isTrue);
      expect(await store.shouldShow(), isFalse);
    });

    test(
        'UID switch during async load fails closed and never finishes the '
        'different UID', () async {
      final progress = FakeProgress();
      progress.value = GuideSnapshot(
        uid: 'u-a',
        version: 'real_ui_v1',
        revision: 0,
        serverRevision: 0,
        step: GuideStep.intro,
        run: GuideRun.active,
      );
      var uidForLoad = 'u-a';
      final store = GuideAccountFeatureTourStore(
        uidProvider: () {
          // Return the initial UID on the first call, then switch.
          final current = uidForLoad;
          uidForLoad = 'u-b';
          return current;
        },
        progress: progress,
      );

      await expectLater(store.markCompleted(), throwsA(isA<StateError>()));

      expect(progress.saveCalls, 0,
          reason: 'no save must occur when UID switches during async load');
      expect(progress.value?.step, GuideStep.intro,
          reason: 'previous UID snapshot must be untouched');
      expect(progress.value?.uid, 'u-a');
    });

    test(
        'UID switch during async save fails closed and never claims completion '
        'for a different UID', () async {
      final progress = FakeProgress();
      progress.value = GuideSnapshot(
        uid: 'u-a',
        version: 'real_ui_v1',
        revision: 0,
        serverRevision: 0,
        step: GuideStep.intro,
        run: GuideRun.active,
      );
      var uidCall = 0;
      final store = GuideAccountFeatureTourStore(
        uidProvider: () {
          uidCall++;
          // call 1: initial capture returns 'u-a'
          // call 2: post-load check still returns 'u-a'
          // call 3: post-save check returns 'u-b' (switched)
          if (uidCall >= 3) return 'u-b';
          return 'u-a';
        },
        progress: progress,
      );

      await expectLater(store.markCompleted(), throwsA(isA<StateError>()));

      // The save call may have happened with the right UID, but the operation
      // must surface the failure to the caller. The captured UID was 'u-a',
      // so no other UID should have been written.
      expect(progress.value?.uid, anyOf('u-a', isNull),
          reason:
              'a different UID must never be persisted as intro-seen by this adapter');
    });

    test(
        'persist failure does not complete intro and propagates the error to '
        'the caller', () async {
      final progress = FakeProgress()
        ..saveError = StateError('storage unavailable');
      progress.value = GuideSnapshot(
        uid: 'u',
        version: 'real_ui_v1',
        revision: 0,
        serverRevision: 0,
        step: GuideStep.intro,
        run: GuideRun.active,
      );
      final store = GuideAccountFeatureTourStore(
        uidProvider: () => 'u',
        progress: progress,
      );

      await expectLater(store.markCompleted(), throwsA(isA<StateError>()));

      // Readback must still report the intro as not seen because persistence
      // failed before completion could be recorded.
      expect(await store.shouldShow(), isTrue);
    });

    test('markCompleted fails closed when no authenticated UID is available',
        () async {
      final progress = FakeProgress();
      final store = GuideAccountFeatureTourStore(
        uidProvider: () => null,
        progress: progress,
      );

      await expectLater(store.markCompleted(), throwsA(isA<StateError>()));
      expect(progress.saveCalls, 0);
    });

    test('shouldShow returns true when UID is missing or empty (fail-closed)',
        () async {
      final progress = FakeProgress();
      final store = GuideAccountFeatureTourStore(
        uidProvider: () => '',
        progress: progress,
      );

      expect(await store.shouldShow(), isTrue);
      expect(progress.loadCalls, 0,
          reason: 'must not even read storage when auth is missing');
    });

    test(
        'shouldShow returns true when no progress is stored for the UID and '
        'false after the intro marker is recorded', () async {
      final progress = FakeProgress();
      final store = GuideAccountFeatureTourStore(
        uidProvider: () => 'u',
        progress: progress,
      );

      expect(await store.shouldShow(), isTrue);

      await store.markCompleted();
      expect(await store.shouldShow(), isFalse);
    });
  });
}
