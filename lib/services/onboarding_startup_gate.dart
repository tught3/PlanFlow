import 'dart:async';

import 'package:flutter/widgets.dart';

/// Defers non-essential signed-in startup work until onboarding is gone and
/// the first home frame has been presented. Calls made while the work is
/// pending share one Future, so lifecycle callbacks cannot duplicate it.
class OnboardingStartupGate {
  Future<void>? _pending;
  bool _completed = false;

  Future<void> runAfterFirstHomeFrame(Future<void> Function() work) {
    if (_completed) return Future<void>.value();
    return _pending ??= _run(work);
  }

  void reset() {
    _pending = null;
    _completed = false;
  }

  Future<void> _run(Future<void> Function() work) async {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      () async {
        try {
          await work();
          _completed = true;
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      }();
    });
    return completer.future;
  }
}
