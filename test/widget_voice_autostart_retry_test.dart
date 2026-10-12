// Bounded-retry DI widget test for VoiceInputScreen autoStart policy.
//
// What this test proves (NOT just strings):
//
//   * The real production `VoiceInputScreen` widget, fed via its
//     existing public `SttService` constructor DI seam (`sttService:`),
//     issues at most two `_startVoiceFlow` calls when the injected
//     fake engine returns `SttListenFailure.unavailable` and the
//     `autoStartOverride: true` flag is on. The first attempt fires
//     after the 600 ms initial delay, the second after the 650 ms
//     screen-level retry delay, and the structural `autoRetryOnEarlyFailure`
//     default on the recursive `_startVoiceFlow()` call (no flag
//     argument passed → defaults to `false`) prevents a third
//     attempt.
//   * `SttListenFailure.permissionDenied` produces exactly one listen
//     attempt: the screen's `_shouldRetryAutoStartedListen` predicate
//     only matches `silence` or `unavailable`, so a permission-denied
//     terminal failure is never reclassified as retriable and never
//     retries.
//   * `autoStartOverride: false` produces no listen attempt at all:
//     only the `unawaited(widget.sttService.warmUp())` from initState
//     fires, and the post-frame `_maybeAutoStartVoiceInput` short-circuits
//     on `_didResolveAutoStart = true` without observing `_isListening`.
//
// All counts are observed through the existing public
// `package:planflow/services/stt_service.dart` `SttService` API
// surface (`warmUp`, `listen`, `cancelActiveListen`, `stopActiveListen`)
// and are tracked IN MEMORY only — no SDK method is forwarded, no
// pinned `plugin.csdcorp.com/speech_to_text` channel is touched, no
// permission is requested, no microphone is engaged, no backend is
// reached.
//
// What this test does NOT do:
//
//   * No production source change (no edits to `lib/screens/voice/*`,
//     `lib/services/stt_service.dart`, the router, the auth provider,
//     the feature tour service, the localization service, or any
//     dependency in `pubspec.yaml`).
//   * No new SDK initialization (no real `SpeechToText()` plugin
//     install; no `Supabase` instance; no `SharedPreferences` mock;
//     the production `tryGetPrefs()` graceful-null path is sufficient
//     for the in-test feature tour tip lookup to return false).
//   * No native run, CI action, store, or Android backend.
//
// Isolation contract:
//
//   * Each test owns its `BoundedFakeSttService` instance and restores
//     its widget via explicit unmount (no cross-test fake future leak).
//   * The fake engine's `warmUp`, `listen`, `cancelActiveListen`,
//     and `stopActiveListen` are memory-only paths that never invoke
//     the SDK private fields or reset any singleton.
//   * `completeFailure(...)` releases exactly one pending listen
//     future. Any extra completions are no-ops so a screen retry
//     cannot accidentally resolve the previous attempt's future.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/screens/voice/voice_input_screen.dart';
import 'package:planflow/services/stt_service.dart';

/// Fake `SttService` whose hot path tracks every public method call
/// in memory. No SDK interaction: `warmUp()`, `listen()`,
/// `cancelActiveListen()`, and `stopActiveListen()` never issue any
/// channel call. The `listen()` future returns a pending `Completer`
/// that the test releases by calling [completeCurrentListen] with the
/// desired `SttListenFailure` (or `completeCurrentListenSuccess` for
/// a success result).
class _BoundedFakeSttService implements SttService {
  int warmUpCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;

  Completer<SttListenResult>? _activeCompleter;

