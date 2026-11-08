// Tour-only voice capture seam and its production adapter.
//
// The adapter wraps the EXISTING `SttService` unchanged: it never edits
// engine behavior, never warms up or asks permission at construction, and
// only starts the microphone lazily inside `listen`. Unit tests inject a
// fake `SttService` so host tests run without the native plugin.
//
// SIMULATED-input note: tests drive this seam with typed fake transcripts,
// never acoustic ASR output.
//
// Lifecycle safety rules enforced here (verified by focused tests):
//  1. `cancel` resolves the active listen future SYNCHRONOUSLY before any
//     native await, so a `listen` started during native cleanup can never
//     be completed with the old cancel's result.
//  2. Every native ack (`stopActiveListen` / `cancelActiveListen`) is
//     BOUNDED: a hung engine call can never wedge `stop`/`cancel` or leave
//     the listen future pending forever.
//  3. A new native listen is SERIALIZED behind an outstanding stop/cancel
//     ack, because `SttService` mutates GLOBAL active state inside those
//     methods (verified source fact). If an ack never returns, new listens
//     fail safely until the cleanup finally settles.
//  4. Partials/finals die with their session (generation + completer
//     identity + completed checks), so no late callback reaches the UI
//     after a terminal state.
//  5. `isListening` reports the ENGINE-ready truth (`SttNativeStatus.ready`
//     via `listen(onStatus:)`), not "a listen was requested", so the UI
//     can show a preparing state while permission/startup settle.
//  6. Failure flags map to fixed safe messages; raw engine messages never
//     reach the UI.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/stt_service.dart';

/// Plain-data outcome of one capture session. No `SttService` types leak
/// past this file, so the controller and tests stay plugin-free.
@immutable
class VoiceCaptureResult {
  const VoiceCaptureResult({
    this.text,
    this.deniedPermission = false,
    this.unsupportedLocale = false,
    this.silence = false,
    this.unavailable = false,
    this.message,
  });

  /// Final transcript, or null on any failure.
  final String? text;

  /// OS denied microphone permission.
  final bool deniedPermission;

  /// STT engine does not support the locale.
  final bool unsupportedLocale;

  /// No usable speech (silence / user cancelled / stopped with no text).
  final bool silence;

  /// Engine unavailable on this platform / build, or listen threw.
  final bool unavailable;

  /// Safe, user-facing status. Never contains raw platform errors.
  final String? message;

  bool get isSuccess => text != null && text!.trim().isNotEmpty;
}

/// Seam the tutorial screen binds to. Implementations MUST:
///  - initialize the engine lazily inside [listen] (never in a constructor),
///  - surface partials for display only via [onPartial],
///  - resolve the [listen] future exactly once with the FINAL outcome,
///  - suppress late partials/finals after cancel/restart/dispose,
///  - never stop/cancel a listen owned by someone else.
///
/// [onReady] is an optional readiness signal: implementations call it with
/// `true` when the engine reports it is actually listening (permission and
/// startup finished). It is never called with `false`; session end is
/// observable through the [listen] future resolving.
abstract class VoiceCapture {
  /// Whether the engine is REALLY listening (ready), not merely asked to.
  bool get isListening;

  Future<VoiceCaptureResult> listen({
    required ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  });

  /// Finalizes the active session. The finalized transcript (if any)
  /// arrives through the already-returned [listen] future.
  Future<void> stop();

  /// Cancels the active session. The [listen] future resolves with a
  /// non-success result immediately (before any native cleanup completes);
  /// stale text is rejected.
  Future<void> cancel();
}

/// Production adapter over the existing `SttService` (instance APIs:
/// listen / stopActiveListen / cancelActiveListen).
class SttServiceVoiceCapture implements VoiceCapture {
  SttServiceVoiceCapture({
    SttService? sttService,
    this.ackTimeout = const Duration(milliseconds: 800),
    this.stopGrace = const Duration(milliseconds: 800),
  }) : _stt = sttService ?? const SttService();

  final SttService _stt;

  /// Bound applied to every native stop/cancel acknowledgement. Test
  /// seams may shorten it; production keeps the 800ms default.
  final Duration ackTimeout;

  /// Grace period after a successful stop ack for the engine to deliver
  /// the finalized transcript before resolving with a non-success.
  final Duration stopGrace;

