import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'guide_contract.dart';

class GuideScope extends InheritedNotifier<ValueListenable<GuideSnapshot>> {
  GuideScope({super.key, required this.coordinator, required super.child})
      : super(notifier: coordinator.state);
  final GuideCoordinator coordinator;
  static GuideCoordinator? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GuideScope>()?.coordinator;
  @override
  bool updateShouldNotify(covariant GuideScope oldWidget) =>
      coordinator != oldWidget.coordinator ||
      super.updateShouldNotify(oldWidget);
}
