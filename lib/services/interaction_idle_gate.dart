import 'dart:async';

/// Process-wide interaction signal used to keep nonessential startup work out
/// of active navigation and scrolling. It is intentionally tiny and has no
/// widget ownership, so recreated ShellScreen instances share one token.
class InteractionIdleGate {
  InteractionIdleGate._();

  static final InteractionIdleGate instance = InteractionIdleGate._();

  static const Duration idleWindow = Duration(milliseconds: 700);
  DateTime? _lastInteractionAt;
  int _generation = 0;

  int get generation => _generation;

  bool get isIdle {
    final last = _lastInteractionAt;
    return last == null || DateTime.now().difference(last) >= idleWindow;
  }

  void notifyInteraction() {
    _lastInteractionAt = DateTime.now();
    _generation += 1;
  }

  Future<void> waitForIdle() async {
    while (!isIdle) {
      final last = _lastInteractionAt;
      final remaining = last == null
          ? Duration.zero
          : idleWindow - DateTime.now().difference(last);
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
  }

  /// Waits for an idle window that survived a microtask turn. This closes the
  /// small race where a startup permit is released immediately before a tap.
  Future<void> waitForStableIdle() async {
    while (true) {
      await waitForIdle();
      final observedGeneration = _generation;
      await Future<void>.microtask(() {});
      if (observedGeneration == _generation && isIdle) return;
    }
  }
}
