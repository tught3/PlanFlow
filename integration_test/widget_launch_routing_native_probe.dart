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
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
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
import 'package:planflow/core/env.dart' show AppEnv;
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
import 'package:planflow/l10n/app_localizations.dart' show AppLocalizations;
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

import 'support/widget_probe_render_wait.dart';
import 'support/widget_probe_speech_stub.dart';

import '_harness/fakes/fake_auth_service.dart';
import '_harness/seed/fixture_events.dart';

const String _probePassMarker = 'WIDGET_LAUNCH_ROUTING_PROBE_PASS';
const String _probeSkipMarker = 'WIDGET_LAUNCH_ROUTING_PROBE_SKIPPED';

// Pinned protocol identity (channel + method names) lives on the shared
// `WidgetProbeSpeechStub` helper so the fixture and the desktop unit
// test assert against the same exact consts. The legacy inline
// `MethodChannel('cjcodezonye.github.io/speech_to_text')` and
// `hasPermission` (camelCase) mock identities were a channel-identity
// bug: the real `speech_to_text_platform_interface` 2.3.0 plugin
// installs at `plugin.csdcorp.com/speech_to_text` and uses
// `has_permission` (snake_case). The helper closes that gap.

/// Readiness delay for the in-memory auth session. Must be strictly greater
/// than the legacy 1.2s production cliff (10 x 120ms) and strictly less than
/// AuthProvider._bootstrapInitialSession's first-event timeout (2s) so the
/// signed-in event deterministically wins the bootstrap wait.
const Duration _readinessDelay = Duration(milliseconds: 1600);

