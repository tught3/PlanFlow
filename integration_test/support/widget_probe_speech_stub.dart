// Shared QA helper that intercepts the pinned speech_to_text
// MethodChannel for iOS widget-launch routing native probes and the
// matching desktop unit test (`test/widget_probe_speech_stub_test.dart`).
//
// Pinned protocol (verified against pubspec.lock on 2026-10-12; archive
// SHA256 a1935847704e41ee468aad83181ddd2423d0833abe55d769c59afca07adb5114
// for speech_to_text_platform_interface 2.3.0 read entirely in memory
// from pub.dev/api/archives/speech_to_text_platform_interface-2.3.0.tar.gz):
//
//   * Channel: `plugin.csdcorp.com/speech_to_text`
//     (`speech_to_text_platform_interface-2.3.0/lib/method_channel_speech_to_text.dart:9`)
//   * Method `has_permission` returns `Future<bool>` (line 28).
//   * Method `initialize` returns `Future<bool>` (lines 32-40).
//   * Method `listen` returns the channel-invoked payload.
//
// The legacy regression fixture hardcoded
// `MethodChannel('cjcodezonye.github.io/speech_to_text')` and a
// `hasPermission` method name. Both values never intercepted the real
// plugin installed at the pinned channel, which is the concrete
// channel-identity bug this helper closes.
//
// Protocol invariants enforced by this helper:
//
//   1. The channel identity and method names are exposed as `public
//      const` strings so the integration_test fixture and the desktop
//      unit test assert against the same exact identity — the two
//      surfaces cannot drift apart.
//   2. `initialize` always returns `false` (SDK unavailable). The
//      production `SttService` therefore aborts the listen path
//      without ever calling `listen` on the channel.
//   3. `has_permission` returns the regression fixture's original bool
//      value verbatim (`true`). The permission policy is preserved, not
//      changed.
//   4. `listen` is forbidden: the helper increments its counter and
//      returns `null` without ever forwarding to a real engine, so no
//      native microphone recording can occur during QA.
//
// The integration_test fixture additionally installs a debugPrint
// capture that counts the public `[STT] phase=start` / `attempt=normal`
// trace emitted by `SttService._logPhase`. The capture increments a
// counter only — the trace message text is never stored beyond the
// regex-match (`attempt=normal`, `gen=N`) needed for per-attempt
// bookkeeping, and the original implementation is restored on
// tear-down even if the test body throws.
//
// Finite-2 bounded-retry policy (encoded 2026-10-12):
//
// The VoiceInputScreen autoStart path under pinned-channel-unavailable
// policy issues `_startVoiceFlow` exactly twice (gen=1 then gen=2)
// with a 650 ms screen-level delay between them, and the recursive
// `_startVoiceFlow()` call drops the `autoRetryOnEarlyFailure` flag
// (default `false`), so a third attempt is structurally impossible.
// This helper tracks each start ordinal / `_activeListenGeneration`
// independently and counts the `initialize` calls observed AFTER each
// start trace, so the leg-level claim is encoded as
// `postStartBoundedRetry` rather than a `startAttempt == 1` proxy or
// a total `initCount >= 2` proxy.
//
// Rejection getters expose the failure modes callers must NOT trigger:
//
//   * `excessRetry` — startAttempt > 2 (more than the bounded budget).
//   * `sameGenRepeated` — startAttempt > startOrdinalsSeen.length
//     (the same `_activeListenGeneration` was logged twice without a
//     new listen call, which is not how the screen advances the
//     counter).
//   * `missingPostCoverage` — any observed ordinal has no
//     `initialize` recorded after it (each listen attempt must do its
//     own `SpeechToText().initialize()` BEFORE the channel `listen`,
//     and the helper sees that initialize handler call after the
//     matching start trace).
//
// Public SDK characterization is preserved, not faked: the existing
// unit-test surface still drives the real
// `package:speech_to_text/speech_to_text.dart` `SpeechToText` API
// through this mock handler and observes the helper's RPC counters,
// never the SDK's private fields or a singleton reset.
//
// This helper is intentionally a small QA seam: it touches only the
// public `MethodChannel`/`debugPrint` seams, never any SDK private
// fields, listener singletons, or production flag reset APIs.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pinned protocol identity exposed as `public const` so both the
/// integration_test fixture and `test/widget_probe_speech_stub_test.dart`
/// assert against the same exact values. Renaming the helper's channel
/// or method name MUST update both call sites; the desktop unit test
/// fails if either value stops matching the pinned protocol.
class WidgetProbeSpeechStub {
  WidgetProbeSpeechStub();

