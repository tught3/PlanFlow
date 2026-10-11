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
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/screens/onboarding/permission_onboarding_screen.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:planflow/services/external_calendar_sync_guide_service.dart';
import 'package:planflow/services/feature_tour_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _calendarTarget = '/calendar?date=2026-10-14';
const _voiceTarget = '/voice?autoStart=1';

String _permissionKey(String userId) =>
    'planflow_permissions_onboarded_v1:$userId';

/// Each shouldShow() call gets its own controllable answer so stale and
/// current flows can be resolved independently.
class _QueuedTourStore extends FeatureTourStore {
  _QueuedTourStore({this.autoAnswer});

  bool? autoAnswer;
  bool completed = false;
  final List<Completer<bool>> calls = <Completer<bool>>[];

  @override
  Future<bool> shouldShow() {
    if (autoAnswer != null) return Future<bool>.value(autoAnswer! && !completed);
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

  Uri get currentUri =>
      simulatedVoiceUri ?? currentAppRouterLocation(router);
  HomeWidgetRouteReadiness get readiness =>
      resolveAppHomeWidgetReadiness(auth: auth, gate: gate, supabaseReady: true);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required String? user,
  required _QueuedTourStore store,
  bool runPostTourStages = true,
}) async {
  final auth = AuthProvider()..start();
  if (user != null) auth.setUser(user);
  final gate = StartupRouteGate();
  final router = createAppRouter(
    authProviderOverride: auth,
    startupRouteGateOverride: gate,
    featureTourStore: store,
    runPostTourOnboardingStages: runPostTourStages,
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
  router.routeInformationProvider.addListener(coordinator.notifyLocationChanged);
  router.routerDelegate.addListener(coordinator.notifyLocationChanged);
  addTearDown(() {
    router.routeInformationProvider
        .removeListener(coordinator.notifyLocationChanged);
    router.routerDelegate.removeListener(coordinator.notifyLocationChanged);
    coordinator.dispose();
    router.dispose();
    gate.dispose();
    auth.dispose();
  });
  await tester.pumpWidget(MaterialApp.router(
    routerConfig: router,
    locale: const Locale('ko', 'KR'),
    supportedLocales: const <Locale>[Locale('ko', 'KR'), Locale('en', 'US')],
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
  ));
  return h;
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

/// The required tour hides Skip; it is completed only through the real
/// practice flow (create, next, +30/confirm, next, Finish), which writes the
/// completion marker, reads it back and pops.
Future<void> _finishRequiredTour(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('feature-tour-skip-button')), findsNothing);
  Future<void> tapKey(String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pump();
  }

  await tester.enterText(
      find.byKey(const ValueKey('feature-tour-title-field')), 'Dentist');
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tapKey('feature-tour-create-button');
  await tapKey('feature-tour-next-button');
  await _pumpFor(tester, 10);
  await tapKey('feature-tour-plus-30-button');
  await tapKey('feature-tour-confirm-time-button');
  await tapKey('feature-tour-next-button');
  await _pumpFor(tester, 10);
  await tapKey('feature-tour-next-button'); // Finish
  await _pumpFor(tester, 8);
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

  void seedPrefs({required Map<String, bool> permissionDone}) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExternalCalendarSyncGuideService.guideSeenKey('a'): true,
      ExternalCalendarSyncGuideService.guideSeenKey('b'): true,
    });
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(<String, Object>{
      for (final e in permissionDone.entries)
        if (e.value) _permissionKey(e.key): true,
    });
  }

  setUp(ShellScreen.resetSessionOnboardingStateForTest);
  tearDown(() {
    ShellScreen.resetSessionOnboardingStateForTest();
    SharedPreferencesAsyncPlatform.instance = null;
  });

  testWidgets(
      'already-onboarded user: real Shell makes readiness ready without any '
      'test begin/complete call and the pending calendar target replays once',
      (tester) async {
    seedPrefs(permissionDone: {'a': true});
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
      seedPrefs(permissionDone: {'a': true});
      final store = _QueuedTourStore(autoAnswer: true);
      final h = await _pump(tester, user: 'a', store: store);
      _submitWidgetLaunch(h, target);
      await _pumpUntil(
          tester, () => find.byType(FeatureTourScreen).evaluate().isNotEmpty);

      // The widget hold was released without consuming: the router left the
      // splash, reached HOME and the Shell pushed the required tour.
      expect(find.byType(FeatureTourScreen), findsOneWidget);
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

  testWidgets(
      'permission onboarding: route pop alone is not completion; typed '
      'readback after the screen marks completion replays in the same session',
      (tester) async {
    seedPrefs(permissionDone: {});
    final h = await _pump(tester,
        user: 'a', store: _QueuedTourStore(autoAnswer: false));
    _submitWidgetLaunch(h, _calendarTarget);
    await _pumpUntil(tester,
        () => find.byType(PermissionOnboardingScreen).evaluate().isNotEmpty);
    expect(find.byType(PermissionOnboardingScreen), findsOneWidget);
    expect(h.gate.requiredSetupCompleteFor('a'), isFalse);

    // What the permission screen's finish path does (denied optional
    // permissions still finish): persist the typed flag, then pop.
    await SharedPreferencesAsync().setBool(_permissionKey('a'), true);
    h.router.pop();
    await _pumpUntil(tester, () => h.consumed.isNotEmpty);

    expect(h.gate.requiredSetupCompleteFor('a'), isTrue);
    expect(h.navigations, [_calendarTarget]);
    expect(h.consumed, [_calendarTarget]);
  });

  testWidgets(
      'permission onboarding cancelled (popped without completion) stays '
      'incomplete: target retained, never navigated or consumed',
      (tester) async {
    seedPrefs(permissionDone: {});
    final h = await _pump(tester,
        user: 'a', store: _QueuedTourStore(autoAnswer: false));
    _submitWidgetLaunch(h, _voiceTarget);
    await _pumpUntil(tester,
        () => find.byType(PermissionOnboardingScreen).evaluate().isNotEmpty);
    h.router.pop();
    await _pumpFor(tester, 20);

    expect(h.gate.requiredSetupCompleteFor('a'), isFalse);
    expect(h.readiness, HomeWidgetRouteReadiness.notReady);
    expect(h.coordinator.pendingRoute, _voiceTarget);
    expect(h.navigations, isEmpty);
    expect(h.consumed, isEmpty);
  });

  testWidgets(
      'required tour cancelled (route popped without finishing) stays '
      'incomplete: target retained, never navigated or consumed',
      (tester) async {
    seedPrefs(permissionDone: {'a': true});
    final store = _QueuedTourStore(autoAnswer: true);
    final h = await _pump(tester, user: 'a', store: store);
    _submitWidgetLaunch(h, _calendarTarget);
    await _pumpUntil(
        tester, () => find.byType(FeatureTourScreen).evaluate().isNotEmpty);
    h.router.pop();
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
    seedPrefs(permissionDone: {'a': true, 'b': true});
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
