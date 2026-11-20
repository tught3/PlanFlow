import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_coordinator.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:planflow/widgets/guided_coachmark_overlay.dart';

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

class _FailureGuide extends _Guide {
  _FailureGuide(this.failure, {this.terminal = false});
  final GuideFailureKind failure;
  final bool terminal;

  @override
  Future<GuideSnapshot> start({required String uid}) async {
    starts++;
    notifier.value = notifier.value.copyWith(
      uid: uid,
      run: terminal ? GuideRun.terminal : GuideRun.blocked,
      step: terminal ? GuideStep.completed : GuideStep.intro,
      failureDiagnostic: GuideFailureDiagnostic(failure),
    );
    return notifier.value;
  }
}

class _BindingConflictGuide extends _Guide {
  _BindingConflictGuide({this.conflictCode = 'created_binding_conflict'});
  final String conflictCode;

  @override
  Future<GuideSnapshot> start({required String uid}) async {
    starts++;
    notifier.value = notifier.value.copyWith(
      uid: uid,
      sessionId: 'original-session',
      run: GuideRun.blocked,
      failureDiagnostic: const GuideFailureDiagnostic(GuideFailureKind.timeout),
    );
    return notifier.value;
  }

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async {
    notifier.value = notifier.value.copyWith(
      run: GuideRun.blocked,
      errorCode: conflictCode,
    );
    return notifier.value;
  }
}

class _SaveFailureStore implements GuideProgressStore {
  int saves = 0;
  GuideSnapshot? value;
  final secondSave = Completer<void>();

  @override
  Future<GuideSnapshot?> load({required String uid, required String version}) async => value;

  @override
  Future<void> save(GuideSnapshot snapshot) async {
    saves++;
    if (saves == 2) throw StateError('synthetic persistence failure');
    if (saves == 4) await secondSave.future;
    value = snapshot;
  }
}

class _RetryBackend implements GuideBackendPort {
  int begins = 0;
  @override
  Future<GuideBeginResult> begin({required String uid, required String version,
      required String requestId}) async {
    begins++;
    if (begins == 1) {
      return const GuideBeginFailed(
        GuideFailureDiagnostic(GuideFailureKind.backendUnavailable),
      );
    }
    return const GuideBeginGranted(GuideBackendState(
      sessionId: 'synthetic-session', serverRevision: 1, step: GuideStep.intro,
    ));
  }

  @override
  Future<GuideBackendState> advance({required GuideSnapshot snapshot,
      required GuideBackendAction action, required String requestId,
      EventModel? event, DateTime? expectedStartLocal}) =>
      throw StateError('unexpected advance');

  @override
  Future<GuideAccess> authorize({required GuideChargeContext context,
      required String operationId}) => throw StateError('unexpected authorize');

  @override
  Future<void> finish({required GuideSnapshot snapshot, required GuideExit exit,
      required String requestId}) async {}
}

class _RetryGuide extends _Guide {
  _RetryGuide() : super(uid: 'qa-one');
  Completer<bool>? attempt;

  @override
  Future<GuideSnapshot> start({required String uid}) async {
    starts++;
    if (starts == 1) {
      notifier.value = notifier.value.copyWith(
          step: GuideStep.intro,
          run: GuideRun.blocked,
          errorCode: 'guide_operation_failed');
    } else {
      final success = await attempt!.future;
      if (success) {
        notifier.value = notifier.value.copyWith(
            run: GuideRun.active, clearErrorCode: true);
      }
    }
    return notifier.value;
  }
}

class _RewardGuide extends _Guide {
  _RewardGuide() : super(uid: 'qa-one') {
    notifier.value = notifier.value.copyWith(
      step: GuideStep.querySpeech,
      run: GuideRun.active,
      sessionId: 'replay-session',
      isReplay: true,
    );
  }

  int resumes = 0;

