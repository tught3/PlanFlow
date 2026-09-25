import 'package:flutter/foundation.dart';
import 'dart:async';

import '../services/interaction_idle_gate.dart';

class StartupRouteGate extends ChangeNotifier {
  bool _widgetLaunchPending = false;
  bool _startupWorkDeferred = false;
  final ChangeNotifier _redirectRefresh = ChangeNotifier();
  final Completer<void> _startupWorkAllowed = Completer<void>();

  /// Router refreshes only for gate state that can change redirect decisions.
  /// Startup deferral is observed by app services, but must not rebuild a
  /// Router while it is parsing/building the current route.
  Listenable get redirectRefreshListenable => _redirectRefresh;

  bool get widgetLaunchPending => _widgetLaunchPending;

  bool get suppressLoginRedirects => _widgetLaunchPending;

  /// 로그인/온보딩 중에는 비필수 초기화 작업을 미루기 위한 전역 게이트.
  bool get startupWorkDeferred => _startupWorkDeferred || _widgetLaunchPending;

  Future<void> get startupWorkAllowed => _startupWorkAllowed.future;

  /// Combines the onboarding permit with a settled interaction-idle window.
  /// Callers that do not defer startup resolve immediately but still honor
  /// active user interaction.
  Future<void> get startupWorkAllowedWhenIdle async {
    if (startupWorkDeferred) {
      await _startupWorkAllowed.future;
    }
    await InteractionIdleGate.instance.waitForStableIdle();
  }

  void beginWidgetLaunch() {
    if (_widgetLaunchPending) {
      return;
    }
    _widgetLaunchPending = true;
    _redirectRefresh.notifyListeners();
    notifyListeners();
  }

  void completeWidgetLaunch() {
    if (!_widgetLaunchPending) {
      return;
    }
    _widgetLaunchPending = false;
    _redirectRefresh.notifyListeners();
    notifyListeners();
  }

  void beginStartupWorkDeferral() {
    if (_startupWorkDeferred) {
      return;
    }
    _startupWorkDeferred = true;
    notifyListeners();
  }

  void completeStartupWorkDeferral() {
    if (!_startupWorkDeferred) {
      return;
    }
    _startupWorkDeferred = false;
    notifyListeners();
    if (!_startupWorkAllowed.isCompleted) _startupWorkAllowed.complete();
  }

  @override
  void dispose() {
    _redirectRefresh.dispose();
    super.dispose();
  }
}

final StartupRouteGate startupRouteGate = StartupRouteGate();
