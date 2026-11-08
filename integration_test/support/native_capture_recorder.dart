// Test-only transparent recorder wrapping `SttServiceVoiceCapture()`.
//
// The probe must verify each stage against the REAL final `VoiceCaptureResult`
// delivered by the engine, not against the UI caption. `applyFinalTranscript`
// intentionally clears `_caption = null` after every final transcript, which
// makes the `voice-tour-transcript` box fall back to the localized
// placeholder ("인식된 문장이 여기에 보여요" / "Recognized speech appears here").
// Reading that box after apply proves nothing about ASR. So we record the
// EXACT result the engine delivered before the screen can drop it.
//
// Discipline (all enforced below):
//  - The delegate is the unchanged `SttServiceVoiceCapture()` constructed
//    lazily. No mock, no seed text, no expected-transcript injection.
//  - `listen` is captured at call time as an immutable local `stage`, so
//    even if the harness mutates `currentStage` mid-listen the recorded
//    result is keyed to the stage active when the listen was issued.
//  - The result is stored in `_results[stage]` BEFORE the future returns to
//    the screen. The screen never gets a chance to clear it.
//  - `stop`, `cancel`, `isListening`, `onPartial`, and `onReady` pass
//    straight through. We never decorate a callback with our own logic.
//  - The recorder never fabricates success. If the engine returned a
//    failure/empty result, the recorder stores it verbatim; the probe is
//    the only place that decides whether a non-empty final is required.
//
// Scope: integration_test only. Not used by unit tests except the focused
// regression under `test/native_capture_recorder_test.dart`. Production
// code paths (lib/, android/, ios/, pubspec.*) never reference this.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:planflow/screens/onboarding/voice_first_tour_voice_capture.dart';

class NativeCaptureRecorder implements VoiceCapture {
  NativeCaptureRecorder();

  // Lazy to mirror `SttServiceVoiceCapture`'s own construction rule: the
  // microphone is never warmed up at this seam, and tests that never tap
  // the mic must not pay the cost of constructing the engine.
  VoiceCapture? _delegate;
  VoiceCapture get _capture {
    return _delegate ??= SttServiceVoiceCapture();
  }

  /// Stage name keyed against the listen currently being issued by the
  /// screen. The probe sets this immediately before tapping the mic button,
  /// so `listen()` can capture it as the immutable local stage for this
  /// call.
  String currentStage = '';

  /// Per-stage real final results, keyed by stage name. Populated before
  /// `listen` resolves to the screen, so `_applyFinalTranscript` cannot
  /// erase the evidence. The probe uses these for ALL stage-by-stage
  /// transcript assertions instead of reading the UI caption.
  final Map<String, VoiceCaptureResult> _results =
      <String, VoiceCaptureResult>{};
  Map<String, VoiceCaptureResult> get results =>
      Map<String, VoiceCaptureResult>.unmodifiable(_results);

  /// Per-stage ordered list of every recorded result. Late-final leakage
  /// from a prior stage would show up as extra entries here; the focused
  /// regression enforces one entry per stage.
  final Map<String, List<VoiceCaptureResult>> _resultHistory =
      <String, List<VoiceCaptureResult>>{};

  /// In-flight listen handle so the probe can correlate the stage captured
  /// by `listen` with the result delivered by the engine.
  String? _activeStage;

  /// Test-only escape hatch: lets the focused unit regression swap the
  /// real `SttServiceVoiceCapture()` for a controllable mock without ever
  /// reaching for `package:flutter_test`. The integration probe never
  /// calls this; it always uses the lazy real delegate.
  @visibleForTesting
  void debugSetDelegate(VoiceCapture capture) {
    _delegate = capture;
  }

  @override
  bool get isListening => _capture.isListening;

  @override
  Future<VoiceCaptureResult> listen({
    required ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  }) {
    final stage = currentStage;
    _activeStage = stage;
    // Pass-through: the recorder never decorates the screen's callbacks.
    return _capture.listen(onPartial: onPartial, onReady: onReady).then(
        (result) {
      // Save the EXACT actual result keyed to the immutable stage captured
      // at listen() time. Any later mutation of `_currentStage` cannot
      // re-key this entry.
      _results[stage] = result;
      _resultHistory
          .putIfAbsent(stage, () => <VoiceCaptureResult>[])
          .add(result);
      _activeStage = null;
      return result;
    }, onError: (Object e, StackTrace s) {
      _activeStage = null;
      // Never fabricate a success: rethrow so the screen sees the same
      // engine failure the user would have seen.
      throw e;
    });
  }

  @override
  Future<void> stop() => _capture.stop();

  @override
  Future<void> cancel() => _capture.cancel();

  /// Releases the underlying adapter. Probe owns this because injection
  /// flips `FeatureTourScreen._ownsCapture` to false, so the screen will
  /// not call `dispose()` on the recorder.
  Future<void> disposeRecorder() async {
    final delegate = _delegate;
    _delegate = null;
    if (delegate is SttServiceVoiceCapture) {
      delegate.dispose();
    }
  }

  @visibleForTesting
  Map<String, List<VoiceCaptureResult>> debugResultHistory() =>
      Map<String, List<VoiceCaptureResult>>.unmodifiable(
        _resultHistory.map(
          (k, v) => MapEntry(k, List<VoiceCaptureResult>.unmodifiable(v)),
        ),
      );

  @visibleForTesting
  String? debugActiveStage() => _activeStage;
}

/// Requires that the recorder holds a REAL ASR final for [stage]: a non-null
/// entry, `isSuccess`, non-empty text, and text that is NOT the localized
/// caption placeholder. [forbiddenPlaceholderHint] must be the REAL localized
/// `AppLocalizations.voiceTourTranscriptHint` resolved from a
/// `FeatureTourScreen`-descendant element (MaterialApp sits above the
/// Localizations scope and null-throws). The hint is used ONLY as a forbidden
/// comparison; it is never injected as input, expected text, or result. Both
/// sides are trimmed before comparing so whitespace drift cannot smuggle the
/// placeholder through as a transcript.
void requireRecordedResult(
  VoiceCaptureResult? recorded,
  String stage, {
  required String forbiddenPlaceholderHint,
}) {
  if (recorded == null) {
    throw StateError(
      'No actual ASR result recorded for $stage; engine never resolved.',
    );
  }
  if (!recorded.isSuccess ||
      recorded.text == null ||
      recorded.text!.trim().isEmpty) {
    throw StateError(
      'Recorded ASR for $stage is not a success. '
      'silence=${recorded.silence} denied=${recorded.deniedPermission} '
      'unsupported=${recorded.unsupportedLocale} unavailable=${recorded.unavailable} '
      'message=${recorded.message} text=${recorded.text}',
    );
  }
  final actualText = recorded.text!.trim();
  final forbidden = forbiddenPlaceholderHint.trim();
  if (forbidden.isNotEmpty && actualText == forbidden) {
    throw StateError(
      'Recorded ASR final for $stage equals the localized caption placeholder '
      'instead of a real transcript. text="$actualText"',
    );
  }
}
