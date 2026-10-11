// iOS-only isolated QA legs. Production HomeWidgetRouteCoordinator drives
// fake delayed auth (1600ms > old 1200ms cliff) and the real router/screens.
// Calendar chosen-date sheet uses an in-memory repository. Voice autoStart
// uses channel-blocked native availability plus an injected fake STT screen.
// No production _PlanFlowAppState startup, auth/backend, real mic or widget
// tap is claimed. External AppLinks/home_widget transport is independently
// tested by tracked tool/widget_launch_qa assets and simctl openURL.
// Non-iOS execution skips, never supplies native proof.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:planflow/app.dart'
    show
        HomeWidgetArrivalCheckResult,
        currentAppRouterLocation,
        seedHomeAndDeferHomeWidgetPush,
        resolveHomeWidgetArrivalCheckResult,
        resolveHomeWidgetRoute,
        shouldConsumeHomeWidgetLaunch,
        shouldIgnoreDuplicateHomeWidgetRoute,
        shouldSeedHomeBaseForHomeWidgetRoute;
import 'package:planflow/core/home_widget_route_coordinator.dart'
    show
        HomeWidgetRouteCoordinator,
        HomeWidgetRouteReadiness,
        HomeWidgetRouteOutcome;
import 'package:planflow/core/constants.dart' show AppRoutes;
import 'package:planflow/core/router.dart' show createAppRouter;
import 'package:planflow/core/startup_route_gate.dart' show StartupRouteGate;
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/providers/auth_provider.dart' show AuthProvider;
import 'package:planflow/screens/auth/login_screen.dart' show LoginScreen;
import 'package:planflow/screens/calendar/calendar_screen.dart'
    show CalendarScreen;
import 'package:planflow/screens/voice/voice_input_screen.dart'
    show VoiceInputScreen;
import 'package:planflow/services/feature_tour_service.dart'
    show FeatureTourStore;
import 'package:planflow/services/notification_route_contract.dart'
    show NotificationRouteContract;
import 'package:planflow/services/stt_service.dart'
    show
        SttListenFailure,
        SttListenMode,
        SttListenResult,
        SttNativeStatusEvent,
        SttService;

import '_harness/fakes/fake_auth_service.dart';
import '_harness/seed/fixture_events.dart';

const String _probePassMarker = 'WIDGET_LAUNCH_ROUTING_PROBE_PASS';
const String _probeSkipMarker = 'WIDGET_LAUNCH_ROUTING_PROBE_SKIPPED';

/// speech_to_text plugin base channel (iOS path used by SttService
/// `_listenWithSpeechToText`; the Android-only `planflow/native_stt` channel
/// is not exercised on an iOS host).
const MethodChannel _speechToTextChannel =
    MethodChannel('cjcodezonye.github.io/speech_to_text');

/// Readiness delay for the in-memory auth session. Must be strictly greater
/// than the legacy 1.2s production cliff (10 x 120ms) and strictly less than
/// AuthProvider._bootstrapInitialSession's first-event timeout (2s) so the
/// signed-in event deterministically wins the bootstrap wait.
const Duration _readinessDelay = Duration(milliseconds: 1600);