  /// The pinned channel name lifted directly from
  /// `speech_to_text_platform_interface-2.3.0/lib/method_channel_speech_to_text.dart:9`.
  static const String pinnedChannelName = 'plugin.csdcorp.com/speech_to_text';

  /// Method name for the boolean `has_permission` invocation
  /// (line 28 of the pinned source). The regression fixture used
  /// `hasPermission`, which never matched.
  static const String pinnedHasPermissionMethod = 'has_permission';

  /// Method name for the boolean `initialize` invocation
  /// (lines 32-40 of the pinned source).
  static const String pinnedInitializeMethod = 'initialize';

  /// The exact `MethodChannel` both the fixture and the unit test
  /// register their mock handler on. Public so neither side can
  /// accidentally fall back to the legacy channel identity.
  static const MethodChannel speechChannel = MethodChannel(pinnedChannelName);

  /// The regression fixture answered `has_permission` with `true`
  /// (line 546 of the previous `widget_launch_routing_native_probe.dart`).
  /// Preserve that exact value verbatim so this helper does not
  /// change the permission policy.
  static const bool _kOriginalHasPermissionValue = true;

  WidgetProbeSpeechStubState? _activeState;

  /// Active state — exposed only so the fixture can introspect the
  /// most recent install without having to thread the return value
  /// through every helper method call.
  WidgetProbeSpeechStubState? get state => _activeState;

  /// Install a mock handler on the pinned `speechChannel`.
  ///
  /// Returns a fresh per-fixture [WidgetProbeSpeechStubState] whose
  /// counters start at zero. Throws if a previous install is still
  /// active on this helper instance — fixture ownership must be
  /// paired with [remove] before a second install is allowed.
  WidgetProbeSpeechStubState install() {
    if (_activeState != null) {
      throw StateError(
        'WidgetProbeSpeechStub.install called while another fixture '
        'is still installed. Call remove() first.',
      );
    }
    final WidgetProbeSpeechStubState state = WidgetProbeSpeechStubState();
    _activeState = state;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(speechChannel, (MethodCall call) async {
      state.calls.add(call);
      switch (call.method) {
        case pinnedInitializeMethod:
          state.initCount += 1;
          if (state.startAttempt == 0) {
            state.initBeforeStart += 1;
          } else {
            state.initAfterStart += 1;
            // Per-ordinal bookkeeping: each listen call's
            // `_listenWithSpeechToText` calls `SpeechToText().initialize`
            // AFTER the matching `[STT] phase=start gen=N ...`
            // trace, so each in-progress ordinal captures its own
            // initialize handler coverage here.
            final int? ordinal = state.currentStartOrdinal;
            if (ordinal != null && state.startOrdinalsSeen.contains(ordinal)) {
              state.initAfterStartByOrdinal[ordinal] =
                  (state.initAfterStartByOrdinal[ordinal] ?? 0) + 1;
            }
          }
          // Always unavailable: production listen path must abort
          // without ever issuing a real listen call.
          return false;
        case pinnedHasPermissionMethod:
          // Regression-original value preserved verbatim.
          return _kOriginalHasPermissionValue;
        case 'listen':
          // Forbidden: count and discard without forwarding.
          state.listenCount += 1;
          return null;
      }
      return null;
    });
    return state;
  }