/// Hard cap on timestamped trace lines printed by the QA recorder. Trace
/// lines are diagnostic only — they MUST NOT be treated as pass criteria.
const int _maxTraceEvents = 20;

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

      // Compile-time QA defines must survive AppEnv's real validation before
      // this fixture may initialize any SDK or construct a provider. This is
      // not a readiness bypass: the owned placeholder SDK init below remains
      // separately required and fail-closed.
      if (!AppEnv.hasValidSupabaseConfig) {
        throw StateError(
          'Widget routing native QA requires valid compile-time Supabase QA defines',
        );
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
      final Stopwatch readinessClock = Stopwatch()..start();
      final _QaTrace trace = _QaTrace(
        clock: readinessClock,
        emit: (line) {
          // ignore: avoid_print
          print(line);
        },
      );
      trace.add('leg1_setup');

      // Prove ownership before shared mutation or AuthProvider construction.
      expect(
          _hasPriorSupabaseOwnershipConflict(
              appReady: true, sdkInitialized: false),
          isTrue);
      expect(
          _hasPriorSupabaseOwnershipConflict(
              appReady: false, sdkInitialized: true),
          isTrue);
      final _NoNetworkHttpClient blockingClient =
          await _ensurePlaceholderSupabase();
      trace.add(
        'placeholder_ready',
        <String, Object?>{
          'appenv_ready': AppEnv.isSupabaseReady,
          'attempts': blockingClient.attempts,
        },
      );

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
      // Isolated test lifetime only, not production PlanFlowAppState.mounted.
      bool probeLifetimeActive = true;
      late final HomeWidgetRouteCoordinator coordinator;
      coordinator = HomeWidgetRouteCoordinator(
        readinessResolver: () {
          final resolved = qaAuth.hasResolvedInitialSession;
          final signed = qaAuth.isSignedIn;
          if (!resolved) return HomeWidgetRouteReadiness.notReady;
          return signed
              ? HomeWidgetRouteReadiness.ready
              : HomeWidgetRouteReadiness.needsAuth;
        },
        wakeSignal: qaAuth,
        currentUri: () => currentAppRouterLocation(qaRouter),
        navigate: (route) {
          navigationCalls++;
          if (firstNavigationElapsedMs < 0) {
            firstNavigationElapsedMs = readinessClock.elapsedMilliseconds;
          }
          trace.add(
            'navigate',
            <String, Object?>{
              'route': route,
              'delegate': currentAppRouterLocation(qaRouter).toString(),
              'phase': coordinator.phase.toString(),
              'generation': coordinator.generation,
            },
          );
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
        consume: (route) async {
          consumeCalls++;
          trace.add(
            'consume',
            <String, Object?>{'route': route, 'n': consumeCalls},
          );
        },
        onDeferred: (route, readiness) {
          trace.add(
            'deferred',
            <String, Object?>{
              'route': route,
              'readiness': readiness.toString(),
              'phase': coordinator.phase.toString(),
              'has_pending': coordinator.hasPendingRoute,
              'session_status': qaAuth.sessionStatus.toString(),
              'ready': AppEnv.isSupabaseReady,
            },
          );
        },
        onTerminal: (route, outcome) {
          terminal = outcome;
          terminalRoute = route;
          trace.add(
            'terminal',
            <String, Object?>{
              'route': route,
              'outcome': outcome.toString(),
              'phase': coordinator.phase.toString(),
              'nav': navigationCalls,
              'consume': consumeCalls,
            },
          );
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

      // Subscribe FakeAuth BEFORE scheduling the delayed emit AND BEFORE
      // pumpWidget, so the broadcast stream has a listener by the time the
      // 1.6s timer fires (broadcast streams do not buffer late events).
      expect(
        qaAuth.hasResolvedInitialSession,
        isFalse,
        reason: 'qaAuth must start unresolved; AuthProvider.bootstrap has '
            'not yet observed the first AuthState event',
      );
      qaAuth.start();
      trace.add(
        'qaAuth_started',
        <String, Object?>{
          'has_resolved': qaAuth.hasResolvedInitialSession,
          'session_status': qaAuth.sessionStatus.toString(),
        },
      );

      // Delayed readiness: no session events at all until 1.6s, then a
      // signed-in session. hasResolvedInitialSession stays false for the
      // whole window that used to kill the pending route after ~1.2s.
      unawaitedTestSafe(
        Future<void>.delayed(_readinessDelay, () {
          authClient.emitSignedIn(FixtureSession.build());
          trace.add('emit_signed_in');
        }),
      );

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: qaRouter,
          locale: const Locale('ko', 'KR'),
          // Production Material/Cupertino + AppLocalizations delegates
          // silence the Korean delegate warning exposed in native phone
          // logs and keep the rendered widget tree aligned with real
          // navigator behaviors.
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
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
      final Finder calendarFinder = find.byType(CalendarScreen);
      final Set<String> renderStates = <String>{};
      int renderDiagnosticLines = 0;
      void recordRenderState() {
        if (find.byType(LoginScreen).evaluate().isNotEmpty) {
          loginBounceFrames.add(readinessClock.elapsedMilliseconds);
        }
        final Uri location = currentAppRouterLocation(qaRouter);
        final List<Element> visible = calendarFinder.evaluate().toList();
        final List<Element> all = find
            .byType(CalendarScreen, skipOffstage: false)
            .evaluate()
            .toList();
        final String date = visible.isEmpty
            ? 'none'
            : ((visible.single.widget as CalendarScreen)
                    .initialDate
                    ?.toIso8601String() ??
                'null');
        final String state = 'path=${location.path} query=${location.query} '
            'visible=${visible.length} all=${all.length} date=$date '
            'gate=${qaGate.widgetLaunchPending} '
            'progress=${find.byType(CircularProgressIndicator).evaluate().length} '
            'scheduled=${tester.binding.hasScheduledFrame} '
            'phase=${tester.binding.schedulerPhase}';
        if (renderStates.add(state) && renderDiagnosticLines < 4) {
          renderDiagnosticLines++;
          // ignore: avoid_print
          print('WIDGET_NATIVE_RENDER_STATE $state');
        }
      }

      try {
        await waitForNativeRouteRender(
          tester,
          isRendered: () {
            final List<Element> visible = calendarFinder.evaluate().toList();
            if (visible.length != 1 || qaGate.widgetLaunchPending) return false;
            final DateTime? date =
                (visible.single.widget as CalendarScreen).initialDate;
            final Uri location = currentAppRouterLocation(qaRouter);
            return date != null &&
                date.year == chosenDay.year &&
                date.month == chosenDay.month &&
                date.day == chosenDay.day &&
                location.path == AppRoutes.calendar &&
                location.queryParameters['date'] == chosenDayText;
          },
          onPump: recordRenderState,
        );
      } catch (_) {
        recordRenderState();
        rethrow;
      }
      recordRenderState();
      expect(calendarFinder, findsOneWidget,
          reason: 'the real CalendarScreen must be visible at the chosen date');
      final CalendarScreen renderedCalendar = tester.widget(calendarFinder);
      expect(renderedCalendar.initialDate!.year, chosenDay.year);
      expect(renderedCalendar.initialDate!.month, chosenDay.month);
      expect(renderedCalendar.initialDate!.day, chosenDay.day);
      expect(currentAppRouterLocation(qaRouter).path, AppRoutes.calendar);
      expect(currentAppRouterLocation(qaRouter).queryParameters['date'],
          chosenDayText);
      expect(qaGate.widgetLaunchPending, isFalse,
          reason: 'the launch gate must complete after confirmation');
      expect(loginBounceFrames, isEmpty,
          reason:
              'login must remain suppressed through visible route rendering');

      // Probe-level invariants for the placeholder init fix:
      // 1) No HTTP may leak through the blocking client — any non-zero
      //    attempt means a real backend host was reached and the probe
      //    MUST NOT report native green.
      // 2) AuthProvider resolved the initial session via the FakeAuth
      //    subscription (proven by isSignedIn == true after the 1.6s
      //    delay) so the resolution chain survived the readiness window.
      // 3) QA trace buffer never grew beyond its hard cap.
      expect(
        qaAuth.hasResolvedInitialSession,
        isTrue,
        reason: 'AuthProvider must have resolved the initial session '
            'via the FakeAuth subscription within the bootstrap 2s window',
      );
      expect(
        qaAuth.isSignedIn,
        isTrue,
        reason: 'AuthProvider must be signed in after the 1.6s delayed emit',
      );
      expect(
        trace.lines.length,
        lessThanOrEqualTo(_maxTraceEvents),
        reason: 'trace buffer must respect its hard cap',
      );

      // ignore: avoid_print
      print('WIDGET_SHARED_ROUTING_DELAYED_AUTH_PASS '
          'controller=production delay_ms=$firstNavigationElapsedMs '
          'navigation_calls=$navigationCalls consume_calls=$consumeCalls '
          'production_app_state=false '
          'blocking_attempts=${blockingClient.attempts} '
          'trace_lines=${trace.lines.length}');

      // Warm submitted URI on the same live router (not external delivery).
      // Install the pinned speech_to_text protocol mock through the
      // shared helper so both this fixture and
      // `test/widget_probe_speech_stub_test.dart` assert against the
      // same exact channel/method identity. The helper enforces:
      //   * `initialize` returns false (unavailable) on every call.
      //   * `has_permission` preserves the regression-original true.
      //   * `listen` is forbidden: counted and discarded, no recording.
      final WidgetProbeSpeechStub speechStub = WidgetProbeSpeechStub();
      final WidgetProbeSpeechStubState speechState = speechStub.install();
      addTearDown(speechStub.remove);

      // Capture public [STT] phase=start / attempt=normal traces that
      // `SttService._logPhase` emits via debugPrint. The capture is
      // installed BEFORE the warm voice route is submitted and removed
      // in an outer `addTearDown` so the original `debugPrint` is
      // restored even if the surrounding test fails.
      speechStub.installDebugPrintCapture(speechState);
      addTearDown(() => speechStub.removeDebugPrintCapture(speechState));

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

      // Existing legacy assert 601 RETAINed. Method name resolved via
      // the shared helper const so the fixture and the unit test assert
      // against the same pinned identity (the legacy wrong
      // `cjcodezonye.github.io/speech_to_text` channel + `hasPermission`
      // camelCase name would never have observed this call).
      expect(
        speechState.calls.any((call) =>
            call.method == WidgetProbeSpeechStub.pinnedInitializeMethod),
        isTrue,
        reason: 'the autoStart listen attempt must have reached the '
            'speech_to_text availability check on the pinned channel',
      );
      // Existing legacy assert RETAINed verbatim.
      expect(
        speechState.calls.any((call) => call.method == 'listen'),
        isFalse,
        reason: 'with initialize() unavailable, no native listen may be '
            'issued: no microphone recording in QA',
      );

      // startAttempt EXACT ONE: the post-frame _startVoiceFlow path
      // must have observed exactly one [STT] phase=start /
      // attempt=normal trace. warmUp-only init (count == 0) and
      // repeated autoStart attempts (count > 1) both fail.
      expect(
        speechState.startAttempt,
        1,
        reason: 'exactly one public [STT] phase=start / attempt=normal trace '
            'must be observed; warmUp-only init would observe 0, '
            'repeated autoStart attempts would observe > 1',
      );
      // warmUp (initState) + autoStart (post-frame listen) must both
      // have invoked initialize on the pinned channel. warmUp-only
      // init (count == 1) fails this guard.
      expect(
        speechState.initCount,
        greaterThanOrEqualTo(2),
        reason: 'pinned initialize must have been called by both warmUp and '
            'the post-frame autoStart path; warmUp-only init cannot '
            'prove autoStart',
      );
      // Speech calls listen ZERO remains required: no native mic.
      expect(
        speechState.listenCount,
        0,
        reason: 'with initialize() returning false, the production listen '
            'path must abort before reaching the native listen API',
      );
      // Correct actual post-start availability verify.
      expect(
        speechState.postStartAvailability,
        isTrue,
        reason: 'post-start availability requires exactly one start trace '
            'and at least one initialize observed after that trace; '
            'pre-start warmUp counts alone must NOT pass',
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

      // Capped non-secret receipt of the pinned-protocol counts observed
      // by the shared helper. Trace cap mirrors the existing
      // _maxTraceEvents = 20 contract: this line is diagnostic only and
      // never serves as a pass criterion. Counts are bounded integers;
      // no message text is recorded.
      final Map<String, int> receipt = speechState.receipt();
      // ignore: avoid_print
      print('WIDGET_SPEECH_PROBE_RECEIPT init=${receipt['init']} '
          'listen=${receipt['listen']} '
          'start_attempt=${receipt['start_attempt']} '
          'init_before_start=${receipt['init_before_start']} '
          'init_after_start=${receipt['init_after_start']} '
          'post_start_availability=${speechState.postStartAvailability} '
          'pinned_channel=${WidgetProbeSpeechStub.pinnedChannelName} '
          'has_permission_method='
          '${WidgetProbeSpeechStub.pinnedHasPermissionMethod} '
          'initialize_method='
          '${WidgetProbeSpeechStub.pinnedInitializeMethod} '
          'cap=$_maxTraceEvents');

      expect(
        blockingClient.attempts,
        0,
        reason: 'HTTP attempts were blocked locally and not transmitted; '
            'attempts=${blockingClient.attempts}',
      );
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

/// Local no-network HTTP client injected into the placeholder Supabase
/// initialize so any unintended HTTP attempt is recorded and short-circuited
/// (fail-closed). Increments [attempts] before throwing so the probe can
/// assert zero outbound traffic. Disposal is owned by the test fixture and
/// limited to this client only — the shared `Supabase.instance` is never
/// disposed by the probe (the SDK may be shared with other probes in the
/// same test binary).
class _NoNetworkHttpClient extends http.BaseClient {
  int attempts = 0;
  String? lastMethod;
  String? lastHost;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts++;
    lastMethod = request.method;
    lastHost = request.url.host;
    throw StateError(
      'QA HTTP attempt blocked locally and not transmitted '
      '(method=$lastMethod host=$lastHost)',
    );
  }
}

/// Capped timestamped QA recorder. Lines print via [emit] (typically
/// `print`) but the recorder never serves as a pass criterion — pass is
/// always asserted via `expect(...)` on the actual state.
class _QaTrace {
  _QaTrace({required this.clock, required this.emit});

  final Stopwatch clock;
  final void Function(String line) emit;
  final List<String> lines = <String>[];

  void add(String event,
      [Map<String, Object?> extras = const <String, Object?>{}]) {
    if (lines.length >= _maxTraceEvents) {
      return;
    }
    final int elapsed = clock.elapsedMilliseconds;
    final List<String> parts = <String>[
      '$event t=${elapsed}ms',
    ];
    extras.forEach((String key, Object? value) {
      parts.add('$key=$value');
    });
    final String line = 'WIDGET_LAUNCH_QA_TRACE ${parts.join(' ')}';
    lines.add(line);
    emit(line);
  }
}

/// Placeholder Supabase client so `Supabase.instance` is non-null when the
/// router-mounted screens evaluate signed-out states. The `.invalid` host is
/// never resolvable and must never be queried; the probe signs in only
/// through the in-memory FakeAuthService and uses the in-memory repository
/// for LEG 2 (LEG 1 never signs the placeholder client in via Supabase, so
/// CalendarScreen early-returns to its signed-out state).
///
/// The init takes ownership of the placeholder and only then flips
/// `AppEnv.markSupabaseInitialized()`. Failure modes:
///
///   * Real init errors propagate (`rethrow`) — they are never swallowed.
///   * If the blocking client observed any HTTP attempt during init, the
///     fixture reports this in trace and refuses to flip ready (fail-closed).
///   * When `AppEnv.isSupabaseReady` was already true on entry (i.e. init
///     was a no-op returning the existing instance), the fixture cannot
///     prove ownership of the placeholder and also refuses to flip ready.
///
/// Both disposals are registered as teardowns:
///   * Restore the prior `AppEnv.isSupabaseReady` flag without falsifying
///     an already-ready shared client.
///   * Close only the OWNED blocking HTTP client; never dispose the
///     shared `Supabase.instance`.
/// Supabase 2.12.4 public API: `instance` documents an AssertionError until
/// initialized, and the returned instance exposes `isInitialized`.
Future<_NoNetworkHttpClient> _ensurePlaceholderSupabase() async {
  if (AppEnv.isSupabaseReady) {
    throw StateError('Refusing QA init: AppEnv already reports ready');
  }
  Supabase? priorInstance;
  try {
    priorInstance = Supabase.instance;
  } on AssertionError catch (error) {
    if (!error.toString().contains(
          'You must initialize the supabase instance before calling Supabase.instance',
        )) {
      rethrow;
    }
  }
  if (priorInstance != null && priorInstance.isInitialized) {
    throw StateError('Refusing QA init: existing usable Supabase client');
  }

  final _NoNetworkHttpClient client = _NoNetworkHttpClient();
  Supabase? createdInstance;
  bool appEnvMarkedByUs = false;
  try {
    createdInstance = await Supabase.initialize(
      url: 'https://planflow-qa-placeholder.invalid',
      anonKey: 'qa-placeholder-anon-key',
      httpClient: client,
      debug: false,
    );
    if (!createdInstance.isInitialized || client.attempts != 0) {
      throw StateError(
        'Refusing QA AuthProvider setup: owned init failed clean checks '
        '(initialized=${createdInstance.isInitialized} attempts=${client.attempts})',
      );
    }
    AppEnv.markSupabaseInitialized();
    appEnvMarkedByUs = true;
    if (!AppEnv.isSupabaseReady) {
      throw StateError('Owned init failed to mark AppEnv ready');
    }
  } catch (_) {
    Supabase? partialInstance = createdInstance;
    if (partialInstance == null) {
      try {
        final Supabase candidate = Supabase.instance;
        if (candidate.isInitialized) partialInstance = candidate;
      } on AssertionError catch (error) {
        if (!error.toString().contains(
              'You must initialize the supabase instance before calling Supabase.instance',
            )) {
          rethrow;
        }
      }
    }
    if (partialInstance != null && partialInstance.isInitialized) {
      await partialInstance.dispose();
    }
    client.close();
    if (appEnvMarkedByUs) {
      AppEnv.resetSupabaseInitializationState();
    }
    rethrow;
  }

  // First registered teardown runs last: provider/router cleanup precedes
  // disposal of only the instance just created here.
  addTearDown(() async {
    await createdInstance!.dispose();
    client.close();
    AppEnv.resetSupabaseInitializationState();
  });
  return client;
}

bool _hasPriorSupabaseOwnershipConflict({
  required bool appReady,
  required bool sdkInitialized,
}) =>
    appReady || sdkInitialized;

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