  @override
  void suspend(GuidePauseReason reason) {
    if (notifier.value.pauseReason == reason) return;
    notifier.value = notifier.value.copyWith(
      run: GuideRun.paused,
      revision: notifier.value.revision + 1,
      pauseReason: reason,
    );
  }

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async {
    if (signal is ResumeRequested) {
      resumes++;
      notifier.value = notifier.value.copyWith(
          run: GuideRun.active, revision: notifier.value.revision + 1);
    }
    return notifier.value;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    startupRouteGate.closeGuideChoice('qa-one');
    startupRouteGate.closeGuideChoice('qa-two');
  });

  testWidgets('earned replay reward waits across ad pause for one resume',
      (tester) async {
    final guide = _RewardGuide();
    final uid = ValueNotifier('qa-one');
    addTearDown(guide.notifier.dispose);
    addTearDown(uid.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final captured = guide.state.value;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    guide.suspend(GuidePauseReason.background);
    final reward = resumeGuideReplayAfterReward(
      coordinator: guide,
      captured: captured,
      stillOwnsScreen: () => uid.value == captured.uid,
      accountChanges: uid,
    );
    await tester.pump();
    expect(guide.resumes, 0);
    expect(guide.state.value.run, GuideRun.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(guide.resumes, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(await reward, same(guide.state.value));
    expect(guide.resumes, 1);
    expect(guide.state.value.revision, captured.revision + 2);
    expect(guide.state.value.step, captured.step);
    expect(
      await resumeGuideReplayAfterReward(
        coordinator: guide,
        captured: captured,
        stillOwnsScreen: () => uid.value == captured.uid,
        accountChanges: uid,
      ),
      isNull,
    );
    expect(guide.resumes, 1);
  });

  testWidgets('account or phase change invalidates earned replay reward',
      (tester) async {
    for (final changeAccount in [true, false]) {
      final guide = _RewardGuide();
      final uid = ValueNotifier('qa-one');
      addTearDown(guide.notifier.dispose);
      addTearDown(uid.dispose);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final captured = guide.state.value;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      guide.suspend(GuidePauseReason.background);
      final reward = resumeGuideReplayAfterReward(
        coordinator: guide,
        captured: captured,
        stillOwnsScreen: () => uid.value == captured.uid,
        accountChanges: uid,
      );
      if (changeAccount) {
        uid.value = 'qa-two';
        uid.value = captured.uid;
      } else {
        guide.notifier.value = guide.state.value.copyWith(
            step: GuideStep.changeSpeech,
            revision: guide.state.value.revision + 1);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(await reward, isNull);
      expect(guide.resumes, 0);
    }
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
  testWidgets('retry after a failed progress save starts again and waits for persistence',
      (tester) async {
    final backend = _RetryBackend();
    final store = _SaveFailureStore();
    final guide = RealUiGuideCoordinator(
        backend: backend, progress: store, version: 'real_ui_v1');
    await tester.pumpWidget(ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(home: RootGuideScope(
        uid: 'qa-one', bindRuntime: (_) => Object(), unbindRuntime: (_) {},
        child: const Scaffold(body: Text('Ready child')),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    expect(backend.begins, 1);
    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pump();
    expect(backend.begins, 2);
    expect(store.saves, 3);
    expect(guide.state.value.failureDiagnostic?.kind, GuideFailureKind.progressSaveFailed);
    expect(find.textContaining('안내 진행 상태를 저장하지 못했어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pump();
    expect(backend.begins, 3);
    expect(store.saves, 4);
    expect(find.byKey(const ValueKey('guide-retry-progress')), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('guide-retry'))).onPressed, isNull);
    store.secondSave.complete();
    await tester.pump();
    expect(store.value, isNotNull);
    expect(guide.state.value.run, GuideRun.active);
    expect(find.byKey(const ValueKey('guide-retry')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fatal retry shows single-flight progress while start is pending',
      (tester) async {
    final wait = Completer<void>();
    final guide = _Guide(failFirst: true, wait: wait);
    await tester.pumpWidget(ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(home: RootGuideScope(
        uid: 'qa-one', bindRuntime: (_) => Object(), unbindRuntime: (_) {},
        child: const Scaffold(body: Text('Ready child')),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    expect(guide.starts, 1);
    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pump(const Duration(milliseconds: 1));
    expect(guide.starts, 2);
    expect(find.byKey(const ValueKey('guide-retry-progress')), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('guide-retry'))).onPressed, isNull);
    wait.complete();
    await tester.pump();
    expect(guide.starts, 2);
    expect(find.byKey(const ValueKey('guide-retry')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('QA recovery account switch is single flight and can retry',
      (tester) async {
    final guide = _Guide(failFirst: true);
    final uid = ValueNotifier<String?>('qa-one');
    var attempt = Completer<void>();
    final switchedAccounts = <String>[];
    addTearDown(guide.notifier.dispose);
    addTearDown(uid.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(home: ValueListenableBuilder<String?>(
        valueListenable: uid,
        builder: (_, account, __) => RootGuideScope(
          uid: account,
          bindRuntime: (_) => Object(),
          unbindRuntime: (_) {},
          onSwitchQaAccount: (account) {
            switchedAccounts.add(account);
            return attempt.future;
          },
          child: const Scaffold(body: Text('Ready child')),
        ),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    final switchAccount = find.byKey(const ValueKey('guide-switch-qa-account'));
    final retry = find.byKey(const ValueKey('guide-retry'));
    final skip = find.byKey(const ValueKey('guide-session-skip'));

    await tester.tap(switchAccount);
    // A second tap can arrive before Flutter rebuilds the disabled buttons.
    await tester.tap(switchAccount);
    await tester.pump();
    expect(switchedAccounts, ['qa-one']);
    for (final action in [switchAccount, retry, skip]) {
      expect(tester.widget<TextButton>(action).onPressed, isNull);
    }

    attempt.completeError(StateError('synthetic failure'));
    await tester.pump();
    expect(find.textContaining('계정을 바꾸지 못했어요'), findsOneWidget);
    expect(tester.widget<TextButton>(switchAccount).onPressed, isNotNull);
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);

    attempt = Completer<void>();
    await tester.tap(switchAccount);
    await tester.pump();
    uid.value = null;
    await tester.pump();
    attempt.completeError(StateError('stale synthetic failure'));
    await tester.pump();
    expect(switchedAccounts, ['qa-one', 'qa-one']);
    expect(switchAccount, findsNothing);
    expect(find.textContaining('계정을 바꾸지 못했어요'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retry shows progress, suppresses duplicate taps and can recover',
      (tester) async {
    final guide = _RetryGuide();
    addTearDown(guide.notifier.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(home: RootGuideScope(
        uid: 'qa-one',
        bindRuntime: (_) => Object(),
        unbindRuntime: (_) {},
        child: const Scaffold(body: Text('Ready child')),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('guide-switch-qa-account')), findsNothing);
    guide.attempt = Completer<bool>();
    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pump();
    expect(find.byKey(const ValueKey('guide-retry-progress')), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('guide-retry'))).onPressed, isNull);
    expect(guide.starts, 2);
    guide.attempt!.complete(false);
    await tester.pump();
    expect(find.textContaining('안내를 이어가지 못했어요'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('guide-retry'))).onPressed, isNotNull);
    guide.attempt = Completer<bool>();
    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pump();
    expect(guide.starts, 3);
    guide.attempt!.complete(true);
    await tester.pump();
    expect(find.byKey(const ValueKey('guide-retry')), findsNothing);
    expect(guide.state.value.run, GuideRun.active);
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

  testWidgets('QA recovery explains safe cause, offers account switch and hides skip',
      (tester) async {
    for (final entry in <(GuideFailureKind, String)>[
      (GuideFailureKind.localUidMismatch, '로그인 정보를 확인할 수 없어요'),
      (GuideFailureKind.authError, '로그인 정보를 확인할 수 없어요'),
      (GuideFailureKind.timeout, '안내 연결 시간이 초과됐어요'),
      (GuideFailureKind.network, '안내 서버에 연결하지 못했어요'),
      (GuideFailureKind.terminal, '이 안내는 다시 시작해야 해요'),
      (GuideFailureKind.expired, '이 안내는 다시 시작해야 해요'),
      (GuideFailureKind.boundEventMissing, '이 안내는 다시 시작해야 해요'),
      (GuideFailureKind.progressSaveFailed, '안내 진행 상태를 저장하지 못했어요'),
    ]) {
      final guide = _FailureGuide(entry.$1);
      var switched = 0;
      await tester.pumpWidget(ProviderScope(
          overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
          child: MaterialApp(home: RootGuideScope(
            uid: 'qa-one', isGuideQa: true,
            bindRuntime: (_) => Object(), unbindRuntime: (_) {},
            onSwitchQaAccount: (_) async { switched++; },
            child: const Scaffold(body: Text('underlying')),
          ))));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.textContaining(entry.$2), findsOneWidget);
      expect(find.text('안내 오류 코드: ${entry.$1.code}'), findsOneWidget);
      expect(find.byKey(const ValueKey('guide-skip')), findsNothing);
      expect(find.byKey(const ValueKey('guide-session-skip')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('guide-switch-qa-account')));
      await tester.pump();
      expect(switched, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('QA retry shows current binding conflict and keeps controls blocked',
      (tester) async {
    final guide = _BindingConflictGuide();
    var actions = 0;
    await tester.pumpWidget(ProviderScope(
        overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
        child: MaterialApp(home: RootGuideScope(
          uid: 'qa-one', isGuideQa: true,
          bindRuntime: (_) => Object(), unbindRuntime: (_) {},
          child: Scaffold(body: Align(
            alignment: Alignment.topCenter,
            child: TextButton(
              key: const ValueKey('conflict-underlying-action'),
              onPressed: () => actions++, child: const Text('underlying'),
            ),
          )),
        ))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.textContaining('안내 연결 시간이 초과됐어요'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pump();
    expect(find.textContaining('저장된 일정과 안내의 연결 정보가 일치하지 않아요'),
        findsOneWidget);
    expect(find.text('안내 오류 코드: created_binding_conflict'), findsOneWidget);
    expect(find.textContaining('안내 연결 시간이 초과됐어요'), findsNothing);
    expect(guide.state.value.failureDiagnostic?.kind, GuideFailureKind.timeout);
    expect(find.byKey(const ValueKey('guide-skip')), findsNothing);
    await tester.tapAt(tester.getCenter(
        find.byKey(const ValueKey('conflict-underlying-action'))));
    expect(actions, 0);
    expect(guide.state.value.sessionId, 'original-session');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('session and missing event blocks take precedence over timeout',
      (tester) async {
    for (final entry in [
      ('guide_session_changed', '로그인 상태가 바뀌었어요'),
      ('guide_bound_event_missing', '이 안내는 다시 시작해야 해요'),
    ]) {
      final guide = _BindingConflictGuide(conflictCode: entry.$1);
      await tester.pumpWidget(ProviderScope(
          overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
          child: MaterialApp(home: RootGuideScope(
            uid: 'qa-one', isGuideQa: true,
            bindRuntime: (_) => Object(), unbindRuntime: (_) {},
            child: const Scaffold(body: Text('underlying')),
          ))));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.tap(find.byKey(const ValueKey('guide-retry')));
      await tester.pump();
      expect(find.textContaining(entry.$2), findsOneWidget);
      expect(find.text('안내 오류 코드: ${entry.$1}'), findsOneWidget);
      expect(find.textContaining('안내 연결 시간이 초과됐어요'), findsNothing);
      expect(guide.state.value.failureDiagnostic?.kind, GuideFailureKind.timeout);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('QA missing target hides skip and terminal notice leaves settings reachable',
      (tester) async {
    final guide = _Guide();
    await tester.pumpWidget(ProviderScope(
        overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
        child: MaterialApp(home: RootGuideScope(
          uid: 'qa-one', isGuideQa: true,
          bindRuntime: (_) => Object(), unbindRuntime: (_) {},
          child: const Scaffold(body: Text('target absent')),
        ))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('guide-missing-target-skip')), findsNothing);
    expect(find.text('안내 건너뛰기'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    final terminal = _FailureGuide(GuideFailureKind.terminal, terminal: true);
    var actions = 0;
    await tester.pumpWidget(ProviderScope(
        overrides: [realUiGuideCoordinatorProvider.overrideWithValue(terminal)],
        child: MaterialApp(home: RootGuideScope(
          uid: 'qa-one', isGuideQa: true,
          bindRuntime: (_) => Object(), unbindRuntime: (_) {},
          child: Scaffold(body: TextButton(
            key: const ValueKey('terminal-settings'),
            onPressed: () => actions++, child: const Text('설정'),
          )),
        ))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('안내 오류 코드: terminal'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-settings')));
    expect(actions, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('production recovery does not reveal QA code or account switch',
      (tester) async {
    final guide = _FailureGuide(GuideFailureKind.authError);
    await tester.pumpWidget(ProviderScope(
        overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
        child: MaterialApp(home: RootGuideScope(
          uid: 'qa-one', bindRuntime: (_) => Object(), unbindRuntime: (_) {},
          child: const Scaffold(body: Text('underlying')),
        ))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.textContaining('로그인 정보를 확인할 수 없어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-failure-code')), findsNothing);
    expect(find.byKey(const ValueKey('guide-switch-qa-account')), findsNothing);
    expect(find.byKey(const ValueKey('guide-skip')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });


  testWidgets('coachmark with no skip callback omits skip with or without target',
      (tester) async {
    for (final showTarget in [false, true]) {
      final registry = GuidedAnchorRegistry();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [
        if (showTarget)
          GuidedAnchor(id: 'target', registry: registry,
              child: const SizedBox(width: 80, height: 80)),
        GuidedCoachmarkOverlay(
          registry: registry, targetId: 'target',
          bubble: const Text('안내'), progressLabel: '1/7', onSkip: null,
        ),
      ]))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('안내 건너뛰기'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });


  testWidgets('QA account confirmation can receive input above recovery overlay',
      (tester) async {
    final guide = _FailureGuide(GuideFailureKind.localUidMismatch);
    final navigatorKey = GlobalKey<NavigatorState>();
    var underlyingActions = 0;
    var confirmed = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide)],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => RootGuideScope(
          uid: 'qa-one', isGuideQa: true,
          bindRuntime: (_) => Object(), unbindRuntime: (_) {},
          onSwitchQaAccount: (_) async {
            confirmed = await showDialog<bool>(
                  context: navigatorKey.currentContext!,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('계정 확인'),
                    actions: [TextButton(
                      key: const ValueKey('confirm-account-switch'),
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('확인'),
                    )],
                  ),
                ) ??
                false;
          },
          child: child!,
        ),
        home: Scaffold(body: TextButton(
          key: const ValueKey('underlying-switch-test'),
          onPressed: () => underlyingActions++, child: const Text('원래 화면'),
        )),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.tap(find.byKey(const ValueKey('guide-switch-qa-account')));
    await tester.pumpAndSettle();
    expect(find.text('계정 확인'), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-skip')), findsNothing);
    expect(find.byKey(const ValueKey('confirm-account-switch')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-account-switch')));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
    expect(underlyingActions, 0);
    expect(find.byKey(const ValueKey('guide-skip')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

}
