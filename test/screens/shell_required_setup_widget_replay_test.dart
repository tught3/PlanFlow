// Real-Shell regression for the widget startup -> required onboarding -> HOME
// -> widget replay goal. Pumps the production router (createAppRouter) with
// the real ShellScreen, a real AuthProvider and a real StartupRouteGate. The
// test NEVER calls gate.beginRequiredSetup/completeRequiredSetup: required
// setup evidence must come from the Shell's actual signed-in decision.
//
// Mocks: in-memory SharedPreferences (legacy + async), in-memory
// FeatureTourStore, placeholder Supabase (AppEnv not marked ready, so no
// backend I/O). The voice target uses a simulated arrival (no VoiceInputScreen,
// no microphone/STT); the calendar target navigates the real router.
// The coordinator is wired like _PlanFlowAppState (readiness resolver, wake
// signal, hold release policy) but _PlanFlowAppState itself is not pumped.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/app.dart'
    show
        currentAppRouterLocation,
        resolveAppHomeWidgetReadiness,
        shouldReleaseWidgetHoldAwaitingRequiredSetup,
        shouldSeedHomeBaseForHomeWidgetRoute;
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/home_widget_route_coordinator.dart';
import 'package:planflow/core/router.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart'
    show GuideSyncChoiceStore, RootGuideScope;
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/onboarding/legacy_intro_screen.dart';
import 'package:planflow/screens/onboarding/permission_onboarding_screen.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:planflow/services/external_calendar_sync_guide_service.dart';
import 'package:planflow/services/feature_tour_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/test_guide_scope.dart';

const _calendarTarget = '/calendar?date=2026-10-14';
const _voiceTarget = '/voice?autoStart=1';

/// Each shouldShow() call gets its own controllable answer so stale and
/// current flows can be resolved independently.
class _QueuedTourStore extends FeatureTourStore {
  _QueuedTourStore({this.autoAnswer});

  bool? autoAnswer;
  bool completed = false;
  final List<Completer<bool>> calls = <Completer<bool>>[];

  @override
  Future<bool> shouldShow() {
    if (autoAnswer != null) {
      return Future<bool>.value(autoAnswer! && !completed);
    }
    final c = Completer<bool>();
    calls.add(c);
    return c.future;
  }

  @override
  Future<void> markCompleted() async {
    completed = true;
    autoAnswer = false;
  }

  @override
  Future<bool> shouldShowTip(String tipId) async => false;

  @override
  Future<void> markTipShown(String tipId) async {}
}

class _Harness {
  _Harness(this.auth, this.gate, this.router, this.coordinator, this.store);
  final AuthProvider auth;
  final StartupRouteGate gate;
  final GoRouter router;
  final HomeWidgetRouteCoordinator coordinator;
  final _QueuedTourStore store;
  final List<String> navigations = <String>[];
  final List<String> consumed = <String>[];
  final List<HomeWidgetRouteOutcome> terminals = <HomeWidgetRouteOutcome>[];
  Uri? simulatedVoiceUri;
  bool? seedHomeBase;