/// Register alongside the HomeWidget storage probe and the feature-tour
/// practice probe. Each probe keeps its own PASS marker and platform gate.
void registerWidgetLaunchRoutingNativeProbe() {
  testWidgets(
    'native widget-launch pending route survives readiness delay to real destinations',
    (WidgetTester tester) async {
      if (!Platform.isIOS) {
        // ignore: avoid_print
        print(
          '$_probeSkipMarker: dart:io.Platform.isIOS=false '
          '(host=${Platform.operatingSystem}); the widget-launch routing '
          'probe requires a real iOS XCTest host and is reported as skipped, '
          'never as native green.',
        );
        markTestSkipped(
          'WIDGET_LAUNCH_ROUTING_PROBE_SKIPPED: widget-launch routing probe '
          'requires dart:io.Platform.isIOS (got ${Platform.operatingSystem}).',
        );
        return;
      }

      // ------------------------------------------------------------------
      // LEG 0 — real production pure functions (mapping + state machine).
      // ------------------------------------------------------------------
      final DateTime now = DateTime.now();
      final DateTime chosenDay = DateTime(
        now.year,
        now.month,
        now.day,
      ).add(const Duration(days: 3));
      final String chosenDayText =
          '${chosenDay.year.toString().padLeft(4, '0')}-'
          '${chosenDay.month.toString().padLeft(2, '0')}-'
          '${chosenDay.day.toString().padLeft(2, '0')}';

      final String? dayRoute =
          resolveHomeWidgetRoute(NotificationRouteContract.day(chosenDay));
      expect(dayRoute, '${AppRoutes.calendar}?date=$chosenDayText',
          reason: 'planflow://day/<date> must map to the calendar route '
              'with the chosen date query');

      final String? voiceRoute = resolveHomeWidgetRoute(
        Uri.parse('planflow://voice-launcher'),
      );
      expect(voiceRoute, '${AppRoutes.voice}?autoStart=1',
          reason: 'planflow://voice-launcher must map to the voice route '
              'with autoStart=1');

      // Legacy cliff boundary, expressed against the real decision function:
      // attempt 9 of 10 is still retrying; attempt 10 is givingUp; only the
      // terminal states consume the native intent.
      expect(
        resolveHomeWidgetArrivalCheckResult(
            arrived: false, attempt: 9, maxAttempts: 10),
        HomeWidgetArrivalCheckResult.retrying,
        reason: 'the last in-budget arrival check must still be retrying',
      );
      expect(
        resolveHomeWidgetArrivalCheckResult(
            arrived: false, attempt: 10, maxAttempts: 10),
        HomeWidgetArrivalCheckResult.givingUp,
        reason: 'exceeding the retry budget must produce givingUp (the '
            'terminal state that consumed intents after the 1.2s readiness '
            'cliff in the regression)',
      );
      expect(
        shouldConsumeHomeWidgetLaunch(HomeWidgetArrivalCheckResult.retrying),
        isFalse,
        reason: 'a still-retrying loop must never consume the intent',
      );
      expect(
        shouldConsumeHomeWidgetLaunch(HomeWidgetArrivalCheckResult.confirmed),
        isTrue,
        reason: 'confirmed arrival is terminal and must consume the intent',
      );
      expect(
        shouldConsumeHomeWidgetLaunch(HomeWidgetArrivalCheckResult.givingUp),
        isFalse,
        reason: 'givingUp retains the intent and must never consume',
      );

      expect(
        shouldSeedHomeBaseForHomeWidgetRoute(route: dayRoute!, canPop: false),
        isTrue,
        reason: 'a cold widget launch (empty stack) must seed the home base '
            'so back navigation does not exit the app',
      );
      expect(
        shouldSeedHomeBaseForHomeWidgetRoute(route: dayRoute, canPop: true),
        isFalse,
        reason: 'a warm launch with an existing stack must only push',
      );

      expect(
        shouldIgnoreDuplicateHomeWidgetRoute(
          route: voiceRoute!,
          previousRoute: voiceRoute,
          previousHandledAt: now.subtract(const Duration(milliseconds: 1999)),
          now: now,
        ),
        isTrue,
        reason: 'the same route re-delivered within 2s is a duplicate',
      );
      expect(
        shouldIgnoreDuplicateHomeWidgetRoute(
          route: voiceRoute,
          previousRoute: voiceRoute,
          previousHandledAt: now.subtract(const Duration(seconds: 2)),
          now: now,
        ),
        isFalse,
        reason: 'duplicates older than 2s must be handled again',
      );

      // ------------------------------------------------------------------
      // LEG 1 + LEG 3a — shared production pending-route controller
      // driving the REAL production router/screens with in-memory auth.
      // ------------------------------------------------------------------
      await _ensurePlaceholderSupabase();

      final FakeAuthService authClient = FakeAuthService();
      final AuthProvider qaAuth = AuthProvider(authService: authClient);
      final StartupRouteGate qaGate = StartupRouteGate();
      final GoRouter qaRouter = createAppRouter(
        authProviderOverride: qaAuth,
        startupRouteGateOverride: qaGate,
        featureTourStore: const _CompletedTourStore(),
        runPostTourOnboardingStages: false,
        runShellStartupTasks: false,
        supabaseReadyOverride: true,
      );
      addTearDown(() async {
        await authClient.dispose();
        qaAuth.dispose();
        qaGate.dispose();
      });

      addTearDown(qaRouter.dispose);
      HomeWidgetRouteOutcome? terminal;
      String? terminalRoute;
      int consumeCalls = 0;
      int navigationCalls = 0;
      int firstNavigationElapsedMs = -1;
      final Stopwatch readinessClock = Stopwatch()..start();
      // Isolated test lifetime only, not production PlanFlowAppState.mounted.
      bool probeLifetimeActive = true;
      late final HomeWidgetRouteCoordinator coordinator;
      coordinator = HomeWidgetRouteCoordinator(
        readinessResolver: () => !qaAuth.hasResolvedInitialSession
            ? HomeWidgetRouteReadiness.notReady
            : qaAuth.isSignedIn
                ? HomeWidgetRouteReadiness.ready
                : HomeWidgetRouteReadiness.needsAuth,
        wakeSignal: qaAuth,
        currentUri: () => currentAppRouterLocation(qaRouter),
        navigate: (route) {
          navigationCalls++;
          if (firstNavigationElapsedMs < 0) {
            firstNavigationElapsedMs = readinessClock.elapsedMilliseconds;
          }
          if (shouldSeedHomeBaseForHomeWidgetRoute(
              route: route, canPop: qaRouter.canPop())) {
            seedHomeAndDeferHomeWidgetPush(
              route: route,
              currentCoordinator: () => coordinator,
              isMounted: () => probeLifetimeActive,
              seedHome: () => qaRouter.go(AppRoutes.home),
              push: (target) => unawaited(qaRouter.push<void>(target)),
            );
          } else {
            unawaited(qaRouter.push<void>(route));
          }
        },
        consume: (_) async {
          consumeCalls++;
        },
        onTerminal: (route, outcome) {
          terminal = outcome;
          terminalRoute = route;
          if (outcome == HomeWidgetRouteOutcome.confirmed) {
            qaGate.completeWidgetLaunch();
          }
        },
      );
      addTearDown(() {
        // Teardowns run in reverse registration order: lifetime ends before
        // coordinator and router disposal, suppressing deferred QA pushes.
        probeLifetimeActive = false;
        coordinator.dispose();
      });
      void submit(Uri uri) {
        terminal = null;
        terminalRoute = null;
        qaGate.beginWidgetLaunch();
        unawaited(coordinator.submitRoute(resolveHomeWidgetRoute(uri)!));
      }

      // Gate before first router mount: unresolved auth must not show login.
      qaGate.beginWidgetLaunch();

      // Delayed readiness: no session events at all until 1.6s, then a
      // signed-in session. hasResolvedInitialSession stays false for the
      // whole window that used to kill the pending route after ~1.2s.
      unawaitedTestSafe(
        Future<void>.delayed(_readinessDelay, () {
          authClient.emitSignedIn(FixtureSession.build());
        }),
      );

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: qaRouter,
          locale: const Locale('ko', 'KR'),
          supportedLocales: const <Locale>[Locale('ko', 'KR')],
        ),
      );
      qaAuth.start();
      submit(NotificationRouteContract.day(chosenDay));

      // While the launch is pending, the login screen must never appear.
      final List<int> loginBounceFrames = <int>[];
      await _pumpUntil(
        tester,
        () => terminal != null,
        timeout: const Duration(seconds: 20),
        onPump: () {
          if (find.byType(LoginScreen).evaluate().isNotEmpty) {
            loginBounceFrames.add(readinessClock.elapsedMilliseconds);
          }
        },
      );

      expect(
        terminal,
        HomeWidgetRouteOutcome.confirmed,
        reason: 'the chosen-date route must be confirmed after readiness '
            'resolves at ${_readinessDelay.inMilliseconds}ms (> legacy 1.2s cliff)',
      );
      expect(loginBounceFrames, isEmpty,
          reason: 'a pending widget launch must suppress login redirects '
              '(startupRouteGate.suppressLoginRedirects contract)');
      expect(consumeCalls, 1);
      expect(coordinator.pendingRoute, isNull);
      expect(navigationCalls, 1);
      expect(
        firstNavigationElapsedMs,
        greaterThanOrEqualTo(1500),
        reason: 'readiness took longer than the legacy 10x120ms budget; the '
            'fixed contract keeps waiting instead of dropping the intent',
      );

      final Uri calendarLocation = currentAppRouterLocation(qaRouter);
      expect(calendarLocation.path, AppRoutes.calendar);
      expect(calendarLocation.queryParameters['date'], chosenDayText);
      expect(
        find.byType(CalendarScreen),
        findsOneWidget,
        reason: 'the real Schedule tab (CalendarScreen) must be mounted at '
            'the confirmed calendar route',
      );
      expect(qaGate.widgetLaunchPending, isFalse,
          reason: 'the launch gate must complete after confirmation');

      // ignore: avoid_print
      print('WIDGET_SHARED_ROUTING_DELAYED_AUTH_PASS '
          'controller=production delay_ms=$firstNavigationElapsedMs '
          'navigation_calls=$navigationCalls consume_calls=$consumeCalls '
          'production_app_state=false');

      // Warm submitted URI on the same live router (not external delivery).
      final List<MethodCall> speechCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_speechToTextChannel, (call) async {
        speechCalls.add(call);
        switch (call.method) {
          case 'initialize':
            return false; // speech unavailable -> listen aborts cleanly
          case 'hasPermission':
            return true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_speechToTextChannel, null);
      });

      final String? warmVoiceRoute = resolveHomeWidgetRoute(
        Uri.parse('planflow://voice-launcher'),
      );
      expect(warmVoiceRoute, '${AppRoutes.voice}?autoStart=1');
      submit(Uri.parse('planflow://voice-launcher'));
      await _pumpUntil(
        tester,
        () => terminalRoute == warmVoiceRoute,
        timeout: const Duration(seconds: 20),
      );
      expect(
        terminalRoute,
        warmVoiceRoute,
        reason: 'the warm voice-launcher route must reach a terminal state',
      );
      expect(
        currentAppRouterLocation(qaRouter).path == AppRoutes.login,
        isFalse,
        reason: 'the warm voice launch must not bounce to login either',
      );
      expect(terminal, HomeWidgetRouteOutcome.confirmed);
      expect(consumeCalls, 2);
      expect(navigationCalls, 2);
      expect(coordinator.pendingRoute, isNull);
      final Uri voiceLocation = currentAppRouterLocation(qaRouter);
      expect(voiceLocation.path, AppRoutes.voice);
      expect(voiceLocation.queryParameters['autoStart'], '1');

      // Give the autoStart listen attempt a bounded window to hit the
      // (mocked) availability check, then verify no native listen happened.
      await _pumpFor(tester, const Duration(seconds: 3));
      expect(
        find.byType(VoiceInputScreen),
        findsOneWidget,
        reason: 'the real VoiceInputScreen must be mounted at the confirmed '
            'voice route',
      );
      final VoiceInputScreen mountedVoiceScreen =
          tester.widget<VoiceInputScreen>(find.byType(VoiceInputScreen));
      expect(
        mountedVoiceScreen.autoStartOverride,
        isTrue,
        reason: 'the router must construct VoiceInputScreen with '
            'autoStartOverride=true for autoStart=1',
      );
      expect(
        speechCalls.any((call) => call.method == 'initialize'),
        isTrue,
        reason: 'the autoStart listen attempt must have reached the '
            'speech_to_text availability check',
      );
      expect(
        speechCalls.any((call) => call.method == 'listen'),
        isFalse,
        reason: 'with initialize() unavailable, no native listen may be '
            'issued: no microphone recording in QA',
      );

      // ------------------------------------------------------------------
      // LEG 2 — actual chosen-date bottom sheet via the real CalendarScreen
      // constructor seam + in-memory repository (no network, no Supabase).
      // ------------------------------------------------------------------
      final EventModel sheetEvent = FixtureEvents.simple(
        id: 'qa-widget-day-sheet-event',
        title: 'QA 위젯 라우팅 일정',
        daysFromNow: 3,
      );
      final DateTime sheetDay = DateTime(
        sheetEvent.startAt!.year,
        sheetEvent.startAt!.month,
        sheetEvent.startAt!.day,
      );
      expect(sheetDay, chosenDay,
          reason: 'rendered in-memory sheet must match submitted chosen date');
      final _ProbeEventRepository sheetRepo =
          _ProbeEventRepository(<EventModel>[sheetEvent]);
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarScreen(
            eventRepository: sheetRepo,
            userId: 'qa-widget-user',
            initialDate: sheetDay,
          ),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 30),
      );
      expect(
        sheetRepo.listCalls,
        greaterThanOrEqualTo(1),
        reason: 'the in-memory repository must have served the day load',
      );
      expect(
        find.byKey(const ValueKey('calendar-day-events-draggable-sheet')),
        findsOneWidget,
        reason: 'the real chosen-date bottom sheet must open for '
            'initialDate (the production day-agenda sheet)',
      );
      expect(
        find.text(sheetEvent.title),
        findsOneWidget,
        reason: 'the fixture event for the chosen date must be listed in '
            'the day sheet',
      );

      // ignore: avoid_print
      print('WIDGET_CALENDAR_DAY_SHEET_PASS repository=in_memory '
          'date=$chosenDayText rendered_sheet=true');

      // ------------------------------------------------------------------
      // LEG 3b — autoStart drives the real VoiceInputScreen lifecycle with
      // a stub SttService (the same DI seam flow06 uses). No native mic.
      // ------------------------------------------------------------------
      final _StubSttService stubStt = _StubSttService();
      await tester.pumpWidget(
        MaterialApp(
          home: VoiceInputScreen(
            autoStartOverride: true,
            sttService: stubStt,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => stubStt.listenCalls >= 1,
        timeout: const Duration(seconds: 10),
      );
      await _pumpFor(tester, const Duration(milliseconds: 500));
      expect(
        stubStt.listenCalls,
        1,
        reason: 'autoStart must drive exactly one listen attempt through '
            'the real screen code (stub engine, permission-denied terminal '
            'result, no auto-retry storm)',
      );
      expect(
        find.byType(VoiceInputScreen),
        findsOneWidget,
        reason: 'the voice screen stays mounted after the stubbed attempt',
      );
      // ignore: avoid_print
      print('WIDGET_VOICE_AUTOSTART_FAKE_STT_PASS listen_calls=1 '
          'real_screen=true native_recording=false');
      expect(tester.takeException(), isNull,
          reason: 'probe legs must complete without UI exceptions');

      // ignore: avoid_print
      print(
        '$_probePassMarker '
        'os=${Platform.operatingSystemVersion} '
        'shared_production_controller=true '
        'production_app_state=false '
        'pure_contract=true '
        'day_route_calendar_date=true '
        'readiness_wait_ms=${_readinessDelay.inMilliseconds} '
        'readiness_survived=true '
        'login_bounce=false '
        'arrival_confirmed_calendar=true '
        'arrival_confirmed_voice_autostart=true '
        'voice_native_listen=false '
        'day_sheet_ui=true '
        'stub_engine_listen_calls=${stubStt.listenCalls}',
      );
    },
    // Functional routing/UI coverage, not accessibility semantics coverage.
    semanticsEnabled: false,
  );
}