  /// Remove the mock handler previously installed by [install]. Safe
  /// to call from a `try/finally` (or `addTearDown`) even if [install]
  /// was never invoked: no-op in that case.
  void remove() {
    if (_activeState == null) {
      return;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(speechChannel, null);
    _activeState = null;
  }

  /// Capture the public `[STT] phase=start` / `attempt=normal` trace
  /// emitted by `SttService._logPhase` via [debugPrint]. The trace
  /// message is NEVER stored or logged beyond the regex-match
  /// (`gen=(\d+)`) used to track the per-attempt ordinal; only the
  /// counter [WidgetProbeSpeechStubState.startAttempt] and the
  /// [WidgetProbeSpeechStubState.startOrdinalsSeen] set are
  /// incremented on each matching emit. Every other [debugPrint]
  /// call (including the `[STT] phase=start` traces whose `attempt`
  /// key is anything other than `normal`, e.g. Android
  /// `warmup-retry`) is forwarded to the previously-captured
  /// implementation unchanged.
  ///
  /// The capture must be installed BEFORE the warm voice route is
  /// submitted, so the post-start guard can be verified. The original
  /// [debugPrint] implementation is restored in [removeDebugPrintCapture],
  /// which MUST be reached even when the surrounding test fails — pair
  /// the two calls in an `addTearDown` or an outer `try/finally`.
  void installDebugPrintCapture(WidgetProbeSpeechStubState state) {
    if (state.previousDebugPrint != null) {
      throw StateError(
        'WidgetProbeSpeechStub debugPrint capture is already active.',
      );
    }
    state.previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null &&
          message.startsWith('[STT] phase=start ') &&
          RegExp(r'\battempt=normal(?:\s|$)').hasMatch(message)) {
        state.startAttempt += 1;
        // Extract the per-attempt ordinal from `gen=N` so the
        // finite-2 policy can distinguish distinct listen calls
        // (gen increments per `_listenWithSpeechToText` entry).
        final RegExpMatch? ordinalMatch =
            RegExp(r'\bgen=(\d+)').firstMatch(message);
        if (ordinalMatch != null) {
          final int ordinal = int.parse(ordinalMatch.group(1)!);
          if (state.startGenerationOrder.length < 20) {
            state.startGenerationOrder.add(ordinal);
            state.startOrdinalsSeen.add(ordinal);
          }
          state.currentStartOrdinal = ordinal;
        }
      }
      state.previousDebugPrint?.call(message, wrapWidth: wrapWidth);
    };
  }

  /// Restore the [debugPrint] implementation captured by
  /// [installDebugPrintCapture]. Safe to call even when no capture
  /// was ever installed: no-op in that case.
  void removeDebugPrintCapture(WidgetProbeSpeechStubState state) {
    final void Function(String? message, {int? wrapWidth})? previous =
        state.previousDebugPrint;
    state.previousDebugPrint = null;
    if (previous != null) {
      debugPrint = previous;
    }
  }
}

/// Per-fixture counter snapshot returned by
/// [WidgetProbeSpeechStub.install]. Counters are constructor-fresh
/// and must NOT be reset by callers. Each fixture owns its own state
/// instance.
class WidgetProbeSpeechStubState {
  /// All `MethodCall` payloads observed on the pinned channel,
  /// including the matched `initialize`, `has_permission`, and
  /// (forbidden) `listen` calls. Preserved so the regression
  /// fixture can still assert `calls.any((c) => c.method == ...)`
  /// against the same list it used before this helper existed.
  final List<MethodCall> calls = <MethodCall>[];

  /// Number of `initialize` calls observed on the pinned channel.
  /// Must reach at least 2 for the iOS autoStart guard to pass:
  /// `warmUp` (initState) + `_startVoiceFlow` (post-frame listen).
  int initCount = 0;

  /// Number of initialize calls observed before the start trace.
  int initBeforeStart = 0;

  /// Number of initialize calls observed after the start trace.
  int initAfterStart = 0;

  /// Number of `listen` calls observed on the pinned channel. Must
  /// remain exactly zero: with `initialize()` unavailable, the
  /// production listen path must abort without ever reaching the
  /// native listen API.
  int listenCount = 0;

  /// Number of public `[STT] phase=start` / `attempt=normal` traces
  /// observed while [WidgetProbeSpeechStub.installDebugPrintCapture]
  /// was active. Each entry corresponds to one
  /// `_listenWithSpeechToText` entry that logged `_logPhase('start',
  /// mode: mode)` BEFORE the matching `SpeechToText().initialize()`
  /// handler call.
  int startAttempt = 0;

  /// Distinct `_activeListenGeneration` ordinals observed in
  /// matching `[STT] phase=start` / `attempt=normal` traces. The
  /// bounded-retry policy requires exactly two distinct values
  /// (`{1, 2}`) and rejects any repetition of an already-seen
  /// ordinal, which the screen-only path cannot produce because
  /// `_listenSessionGeneration` is a strict monotonic local counter
  /// that mirrors `_activeListenGeneration` per
  /// `_listenWithSpeechToText` entry.
  final Set<int> startOrdinalsSeen = <int>{};

  /// Bounded observed generation order, not inferred from RPC totals.
  final List<int> startGenerationOrder = <int>[];

  /// Most-recent ordinal captured by
  /// [WidgetProbeSpeechStub.installDebugPrintCapture]. `null` while
  /// no matching trace has been observed yet. Used by [install]'s
  /// initialize handler to bucket post-trace `initialize` calls.
  int? currentStartOrdinal;

  /// Per-ordinal `initialize` coverage recorded AFTER the matching
  /// start trace. Each distinct ordinal observed in
  /// `startOrdinalsSeen` should be present with count >= 1; the
  /// `missingPostCoverage` getter exposes failure to honour this
  /// invariant.
  final Map<int, int> initAfterStartByOrdinal = <int, int>{};