  /// Incremented on every restart/cancel/dispose. Callbacks and results
  /// from a superseded generation are dropped.
  int _generation = 0;
  Completer<VoiceCaptureResult>? _pending;
  bool _ownsActiveListen = false;

  /// True once THIS adapter's session has actually invoked the engine's
  /// `listen`. Stays false while the session is staged behind a native
  /// cleanup gate, so stop/cancel never forward engine calls that only
  /// belong to a session that never started natively.
  bool _nativeSessionStarted = false;

  /// Flips to true only when the engine reports
  /// [SttNativeStatus.ready] for the CURRENT generation. Drives the public
  /// [isListening] so the UI never claims listening while permission or
  /// engine startup is still pending.
  bool _nativeReady = false;
  bool _disposed = false;

  /// Every native cleanup that has not truly settled yet: stop/cancel acks
  /// and the underlying listen of an abandoned session that never reached
  /// the engine. A token leaves the set ONLY when its own work settles, so
  /// an older late settle can never hide a newer outstanding cleanup. New
  /// native listens wait (bounded) for the set to drain and fail safely if
  /// it has not.
  final Set<Object> _outstandingCleanup = <Object>{};
  Completer<void>? _cleanupIdle;

  /// Bookkeeping for the session currently (or last) handed to the engine.
  _CaptureSession? _session;

  @override
  bool get isListening =>
      !_disposed && _nativeReady && !(_pending?.isCompleted ?? true);

  @override
  Future<VoiceCaptureResult> listen({
    required ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  }) {
    if (_disposed) {
      return Future<VoiceCaptureResult>.value(
        const VoiceCaptureResult(
          unavailable: true,
          message: '음성 입력을 사용할 수 없어요.',
        ),
      );
    }
    // Restart semantics: a new listen supersedes THIS adapter's previous
    // session. The engine cleans up its own previous listen when listen()
    // is called again, so we never cancel a foreign owner from here.
    if (_ownsActiveListen) {
      _generation += 1;
      _nativeReady = false;
      _nativeSessionStarted = false;
      // A superseded session that never reached the engine must still be
      // cancelled the moment it does start (and the new session waits).
      _abandonUnsettled(_session);
      _completePending(_finishedWithoutText('새 입력을 시작했어요.'));
      _ownsActiveListen = false;
    }
    final generation = ++_generation;
    final completer = Completer<VoiceCaptureResult>();
    _pending = completer;
    _ownsActiveListen = true;
    _nativeSessionStarted = false;
    unawaited(_startSession(completer, generation, onPartial, onReady));
    return completer.future;
  }

  /// Starts the engine session, waiting for any outstanding native
  /// stop/cancel cleanup first (the service's active state is global).
  Future<void> _startSession(
    Completer<VoiceCaptureResult> completer,
    int generation,
    ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  ) async {
    if (_outstandingCleanup.isNotEmpty) {
      await _awaitNativeCleanupSettled();
      if (_disposed || generation != _generation || completer.isCompleted) {
        return; // superseded/canceled while staged
      }
      if (_outstandingCleanup.isNotEmpty) {
        // The previous stop/cancel ack never returned; starting a native
        // listen now could race the service's global cleanup. Fail this
        // attempt safely instead.
        _ownsActiveListen = false;
        completer.complete(
          const VoiceCaptureResult(
            unavailable: true,
            message: '음성 입력이 아직 정리 중이에요. 잠시 후 다시 시도해 주세요.',
          ),
        );
        return;
      }
    }
    await _runSession(completer, generation, onPartial, onReady);
  }

  /// Waits (bounded by [ackTimeout]) until EVERY outstanding cleanup has
  /// settled. Never waits unboundedly.
  Future<void> _awaitNativeCleanupSettled() async {
    if (_outstandingCleanup.isEmpty) {
      return;
    }
    final idle = _cleanupIdle ??= Completer<void>();
    try {
      await idle.future.timeout(ackTimeout);
    } on TimeoutException {
      // Still unsettled: the caller fails safely.
    }
  }

