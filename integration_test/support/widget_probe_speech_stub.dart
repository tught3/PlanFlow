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
// counter only — the trace message is never stored or forwarded to
// anywhere outside the original `debugPrint` implementation, and the
// original implementation is restored on tear-down even if the test
// body throws.
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
    final WidgetProbeSpeechStubState? previous = _activeState;
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
    // Reference the previous state so the analyzer doesn't flag it
    // as unused — ownership semantics still require [remove] before
    // [install] is called again.
    assert(previous != _activeState || previous == null);
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
  /// message is NEVER stored or logged — only the counter
  /// [WidgetProbeSpeechStubState.startAttempt] is incremented on each
  /// matching emit. Every other [debugPrint] call (including the
  /// `[STT] phase=start` traces whose `attempt` key is anything other
  /// than `normal`, e.g. Android `warmup-retry`) is forwarded to the
  /// previously-captured implementation unchanged.
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
  /// was active. Must reach at least 1 for the post-start guard to
  /// pass. The full message text is never stored.
  int startAttempt = 0;

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
      };

  /// `true` only after the post-start guard has been observed: the
  /// iOS `warmUp` and the post-frame `_startVoiceFlow` must both
  /// have invoked `initialize` on the pinned channel AND at least
  /// one `[STT] phase=start` / `attempt=normal` trace must have
  /// been emitted. `warmUp`-only init cannot prove autoStart, so
  /// a warmUp-only run returns `false`.
  bool get postStartAvailability => startAttempt == 1 && initAfterStart >= 1;

  /// The previously-captured [debugPrint] implementation, restored
  /// by [WidgetProbeSpeechStub.removeDebugPrintCapture]. `null`
  /// while no capture is active.
  DebugPrintCallback? previousDebugPrint;
}
