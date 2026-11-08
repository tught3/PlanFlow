import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Component-only synthetic ports: the real RootGuideScope widget with a fake
// coordinator. suspend() mirrors GuideCoordinator.suspend (run=paused,
// revision+1, mayListenContinuously=false) so a wrongly-triggered pause shows
// up in state, not only in a counter.
class _RecordingGuide implements GuideCoordinator {
  _RecordingGuide()
      : notifier = ValueNotifier(const GuideSnapshot(
            uid: '',
            version: 'real_ui_v1',
            revision: 9,
            serverRevision: 9,
            step: GuideStep.intro,
            run: GuideRun.terminal));
  final ValueNotifier<GuideSnapshot> notifier;
  final GuideStep startStep = GuideStep.createSpeech;
  int starts = 0;
  int suspends = 0;
  int dispatches = 0;
  final List<GuidePauseReason> reasons = <GuidePauseReason>[];

  @override
  ValueListenable<GuideSnapshot> get state => notifier;

  @override
  Future<GuideSnapshot> start({required String uid}) async {
    starts++;
    notifier.value = notifier.value.copyWith(
        uid: uid,
        step: startStep,
        run: GuideRun.active,
        revision: 10,
        sessionId: 'synthetic-session',
        clearErrorCode: true);
    return notifier.value;
  }

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async {
    dispatches++;
    return notifier.value;
  }

  @override
  void suspend(GuidePauseReason reason) {
    suspends++;
    reasons.add(reason);
    final s = notifier.value;
    if (s.run == GuideRun.terminal) return;
    notifier.value = s.copyWith(
        run: GuideRun.paused,
        mayListenContinuously: false,
        revision: s.revision + 1);
  }

  @override
  Future<void> terminate(GuideExit exit) async {
    notifier.value = notifier.value.copyWith(
        step: GuideStep.skipped,
        run: GuideRun.terminal,
        mayListenContinuously: false);
  }

  @override
  Future<GuideAccess> authorize(
          {required GuideChargeContext context,
          required String operationId}) async =>
      const GuideAccess(status: GuideAccessStatus.denied);
}

const String kUid = 'qa-lifecycle';

Widget _tree(_RecordingGuide guide, {Widget? child}) => ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(
          home: RootGuideScope(
        uid: kUid,
        bindRuntime: (_) => Object(),
        unbindRuntime: (_) {},
        child: child ?? const Scaffold(body: Text('Ready child')),
      )),
    );

Widget _child(void Function() onAction) => Scaffold(
        body: Align(
            alignment: Alignment.topCenter,
            child: TextButton(
                key: const ValueKey('underlying-action'),
                onPressed: onAction,
                child: const Text('Underlying action'))));

/// Emits a real lifecycle transition through the binding observer path.
Future<void> _emit(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await tester.pump();
}

/// Mounts the scope, waits for the coordinator to start, and lands on the
/// device-reported repro shape: active createSpeech, revision 10, no error.
Future<void> _startActive(WidgetTester tester, _RecordingGuide guide) async {
  await tester.pumpWidget(_tree(guide));
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump(const Duration(milliseconds: 1));
  expect(guide.state.value.run, GuideRun.active);
  expect(guide.state.value.step, GuideStep.createSpeech);
  expect(guide.state.value.revision, 10);
  expect(guide.state.value.errorCode, isNull);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(() {
    // The binding stops scheduling frames outside resumed/inactive, so the
    // lifecycle must be restored or a later test would render a stale tree.
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    startupRouteGate.closeGuideChoice(kUid);
  });

  testWidgets(
      'permission-dialog inactive keeps an active createSpeech guide running',
      (tester) async {
    var actions = 0;
    final guide = _RecordingGuide();
    await _startActive(tester, guide);

    await _emit(tester, AppLifecycleState.inactive);

    expect(guide.suspends, 0, reason: 'inactive must never pause the guide');
    expect(guide.reasons, isEmpty);
    expect(guide.dispatches, 0, reason: 'inactive must not emit any signal');
    expect(guide.state.value.run, GuideRun.active);
    expect(guide.state.value.run, isNot(GuideRun.paused));
    expect(guide.state.value.step, GuideStep.createSpeech);
    expect(guide.state.value.revision, 10);
    expect(guide.state.value.errorCode, isNull);
    expect(guide.state.value.sessionId, 'synthetic-session');
    // The active run keeps rendering without the recovery barrier, so the
    // speech action underneath stays reachable while the OS dialog is up.
    expect(find.byKey(const ValueKey('guide-retry')), findsNothing);
    expect(find.byKey(const ValueKey('guide-skip')), findsNothing);
    await tester.pumpWidget(_tree(guide, child: _child(() => actions++)));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.tap(find.byKey(const ValueKey('underlying-action')));
    expect(actions, 1, reason: 'permission overlay must not block the action');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final state in <AppLifecycleState>[
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached
  ]) {
    testWidgets('true background state $state still fails closed',
        (tester) async {
      final guide = _RecordingGuide();
      await _startActive(tester, guide);

      await _emit(tester, state);

      expect(guide.suspends, greaterThanOrEqualTo(1));
      expect(guide.reasons, contains(GuidePauseReason.background));
      expect(guide.state.value.run, GuideRun.paused);
      expect(guide.state.value.mayListenContinuously, isFalse);
      expect(guide.state.value.step, GuideStep.createSpeech);
      expect(guide.dispatches, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('resumed never auto-resumes a paused guide', (tester) async {
    final guide = _RecordingGuide();
    await _startActive(tester, guide);

    await _emit(tester, AppLifecycleState.hidden);
    expect(guide.state.value.run, GuideRun.paused);
    final suspendedOnce = guide.suspends;

    await _emit(tester, AppLifecycleState.resumed);

    expect(guide.state.value.run, GuideRun.paused,
        reason: 'resume must not restart the guide on its own');
    expect(guide.dispatches, 0, reason: 'resume must not emit a signal');
    expect(guide.suspends, suspendedOnce,
        reason: 'resumed must not suspend again either');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('true background pause keeps the existing recovery barrier',
      (tester) async {
    var actions = 0;
    final guide = _RecordingGuide();
    await tester.pumpWidget(_tree(guide, child: _child(() => actions++)));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(guide.state.value.run, GuideRun.active);
    expect(find.byKey(const ValueKey('guide-retry')), findsNothing);

    await _emit(tester, AppLifecycleState.hidden);
    expect(guide.state.value.run, GuideRun.paused);
    // Returning to the foreground replays the pending frame, so a paused guide
    // must still present the same explicit recovery contract.
    await _emit(tester, AppLifecycleState.resumed);

    expect(guide.state.value.run, GuideRun.paused);
    expect(find.byKey(const ValueKey('guide-retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-skip')), findsOneWidget);
    expect(
        find.text('안내가 잠시 멈췄어요. 다시 시도하거나 건너뛸 수 있어요.'),
        findsOneWidget);
    await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('underlying-action'))));
    expect(actions, 0, reason: 'paused guide must keep blocking actions');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}