  Future<void> _runSession(
    Completer<VoiceCaptureResult> completer,
    int generation,
    ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  ) async {
    _nativeSessionStarted = true;
    final session = _CaptureSession()..invoked = true;
    _session = session;
    VoiceCaptureResult result;
    try {
      final raw = await _stt.listen(
        onPartialResult: (text) {
          // Any engine callback proves the native session REALLY started.
          // If we already abandoned it (stop/cancel/supersede before it
          // started), cancel it now so no orphan mic survives.
          _markLive(session);
          // Partials are display-only and die with their generation AND
          // their session: after any terminal (stop fallback / cancel /
          // supersede) the completer is completed or replaced, so late
          // partials are dropped.
          if (_disposed || generation != _generation) {
            return;
          }
          if (completer.isCompleted || _pending != completer) {
            return;
          }
          onPartial(text);
        },
        onStatus: (event) {
          _markLive(session);
          if (_disposed || generation != _generation) {
            return;
          }
          // A ready that arrives after the session already ended (stop
          // fallback, cancel, supersede) must not resurrect listening UI.
          if (completer.isCompleted || _pending != completer) {
            return;
          }
          if (event.status != SttNativeStatus.ready) {
            return;
          }
          _nativeReady = true;
          onReady?.call(true);
        },
        mode: SttListenMode.dictation,
      );
      result = _convert(raw);
    } catch (_) {
      // Never surface raw engine/platform errors to the UI.
      result = const VoiceCaptureResult(
        unavailable: true,
        message: '음성 입력을 시작하지 못했어요.',
      );
    }
    session.settled = true;
    if (!session.done.isCompleted) {
      session.done.complete();
    }
    if (_disposed || generation != _generation || completer.isCompleted) {
      // Stale session: the late final is dropped entirely.
      return;
    }
    _ownsActiveListen = false;
    _nativeSessionStarted = false;
    _nativeReady = false;
    completer.complete(result);
  }

  @override
  Future<void> stop() async {
    if (_disposed || !_ownsActiveListen) {
      return; // nothing of ours is listening; never stop a foreign owner
    }
    final completer = _pending;
    final generation = _generation;
    final session = _session;
    if (!_nativeSessionStarted) {
      // Session is still staged behind a native cleanup gate: nothing of
      // ours is at the engine, so the stop is local-only.
      _ownsActiveListen = false;
      _nativeReady = false;
      if (completer != null && !completer.isCompleted) {
        completer.complete(_finishedWithoutText('중지했어요.'));
      }
      return;
    }
    // Bounded native ack: a hung engine stop must not wedge stop() or the
    // listen future. The ack also feeds the cleanup gate that serializes
    // the next native listen behind this stop.
    final ack = _stt.stopActiveListen();
    _trackCleanup(ack);
    try {
      await ack.timeout(ackTimeout);
    } catch (_) {
      // Timed out or threw: the gate is registered; fall through to the
      // bounded final wait so the session still resolves.
    }
    if (_disposed ||
        generation != _generation ||
        completer == null ||
        completer.isCompleted) {
      return;
    }
    // Grace period: give the engine a moment to deliver the finalized
    // result. If it never does, resolve with a non-success so the UI
    // cannot hang on this session.
    await Future<void>.delayed(stopGrace);
    if (_disposed ||
        generation != _generation ||
        completer.isCompleted ||
        _pending != completer) {
      return;
    }
    _ownsActiveListen = false;
    _nativeSessionStarted = false;
    _nativeReady = false;
    // The engine never finalized. If the native session is live, cancel it
    // so the mic cannot keep running after the UI returned; if it has not
    // started yet (stop landed in the pre-listen window), cancel it the
    // moment it does and make new sessions wait for it.
    if (session != null && session.live && !session.settled) {
      _trackCleanup(_stt.cancelActiveListen());
    } else {
      _abandonUnsettled(session);
    }
    completer.complete(_finishedWithoutText('중지했어요.'));
  }

  @override
  Future<void> cancel() async {
    if (_disposed) {
      return; // dispose() already resolved everything we owned.
    }
    _generation += 1; // late partials / finals are stale from here on
    final owned = _ownsActiveListen;
    final nativeStarted = _nativeSessionStarted;
    final session = _session;
    _ownsActiveListen = false;
    _nativeSessionStarted = false;
    _nativeReady = false;
    // Resolve OUR pending future synchronously BEFORE any await: a listen
    // started during native cleanup gets a fresh pending completer and
    // must never be completed with this canceled result (and the caller
    // sees the documented immediate resolution).
    _completePending(_finishedWithoutText('취소했어요.'));
    if (!owned || !nativeStarted) {
      // Nothing of ours is at the engine; never cancel a foreign owner.
      return;
    }
    final ack = _stt.cancelActiveListen();
    _trackCleanup(ack);
    _abandonUnsettled(session);
    try {
      await ack.timeout(ackTimeout);
    } catch (_) {
      // Bounded: a hung native cancel cannot wedge cancel(); the gate
      // keeps later listens from racing the unsettled cleanup.
    }
    // Nothing after the await mutates shared state: a new listen may own
    // the pending slot by now and it must stay untouched.
  }

