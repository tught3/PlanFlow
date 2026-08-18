import 'dart:async';

import 'package:flutter/widgets.dart';

/// Defers non-essential signed-in startup work until onboarding is gone and
/// the first home frame has been presented. Calls made while the work is
/// pending share one Future, so lifecycle callbacks cannot duplicate it.
class OnboardingStartupGate {
  Future<void>? _pending;
  bool _completed = false;
  int _generation = 0;

  Future<void> runAfterFirstHomeFrame(Future<void> Function() work) {
    if (_completed) return Future<void>.value();
    return _pending ??= _run(work, _generation);
  }

  void reset() {
    _generation += 1;
    _pending = null;
    _completed = false;
  }

  Future<void> _run(Future<void> Function() work, int generation) async {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _generation) {
        // Resolve the obsolete caller without running stale work.
        completer.complete();
        return;
      }
      () async {
        try {
          await work();
          if (generation != _generation) {
            completer.complete();
            return;
          }
          _completed = true;
          completer.complete();
        } catch (error, stackTrace) {
          // A failed deferred task must not poison the gate forever.  Clear
          // the shared future so a later resume can retry once the transient
          // network/initialization failure is gone.
          if (generation == _generation) _pending = null;
          completer.completeError(error, stackTrace);
        }
      }();
    });
    return completer.future;
  }
}