/// In-memory EventRepository serving a fixed list (the same seam
/// test/screens/calendar_screen_test.dart uses via _AsyncEventRepository).
class _ProbeEventRepository extends EventRepository {
  _ProbeEventRepository(this._events);

  final List<EventModel> _events;
  int listCalls = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    listCalls++;
    return List<EventModel>.of(_events);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    return null;
  }

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnimplementedError('QA probe repository is read-only');
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    throw UnimplementedError('QA probe repository is read-only');
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnimplementedError('QA probe repository is read-only');
  }
}

/// Stub STT engine: the same DI seam flow06_voice_permissions_test.dart uses
/// (_PermissionGatedSttService). listen() returns a terminal
/// permission-denied result so autoStart performs exactly one attempt with
/// zero native microphone involvement.
class _StubSttService extends SttService {
  int listenCalls = 0;

  @override
  Future<void> warmUp() async {}

  @override
  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) async {
    listenCalls++;
    return SttListenResult.failure(
      failure: SttListenFailure.permissionDenied,
      message: 'QA stub engine: native microphone disabled',
    );
  }

  @override
  Future<void> cancelActiveListen() async {}

  @override
  Future<void> stopActiveListen() async {}
}

/// In-memory FeatureTourStore that reports the tour as already completed so
/// the shell never tries to launch onboarding tours during the probe.
class _CompletedTourStore implements FeatureTourStore {
  const _CompletedTourStore();

