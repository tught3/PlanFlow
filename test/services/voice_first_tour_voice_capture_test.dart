// Tests for the tour voice-capture adapter over `SttService`.
//
// SIMULATED TRANSCRIPTS / SIMULATED ENGINE: a fake SttService replaces the
// native plugin. Nothing here involves acoustic ASR or a microphone.
//
// Regression focus (parent source review findings):
//  - cancel must resolve the listen future synchronously and must never
//    complete a NEW session started during native cleanup,
//  - native stop/cancel acks are bounded (a hung engine call cannot wedge
//    stop()/cancel() or the listen future),
//  - new native listens serialize behind an outstanding stop/cancel ack,
//    and fail safely while the cleanup is unsettled,
//  - late same-generation partials are dropped after a terminal state,
//  - failure flags map to fixed safe messages, never raw engine text,
//  - isListening only reports ENGINE-ready truth.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/onboarding/voice_first_tour_voice_capture.dart';
import 'package:planflow/services/stt_service.dart';

class FakeSttService implements SttService {
  int listenCount = 0;
  int stopCount = 0;
  int cancelCount = 0;
  int warmUpCount = 0;

  /// When set, `listen` throws synchronously (engine failure simulation).
  Object? throwOnListen;

  /// Final text delivered by [stopActiveListen]. When null, the fake engine
  /// never resolves on stop (hang simulation).
  String? stopFinalText;

  /// When set, [stopActiveListen] waits for this gate before returning
  /// (outstanding/hung ack simulation).
  Completer<void>? stopGate;

  /// When set, [cancelActiveListen] waits for this gate before returning.
  Completer<void>? cancelGate;

  /// When set, `listen` models the service's pre-start awaits (permission /
  /// cleanup): callbacks and the active session only exist once released.
  Completer<void>? startGate;

  ValueChanged<String>? activePartial;
  ValueChanged<SttNativeStatusEvent>? activeStatus;
  Completer<SttListenResult>? active;

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) {
    listenCount += 1;
    if (throwOnListen != null) {
      throw throwOnListen!;
    }
    final gate = startGate;
    if (gate != null) {
      return gate.future.then((_) {
        activePartial = onPartialResult;
        activeStatus = onStatus;
        final late = Completer<SttListenResult>();
        active = late;
        return late.future;
      });
    }
    activePartial = onPartialResult;
    activeStatus = onStatus;
    final completer = Completer<SttListenResult>();
    active = completer;
    return completer.future;
  }

  @override
  Future<void> stopActiveListen() async {
    stopCount += 1;
    final gate = stopGate;
    if (gate != null) {
      await gate.future;
    }
    final current = active;
    if (current != null && !current.isCompleted) {
      // Like the real service, stop settles the active listen: with the
      // finalized text, or with a non-success when nothing was heard.
      current.complete(
        stopFinalText != null
            ? SttListenResult.success(stopFinalText!)
            : SttListenResult.failure(
                failure: SttListenFailure.silence,
                message: '중지',
              ),
      );
    }
  }

  @override
  Future<void> cancelActiveListen() async {
    cancelCount += 1;
    final gate = cancelGate;
    if (gate != null) {
      await gate.future;
    }
    final current = active;
    if (current != null && !current.isCompleted) {
      current.complete(
        SttListenResult.failure(
          failure: SttListenFailure.silence,
          message: '취소',
        ),
      );
    }
  }

  @override
  Future<void> warmUp() async {
    warmUpCount += 1;
  }

  @override
  Future<String> undoLastSpeechSegment() => throw UnimplementedError();

  @override
  Future<String> undoLastSpeechWord() => throw UnimplementedError();

  @override
  Future<String> clearActiveTranscript() => throw UnimplementedError();
}