  Uri get currentUri => simulatedVoiceUri ?? currentAppRouterLocation(router);
  HomeWidgetRouteReadiness get readiness => resolveAppHomeWidgetReadiness(
      auth: auth, gate: gate, supabaseReady: true);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required String? user,
  required _QueuedTourStore store,
  GuideCoordinator? guide,
  bool allowBackSkip = false,
  bool mountRootGuide = false,
}) async {
  final auth = AuthProvider()..start();
  if (user != null) auth.setUser(user);
  final gate = StartupRouteGate();
  final prefs = await SharedPreferences.getInstance();
  final syncChoice = GuideSyncChoiceStore();
  // RootGuideScope normally restores this gate when a terminal guide is
  // mounted. This fixture supplies the same per-account state for its router.
  void restoreGuideChoice() {
    final uid = auth.userId;
    if (uid == null) return;
    gate.beginGuideChoice(uid);
    if (prefs.getBool(syncChoice.key(uid)) == true) gate.closeGuideChoice(uid);
  }

  restoreGuideChoice();
  auth.addListener(restoreGuideChoice);
  final router = createAppRouter(
    authProviderOverride: auth,
    startupRouteGateOverride: gate,
    featureTourStore: store,
    runShellStartupTasks: false,
    supabaseReadyOverride: true,
  );
  late final _Harness h;
  final coordinator = HomeWidgetRouteCoordinator(
    readinessResolver: () => h.readiness,
    wakeSignal: Listenable.merge(<Listenable>[auth, gate]),
    currentUri: () => h.currentUri,
    // Mirrors _PlanFlowAppState._navigatePendingHomeWidgetRoute: seed HOME
    // on an empty stack, navigate first, then raise the widget hold.
    navigate: (route) {
      h.navigations.add(route);
      if (Uri.parse(route).path == AppRoutes.voice) {
        h.simulatedVoiceUri = Uri.parse(route); // no real mic screen
      } else if (h.seedHomeBase ??= shouldSeedHomeBaseForHomeWidgetRoute(
          route: route, canPop: router.canPop())) {
        router.go(AppRoutes.home);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (h.coordinator.pendingRoute == route) router.push(route);
        });
      } else {
        router.push(route);
      }
      gate.beginWidgetLaunch();
    },
    consume: (route) async => h.consumed.add(route),
    onDeferred: (route, readiness) {
      scheduleMicrotask(() {
        if (shouldReleaseWidgetHoldAwaitingRequiredSetup(
          readiness: h.readiness,
          auth: auth,
          gate: gate,
          supabaseReady: true,
        )) {
          gate.completeWidgetLaunch();
        }
      });
    },
    onTerminal: (route, outcome) {
      h.terminals.add(outcome);
      if (outcome != HomeWidgetRouteOutcome.cancelled) {
        gate.completeWidgetLaunch();
      }
    },
    readinessTimeout: const Duration(milliseconds: 300),
    // Production arrival budget (_PlanFlowAppState: 10 x 120ms).
    arrivalCheckInterval: const Duration(milliseconds: 120),
    arrivalMaxAttempts: 10,
    retainedRetryDelay: const Duration(milliseconds: 50),
    maxNavigationCycles: 2,
  );
  h = _Harness(auth, gate, router, coordinator, store);
  router.routeInformationProvider
      .addListener(coordinator.notifyLocationChanged);
  router.routerDelegate.addListener(coordinator.notifyLocationChanged);
  addTearDown(() {
    router.routeInformationProvider
        .removeListener(coordinator.notifyLocationChanged);
    router.routerDelegate.removeListener(coordinator.notifyLocationChanged);
    coordinator.dispose();
    router.dispose();
    auth.removeListener(restoreGuideChoice);
    gate.dispose();
    auth.dispose();
  });
  final app = MaterialApp.router(
    routerConfig: router,
    builder: !mountRootGuide
        ? null
        : (_, child) => RootGuideScope(
              uid: user,
              router: router,
              backButtonDispatcher: router.backButtonDispatcher,
              isGuideQa: !allowBackSkip,
              bindRuntime: (_) => Object(),
              unbindRuntime: (_) {},
              child: child!,
            ),
    locale: const Locale('ko', 'KR'),
    supportedLocales: const <Locale>[Locale('ko', 'KR'), Locale('en', 'US')],
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
  );
  await tester.pumpWidget(mountRootGuide
      ? ProviderScope(
          overrides: [realUiGuideCoordinatorProvider.overrideWithValue(guide!)],
          child: app,
        )
      : guide == null
          ? TestGuideScope(auth: auth, child: app)
          : GuideScope(
              coordinator: guide,
              allowBackSkip: allowBackSkip,
              child: app,
            ));
  return h;
}

class _CompletingGuide with WidgetsBindingObserver implements GuideCoordinator {
  _CompletingGuide({
    this.failCompletionSaveOnce = false,
    this.failCompletionResumeOnce = false,
    this.delayedCompletionSave,
  }) : state = ValueNotifier(const GuideSnapshot(
          uid: 'a',
          version: 'real_ui_v1',
          revision: 1,
          serverRevision: 1,
          sessionId: 'guide-session',
          createdEventId: 'updated',
          step: GuideStep.updatedDetail,
          run: GuideRun.active,
        ));

  @override
  final ValueNotifier<GuideSnapshot> state;
  final confirmations = <GuideCompletionConfirmed>[];
  final syncChoices = <SyncChoiceClosed>[];
  final exits = <GuideExit>[];
  int resumes = 0;
  bool failCompletionSaveOnce;
  bool failCompletionResumeOnce;
  Completer<void>? delayedCompletionSave;

