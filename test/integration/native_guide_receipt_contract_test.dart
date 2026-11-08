import 'package:flutter_test/flutter_test.dart';
import '../../integration_test/support/native_guide_receipt.dart';

void main() {
  const arm = NativeGuideArm(runId: 'run_12345678', phase: 'query',
    nativePid: 4312, sessionId: 7, generation: 3, afterSequence: 90);
  Map<String, Object?> receipt({String? runId, String? phase, int? pid,
      int? session, int? generation, int? sequence, int? count,
      bool mic = true, bool transcript = false}) => {
    'source': 'parent_native_pid_log', 'runId': runId ?? arm.runId,
    'phase': phase ?? arm.phase, 'nativePid': pid ?? arm.nativePid,
    'nativeSessionId': session ?? arm.sessionId,
    'generation': generation ?? arm.generation,
    'logSequence': sequence ?? 91, 'recognizedResultCount': count ?? 1,
    'liveMicrophone': mic, if (transcript) 'transcript': 'forbidden'
  };
  test('accepts only fresh phase-scoped PID/session/generation evidence', () {
    expect(acceptsNativeGuideReceipt(receipt(), arm), isTrue);
  });
  test('rejects stale or replayed sequence', () {
    expect(acceptsNativeGuideReceipt(receipt(sequence: 90), arm), isFalse);
    expect(acceptsNativeGuideReceipt(receipt(sequence: 89), arm), isFalse);
  });
  test('rejects wrong run, phase, PID, session, generation', () {
    for (final bad in [receipt(runId: 'other_run_1234'), receipt(phase: 'create'),
      receipt(pid: 99), receipt(session: 8), receipt(generation: 4)]) {
      expect(acceptsNativeGuideReceipt(bad, arm), isFalse);
    }
  });
  test('rejects no actual recognition, no live mic, injected transcript or wrong source', () {
    expect(acceptsNativeGuideReceipt(receipt(count: 0), arm), isFalse);
    expect(acceptsNativeGuideReceipt(receipt(mic: false), arm), isFalse);
    expect(acceptsNativeGuideReceipt(receipt(transcript: true), arm), isFalse);
    expect(acceptsNativeGuideReceipt({...receipt(), 'source': 'timer'}, arm), isFalse);
  });
}