void main() {
  group('SttServiceVoiceCapture (SIMULATED engine)', () {
    test('construction is side-effect free; mic starts lazily on listen',
        () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      expect(adapter.isListening, isFalse);
      expect(fake.listenCount, 0);
      expect(fake.warmUpCount, 0); // no warm-up on construction

      final future = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(fake.listenCount, 1);
      expect(fake.warmUpCount, 0); // adapter never warms up
      await adapter.cancel();
      await future;
    });

    test('listen future returns the final result; partials pass while active',
        () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final partials = <String>[];
      final future = adapter.listen(onPartial: partials.add);
      await pumpEventQueue();
      expect(adapter.isListening, isFalse); // not ready yet

      fake.activeStatus?.call(
        const SttNativeStatusEvent(status: SttNativeStatus.ready),
      );
      expect(adapter.isListening, isTrue); // engine really listening

      fake.activePartial?.call('내일 오후');
      final result = await fake.completeAndAwait(future, '내일 오후 1시 회의');

      expect(result.isSuccess, isTrue);
      expect(result.text, '내일 오후 1시 회의');
      expect(partials, ['내일 오후']);
      expect(adapter.isListening, isFalse);
    });

    test('isListening drops when a new session supersedes the ready one',
        () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final first = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      fake.activeStatus?.call(
        const SttNativeStatusEvent(status: SttNativeStatus.ready),
      );
      expect(adapter.isListening, isTrue);

      final second = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(adapter.isListening, isFalse); // superseded before ready
      await first;
      unawaited(second);
      await adapter.cancel();
    });

    test('stop finalizes the existing engine result via the listen future',
        () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final future = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();

      fake.stopFinalText = '내일 오전 9시에 강남역에서 팀장님과 면담';
      await adapter.stop();
      final result = await future;

      expect(fake.stopCount, 1);
      expect(result.isSuccess, isTrue);
      expect(result.text, '내일 오전 9시에 강남역에서 팀장님과 면담');
      expect(adapter.isListening, isFalse);
    });

    test('stop resolves non-success when the engine never finalizes',
        () async {
      final fake = FakeSttService(); // stopFinalText stays null (hang)
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final future = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();

      await adapter.stop();
      final result = await future;

      expect(result.isSuccess, isFalse);
      expect(result.silence, isTrue);
      expect(adapter.isListening, isFalse);
    });

    test('cancel rejects the session and suppresses late callbacks', () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final partials = <String>[];
      final future = adapter.listen(onPartial: partials.add);
      await pumpEventQueue();
      final stalePartial = fake.activePartial;

      await adapter.cancel();
      final result = await future;

      expect(fake.cancelCount, 1);
      expect(result.isSuccess, isFalse);
      expect(result.silence, isTrue);
      expect(adapter.isListening, isFalse);

      // Late partials / finals from the stale session are dropped.
      stalePartial?.call('늦은 부분 인식');
      expect(partials, isEmpty);
    });

    test('cancel/stop are not forwarded when nothing is owned', () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      await adapter.cancel();
      await adapter.stop();
      expect(fake.cancelCount, 0);
      expect(fake.stopCount, 0);
    });

    test('restart supersedes only the previous own session', () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final firstPartials = <String>[];
      final firstFuture = adapter.listen(onPartial: firstPartials.add);
      await pumpEventQueue();
      fake.activeStatus?.call(
        const SttNativeStatusEvent(status: SttNativeStatus.ready),
      );
      final stalePartial = fake.activePartial;

      final secondFuture = adapter.listen(onPartial: (_) {});
      final first = await firstFuture;
      expect(first.isSuccess, isFalse); // superseded
      expect(adapter.isListening, isFalse);

      // The stale generation's partial callback is dead.
      stalePartial?.call('옛날 부분');
      expect(firstPartials, isEmpty);

      final second = await fake.completeAndAwait(secondFuture, '모레 저녁 7시에 회식');
      expect(second.text, '모레 저녁 7시에 회식');
      expect(fake.listenCount, 2);
      expect(adapter.isListening, isFalse);
    });

    test('dispose while listening cancels once and suppresses late results',
        () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final future = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();

      adapter.dispose();
      final result = await future;
      expect(result.isSuccess, isFalse);
      expect(fake.cancelCount, 1);
      expect(adapter.isListening, isFalse);

      // Late engine completion after dispose is ignored (already resolved).
      await fake.completeActive('늦은 최종');
      expect(result.text, isNull);
    });

    test('dispose without an owned listen does not touch the engine', () {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      adapter.dispose();
      expect(fake.cancelCount, 0);
      expect(fake.listenCount, 0);
    });

    test('engine failure yields a safe unavailable result without secrets',
        () async {
      final fake = FakeSttService();
      fake.throwOnListen = StateError('native-secret-payload');
      final adapter = SttServiceVoiceCapture(sttService: fake);

      final result = await adapter.listen(onPartial: (_) {});

      expect(result.isSuccess, isFalse);
      expect(result.unavailable, isTrue);
      expect(result.text, isNull);
      expect(result.message, isNot(contains('native-secret')));
    });

    test('permission failure maps to deniedPermission', () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final future = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();

      fake.active?.complete(
        SttListenResult.failure(
          failure: SttListenFailure.permissionDenied,
          message: 'raw platform message',
        ),
      );
      final result = await future;

      expect(result.deniedPermission, isTrue);
      expect(result.isSuccess, isFalse);
    });

    test('failure flags carry fixed safe messages, never raw engine text',
        () async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(sttService: fake);
      final future = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();

      fake.active?.complete(
        SttListenResult.failure(
          failure: SttListenFailure.silence,
          message: 'RAW-ENGINE-SECRET-DETAIL',
        ),
      );
      final result = await future;

      expect(result.silence, isTrue);
      expect(result.message, '음성이 인식되지 않았어요.');
      expect(result.message, isNot(contains('RAW-ENGINE')));
    });

    test(
        'cancel resolves the listen future synchronously and never completes '
        'a session started during native cleanup',
        () async {
      final fake = FakeSttService();
      final cancelGate = Completer<void>();
      fake.cancelGate = cancelGate;
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 500),
      );
      final firstFuture = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(fake.listenCount, 1);

      // cancel() runs synchronously up to its first await: the listen
      // future must be resolved BEFORE the native cancel ack returns.
      final cancelFuture = adapter.cancel();
      final canceled = await firstFuture;
      expect(cancelGate.isCompleted, isFalse); // ack not returned yet
      expect(canceled.isSuccess, isFalse);
      expect(canceled.silence, isTrue);
      expect(fake.cancelCount, 1);

      // A new listen while the native cancel ack is still outstanding:
      // it stays staged (no engine listen yet)...
      final secondFuture = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(fake.listenCount, 1); // serialized behind the cancel ack

      // ...and once the ack settles, the new session owns its own result.
      cancelGate.complete();
      await cancelFuture;
      await pumpEventQueue();
      expect(fake.listenCount, 2);
      fake.activeStatus?.call(
        const SttNativeStatusEvent(status: SttNativeStatus.ready),
      );
      final second = await fake.completeAndAwait(secondFuture, '내일 일정 보여줘');
      expect(second.isSuccess, isTrue);
      expect(second.text, '내일 일정 보여줘'); // never the old cancel result
    });

    test('a new native listen serializes behind an outstanding stop ack',
        () async {
      final fake = FakeSttService();
      final stopGate = Completer<void>();
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 500),
        stopGrace: const Duration(milliseconds: 5),
      );
      final firstFuture = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      fake.activeStatus?.call(
        const SttNativeStatusEvent(status: SttNativeStatus.ready),
      );

      fake.stopGate = stopGate;
      final stopFuture = adapter.stop();
      final secondFuture = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(fake.listenCount, 1); // blocked until the stop ack settles
      expect(fake.stopCount, 1);

      stopGate.complete();
      await stopFuture;
      await firstFuture;
      await pumpEventQueue();
      expect(fake.listenCount, 2); // serialized start, no race
      await adapter.cancel();
      await secondFuture;
    });

    test('a hung native stop is bounded: stop and the listen still resolve',
        () async {
      final fake = FakeSttService();
      fake.stopGate = Completer<void>(); // never completed
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 30),
        stopGrace: const Duration(milliseconds: 10),
      );
      final future = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();

      // Must return even though the native stop never acked.
      await adapter.stop();
      final result = await future;

      expect(fake.stopCount, 1);
      expect(result.isSuccess, isFalse);
      expect(result.silence, isTrue);
      expect(adapter.isListening, isFalse);
    });

    test('listen while cleanup is unsettled fails safely; works after settle',
        () async {
      final fake = FakeSttService();
      final hungGate = Completer<void>();
      fake.stopGate = hungGate;
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 30),
        stopGrace: const Duration(milliseconds: 10),
      );
      final first = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      await adapter.stop();
      await first; // bounded fallback resolved it

      // The stop ack never returned: a new attempt must fail safely
      // instead of racing the service's global cleanup.
      final blocked = await adapter.listen(onPartial: (_) {});
      expect(blocked.isSuccess, isFalse);
      expect(blocked.unavailable, isTrue);
      expect(fake.listenCount, 1); // no native start was attempted

      // The engine finally settles: attempts proceed again.
      hungGate.complete();
      await pumpEventQueue();
      final ok = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(fake.listenCount, 2);
      fake.activeStatus?.call(
        const SttNativeStatusEvent(status: SttNativeStatus.ready),
      );
      final result = await fake.completeAndAwait(ok, '모레 오전 10시 회의');
      expect(result.isSuccess, isTrue);
    });

    test('late same-generation partial after the stop fallback is dropped',
        () async {
      final fake = FakeSttService(); // stop returns, no final text
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        stopGrace: const Duration(milliseconds: 5),
      );
      final partials = <String>[];
      final future = adapter.listen(onPartial: partials.add);
      await pumpEventQueue();

      await adapter.stop();
      final result = await future;
      expect(result.isSuccess, isFalse); // fallback terminal

      // Same generation (stop fallback does not bump it), but the session
      // completer is already terminal: the late partial must be dropped.
      fake.activePartial?.call('늦은 부분 인식');
      expect(partials, isEmpty);
    });

    test('stop/cancel on a session staged behind a gate stays local', () async {
      final fake = FakeSttService();
      final hungGate = Completer<void>();
      fake.stopGate = hungGate;
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 30),
        stopGrace: const Duration(milliseconds: 10),
      );
      final first = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      await adapter.stop(); // hung ack -> bounded fallback, unsettled gate
      await first;

      // New session stays staged; stop/cancel must not hit the engine.
      final stagedFuture = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(fake.listenCount, 1);

      await adapter.stop();
      final staged = await stagedFuture;
      expect(staged.isSuccess, isFalse); // resolved locally
      expect(fake.stopCount, 1); // unchanged: no engine stop forwarded

      final stagedFuture2 = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      await adapter.cancel();
      final staged2 = await stagedFuture2;
      expect(staged2.isSuccess, isFalse);
      expect(fake.cancelCount, 0); // nothing of ours at the engine
      hungGate.complete();
    });
    // ---- Final lifecycle repair regressions (SIMULATED engine) ----

    const ready = SttNativeStatusEvent(status: SttNativeStatus.ready);

    Future<(SttServiceVoiceCapture, FakeSttService, Future<VoiceCaptureResult>)>
        readySession() async {
      final fake = FakeSttService();
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 30),
        stopGrace: const Duration(milliseconds: 10),
      );
      final first = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      fake.activeStatus?.call(ready);
      return (adapter, fake, first);
    }

    for (final olderFirst in [true, false]) {
      test(
          'double hung stop+cancel overlap: new native listen waits for ALL '
          'acks (${olderFirst ? 'older' : 'newer'} settles first)',
          () async {
        final (adapter, fake, first) = await readySession();
        final stopGate = Completer<void>();
        final cancelGate = Completer<void>();
        fake.stopGate = stopGate;
        fake.cancelGate = cancelGate;

        final stopFuture = adapter.stop();
        final cancelFuture = adapter.cancel(); // before the stop grace ends
        await Future.wait([stopFuture, cancelFuture, first]);
        expect(fake.stopCount, 1);
        expect(fake.cancelCount, 1);

        // Settle only ONE ack; the other is still outstanding.
        (olderFirst ? stopGate : cancelGate).complete();
        await pumpEventQueue();
        final blocked = await adapter.listen(onPartial: (_) {});
        expect(blocked.unavailable, isTrue); // bounded, fails safely
        expect(blocked.isSuccess, isFalse);
        expect(fake.listenCount, 1); // native NEVER started early

        // The remaining ack settles: only now may a native listen start,
        // and the old cancel can no longer complete the new session.
        (olderFirst ? cancelGate : stopGate).complete();
        await pumpEventQueue();
        final next = adapter.listen(onPartial: (_) {});
        await pumpEventQueue();
        expect(fake.listenCount, 2);
        fake.activeStatus?.call(ready);
        final result = await fake.completeAndAwait(next, '내일 일정 보여줘');
        expect(result.text, '내일 일정 보여줘');
      });
    }

    test('cancel ack that fails after dispose is swallowed (no unhandled)',
        () async {
      final (adapter, fake, first) = await readySession();
      final cancelGate = Completer<void>();
      fake.cancelGate = cancelGate;
      adapter.dispose();
      await first;
      cancelGate.completeError(StateError('RAW-SECRET'));
      await pumpEventQueue();
      expect(fake.cancelCount, 1);
    });

    test('stop in the pre-listen window cancels the late-started native '
        'session and never shows listening', () async {
      final fake = FakeSttService()..startGate = Completer<void>();
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 30),
        stopGrace: const Duration(milliseconds: 10),
      );
      var readyCalls = 0;
      final first = adapter.listen(
        onPartial: (_) {},
        onReady: (_) => readyCalls += 1,
      );
      await pumpEventQueue();
      expect(fake.listenCount, 1); // engine still in permission/cleanup

      await adapter.stop();
      final stopped = await first;
      expect(stopped.isSuccess, isFalse);

      // A new session must not overlap the still-unstarted old one.
      final blocked = await adapter.listen(onPartial: (_) {});
      expect(blocked.unavailable, isTrue);
      expect(fake.listenCount, 1);

      // The engine finally starts and reports ready for the dead session.
      fake.startGate!.complete();
      await pumpEventQueue();
      fake.activeStatus?.call(ready);
      await pumpEventQueue();

      expect(fake.cancelCount, 1); // late native session cancelled
      expect(readyCalls, 0);
      expect(adapter.isListening, isFalse);

      // Cleanup drained: a fresh session can start again.
      final next = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      expect(fake.listenCount, 2);
      await adapter.cancel();
      await next;
    });

    test('cancel in the pre-listen window cancels the late native session',
        () async {
      final fake = FakeSttService()..startGate = Completer<void>();
      final adapter = SttServiceVoiceCapture(
        sttService: fake,
        ackTimeout: const Duration(milliseconds: 30),
      );
      final first = adapter.listen(onPartial: (_) {});
      await pumpEventQueue();
      await adapter.cancel();
      await first;
      final before = fake.cancelCount;

      fake.startGate!.complete();
      await pumpEventQueue();
      fake.activePartial?.call('늦은 부분');
      await pumpEventQueue();

      expect(fake.cancelCount, before + 1); // late start cancelled once
      expect(adapter.isListening, isFalse);
    });
  });
}

extension on FakeSttService {
  /// Emits a final transcript through the active session and returns the
  /// adapter-resolved capture result.
  Future<VoiceCaptureResult> completeAndAwait(
    Future<VoiceCaptureResult> pending,
    String text,
  ) async {
    _completeActiveSafe(text);
    return pending;
  }

  Future<void> completeActive(String text) async {
    _completeActiveSafe(text);
  }

  void _completeActiveSafe(String text) {
    final completer = active;
    if (completer != null && !completer.isCompleted) {
      completer.complete(SttListenResult.success(text));
    }
  }
}