  @override
  Future<bool> shouldShow() async => false;

  @override
  Future<void> markCompleted() async {}

  @override
  Future<bool> shouldShowTip(String tipId) async => false;

  @override
  Future<void> markTipShown(String tipId) async {}
}

/// Placeholder Supabase client so Supabase.instance is non-null when the
/// router-mounted screens evaluate signed-out states. The `.invalid` host is
/// never resolvable and is never queried: the probe signs in only through
/// the in-memory AuthSessionClient, and no repository call is issued with it
/// (LEG 2 uses the in-memory repository; LEG 1 never signs the placeholder
/// client in, so CalendarScreen early-returns to its signed-out state).
Future<void> _ensurePlaceholderSupabase() async {
  try {
    await Supabase.initialize(
      url: 'https://planflow-qa-placeholder.invalid',
      anonKey: 'qa-placeholder-anon-key',
    );
  } catch (_) {
    // Already initialized in this process (an earlier probe or the host).
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  void Function()? onPump,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      return; // caller's expect() will fail with the stale condition value
    }
    await tester.pump(const Duration(milliseconds: 100));
    onPump?.call();
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final DateTime deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Fire-and-forget that must not leak unhandled async errors into the
/// integration test zone.
void unawaitedTestSafe(Future<void> future) {
  future.catchError((Object error, StackTrace stackTrace) {
    // ignore: avoid_print
    print('WIDGET_LAUNCH_QA_DELAYED_TASK_ERROR error=$error');
  });
}
