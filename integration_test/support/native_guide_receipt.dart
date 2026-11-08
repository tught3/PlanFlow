/// Strict acceptance for a parent-collected native speech receipt.
/// This validates evidence only; it never opens a channel or simulates speech.
class NativeGuideArm {
  const NativeGuideArm({required this.runId, required this.phase,
    required this.nativePid, required this.sessionId, required this.generation,
    required this.afterSequence});
  final String runId, phase;
  final int nativePid, sessionId, generation, afterSequence;
}

bool acceptsNativeGuideReceipt(Map<String, Object?> receipt, NativeGuideArm arm) {
  final sequence = receipt['logSequence'];
  final recognized = receipt['recognizedResultCount'];
  return receipt['source'] == 'parent_native_pid_log' &&
      receipt['runId'] == arm.runId && receipt['phase'] == arm.phase &&
      receipt['nativePid'] == arm.nativePid && arm.nativePid > 0 &&
      receipt['nativeSessionId'] == arm.sessionId && arm.sessionId > 0 &&
      receipt['generation'] == arm.generation && arm.generation > 0 &&
      sequence is int && sequence > arm.afterSequence &&
      recognized is int && recognized > 0 &&
      receipt['liveMicrophone'] == true && !receipt.containsKey('transcript');
}
