import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Component-only synthetic ports. No PlanFlowApp/global client/native mount.
class _Guide implements GuideCoordinator {
  _Guide({String uid = '', this.wait, this.failFirst = false})
      : notifier = ValueNotifier(GuideSnapshot(
            uid: uid,
            version: 'real_ui_v1',
            revision: 0,
            serverRevision: 0,
            step: GuideStep.intro,
            run: GuideRun.terminal));
  final ValueNotifier<GuideSnapshot> notifier;
  final Completer<void>? wait;
  final bool failFirst;
  int starts = 0;
  int suspends = 0;
  @override
  ValueListenable<GuideSnapshot> get state => notifier;
  @override
  Future<GuideSnapshot> start({required String uid}) async {
    starts++;
    if (failFirst && starts == 1) throw StateError('synthetic start error');
    if (wait != null) await wait!.future;
    notifier.value = notifier.value.copyWith(
        uid: uid,
        step: GuideStep.homeMic,
        run: GuideRun.active,
        sessionId: 'synthetic-session',
        clearErrorCode: true);
    return notifier.value;
  }

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async => notifier.value;
  @override
  void suspend(GuidePauseReason reason) {
    suspends++;
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    startupRouteGate.closeGuideChoice('qa-one');
    startupRouteGate.closeGuideChoice('qa-two');
  });

  testWidgets('factory failure blocks actions until explicit session-only skip',
      (tester) async {
    int actions = 0;
    GuideCoordinator? seen;
    GuideCoordinator? provided;
    Widget tree(String uid) => ProviderScope(
          overrides: [
            realUiGuideCoordinatorProvider.overrideWith(
                (ref) => throw StateError('synthetic factory error'))
          ],
          child: MaterialApp(
              home: RootGuideScope(
            key: const ValueKey('root'),
            uid: uid,
            bindRuntime: (_) => Object(),
            unbindRuntime: (_) {},
            child: Consumer(builder: (context, ref, _) {
              seen = GuideScope.maybeOf(context);
              provided = seen == null
                  ? null
                  : ref.read(realUiGuideCoordinatorProvider);
              return Scaffold(
                  body: Align(
                      alignment: Alignment.topCenter,
                      child: TextButton(
                          key: const ValueKey('underlying-action'),
                          onPressed: () => actions++,
                          child: const Text('Underlying action'))));
            }),
          )),
        );
    await tester.pumpWidget(tree('qa-one'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('guide-session-skip')), findsOneWidget);
    await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('underlying-action'))));
    expect(actions, 0);
    await tester.tap(find.byKey(const ValueKey('guide-session-skip')));
    await tester.pump(const Duration(milliseconds: 1));
    expect(seen, isNotNull);
    expect(identical(seen, provided), isTrue);
    expect(seen!.state.value.uid, 'qa-one');
    expect(seen!.state.value.step, GuideStep.skipped);
    expect(seen!.state.value.run, GuideRun.terminal);
    expect(seen!.state.value.sessionId, isNull);
    expect(startupRouteGate.calendarSyncHeldFor('qa-one'), isTrue);
    final access = await seen!.authorize(
        context: const GuideChargeContext(
            uid: 'qa-one',
            version: 'real_ui_v1',
            sessionId: 'not-a-grant',
            kind: GuideChargeKind.scheduleParse,
            operation: GuideOperation.createParse,
            phase: GuideStep.homeMic,
            revision: 0,
            serverRevision: 0),
        operationId: 'no-grant');
    expect(access.status, GuideAccessStatus.denied);
    expect(access.permit, isNull);
    await tester.tap(find.byKey(const ValueKey('underlying-action')));
    expect(actions, 1); // Only after the explicit guide-skip gesture.
    await tester.pumpWidget(tree('qa-two'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('guide-session-skip')), findsOneWidget);
    expect(seen, isNull); // A second UID never inherits session-only skip.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'bind failure does not start backend and can be skipped without a grant',
      (tester) async {
    final guide = _Guide(uid: 'qa-one');
    GuideCoordinator? current;
    await tester.pumpWidget(ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(
          home: RootGuideScope(
        uid: 'qa-one',
        bindRuntime: (_) => throw StateError('synthetic bind error'),
        unbindRuntime: (_) {},
        child: Builder(builder: (context) {
          current = GuideScope.maybeOf(context);
          return const Scaffold(body: Text('Ready child'));
        }),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    expect(guide.starts, 0);
    await tester.tap(find.byKey(const ValueKey('guide-session-skip')));
    await tester.pump(const Duration(milliseconds: 1));
    expect(current!.state.value.step, GuideStep.skipped);
    expect(current!.state.value.uid, 'qa-one');
    expect(current!.state.value.sessionId, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'pending identity blocks controls without blocking startup future',
      (tester) async {
    final wait = Completer<void>();
    final guide = _Guide(wait: wait);
    int actions = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(
          home: RootGuideScope(
        uid: 'qa-one',
        bindRuntime: (_) => Object(),
        unbindRuntime: (_) {},
        child: Scaffold(
            body: Align(
                alignment: Alignment.topCenter,
                child: TextButton(
                    key: const ValueKey('underlying-action'),
                    onPressed: () => actions++,
                    child: const Text('Underlying action')))),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('guide-loading-barrier')), findsOneWidget);
    await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('underlying-action'))));
    expect(actions, 0);
    wait.complete();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('guide-loading-barrier')), findsNothing);
    expect(guide.state.value.uid, 'qa-one');
    await tester.tap(find.byKey(const ValueKey('underlying-action')));
    expect(actions, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'retry reuses the coordinator rather than orphaning same-UID work',
      (tester) async {
    final guide = _Guide(failFirst: true);
    int factories = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        realUiGuideCoordinatorProvider.overrideWith((ref) {
          factories++;
          return guide;
        })
      ],
      child: MaterialApp(
          home: RootGuideScope(
        uid: 'qa-one',
        bindRuntime: (_) => Object(),
        unbindRuntime: (_) {},
        child: const Scaffold(body: Text('Ready child')),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('guide-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(factories, 1);
    expect(guide.starts, 2);
    expect(guide.state.value.uid, 'qa-one');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'missing real target never advances and can be explicitly skipped',
      (tester) async {
    final guide = _Guide();
    await tester.pumpWidget(ProviderScope(
        overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
        child: MaterialApp(
            home: RootGuideScope(
                uid: 'qa-one',
                bindRuntime: (_) => Object(),
                unbindRuntime: (_) {},
                child: const Scaffold(body: Text('Real target absent'))))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(guide.state.value.step, GuideStep.homeMic);
    final skip = find.byKey(const ValueKey('guide-missing-target-skip'));
    expect(skip, findsOneWidget);
    await tester.tap(skip);
    await tester.pump(const Duration(milliseconds: 1));
    expect(guide.state.value.step, GuideStep.skipped);
    expect(guide.state.value.run, GuideRun.terminal);
    expect(guide.starts, 1);
    expect(skip, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
