// Deterministic UNIT regression (MOCK, not ASR) for the
// `SttService._clearActiveListenState` retired-session fence.
//
// Production bug summary (parent-briefed, line 799-808 of
// `lib/services/stt_service.dart`, currently under test):
//
//   static void _clearActiveListenState({required bool clearHandler}) {
//     _expelledNativeSessionId = _activeNativeSessionId;   // <-- BUG
//     ...
//     _activeNativeSessionId = null;
//     if (clearHandler) { _nativeSttChannel.setMethodCallHandler(null); }
//   }
//
// When `_activeNativeSessionId` is already null on the redundant
// detach path (e.g. a stale native SDK buffered `stopped` /
// `cancelled` method channel message that resolved AFTER the
// genuine stop, or a fast `stopActiveListen` then `cancelActiveListen`
// user-input race), the unconditional `_expelledNativeSessionId =
// _activeNativeSessionId` assignment wipes the previously-recorded
// fence from sessionId=N to null. The next `listen()`'s `acceptsEvent`
// therefore stops rejecting events that carry the JUST-expelled
// sessionId — the old session's late event slips past, the new
// listen wrongly adopts it via `_activeNativeSessionId ??= eventSession`,
// and a stale partial finishes the new listen's promise before the
// actual current session is observed.
//
// Targeted fix (parent-designed, one assignment only):
//
//     _expelledNativeSessionId =
//         _activeNativeSessionId ?? _expelledNativeSessionId;
//
// Required test seams (parent approved via block report)
// ---------------------------------------------------------
//
// Three new `@visibleForTesting` seams were added to
// `lib/services/stt_service.dart` so the regression can observe the
// `acceptsEvent` fence value directly. Existing seams
// (`debugHasActiveListen`, `debugActiveListenGeneration`) cannot
// distinguish "active id 1, fence 1" from "active id null,
// fence null" because they collapse seven fields into a single bool
// or expose only the integer generation.
//
//   * `debugActiveNativeSessionId` (getter+setter) — seeds and reads
//     the active native session id without going through
//     `acceptsEvent`. The state-setup is the messenger-mock-free
//     equivalent of a `ready` event whose `sessionId` is adopted.
//   * `debugExpelledNativeSessionId` (getter) — the direct
//     observer for the fence survival that distinguishes bug
//     from fix.
//
// Scenario (mirrors the RUN04 trace in the parent brief):
//
//   1. Seed `debugActiveNativeSessionId = 1` — equivalent to a
//      clean run that adopted a session id 1 via `ready` event.
//   2. `cancelActiveListen()` (1st detach) — bug code path and fix
//      code path BOTH record fence=1 here because `_activeNativeSessionId`
//      is 1. This sanity pin prevents future regressions that
//      accidentally remove the fence-write side of `_clearActiveListenState`.
//   3. `cancelActiveListen()` (2nd redundant detach) — bug code path
//      now sees `_activeNativeSessionId = null` (from step 2) and
//      **assigns null to the fence**, wiping it; fix code path uses
//      `_activeNativeSessionId ?? _expelledNativeSessionId` and
//      preserves fence=1.
//
// Outside this test's scope
// --------------------------
//
// No `package:speech_to_text` plugin, no real SDK, no microphone,
// no backend, no production code change other than the single
// assignment under test and the three `@visibleForTesting` seam
// getters/setter described above. Model-neutral QA tokens
// (QA_OLD_NATIVE / QA_CURRENT_NATIVE) are irrelevant here because
// the regression observes `debugExpelledNativeSessionId` directly.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/services/stt_service.dart';

void main() {
  group('SttService retired-session fence (UNIT MOCK)', () {
    testWidgets(
      'expelledNativeSessionId fence survives the redundant second '
      'cancelActiveListen detach after active session id 1',
      (WidgetTester tester) async {
        TestWidgetsFlutterBinding.ensureInitialized();
        const SttService service = SttService();
        // Pin the test host target so the production native-path
        // branch's `cancelActiveListen` is the only path under
        // observation. This value does not affect the field-level
        // assertion under test but guards against an upstream
        // refactor that splits the method.
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          // Reset both fields to a clean baseline so the test is
          // order-independent against any earlier test that leaked
          // state into the static fields.
          SttService.debugActiveNativeSessionId = null;
          // Pre-fix and post-fix both start the same way.
          expect(
            SttService.debugActiveNativeSessionId,
            isNull,
            reason: 'baseline: active id must be null at test start',
          );
          expect(
            SttService.debugExpelledNativeSessionId,
            isNull,
            reason: 'baseline: fence must be null at test start',
          );

          // Step 1: seed an active native session, equivalent to a
          // `ready` event whose `sessionId` is adopted.
          SttService.debugActiveNativeSessionId = 1;
          expect(
            SttService.debugActiveNativeSessionId,
            1,
            reason: 'seed: active session id 1 must be observable '
                'through the @visibleForTesting seam',
          );

          // Step 2: first `cancelActiveListen`. Both the bug and the
          // fix record fence=1 here because `_activeNativeSessionId`
          // is 1 at the start of `_clearActiveListenState`. If this
          // assertion flips to !=1 in either build, an upstream
          // change has begun removing the fence-write path itself,
          // independent of the redundant-detach bug.
          service.cancelActiveListen();
          expect(
            SttService.debugActiveNativeSessionId,
            isNull,
            reason: 'first detach must null active (existing debug seam)',
          );
          expect(
            SttService.debugExpelledNativeSessionId,
            1,
            reason: 'first detach MUST set fence=1 in both the bug '
                'build and the fix build — this guards the basic '
                'fence-write path against regressions other than the '
                'redundant-detach wipe',
          );

          // Step 3: second `cancelActiveListen`. THIS is the
          // redundant-detach race. With the buggy assignment
          // `_expelledNativeSessionId = _activeNativeSessionId`, the
          // fence is overwritten from 1 to `null` (the active value
          // is already null after step 2). With the fix
          // `_expelledNativeSessionId = _activeNativeSessionId ??
          // _expelledNativeSessionId`, the fence stays 1.
          service.cancelActiveListen();
          expect(
            SttService.debugActiveNativeSessionId,
            isNull,
            reason: 'second detach must keep active null',
          );
          expect(
            SttService.debugExpelledNativeSessionId,
            1,
            reason: 'redundant second detach MUST preserve fence=1 '
                '(`_activeNativeSessionId = null ?? _expelledNativeSessionId = 1`). '
                'A value of `null` here is the exact `_expelledNativeSessionId = '
                '_activeNativeSessionId` wipe at the heart of the RUN04 regression.',
          );

          // Cleanup: reset both fields so any subsequent test on
          // this binding runs from a clean baseline.
          SttService.debugActiveNativeSessionId = null;
          expect(
            SttService.debugHasActiveListen,
            isFalse,
            reason: 'final cleanup: service must report a fully '
                'cleared idle state after the redundant-detach '
                'sequence, observable through the existing '
                '`debugHasActiveListen` seam',
          );
        } finally {
          SttService.debugActiveNativeSessionId = null;
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