  /// Capped non-secret receipt of counts, intended for the
  /// fixture's diagnostic `print` line after asserts. Mirrors the
  /// `_maxTraceEvents = 20` cap used by the regression fixture's
  /// `_QaTrace` so the diagnostic surface stays bounded.
  Map<String, int> receipt() => <String, int>{
        'init': initCount,
        'listen': listenCount,
        'start_attempt': startAttempt,
        'init_before_start': initBeforeStart,
        'init_after_start': initAfterStart,
        'start_ordinals': startOrdinalsSeen.length,
      };

  /// Capped non-secret receipt of counts INCLUDING the new
  /// per-ordinal bookkeeping. Intended for the bounded-retry
  /// diagnostic line; per-ordinal init coverage is exposed as a
  /// compact `gen=N:count` summary so the receipt never grows
  /// unbounded.
  Map<String, Object> receiptBounded() {
    final List<int> ordinals = startOrdinalsSeen.toList()..sort();
    final Map<int, int> coverage = <int, int>{
      for (final int ord in ordinals) ord: initAfterStartByOrdinal[ord] ?? 0,
    };
    return <String, Object>{
      'init': initCount,
      'listen': listenCount,
      'start_attempt': startAttempt,
      'init_before_start': initBeforeStart,
      'init_after_start': initAfterStart,
      'start_ordinals': ordinals,
      'init_after_by_ordinal': coverage,
      'excess_retry': excessRetry,
      'same_gen_repeated': sameGenRepeated,
      'missing_post_coverage': missingPostCoverage,
    };
  }

  /// Compatibility name for the same finite, per-attempt policy.
  /// It never accepts a loose at-least-one start or total-init proxy.
  bool get postStartAvailability => postStartBoundedRetry;

  /// Finite-2 bounded-retry guard. Returns `true` only when the
  /// pinned-channel unavailable leg has been characterized by
  ///
  ///   * exactly two public `[STT] phase=start` / `attempt=normal`
  ///     traces (the bounded-retry budget),
  ///   * the two traces came from two distinct
  ///     `_activeListenGeneration` ordinals (typically `1` and `2`),
  ///     ruling out a same-gen counter doubling,
  ///   * and each ordinal was followed by at least one `initialize`
  ///     handler call on the pinned channel (per-attempt
  ///     post-coverage, not a total `initCount >= 2` proxy).
  ///
  /// This getter is the canonical pass condition for the
  /// bounded-retry unavailable leg in the iOS native probe and in
  /// the desktop unit test. Pre-bound warmUp-only runs return
  /// `false` because `startAttempt` is below the bounded budget;
  /// any third attempt flips the guard back to `false`.
  bool get postStartBoundedRetry =>
      startAttempt == 2 &&
      startOrdinalsSeen.length == 2 &&
      startGenerationOrder.length == 2 &&
      startGenerationOrder[0] == 1 &&
      startGenerationOrder[1] == 2 &&
      initAfterStartByOrdinal[1] != null &&
      initAfterStartByOrdinal[1]! >= 1 &&
      initAfterStartByOrdinal[2] != null &&
      initAfterStartByOrdinal[2]! >= 1;

  /// `true` if more than two start traces were observed. The
  /// bounded-retry screen policy issues exactly two
  /// `_startVoiceFlow` calls under the unavailable result and cannot
  /// exceed the budget; a positive value here means a third attempt
  /// slipped through and the test must NOT report a green check.
  bool get excessRetry => startAttempt > 2;

  /// `true` if the number of matching traces exceeds the number of
  /// distinct ordinals. `_activeListenGeneration` is a strict
  /// monotonic counter advanced only at the entry of each
  /// `_listenWithSpeechToText`, so a positive value here means the
  /// same ordinal was logged twice (which can happen if a counter
  /// doubling were silently repaired instead of an actual second
  /// listen attempt).
  bool get sameGenRepeated => startAttempt > startOrdinalsSeen.length;

  /// `true` if any observed ordinal has no `initialize` handler
  /// coverage recorded after its start trace. Each
  /// `_listenWithSpeechToText` must issue `SpeechToText().initialize`
  /// AFTER logging the matching start trace; missing coverage for
  /// any ordinal means the per-attempt characterization is
  /// incomplete and the test must NOT report a green check.
  bool get missingPostCoverage {
    for (final int ord in startOrdinalsSeen) {
      final int? coverage = initAfterStartByOrdinal[ord];
      if (coverage == null || coverage < 1) {
        return true;
      }
    }
    return false;
  }

  /// The previously-captured [debugPrint] implementation, restored
  /// by [WidgetProbeSpeechStub.removeDebugPrintCapture]. `null`
  /// while no capture is active.
  DebugPrintCallback? previousDebugPrint;
}
