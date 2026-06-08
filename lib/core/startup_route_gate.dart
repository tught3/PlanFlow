import 'package:flutter/foundation.dart';

class StartupRouteGate extends ChangeNotifier {
  bool _widgetLaunchPending = false;

  bool get widgetLaunchPending => _widgetLaunchPending;

  bool get suppressLoginRedirects => _widgetLaunchPending;

  void beginWidgetLaunch() {
    if (_widgetLaunchPending) {
      return;
    }
    _widgetLaunchPending = true;
    notifyListeners();
  }

  void completeWidgetLaunch() {
    if (!_widgetLaunchPending) {
      return;
    }
    _widgetLaunchPending = false;
    notifyListeners();
  }
}

final StartupRouteGate startupRouteGate = StartupRouteGate();