  @override
  Future<void> warmUp() async {
    warmUpCalls += 1;
  }

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) async {
    listenCalls += 1;
    _activeCompleter = Completer<SttListenResult>();
    return _activeCompleter!.future;
  }

  /// Release the currently pending `listen()` future with the
  /// requested `SttListenFailure`. A second call without a fresh
  /// `listen()` future is a no-op (the previous completer was already
  /// completed), which lets the test drive a retry whose previous
  /// attempt's future cannot accidentally be re-resolved.
  void completeCurrentListen({
    required SttListenFailure failure,
    String message = 'QA bounded-retry fake',
  }) {
    final Completer<SttListenResult>? completer = _activeCompleter;
    _activeCompleter = null;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(
      SttListenResult.failure(
        failure: failure,
        message: message,
      ),
    );
  }

  /// Release the currently pending `listen()` future with a success
  /// result (unused in the bounded-retry cases but kept for
  /// completeness).
  void completeCurrentListenSuccess(String text) {
    final Completer<SttListenResult>? completer = _activeCompleter;
    _activeCompleter = null;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(SttListenResult.success(text));
  }

  @override
  Future<void> cancelActiveListen() async {
    cancelCalls += 1;
    final Completer<SttListenResult>? completer = _activeCompleter;
    _activeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        SttListenResult.failure(
          failure: SttListenFailure.unavailable,
          message: 'cancelled by fake engine',
        ),
      );
    }
  }

  @override
  Future<void> stopActiveListen() async {
    stopCalls += 1;
    final Completer<SttListenResult>? completer = _activeCompleter;
    _activeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        SttListenResult.failure(
          failure: SttListenFailure.unavailable,
          message: 'stopped by fake engine',
        ),
      );
    }
  }

  @override
  Future<String> clearActiveTranscript() async => '';

  @override
  Future<String> undoLastSpeechSegment() async => '';

  @override
  Future<String> undoLastSpeechWord() async => '';

  /// No-op dispose: no listeners or sdk engine to release in the
  /// fake; tracked only so the test can assert cleanup happened if
  /// the production widget invokes it (production doesn't, but
  /// symmetry makes the contract clear).
  void disposeFake() {
    disposeCalls += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceInputScreen autoStart bounded-retry policy (DI)', () {
    testWidgets(
      'autoStart=true+unavailable: first listen after 600ms, retry after 650ms; '
      'no third attempt after another 650ms',
      (WidgetTester tester) async {
        final _BoundedFakeSttService fakeStt = _BoundedFakeSttService();

        await tester.pumpWidget(
          MaterialApp(
            home: VoiceInputScreen(
              autoStartOverride: true,
              sttService: fakeStt,
            ),
          ),
        );

        // warmUp fires from initState (unawaited future). Confirm
        // that warmUp was called exactly once, then advance the
        // binding clock through the 600 ms initial autoStart delay.
        await tester.pump();
        expect(
          fakeStt.warmUpCalls,
          1,
          reason: 'initState must invoke warmUp exactly once',
        );
        expect(
          fakeStt.listenCalls,
          0,
          reason: 'no listen should fire before the 600 ms initial delay '
              'elapses',
        );

        // Advance just under the 600 ms threshold: still zero listens.
        await tester.pump(const Duration(milliseconds: 590));
        expect(
          fakeStt.listenCalls,
          0,
          reason: 'still under the 600 ms threshold; autoStart listen must '
              'not have fired',
        );

        // Cross the 600 ms threshold: first listen fires exactly once.
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          fakeStt.listenCalls,
          1,
          reason: 'autoStart must have driven exactly one listen attempt '
              'through the screen code',
        );

        // Resolve the first listen with `unavailable`. The screen's
        // `_shouldRetryAutoStartedListen` predicate matches
        // `unavailable` and `autoRetryOnEarlyFailure` was true
        // (autoStartOverride == true), so the retry branch should
        // clear `_isListening`, sleep 650 ms, then call
        // `_startVoiceFlow()` again with the default
        // `autoRetryOnEarlyFailure = false`.
        fakeStt.completeCurrentListen(
          failure: SttListenFailure.unavailable,
        );
        await tester.pump();
        expect(
          fakeStt.listenCalls,
          1,
          reason: 'immediate pump only releases the future; the retry '
              'waits 650 ms',
        );

        // Advance just under the 650 ms retry threshold.
        await tester.pump(const Duration(milliseconds: 640));
        expect(
          fakeStt.listenCalls,
          1,
          reason: 'still under the 650 ms retry interval; the second '
              'listen has not fired yet',
        );

        // Cross the 650 ms retry threshold: second listen fires.
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          fakeStt.listenCalls,
          2,
          reason: 'bounded-retry policy must have driven exactly one '
              'retry through the screen code (total: 2 listen calls '
              'for the single autoStart request)',
        );

        // Resolve the second listen with `unavailable` again. The
        // recursive `_startVoiceFlow()` was called WITHOUT the
        // autoRetryOnEarlyFailure argument, so the default `false`
        // value prevents another recursion: this is the structural
        // cap that proves the bounded-retry budget.
        fakeStt.completeCurrentListen(
          failure: SttListenFailure.unavailable,
        );
        await tester.pump();

        // Pump another 650 ms (the same retry interval). The
        // recursive call's `autoRetryOnEarlyFailure = false` means
        // the `_shouldRetryAutoStartedListen` branch will not fire
        // again. No third attempt may occur.
        await tester.pump(const Duration(milliseconds: 650));
        expect(
          fakeStt.listenCalls,
          2,
          reason: 'no third listen attempt may fire: the recursive '
              '_startVoiceFlow() call dropped the autoRetryOnEarlyFailure '
              'flag (default false), so the retry branch cannot recurse '
              'again under the screen-only path',
        );

        // Drain the pump window fully to confirm the bounded-retry
        // budget holds across the entire 650 ms interval window.
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          fakeStt.listenCalls,
          2,
          reason: 'draining the pump window beyond the 650 ms retry '
              'interval still shows exactly two listens — the bounded '
              'budget is structurally enforced',
        );

        // Capped non-secret diagnostic receipt before the final
        // asserts, mirroring the integration probe's
        // WIDGET_SPEECH_PROBE_RECEIPT_BOUNDED contract: this line
        // is diagnostic only and never serves as a pass criterion.
        // ignore: avoid_print
        print('WIDGET_BOUNDED_RETRY_RECEIPT warmUpCalls=${fakeStt.warmUpCalls} '
            'listenCalls=${fakeStt.listenCalls} '
            'stopCalls=${fakeStt.stopCalls} '
            'cancelCalls=${fakeStt.cancelCalls} '
            'autoStartOverride=true expected_listen=2 '
            'observed_listen=${fakeStt.listenCalls} '
            'no_third_attempt=true');

        expect(find.byType(VoiceInputScreen), findsOneWidget,
            reason: 'the real VoiceInputScreen must remain mounted through '
                'the bounded-retry leg');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(fakeStt.cancelCalls, 1, reason: 'unmount owns fake cleanup');
        expect(fakeStt._activeCompleter, isNull);
        expect(tester.takeException(), isNull);
        fakeStt.disposeFake();
      },
    );

    testWidgets(
      'autoStart=true+permissionDenied: exactly one listen, no retry storm',
      (WidgetTester tester) async {
        final _BoundedFakeSttService fakeStt = _BoundedFakeSttService();

        await tester.pumpWidget(
          MaterialApp(
            home: VoiceInputScreen(
              autoStartOverride: true,
              sttService: fakeStt,
            ),
          ),
        );

        await tester.pump();
        expect(fakeStt.warmUpCalls, 1);
        expect(fakeStt.listenCalls, 0);

        // Cross the 600 ms initial delay: exactly one listen.
        await tester.pump(const Duration(milliseconds: 610));
        expect(
          fakeStt.listenCalls,
          1,
          reason: 'autoStart must have driven exactly one listen attempt',
        );

        // Resolve with `permissionDenied`. The screen's
        // `_shouldRetryAutoStartedListen` predicate matches only
        // `silence` and `unavailable`, so permissionDenied must NOT
        // be reclassified as retriable.
        fakeStt.completeCurrentListen(
          failure: SttListenFailure.permissionDenied,
          message: 'native microphone denied',
        );
        await tester.pump();

        // Pump through the 650 ms retry window. Even though
        // `autoRetryOnEarlyFailure == true`, the predicate rejects
        // permissionDenied, so the retry branch must NOT fire.
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          fakeStt.listenCalls,
          1,
          reason: 'permissionDenied is not eligible for the bounded retry '
              '(only silence / unavailable are). No second listen may '
              'fire even after the 650 ms retry interval',
        );

        // Drain the pump window fully: still exactly one listen.
        await tester.pump(const Duration(seconds: 1));
        expect(
          fakeStt.listenCalls,
          1,
          reason: 'draining the pump window beyond the 650 ms retry '
              'interval still shows exactly one listen — '
              'permissionDenied is structurally non-retriable',
        );

        // ignore: avoid_print
        print('WIDGET_BOUNDED_RETRY_RECEIPT warmUpCalls=${fakeStt.warmUpCalls} '
            'listenCalls=${fakeStt.listenCalls} '
            'stopCalls=${fakeStt.stopCalls} '
            'cancelCalls=${fakeStt.cancelCalls} '
            'autoStartOverride=true expected_listen=1 '
            'observed_listen=${fakeStt.listenCalls} '
            'no_third_attempt=true permission_denied_single_attempt=true');

        expect(find.byType(VoiceInputScreen), findsOneWidget,
            reason: 'the real VoiceInputScreen must remain mounted through '
                'the permission-denied terminal failure');
        expect(tester.takeException(), isNull,
            reason: 'the bounded-retry DI leg must complete without UI '
                'exceptions');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(fakeStt.cancelCalls, 1, reason: 'unmount owns fake cleanup');
        expect(fakeStt._activeCompleter, isNull);
        expect(tester.takeException(), isNull);
        fakeStt.disposeFake();
      },
    );

    testWidgets(
      'autoStart=false: warmUp only; no listen attempt fires',
      (WidgetTester tester) async {
        final _BoundedFakeSttService fakeStt = _BoundedFakeSttService();

        await tester.pumpWidget(
          MaterialApp(
            home: VoiceInputScreen(
              autoStartOverride: false,
              sttService: fakeStt,
            ),
          ),
        );

        await tester.pump();
        expect(
          fakeStt.warmUpCalls,
          1,
          reason: 'initState must invoke warmUp exactly once regardless of '
              'the autoStartOverride value',
        );
        expect(
          fakeStt.listenCalls,
          0,
          reason: 'autoStartOverride=false must not trigger any autoStart '
              'listen attempt',
        );

        // Pump through the full 600 ms initial-delay window: still
        // no listen. The screen sets `_didResolveAutoStart = true`
        // in post-frame and short-circuits when
        // `shouldAutoStart` is false.
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          fakeStt.listenCalls,
          0,
          reason: 'no listen may fire when autoStartOverride is false, '
              'regardless of how long the pump runs',
        );

        // Drain the pump window fully: still zero listens.
        await tester.pump(const Duration(seconds: 2));
        expect(
          fakeStt.listenCalls,
          0,
          reason: 'no listen may fire for the lifetime of the widget when '
              'autoStartOverride is false — even after a 2.7 s drain',
        );

        // ignore: avoid_print
        print('WIDGET_BOUNDED_RETRY_RECEIPT warmUpCalls=${fakeStt.warmUpCalls} '
            'listenCalls=${fakeStt.listenCalls} '
            'stopCalls=${fakeStt.stopCalls} '
            'cancelCalls=${fakeStt.cancelCalls} '
            'autoStartOverride=false expected_listen=0 '
            'observed_listen=${fakeStt.listenCalls} '
            'no_third_attempt=true warmUp_only=true');

        expect(find.byType(VoiceInputScreen), findsOneWidget,
            reason: 'the real VoiceInputScreen must remain mounted even '
                'when autoStartOverride is false');
        expect(tester.takeException(), isNull,
            reason: 'the warmUp-only leg must complete without UI '
                'exceptions');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(fakeStt.cancelCalls, 1, reason: 'unmount owns fake cleanup');
        expect(fakeStt._activeCompleter, isNull);
        expect(tester.takeException(), isNull);
        fakeStt.disposeFake();
      },
    );

    testWidgets(
      'permissionDenied remains terminal across two retry windows',
      (WidgetTester tester) async {
        // Drives a single autoStart request where the FIRST listen
        // returns permissionDenied terminal failure. This is the
        // existing DI leg pattern (see LEG 3b in
        // `widget_launch_routing_native_probe.dart`); it must
        // observe exactly one listen attempt and prove that
        // `permissionDenied` blocks the 650 ms retry window.
        final _BoundedFakeSttService fakeStt = _BoundedFakeSttService();

        await tester.pumpWidget(
          MaterialApp(
            home: VoiceInputScreen(
              autoStartOverride: true,
              sttService: fakeStt,
            ),
          ),
        );

        await tester.pump();
        expect(fakeStt.warmUpCalls, 1);
        expect(fakeStt.listenCalls, 0);

        await tester.pump(const Duration(milliseconds: 610));
        expect(fakeStt.listenCalls, 1);

        fakeStt.completeCurrentListen(
          failure: SttListenFailure.permissionDenied,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          fakeStt.listenCalls,
          1,
          reason: 'even when the post-frame retry window is pumped twice '
              'in succession (the 650 ms screen retry interval and a '
              'subsequent interval), permissionDenied must not trigger '
              'another listen attempt',
        );

        expect(find.byType(VoiceInputScreen), findsOneWidget,
            reason: 'the real VoiceInputScreen must remain mounted');

        // Capped non-secret receipt: minimal counter summary to
        // mirror the integration probe's
        // `WIDGET_SPEECH_PROBE_RECEIPT_BOUNDED` contract.
        // ignore: avoid_print
        print('WIDGET_BOUNDED_RETRY_RECEIPT warmUpCalls=${fakeStt.warmUpCalls} '
            'listenCalls=${fakeStt.listenCalls} '
            'stopCalls=${fakeStt.stopCalls} '
            'cancelCalls=${fakeStt.cancelCalls} '
            'autoStartOverride=true expected_listen=1 '
            'observed_listen=${fakeStt.listenCalls} '
            'permission_denied_no_retry=true');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(fakeStt.cancelCalls, 1, reason: 'unmount owns fake cleanup');
        expect(fakeStt._activeCompleter, isNull);
        expect(tester.takeException(), isNull);
        fakeStt.disposeFake();
      },
    );
  });
}