  @override
  Future<GuideSnapshot> start({required String uid}) async => state.value;

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async {
    final current = state.value;
    if (signal.uid != current.uid ||
        signal.sessionId != current.sessionId ||
        signal.expectedRevision != current.revision) {
      return current;
    }
    if (signal is ResumeRequested &&
        (current.run == GuideRun.paused ||
            (current.step == GuideStep.completionConfirm &&
                current.run == GuideRun.blocked))) {
      resumes++;
      if (failCompletionResumeOnce) {
        failCompletionResumeOnce = false;
        return state.value = current.copyWith(
          run: GuideRun.blocked,
          revision: current.revision + 1,
          failureDiagnostic:
              const GuideFailureDiagnostic(GuideFailureKind.network),
        );
      }
      state.value = current.copyWith(
        run: GuideRun.active,
        revision: current.revision + 1,
        clearErrorCode: true,
        clearFailureDiagnostic: true,
      );
    }
    if (signal is GuideCompletionConfirmed &&
        current.step == GuideStep.completionConfirm &&
        current.run == GuideRun.active) {
      confirmations.add(signal);
      final pending = delayedCompletionSave;
      if (pending != null) {
        delayedCompletionSave = null;
        await pending.future;
        if (!identical(state.value, current)) return state.value;
      }
      if (failCompletionSaveOnce) {
        failCompletionSaveOnce = false;
        state.value = current.copyWith(
          run: GuideRun.blocked,
          revision: current.revision + 1,
          failureDiagnostic:
              const GuideFailureDiagnostic(GuideFailureKind.progressSaveFailed),
        );
        return state.value;
      }
      state.value = current.copyWith(
        step: GuideStep.syncChoiceConfirmed,
        revision: current.revision + 1,
      );
    }
    if (signal is SyncChoiceClosed) {
      syncChoices.add(signal);
      if (current.step == GuideStep.syncChoiceConfirmed &&
          current.run == GuideRun.active) {
        state.value =
            current.copyWith(step: GuideStep.completed, run: GuideRun.terminal);
      }
    }
    return state.value;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused) {
      suspend(GuidePauseReason.background);
    }
  }

  @override
  void suspend(GuidePauseReason reason) {
    final current = state.value;
    if (current.run == GuideRun.active) {
      state.value = current.copyWith(
          run: GuideRun.paused,
          pauseReason: reason,
          revision: current.revision + 1);
    }
  }

  @override
  Future<void> terminate(GuideExit exit) async {
    exits.add(exit);
    state.value = state.value.copyWith(
      run: GuideRun.terminal,
      step: GuideStep.skipped,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _observeCompletingGuide(WidgetTester tester, _CompletingGuide guide) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.binding.addObserver(guide);
  addTearDown(() => tester.binding.removeObserver(guide));
}

void _backgroundApp(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _foregroundApp(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

/// Mirrors _handleHomeWidgetUri: hold first, then submit the pending target.
void _submitWidgetLaunch(_Harness h, String target) {
  h.gate.beginWidgetLaunch();
  unawaited(h.coordinator.submitRoute(target));
}

Future<void> _pumpFor(WidgetTester tester, int frames,
    [Duration step = const Duration(milliseconds: 50)]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition,
    {int max = 60}) async {
  for (var i = 0; i < max && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Complete the intro through the same three page controls as the app.
Future<void> _finishRequiredTour(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('legacy-intro-skip-button')), findsNothing);
  final next = find.byKey(const ValueKey('legacy-intro-next-button'));
  for (var page = 0; page < 3; page++) {
    await tester.tap(next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    try {
      Supabase.instance.client;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://example.com',
        anonKey: 'public-anon-key',
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
      );
    }
  });

  void seedPrefs({Set<String> closedGuideChoices = const {'a', 'b'}}) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExternalCalendarSyncGuideService.guideSeenKey('a'): true,
      ExternalCalendarSyncGuideService.guideSeenKey('b'): true,
      for (final uid in closedGuideChoices)
        GuideSyncChoiceStore().key(uid): true,
    });
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  }

  setUp(ShellScreen.resetSessionOnboardingStateForTest);
  tearDown(() {
    ShellScreen.resetSessionOnboardingStateForTest();
    SharedPreferencesAsyncPlatform.instance = null;
  });

  for (final settings in [false, true]) {
    testWidgets(
        'Home shows completion before sync and then ${settings ? "Settings" : "normal use"}',
        (tester) async {
      // Both the ordinary sync prompt and an earlier choice were seen.
      seedPrefs();
      final guide = _CompletingGuide();
      addTearDown(guide.state.dispose);
      final h = await _pump(tester,
          user: 'a', store: _QueuedTourStore(autoAnswer: false), guide: guide);
      await _pumpUntil(
          tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
      final detail = '${AppRoutes.eventDetail}/updated';
      h.router
          .go(detail); // 6/7 save replaces the previous shell in production.
      await _pumpUntil(tester, () => h.currentUri.path == detail);
      expect(h.currentUri.path, detail);
      await _pumpFor(tester, 10); // Finish the underlying route transition.

      guide.state.value =
          guide.state.value.copyWith(step: GuideStep.completionConfirm);
      h.router.go(AppRoutes.home);
      const completion = '모든 튜토리얼이 끝났습니다. 이제 자유롭게 사용해보세요.';
      final sync = find.text('외부 캘린더 동기화 안내');
      await _pumpUntil(
          tester, () => find.text(completion).evaluate().isNotEmpty);
      expect(h.currentUri.path, AppRoutes.home);
      expect(guide.state.value.step, GuideStep.completionConfirm);
      expect(sync, findsNothing);
      expect(guide.syncChoices, isEmpty);
      await _pumpFor(tester, 10);
      await tester.tap(find.descendant(
        of: find.widgetWithText(AlertDialog, '튜토리얼 완료'),
        matching: find.widgetWithText(FilledButton, '확인'),
      ));
      await _pumpUntil(tester, () => sync.evaluate().isNotEmpty);
      // A pop animation can leave the older dialog in the tree for a frame.
      await _pumpFor(tester, 10);
      expect(guide.state.value.step, GuideStep.syncChoiceConfirmed);
      expect(guide.state.value.run, GuideRun.active);
      expect(find.text(completion), findsNothing);
      await _pumpFor(tester, 10);
      await tester.tap(find.text(settings ? '동기화 설정' : '동기화 안 함'));
      await _pumpUntil(
          tester, () => guide.state.value.run == GuideRun.terminal);
      expect(guide.state.value.step, GuideStep.completed);
      final destination = settings ? AppRoutes.settings : AppRoutes.home;
      await _pumpUntil(tester, () => h.currentUri.path == destination);
      await _pumpFor(tester, 10);
      expect(h.currentUri.path, destination);
      expect(find.text(completion), findsNothing);
      expect(find.text('외부 캘린더 동기화 안내'), findsNothing);
    });
  }

  for (final transientFailure in [false, true]) {
    testWidgets(
        'completion save failure offers retry before showing sync'
        '${transientFailure ? " after a transient recovery failure" : ""}',
        (tester) async {
      seedPrefs();
      final guide = _CompletingGuide(
          failCompletionSaveOnce: true,
          failCompletionResumeOnce: transientFailure);
      addTearDown(guide.state.dispose);
      await _pump(tester,
          user: 'a', store: _QueuedTourStore(autoAnswer: false), guide: guide);
      await _pumpUntil(
          tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
      guide.state.value =
          guide.state.value.copyWith(step: GuideStep.completionConfirm);
      final dialog = find.widgetWithText(AlertDialog, '튜토리얼 완료');
      Finder action(String text) => find
          .descendant(
            of: dialog,
            matching: find.widgetWithText(FilledButton, text),
          )
          .hitTestable();
      final confirm = action('확인');
      final retry = action('다시 시도');
      final sync = find.text('외부 캘린더 동기화 안내');
      await _pumpUntil(tester, () => confirm.evaluate().length == 1);
      await _pumpFor(tester, 10);
      await tester.tap(confirm);
      await _pumpUntil(tester, () => retry.evaluate().length == 1);
      await _pumpFor(tester, 10);
      expect(guide.state.value.run, GuideRun.blocked);
      expect(sync, findsNothing);
      await tester.tap(retry);
      if (transientFailure) {
        await _pumpUntil(tester, () => guide.resumes == 1);
        await _pumpFor(tester, 10);
        expect(confirm, findsNothing);
        expect(sync, findsNothing);
        final blocked = guide.state.value;
        expect(blocked.run, GuideRun.blocked);
        // Mirrors the recovery panel dispatching an explicit user retry.
        await guide.dispatch(ResumeRequested(
          uid: blocked.uid,
          sessionId: blocked.sessionId!,
          expectedRevision: blocked.revision,
        ));
      }
      await _pumpUntil(tester, () => confirm.evaluate().length == 1);
      await _pumpFor(tester, 10);
      expect(guide.resumes, transientFailure ? 2 : 1);
      expect(guide.state.value.run, GuideRun.active);
      expect(sync, findsNothing);
      await tester.tap(confirm);
      await _pumpUntil(tester, () => sync.evaluate().isNotEmpty);
      await _pumpFor(tester, 10);
      expect(sync, findsOneWidget);
      expect(dialog, findsNothing);
      expect(guide.state.value.step, GuideStep.syncChoiceConfirmed);
      expect(guide.syncChoices, isEmpty);
    });
  }

  for (final interruption in ['background', 'replacement', 'termination']) {
    testWidgets('completion save interruption handles $interruption',
        (tester) async {
      seedPrefs();
      final save = Completer<void>();
      final guide = _CompletingGuide(delayedCompletionSave: save);
      addTearDown(guide.state.dispose);
      _observeCompletingGuide(tester, guide);
      final h = await _pump(tester,
          user: 'a', store: _QueuedTourStore(autoAnswer: false), guide: guide);
      await _pumpUntil(
          tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
      guide.state.value =
          guide.state.value.copyWith(step: GuideStep.completionConfirm);
      final confirm = find
          .descendant(
            of: find.widgetWithText(AlertDialog, '튜토리얼 완료'),
            matching: find.widgetWithText(FilledButton, '확인'),
          )
          .hitTestable();
      final sync = find.text('외부 캘린더 동기화 안내');
      await _pumpUntil(tester, () => confirm.evaluate().length == 1);
      await _pumpFor(tester, 10);
      await tester.tap(confirm);
      await _pumpUntil(tester, () => guide.confirmations.length == 1);
      _backgroundApp(tester);
      expect(guide.state.value.run, GuideRun.paused);
      save.complete();
      await _pumpFor(tester, 10);
      expect(sync, findsNothing);
      switch (interruption) {
        case 'replacement':
          guide.state.value =
              guide.state.value.copyWith(createdEventId: 'replacement');
        case 'termination':
          await guide.terminate(GuideExit.cancel);
      }
      _foregroundApp(tester);
      if (interruption != 'background') {
        await _pumpFor(tester, 15);
        expect(confirm, findsNothing);
        expect(sync, findsNothing);
        expect(guide.resumes, 0);
        expect(guide.confirmations, hasLength(1));
        return;
      }

      await _pumpUntil(tester, () => confirm.evaluate().length == 1);
      await _pumpFor(tester, 10);
      expect(h.currentUri.path, AppRoutes.home);
      expect(guide.state.value.run, GuideRun.active);
      expect(guide.resumes, 1);
      expect(guide.confirmations, hasLength(1));
      expect(sync, findsNothing);
      final resumedRevision = guide.state.value.revision;
      await tester.tap(confirm);
      await _pumpUntil(tester, () => sync.evaluate().isNotEmpty);
      expect(guide.confirmations, hasLength(2));
      expect(guide.confirmations.last.expectedRevision, resumedRevision);
      expect(guide.state.value.step, GuideStep.syncChoiceConfirmed);
      expect(guide.syncChoices, isEmpty);
    });
  }

  testWidgets(
      'restored confirmed sync waits for Home and does not repeat completion',
      (tester) async {
    seedPrefs(closedGuideChoices: {});
    final guide = _CompletingGuide();
    addTearDown(guide.state.dispose);
    final h = await _pump(tester,
        user: 'a', store: _QueuedTourStore(autoAnswer: false), guide: guide);
    await _pumpUntil(
        tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
    unawaited(h.router.push(AppRoutes.featureTour));
    await _pumpUntil(tester, () => h.currentUri.path == AppRoutes.featureTour);
    await _pumpFor(tester, 10);
    guide.state.value =
        guide.state.value.copyWith(step: GuideStep.syncChoiceConfirmed);
    await _pumpFor(tester, 15);
    expect(find.text('외부 캘린더 동기화 안내'), findsNothing);
    expect(guide.state.value.step, GuideStep.syncChoiceConfirmed);
    expect(h.currentUri.path, AppRoutes.featureTour);

    h.router.pop();
    await _pumpUntil(
        tester, () => find.text('외부 캘린더 동기화 안내').evaluate().isNotEmpty);
    expect(h.currentUri.path, AppRoutes.home);
    await _pumpFor(tester, 10);
    const completion = '모든 튜토리얼이 끝났습니다. 이제 자유롭게 사용해보세요.';
    expect(find.text(completion), findsNothing);
    Navigator.of(tester.element(find.text('외부 캘린더 동기화 안내'))).pop();
    await _pumpFor(tester, 10);
    expect(guide.state.value.step, GuideStep.syncChoiceConfirmed);
    expect(find.text(completion), findsNothing);
    await _pumpUntil(tester, () => find.text('동기화 안 함').evaluate().isNotEmpty);
    await tester.tap(find.text('동기화 안 함'));
    await _pumpUntil(tester, () => guide.state.value.run == GuideRun.terminal);
    expect(guide.state.value.step, GuideStep.completed);
    expect(find.text(completion), findsNothing);
    expect(h.currentUri.path, AppRoutes.home);
  });

  for (final (destination, step) in [
    (AppRoutes.home, GuideStep.homeMic),
    (AppRoutes.home, GuideStep.savedDetail),
    (AppRoutes.home, GuideStep.queryMic),
  ]) {
    testWidgets('system Back exits $step on the single $destination route',
        (tester) async {
      try {
        seedPrefs();
        final guide = _CompletingGuide();
        addTearDown(guide.state.dispose);
        final h = await _pump(
          tester,
          user: 'a',
          store: _QueuedTourStore(autoAnswer: false),
          guide: guide,
          allowBackSkip: true,
          mountRootGuide: true,
        );
        await _pumpUntil(
            tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
        guide.state.value = guide.state.value.copyWith(
          step: step,
          // banned-ok: this stable fixture tests route/Back behavior, not date expiry; the calendar route matches it below.
          savedLocalDate: DateTime(2030, 1, 2),
        );
        final expectedSurface = switch (step) {
          GuideStep.homeMic => '1/7 · 음성으로 입력 시작',
          GuideStep.savedDetail => '안내 계속',
          _ => '4/7 · 음성으로 조회',
        };
        final waiting = find.textContaining('안내할 실제 화면을 기다리고 있어요');
        final expectsFallback = step == GuideStep.savedDetail;
        bool isGuideSurfaceReady() =>
            find.text(expectedSurface).evaluate().isNotEmpty &&
            waiting.evaluate().isNotEmpty == expectsFallback;
        await _pumpUntil(tester, isGuideSurfaceReady);
        expect(h.currentUri.path, destination);
        expect(h.router.canPop(), isFalse);
        expect(find.text(expectedSurface), findsOneWidget);
        expect(waiting, expectsFallback ? findsOneWidget : findsNothing);
        expect(guide.exits, isEmpty);

        expect(await tester.binding.handlePopRoute(), isTrue);
        await _pumpFor(tester, 10);
        expect(h.currentUri.path, AppRoutes.home);
        expect(find.text(expectedSurface), findsNothing);
        expect(guide.state.value.run, GuideRun.terminal);
        expect(guide.state.value.step, GuideStep.skipped);
        expect(guide.exits, [GuideExit.skip]);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  for (final (paused, stale) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
        'Back closes ${paused ? "paused" : "active"} sync choice '
        'through Router, RootGuideScope and Shell${stale ? " after ownership changes" : ""}',
        (tester) async {
      seedPrefs(closedGuideChoices: {});
      final guide = _CompletingGuide();
      addTearDown(guide.state.dispose);
      final h = await _pump(
        tester,
        user: 'a',
        store: _QueuedTourStore(autoAnswer: false),
        guide: guide,
        allowBackSkip: true,
        mountRootGuide: true,
      );
      await _pumpUntil(
          tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
      guide.state.value =
          guide.state.value.copyWith(step: GuideStep.syncChoiceConfirmed);
      final dialog = find.text('외부 캘린더 동기화 안내');
      await _pumpUntil(tester, () => dialog.evaluate().isNotEmpty);
      await _pumpFor(tester, 10);
      if (paused) {
        _backgroundApp(tester);
        _foregroundApp(tester);
        await _pumpFor(tester, 10);
        expect(dialog, findsOneWidget);
        expect(guide.state.value.run, GuideRun.paused);
        expect(guide.state.value.pauseReason, GuidePauseReason.background);
        expect(guide.resumes, 0);
        expect(guide.exits, isEmpty);
      }
      if (stale) {
        final current = guide.state.value;
        guide.state.value = paused
            ? current.copyWith(
                sessionId: 'replacement-guide-session',
                revision: current.revision + 1,
              )
            : current.copyWith(
                step: GuideStep.queryMic,
                revision: current.revision + 1,
              );
        await _pumpFor(tester, 4);
        expect(dialog, findsOneWidget);
      }
      final beforeBack = guide.state.value;
      expect(h.gate.calendarSyncHeldFor('a'), isTrue);
      expect(await GuideSyncChoiceStore().isClosed('a'), isFalse);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _pumpFor(tester, 10);

      expect(dialog, findsNothing);
      expect(guide.syncChoices, isEmpty);
      expect(h.currentUri.path, AppRoutes.home);
      if (stale) {
        expect(guide.state.value, same(beforeBack));
        expect(guide.exits, isEmpty);
        expect(guide.resumes, 0);
        expect(await GuideSyncChoiceStore().isClosed('a'), isFalse);
        expect(h.gate.calendarSyncHeldFor('a'), isTrue);
      } else {
        expect(guide.exits, [GuideExit.skip]);
        expect(guide.state.value.run, GuideRun.terminal);
        expect(guide.state.value.step, GuideStep.skipped);
        expect(await GuideSyncChoiceStore().isClosed('a'), isTrue);
        expect(h.gate.calendarSyncHeldFor('a'), isFalse);
      }
    });
  }

  for (final alreadyShowing in [false, true]) {
    testWidgets(
        'background pause keeps the ${alreadyShowing ? "open" : "pending"} sync choice bound to Home',
        (tester) async {
      seedPrefs(closedGuideChoices: {});
      final guide = _CompletingGuide();
      addTearDown(guide.state.dispose);
      _observeCompletingGuide(tester, guide);
      final h = await _pump(tester,
          user: 'a', store: _QueuedTourStore(autoAnswer: false), guide: guide);
      await _pumpUntil(
          tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
      final syncTitle = find.text('외부 캘린더 동기화 안내');
      if (!alreadyShowing) {
        unawaited(h.router.push(AppRoutes.featureTour));
        await _pumpUntil(
            tester, () => h.currentUri.path == AppRoutes.featureTour);
        await _pumpFor(tester, 10);
      }
      guide.state.value =
          guide.state.value.copyWith(step: GuideStep.syncChoiceConfirmed);
      if (alreadyShowing) {
        await _pumpUntil(tester, () => syncTitle.evaluate().isNotEmpty);
        expect(syncTitle, findsOneWidget);
      } else {
        await _pumpFor(tester, 10);
        expect(syncTitle, findsNothing);
      }

      _backgroundApp(tester);
      expect(guide.state.value.run, GuideRun.paused);
      expect(guide.syncChoices, isEmpty);
      final pausedRevision = guide.state.value.revision;
      if (!alreadyShowing) h.router.pop();
      await _pumpFor(tester, 5);
      expect(guide.resumes, 0);
      if (!alreadyShowing) expect(syncTitle, findsNothing);
      _foregroundApp(tester);
      await _pumpUntil(tester, () => syncTitle.evaluate().isNotEmpty);
      expect(syncTitle, findsOneWidget);
      expect(h.currentUri.path, AppRoutes.home);
      await _pumpFor(tester, 10);
      await tester.tap(find.text('동기화 안 함'));
      final celebration = find.text('모든 튜토리얼이 끝났습니다. 이제 자유롭게 사용해보세요.');
      await _pumpUntil(
          tester, () => guide.state.value.run == GuideRun.terminal);
      expect(guide.resumes, 1);
      expect(guide.syncChoices.single.expectedRevision, pausedRevision + 1);
      expect(guide.state.value.run, GuideRun.terminal);
      expect(celebration, findsNothing);
      expect(h.currentUri.path, AppRoutes.home);
    });
  }

  for (final switchAccount in [false, true]) {
    testWidgets(
        'background sync choice rejects a changed ${switchAccount ? "account" : "session"}',
        (tester) async {
      seedPrefs(closedGuideChoices: {});
      final guide = _CompletingGuide();
      addTearDown(guide.state.dispose);
      _observeCompletingGuide(tester, guide);
      final h = await _pump(tester,
          user: 'a', store: _QueuedTourStore(autoAnswer: false), guide: guide);
      await _pumpUntil(
          tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
      guide.state.value =
          guide.state.value.copyWith(step: GuideStep.syncChoiceConfirmed);
      final syncTitle = find.text('외부 캘린더 동기화 안내');
      await _pumpUntil(tester, () => syncTitle.evaluate().isNotEmpty);
      expect(syncTitle, findsOneWidget);

      _backgroundApp(tester);
      if (switchAccount) {
        h.auth.setUser('b');
      } else {
        guide.state.value =
            guide.state.value.copyWith(sessionId: 'other-guide');
      }
      _foregroundApp(tester);
      await _pumpFor(tester, 10);
      final noSync = find.text('동기화 안 함');
      if (noSync.evaluate().isNotEmpty) await tester.tap(noSync);
      await _pumpFor(tester, 15);
      expect(guide.syncChoices, isEmpty);
      expect(guide.resumes, 0);
      expect(guide.state.value.step, GuideStep.syncChoiceConfirmed);
      expect(find.text('모든 튜토리얼이 끝났습니다. 이제 자유롭게 사용해보세요.'), findsNothing);
    });
  }

  testWidgets(
      'already-onboarded user: Shell reaches readiness and replays the '
      'pending calendar target once', (tester) async {
    seedPrefs();
    final h = await _pump(tester,
        user: 'a', store: _QueuedTourStore(autoAnswer: false));
    _submitWidgetLaunch(h, _calendarTarget);
    await _pumpUntil(tester, () => h.consumed.isNotEmpty);

    expect(h.gate.requiredSetupCompleteFor('a'), isTrue);
    expect(h.readiness, HomeWidgetRouteReadiness.ready);
    expect(h.navigations, [_calendarTarget]);
    expect(h.consumed, [_calendarTarget]);
    expect(h.currentUri, Uri.parse(_calendarTarget));
    expect(find.byType(ShellScreen), findsWidgets);

    // Storm of wake/location/kick events: no extra navigation or consume.
    for (var i = 0; i < 30; i++) {
      h.coordinator.notifyLocationChanged();
      h.coordinator.kickPendingRoute();
      h.auth.setUser('a');
    }
    await _pumpFor(tester, 10);
    expect(h.navigations, [_calendarTarget]);
    expect(h.consumed, [_calendarTarget]);
    expect(h.gate.requiredSetupCompleteFor('a'), isTrue,
        reason: 'same-identity auth notifications must not reset completion');
  });

  for (final target in [_calendarTarget, _voiceTarget]) {
    testWidgets(
        'required tour: $target retained (hold released to HOME, readiness '
        'timeout, no consume) then actual tour completion replays once',
        (tester) async {
      seedPrefs();
      final store = _QueuedTourStore(autoAnswer: true);
      final h = await _pump(tester, user: 'a', store: store);
      _submitWidgetLaunch(h, target);
      await _pumpUntil(
          tester, () => find.byType(LegacyIntroScreen).evaluate().isNotEmpty);

      // The widget hold was released without consuming: the router left the
      // splash, reached HOME and the Shell pushed the required tour.
      expect(find.byType(LegacyIntroScreen), findsOneWidget);
      expect(h.gate.widgetLaunchPending, isFalse);
      expect(h.readiness, HomeWidgetRouteReadiness.notReady);
      await _pumpFor(tester, 10); // past the 300ms readiness timeout
      expect(h.terminals, contains(HomeWidgetRouteOutcome.givingUp));
      expect(h.coordinator.pendingRoute, target);
      expect(h.navigations, isEmpty);
      expect(h.consumed, isEmpty);

      await _finishRequiredTour(tester);
      await _pumpUntil(tester, () => h.consumed.isNotEmpty);

      expect(store.completed, isTrue);
      expect(h.gate.requiredSetupCompleteFor('a'), isTrue);
      expect(h.navigations, [target]);
      expect(h.consumed, [target]);
      expect(h.currentUri, Uri.parse(target));

      for (var i = 0; i < 30; i++) {
        h.coordinator.notifyLocationChanged();
        h.coordinator.kickPendingRoute();
        h.auth.setUser('a');
      }
      await _pumpFor(tester, 10);
      expect(h.navigations, [target]);
      expect(h.consumed, [target]);
    });
  }

  for (final target in [_calendarTarget, _voiceTarget]) {
    testWidgets(
        'calendar sync choice holds $target until the choice is closed, then '
        'replays once', (tester) async {
      seedPrefs(closedGuideChoices: {});
      final h = await _pump(tester,
          user: 'a', store: _QueuedTourStore(autoAnswer: false));
      _submitWidgetLaunch(h, target);
      final dialog = find.text('외부 캘린더 동기화 안내');
      await _pumpUntil(tester, () => dialog.evaluate().isNotEmpty);
      expect(dialog, findsOneWidget);
      // Permissions now belong to contextual flows, outside signed-in startup.
      expect(find.byType(PermissionOnboardingScreen), findsNothing);
      expect(h.gate.requiredSetupCompleteFor('a'), isFalse);
      expect(await GuideSyncChoiceStore().isClosed('a'), isFalse);
      await _pumpFor(tester, 10);
      expect(h.coordinator.pendingRoute, target);
      expect(h.navigations, isEmpty);
      expect(h.consumed, isEmpty);

      await tester.tap(find.text('동기화 안 함'));
      await _pumpUntil(tester, () => h.consumed.isNotEmpty);

      expect(await GuideSyncChoiceStore().isClosed('a'), isTrue);
      expect(h.gate.requiredSetupCompleteFor('a'), isTrue);
      expect(h.navigations, [target]);
      expect(h.consumed, [target]);
    });
  }

  testWidgets(
      'required tour cancelled (route popped without finishing) stays '
      'incomplete: target retained, never navigated or consumed',
      (tester) async {
    seedPrefs();
    final store = _QueuedTourStore(autoAnswer: true);
    final h = await _pump(tester, user: 'a', store: store);
    _submitWidgetLaunch(h, _calendarTarget);
    await _pumpUntil(
        tester, () => find.byType(LegacyIntroScreen).evaluate().isNotEmpty);
    final intro = tester.element(find.byType(LegacyIntroScreen));
    Navigator.of(intro).pop();
    await _pumpFor(tester, 20);

    expect(store.completed, isFalse);
    expect(h.gate.requiredSetupCompleteFor('a'), isFalse);
    expect(h.navigations, isEmpty);
    expect(h.consumed, isEmpty);
    expect(h.coordinator.pendingRoute, _calendarTarget);
  });

  testWidgets(
      'identity switch a->b->a: stale flows cannot complete; only the current '
      'flow completes; sign-out resets readiness without false completion',
      (tester) async {
    seedPrefs();
    final store = _QueuedTourStore();
    final h = await _pump(tester, user: 'a', store: store);
    _submitWidgetLaunch(h, _calendarTarget);
    await _pumpUntil(tester, () => store.calls.isNotEmpty);
    expect(store.calls, hasLength(1)); // stale flow a1

    h.auth.setUser('b');
    await _pumpUntil(tester, () => store.calls.length >= 2); // stale flow b
    h.auth.setUser('a');
    await _pumpUntil(tester, () => store.calls.length >= 3); // current a2
    expect(store.calls, hasLength(3));

    store.calls[0].complete(false); // a1 resolves "tour not needed"
    store.calls[1].complete(false); // b resolves while auth is 'a'
    await _pumpFor(tester, 20);
    expect(h.gate.requiredSetupCompleteFor('a'), isFalse,
        reason: 'stale a1 flow must not complete the new a session');
    expect(h.gate.requiredSetupCompleteFor('b'), isFalse);
    expect(h.navigations, isEmpty);
    expect(h.consumed, isEmpty);

    store.calls[2].complete(false); // current flow finishes for real
    await _pumpUntil(tester, () => h.consumed.isNotEmpty);
    expect(h.gate.requiredSetupCompleteFor('a'), isTrue);
    expect(h.navigations, [_calendarTarget]);
    expect(h.consumed, [_calendarTarget]);

    h.auth.setUser(null);
    await _pumpFor(tester, 10);
    expect(h.gate.requiredSetupCompleteFor('a'), isFalse);
    expect(h.readiness, HomeWidgetRouteReadiness.needsAuth);
    expect(h.consumed, [_calendarTarget]);
  });
}
