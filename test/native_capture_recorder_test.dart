// FOCUSED UNIT REGRESSION for `NativeCaptureRecorder`.
//
// IMPORTANT: these tests use a MOCK `VoiceCapture` to exercise the
// recorder's bookkeeping discipline (final-only, immutable listen stage,
// callback pass-through, cancel/stop forward, no fabrication). They are
// NOT native ASR proof. Native execution lives in
// `integration_test/voice_first_tour_native_probe.dart`, which is the only
// file that may claim a real-engine result.
//
// All fake/stub transcripts here are LOCAL to this file. They never reach
// `integration_test/`, never reach the APK, never reach the production
// probe, and never reach a real engine.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/onboarding/voice_first_tour_voice_capture.dart';

import '../integration_test/support/native_capture_recorder.dart';

class _MockVoiceCapture implements VoiceCapture {
  _MockVoiceCapture();

  bool listeningNow = false;
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  bool stopReturned = false;
  bool cancelReturned = false;
  final List<String> partialCalls = <String>[];
  final List<bool> readyCalls = <bool>[];

  Completer<VoiceCaptureResult>? _active;
  ValueChanged<String>? _activeOnPartial;
  ValueChanged<bool>? _activeOnReady;

  void emitPartial(String text) {
    partialCalls.add(text);
    _activeOnPartial?.call(text);
  }

  void emitReady(bool ready) {
    readyCalls.add(ready);
    _activeOnReady?.call(ready);
  }

  void emitFinal(VoiceCaptureResult result) {
    final active = _active;
    if (active == null) return;
    _active = null;
    _activeOnPartial = null;
    _activeOnReady = null;
    listeningNow = false;
    if (!active.isCompleted) active.complete(result);
  }

  @override
  bool get isListening => listeningNow;

  @override
  Future<VoiceCaptureResult> listen({
    required ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  }) {
    listenCalls += 1;
    listeningNow = true;
    _active = Completer<VoiceCaptureResult>();
    _activeOnPartial = onPartial;
    _activeOnReady = onReady;
    return _active!.future;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    stopReturned = true;
  }

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
    cancelReturned = true;
  }
}