  /// Drops the current session. Only cancels the engine if this adapter
  /// owns a natively-started listen.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    final nativeStarted = _nativeSessionStarted;
    final session = _session;
    _ownsActiveListen = false;
    _nativeSessionStarted = false;
    _nativeReady = false;
    _completePending(_finishedWithoutText('종료했어요.'));
    if (nativeStarted) {
      _trackCleanup(_stt.cancelActiveListen());
      _abandonUnsettled(session);
    }
  }

  /// Registers [work] as outstanding native cleanup. Its token is removed
  /// only when THIS work settles (value or error, never unhandled), and
  /// waiters are released only when ALL tokens are gone.
  void _trackCleanup(Future<void> work) {
    final token = Object();
    _outstandingCleanup.add(token);
    void settle() {
      if (_outstandingCleanup.remove(token) && _outstandingCleanup.isEmpty) {
        final idle = _cleanupIdle;
        _cleanupIdle = null;
        if (idle != null && !idle.isCompleted) {
          idle.complete();
        }
      }
    }

    work.then((_) => settle(), onError: (Object _) => settle());
  }

  /// Marks [session] as ended by us while its engine listen has not
  /// settled and has not proven it started. It is cancelled on its first
  /// callback and new native listens wait for it to settle.
  void _abandonUnsettled(_CaptureSession? session) {
    if (session == null ||
        !session.invoked ||
        session.settled ||
        session.abandoned) {
      return;
    }
    session.abandoned = true;
    if (!session.live) {
      // Never started: cancel on first callback. (A session that was already
      // live is cleaned by the engine's own restart/stop; a late cancel then
      // could clobber a newer session.)
      session.cancelOnStart = true;
      _trackCleanup(session.done.future);
    }
  }

  /// Records that the engine called back for [session]; cancels it if we
  /// had already abandoned it before it started.
  void _markLive(_CaptureSession session) {
    session.live = true;
    if (session.cancelOnStart &&
        !session.settled &&
        !session.lateCancelIssued) {
      session.lateCancelIssued = true;
      _trackCleanup(_stt.cancelActiveListen());
    }
  }
  void _completePending(VoiceCaptureResult result) {
    final completer = _pending;
    _pending = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  VoiceCaptureResult _finishedWithoutText(String message) {
    return VoiceCaptureResult(silence: true, message: message);
  }

  VoiceCaptureResult _convert(SttListenResult raw) {
    if (raw.isSuccess) {
      return VoiceCaptureResult(text: raw.text);
    }
    // Fixed safe messages per failure flag: the engine's raw message never
    // reaches the UI from here.
    switch (raw.failure) {
      case SttListenFailure.permissionDenied:
        return const VoiceCaptureResult(
          deniedPermission: true,
          message: '마이크 권한이 필요해요.',
        );
      case SttListenFailure.unsupportedLocale:
        return const VoiceCaptureResult(
          unsupportedLocale: true,
          message: '이 언어는 음성 입력을 지원하지 않아요.',
        );
      case SttListenFailure.unavailable:
        return const VoiceCaptureResult(
          unavailable: true,
          message: '음성 입력을 사용할 수 없어요.',
        );
      case SttListenFailure.silence:
      case null:
        return const VoiceCaptureResult(
          silence: true,
          message: '음성이 인식되지 않았어요.',
        );
    }
  }
}

/// Per-session engine bookkeeping (see [SttServiceVoiceCapture]).
class _CaptureSession {
  /// The engine's `listen` was called.
  bool invoked = false;

  /// The engine called back at least once (native session really started).
  bool live = false;

  /// The engine's `listen` future completed.
  bool settled = false;

  /// We ended the session (stop fallback / cancel / supersede / dispose).
  bool abandoned = false;

  /// Abandoned before it ever called back: cancel it on first callback.
  bool cancelOnStart = false;

  bool lateCancelIssued = false;
  final Completer<void> done = Completer<void>();
}
