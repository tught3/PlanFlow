import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/providers/auth_provider.dart';

/// Supplies the terminal guide state installed by the production root host to
/// router tests that mount ShellScreen without the application root.
class TestGuideScope extends StatefulWidget {
  const TestGuideScope({super.key, required this.auth, required this.child});

  final AuthProvider auth;
  final Widget child;

  @override
  State<TestGuideScope> createState() => _TestGuideScopeState();
}

class _TestGuideScopeState extends State<TestGuideScope> {
  late final _TestGuideCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    _coordinator = _TestGuideCoordinator(widget.auth.userId ?? 'signed-out');
    widget.auth.addListener(_syncIdentity);
  }

  @override
  void didUpdateWidget(TestGuideScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth != widget.auth) {
      oldWidget.auth.removeListener(_syncIdentity);
      widget.auth.addListener(_syncIdentity);
      _syncIdentity();
    }
  }

  void _syncIdentity() =>
      _coordinator.setUid(widget.auth.userId ?? 'signed-out');

  @override
  void dispose() {
    widget.auth.removeListener(_syncIdentity);
    _coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GuideScope(
        coordinator: _coordinator,
        child: widget.child,
      );
}

class _TestGuideCoordinator implements GuideCoordinator {
  _TestGuideCoordinator(String uid) : _state = ValueNotifier(_snapshot(uid));

  final ValueNotifier<GuideSnapshot> _state;

  static GuideSnapshot _snapshot(String uid) => GuideSnapshot(
        uid: uid,
        version: 'real_ui_v1',
        revision: 0,
        serverRevision: 0,
        step: GuideStep.skipped,
        run: GuideRun.terminal,
        calendarSyncHeld: true,
      );

  void setUid(String uid) {
    if (_state.value.uid != uid) _state.value = _snapshot(uid);
  }

  void dispose() => _state.dispose();

  @override
  ValueListenable<GuideSnapshot> get state => _state;

  @override
  Future<GuideSnapshot> start({required String uid}) async => _state.value;

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async => _state.value;

  @override
  void suspend(GuidePauseReason reason) {}

  @override
  Future<void> terminate(GuideExit exit) async {}

  @override
  Future<GuideAccess> authorize({
    required GuideChargeContext context,
    required String operationId,
  }) async =>
      const GuideAccess(
        status: GuideAccessStatus.denied,
        reasonCode: 'test_guide_terminal',
      );
}
