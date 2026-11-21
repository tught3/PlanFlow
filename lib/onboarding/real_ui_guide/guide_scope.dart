import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'guide_contract.dart';

class GuideScope extends InheritedNotifier<ValueListenable<GuideSnapshot>> {
  GuideScope({
    super.key,
    required this.coordinator,
    required super.child,
    this.allowBackSkip = false,
    this.registerSyncChoiceRoute,
  }) : super(notifier: coordinator.state);
  final GuideCoordinator coordinator;
  final bool allowBackSkip;
  final VoidCallback Function(ModalRoute<dynamic>)? registerSyncChoiceRoute;

  static GuideCoordinator? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GuideScope>()?.coordinator;

  static bool allowBackSkipOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<GuideScope>()?.allowBackSkip ??
      false;

  static bool isActiveBackSkippableOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GuideScope>();
    if (scope == null || !scope.allowBackSkip) return false;
    final snapshot = scope.coordinator.state.value;
    return snapshot.uid.isNotEmpty && snapshot.run != GuideRun.terminal;
  }

  bool skipActiveGuideOnBack(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<GuideScope>();
    if (!_canSkip(scope)) return false;
    unawaited(_terminateForBack(scope!.coordinator));
    return true;
  }

  Future<bool> skipActiveGuideOnBackAsync(BuildContext context) async {
    final scope = context.getInheritedWidgetOfExactType<GuideScope>();
    if (!_canSkip(scope)) return false;
    await _terminateForBack(scope!.coordinator);
    return true;
  }

  static bool _canSkip(GuideScope? scope) {
    if (scope == null || !scope.allowBackSkip) return false;
    final snapshot = scope.coordinator.state.value;
    return snapshot.uid.isNotEmpty && snapshot.run != GuideRun.terminal;
  }

  static Future<void> _terminateForBack(GuideCoordinator coordinator) async {
    try {
      await coordinator.terminate(GuideExit.skip);
    } catch (_) {
      // A Back action must still let the user leave if persistence fails.
    }
  }

  @override
  bool updateShouldNotify(covariant GuideScope oldWidget) =>
      coordinator != oldWidget.coordinator ||
      allowBackSkip != oldWidget.allowBackSkip ||
      registerSyncChoiceRoute != oldWidget.registerSyncChoiceRoute ||
      super.updateShouldNotify(oldWidget);
}

bool skipActiveGuideOnBack(BuildContext context) {
  final scope = context.getInheritedWidgetOfExactType<GuideScope>();
  if (scope == null) return false;
  return scope.skipActiveGuideOnBack(context);
}

Future<bool> skipActiveGuideOnBackAsync(BuildContext context) async {
  final scope = context.getInheritedWidgetOfExactType<GuideScope>();
  if (scope == null) return false;
  return scope.skipActiveGuideOnBackAsync(context);
}