void main() {
  group('NativeCaptureRecorder', () {
    test('records final result keyed by stage BEFORE returning to caller',
        () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      recorder.currentStage = 'create';
      final listenFuture = recorder.listen(onPartial: (_) {});
      mock.emitFinal(const VoiceCaptureResult(text: '내일 오전 9시 강남역'));
      final result = await listenFuture;
      expect(result.text, '내일 오전 9시 강남역');
      // The recorder stored the result before listen resolved, so the
      // probe's `_requireTranscript` reading from `recorder.results` after
      // `applyFinalTranscript` cleared the UI caption still sees the real
      // ASR output.
      expect(recorder.results['create']!.text, '내일 오전 9시 강남역');
      expect(recorder.debugResultHistory()['create']!.length, 1);
    });

    test('immutable stage: mid-listen stage change does not re-key result',
        () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      recorder.currentStage = 'create';
      final listenFuture = recorder.listen(onPartial: (_) {});
      // Mutate stage mid-listen. The result delivered after this mutation
      // must still be keyed to 'create'.
      recorder.currentStage = 'edit';
      mock.emitFinal(const VoiceCaptureResult(text: '첫 번째 오후 1시로'));
      await listenFuture;
      expect(recorder.results.containsKey('create'), isTrue);
      expect(recorder.results.containsKey('edit'), isFalse);
      expect(recorder.results['create']!.text, '첫 번째 오후 1시로');
    });

    test('partials are NEVER recorded as final', () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      recorder.currentStage = 'query';
      final listenFuture = recorder.listen(onPartial: (_) {});
      mock.emitPartial('내일');
      mock.emitPartial('내일 일정');
      // No final yet: recorder must not promote any partial to a final.
      expect(recorder.results.isEmpty, isTrue);
      mock.emitFinal(const VoiceCaptureResult(text: '내일 일정 보여줘'));
      await listenFuture;
      expect(recorder.results['query']!.text, '내일 일정 보여줘');
    });

    test('callbacks onPartial/onReady pass straight through to the mock',
        () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      recorder.currentStage = 'edit';
      final observedPartials = <String>[];
      final observedReady = <bool>[];
      final listenFuture = recorder.listen(
        onPartial: observedPartials.add,
        onReady: observedReady.add,
      );
      mock.emitPartial('첫 번째');
      mock.emitPartial('첫 번째 일정');
      mock.emitReady(true);
      expect(observedPartials, <String>['첫 번째', '첫 번째 일정']);
      expect(observedReady, <bool>[true]);
      mock.emitFinal(const VoiceCaptureResult(text: '첫 번째 오후 1시로'));
      await listenFuture;
    });

    test('failed engine result is recorded verbatim, never fabricated',
        () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      recorder.currentStage = 'create';
      final listenFuture = recorder.listen(onPartial: (_) {});
      // Engine returns a silence failure. Recorder must NOT invent text;
      // it stores the failure flags exactly so the probe can fail loud.
      mock.emitFinal(
        const VoiceCaptureResult(silence: true, message: '취소했어요.'),
      );
      await listenFuture;
      expect(recorder.results['create']!.text, isNull);
      expect(recorder.results['create']!.silence, isTrue);
      expect(recorder.results['create']!.message, '취소했어요.');
      expect(recorder.results['create']!.isSuccess, isFalse);
    });

    test('stop() and cancel() forward to the delegate', () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      await recorder.stop();
      await recorder.cancel();
      expect(mock.stopCalls, 1);
      expect(mock.cancelCalls, 1);
      expect(mock.stopReturned, isTrue);
      expect(mock.cancelReturned, isTrue);
    });

    test('isListening reflects the delegate, not recorder bookkeeping',
        () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      mock.listeningNow = true;
      expect(recorder.isListening, isTrue);
      mock.listeningNow = false;
      expect(recorder.isListening, isFalse);
    });

    test('multiple stages produce independent, isolated entries', () async {
      final mock = _MockVoiceCapture();
      final recorder = NativeCaptureRecorder()..debugSetDelegate(mock);
      // Stage 1
      recorder.currentStage = 'create';
      var listen1 = recorder.listen(onPartial: (_) {});
      mock.emitPartial('강남');
      mock.emitPartial('강남 9시');
      mock.emitFinal(const VoiceCaptureResult(text: '내일 오전 9시 강남역'));
      await listen1;
      // Stage 2
      recorder.currentStage = 'query';
      listen1 = recorder.listen(onPartial: (_) {});
      mock.emitFinal(const VoiceCaptureResult(text: '내일 일정 보여줘'));
      await listen1;
      expect(recorder.results['create']!.text, '내일 오전 9시 강남역');
      expect(recorder.results['query']!.text, '내일 일정 보여줘');
      expect(recorder.debugResultHistory()['create']!.length, 1);
      expect(recorder.debugResultHistory()['query']!.length, 1);
    });
  });

  group('requireRecordedResult placeholder guard', () {
    // The hint strings below are LOCAL to this host-only file, mirroring the
    // localized placeholder for test purposes only. They never reach the
    // integration probe or any compiled APK; the probe always resolves the
    // REAL localized getter from a FeatureTourScreen-descendant element.
    const hint = '인식된 문장이 여기에 보여요';

    test('accepts a real success transcript that differs from the hint', () {
      requireRecordedResult(
        const VoiceCaptureResult(text: '내일 오전 9시 강남역'),
        'create',
        forbiddenPlaceholderHint: hint,
      );
    });

    test('rejects a success whose text equals the localized hint', () {
      expect(
        () => requireRecordedResult(
          const VoiceCaptureResult(text: hint),
          'query',
          forbiddenPlaceholderHint: hint,
        ),
        throwsStateError,
      );
    });

    test('rejects placeholder equality after trimming both sides', () {
      expect(
        () => requireRecordedResult(
          const VoiceCaptureResult(text: '  $hint  '),
          'edit',
          forbiddenPlaceholderHint: hint,
        ),
        throwsStateError,
      );
    });

    test('still rejects null, failed, and blank results', () {
      expect(
        () => requireRecordedResult(
          null,
          'create',
          forbiddenPlaceholderHint: hint,
        ),
        throwsStateError,
      );
      expect(
        () => requireRecordedResult(
          const VoiceCaptureResult(silence: true, message: '무음'),
          'query',
          forbiddenPlaceholderHint: hint,
        ),
        throwsStateError,
      );
      expect(
        () => requireRecordedResult(
          const VoiceCaptureResult(text: '   '),
          'edit',
          forbiddenPlaceholderHint: hint,
        ),
        throwsStateError,
      );
    });
  });
}
