import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:planflow/core/env.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:planflow/core/router.dart' show createAppRouter;
import 'package:planflow/core/startup_route_gate.dart' show StartupRouteGate;
import 'package:planflow/providers/auth_provider.dart' show AuthProvider;
import 'package:planflow/screens/auth/login_screen.dart' show LoginScreen;
import 'package:planflow/screens/calendar/calendar_screen.dart'
    show CalendarScreen;
import 'package:planflow/data/models/event_model.dart' show EventModel;
import 'package:planflow/data/repositories/event_repository.dart'
    show EventRepository;
import 'package:planflow/services/feature_tour_service.dart'
    show FeatureTourStore;
import '../integration_test/support/widget_probe_render_wait.dart';
import '../integration_test/support/widget_probe_http_attempt_trace.dart';
import '../integration_test/support/widget_probe_calendar_aux_memory.dart';

final _date = DateTime(DateTime.now().year + 1, 10, 14);
final _location = '/calendar?date=${_date.toIso8601String().split('T').first}';

class _ControlledTourStore extends FeatureTourStore {
  _ControlledTourStore(this.result);
  final Future<bool> result;
  @override
  Future<bool> shouldShow() => result;
  @override
  Future<void> markCompleted() async {}
  @override
  Future<bool> shouldShowTip(String tipId) async => false;
  @override
  Future<void> markTipShown(String tipId) async {}
}

Future<void> _mustTimeout(Future<void> operation) async {
  try {
    await operation;
  } on TimeoutException {
    return;
  }
  fail('Expected bounded native-route render timeout');
}

class _LocalSessionClient implements AuthSessionClient {
  _LocalSessionClient(String id)
      : session = Session(
            accessToken: 'local-test-token',
            tokenType: 'bearer',
            refreshToken: 'local-test-refresh',
            expiresIn: 3600,
            user: User(
                id: id,
                appMetadata: const {},
                userMetadata: const {},
                aud: 'authenticated',
                createdAt: DateTime.utc(2026).toIso8601String()));
  Session? session;
  final events = StreamController<AuthState>.broadcast(sync: true);
  @override
  Session? get currentSession => session;
  @override
  User? get currentUser => session?.user;
  @override
  Stream<AuthState> get authStateChanges => events.stream;
  @override
  Future<void> refreshSession() async {}
  @override
  Future<void> ensureProfile([User? user]) async {}
  @override
  Future<void> signOut() async {
    session = null;
  }

  Future<void> dispose() => events.close();
}

bool _chosenDateVisible() => find
    .byType(CalendarScreen)
    .evaluate()
    .any((e) => (e.widget as CalendarScreen).initialDate == _date);

class _MemoryAuthStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    values.remove(key);
  }
}

class _NoNetworkHttpClient extends http.BaseClient {
  int attempts = 0;
  final httpTrace = WidgetProbeHttpAttemptTrace();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts++;
    httpTrace.record(method: request.method, uri: request.url);
    if (httpTrace.total <= WidgetProbeHttpAttemptTrace.maxRecords) {
      debugPrint('LOCAL_HTTP_BLOCKED ${httpTrace.records.last}');
    }
    throw StateError('Local fixture blocked HTTP before send: '
        'attempts=$attempts');
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// Read-only in-memory personal `EventRepository` for the modified positive
/// render-ready fixture. The screen is mounted with an explicit non-empty
/// `userId`, so without an injected repository the screen would fall back
/// to `EventRepository.supabase()` and the `_NoNetworkHttpClient` would
/// record a blocked attempt. We provide this stub so the personal-day
/// load path stays in-process; the supported public method
/// (`listEvents`) returns the constructor list and increments the
/// call counter, every other path is fail-closed with
/// `UnsupportedError`.
class _RenderWaitPersonalEventRepository extends EventRepository {
  _RenderWaitPersonalEventRepository(this._events);

  final List<EventModel> _events;
  int listEventsCalls = 0;
  int fetchEventCalls = 0;

  @override
  Future<List<EventModel>> listEvents({String? userId}) async {
    listEventsCalls++;
    return List<EventModel>.of(_events);
  }

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    fetchEventCalls++;
    return null;
  }

  @override
  Future<EventModel> createEvent(EventModel event) {
    throw UnsupportedError(
      '_RenderWaitPersonalEventRepository is read-only; createEvent is fail-closed.',
    );
  }

  @override
  Future<EventModel> updateEvent(EventModel event) {
    throw UnsupportedError(
      '_RenderWaitPersonalEventRepository is read-only; updateEvent is fail-closed.',
    );
  }

  @override
  Future<void> deleteEvent(String eventId, {String? userId}) {
    throw UnsupportedError(
      '_RenderWaitPersonalEventRepository is read-only; deleteEvent is fail-closed.',
    );
  }
}

void main() {
  final priorPreferences = SharedPreferencesAsyncPlatform.instance;
  final wasReady = AppEnv.isSupabaseReady;
  Supabase? ownedSdk;
  _NoNetworkHttpClient? blockingClient;
  var completedCases = 0;
  final memoryAuthStorage = _MemoryAuthStorage();
  setUpAll(() async {
    if (wasReady) throw StateError('Refusing shared AppEnv readiness');
    Supabase? priorSdk;
    try {
      priorSdk = Supabase.instance;
    } on AssertionError catch (error) {
      if (!error.toString().contains(
          'You must initialize the supabase instance before calling Supabase.instance')) {
        rethrow;
      }
    }
    if (priorSdk != null) throw StateError('Refusing existing SDK singleton');
    final client = _NoNetworkHttpClient();
    blockingClient = client;
    expect(client.attempts, 0);
    debugPrint('LOCAL_CONFIG valid=${AppEnv.hasValidSupabaseConfig}');
    final sdk = await Supabase.initialize(
      url: 'https://planflow-render-wait.invalid',
      anonKey: 'local-noncredential-dummy-key',
      httpClient: client,
      debug: false,
      authOptions: FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: const EmptyLocalStorage(),
          pkceAsyncStorage: memoryAuthStorage),
    );
    ownedSdk = sdk;
    expect(identical(Supabase.instance, sdk), isTrue);
    expect(sdk.isInitialized, isTrue);
    expect(sdk.client.auth.currentSession, isNull);
    expect(sdk.client.auth.currentUser, isNull);
    expect(client.attempts, 0);
    AppEnv.markSupabaseInitialized();
    expect(AppEnv.isSupabaseReady, isTrue);
    debugPrint(
        'LOCAL_SDK initialized=true ownedIdentity=true sdkUser=null attempts=0');
  });
  tearDownAll(() async {
    final sdk = ownedSdk;
    final client = blockingClient;
    try {
      client?.httpTrace.leg = WidgetProbeHttpLeg.teardown;
      debugPrint(
          'LOCAL_HTTP_TOTAL attempts=${client?.attempts} trace=${client?.httpTrace.total}');
      if (sdk != null) {
        expect(identical(Supabase.instance, sdk), isTrue);
        expect(client!.attempts, 0);
        expect(sdk.client.auth.currentUser, isNull);
        await sdk.dispose();
        expect(sdk.isInitialized, isFalse);
      }
    } finally {
      client?.close();
      memoryAuthStorage.values.clear();
      if (sdk != null) {
        if (wasReady) {
          AppEnv.markSupabaseInitialized();
        } else {
          AppEnv.resetSupabaseInitializationState();
        }
      }
      SharedPreferencesAsyncPlatform.instance = priorPreferences;
    }
    expect(client?.attempts, 0);
    expect(client?.closed, isTrue);
    expect(memoryAuthStorage.values, isEmpty);
    expect(AppEnv.isSupabaseReady, wasReady);
    expect(identical(SharedPreferencesAsyncPlatform.instance, priorPreferences),
        isTrue);
    expect(completedCases, 5);
    debugPrint(
        'LOCAL_SDK disposed=true clientClosed=true attempts=0 cases=5 publicReadyRestored=true preferencesRestored=true');
  });
  setUp(() {
    expect(ownedSdk, isNotNull);
    expect(identical(Supabase.instance, ownedSdk), isTrue);
    expect(blockingClient!.httpTrace.total, blockingClient!.attempts);
    expect(blockingClient!.attempts, 0);
    expect(ownedSdk!.client.auth.currentUser, isNull);
    expect(AppEnv.isSupabaseReady, isTrue);
    blockingClient!.httpTrace.leg = WidgetProbeHttpLeg.delayedAuthCalendarRoute;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    ShellScreen.resetSessionOnboardingStateForTest();
  });
  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = priorPreferences;
    expect(blockingClient!.httpTrace.total, blockingClient!.attempts);
    expect(blockingClient!.attempts, 0);
    expect(ownedSdk!.client.auth.currentUser, isNull);
    expect(AppEnv.isSupabaseReady, isTrue);
    completedCases++;
    debugPrint(
        'LOCAL_SDK case=$completedCases attempts=0 sdkUser=null ready=true');
    ShellScreen.resetSessionOnboardingStateForTest();
  });
  testWidgets(
      'real router Shell delays route render until controlled onboarding gate releases',
      (tester) async {
    final release = Completer<bool>();
    Timer? releaseTimer;
    final client = _LocalSessionClient('render-wait-test');
    final auth = AuthProvider(authService: client)..start();
    await tester.pump();
    expect(auth.hasResolvedInitialSession, isTrue);
    expect(auth.hasAttemptedStartupSync, isTrue);
    expect(auth.hasActiveSession, isTrue);
    expect(auth.userId, 'render-wait-test');
    final gate = StartupRouteGate();
    final router = createAppRouter(
        authProviderOverride: auth,
        startupRouteGateOverride: gate,
        featureTourStore: _ControlledTourStore(release.future),
        runPostTourOnboardingStages: false,
        runShellStartupTasks: false);
    try {
      router.go(_location);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();
      final uriMatches =
          router.routeInformationProvider.value.uri.toString() == _location;
      expect(uriMatches, isTrue,
          reason:
              'negative control: URI may confirm while Shell is still loading');
      expect(find.byType(CalendarScreen), findsNothing,
          reason:
              'old immediate assertion is false while the delayed store gate is unresolved');
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(_chosenDateVisible(), isFalse);
      expect(gate.requiredSetupCompleteFor(auth.userId), isFalse);
      var bouncedToLogin = false;
      final wait = waitForNativeRouteRender(tester,
          isRendered: () =>
              router.routeInformationProvider.value.uri.toString() ==
                  _location &&
              gate.requiredSetupCompleteFor(auth.userId) &&
              !gate.startupWorkDeferred &&
              !bouncedToLogin &&
              _chosenDateVisible(),
          onPump: () {
            bouncedToLogin = bouncedToLogin ||
                find.byType(LoginScreen).evaluate().isNotEmpty;
            releaseTimer ??= Timer(const Duration(milliseconds: 20),
                () => release.complete(false));
          },
          timeout: const Duration(seconds: 2),
          step: const Duration(milliseconds: 20));
      await wait;
      expect(bouncedToLogin, isFalse);
      expect(_chosenDateVisible(), isTrue);
      expect(router.routeInformationProvider.value.uri.toString(), _location);
      expect(gate.requiredSetupCompleteFor(auth.userId), isTrue);
      expect(find.byType(CalendarScreen), findsOneWidget);
    } finally {
      releaseTimer?.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
      if (!release.isCompleted) release.complete(false);
      await tester.pump();
      router.dispose();
      gate.dispose();
      auth.dispose();
      await client.dispose();
    }

    // A second phase in the same case exercises the real calendar public DI
    // seams without replacing the delayed-router positive control above.
    final memory = CalendarAuxMemory();
    final personalRepo =
        _RenderWaitPersonalEventRepository(const <EventModel>[]);
    try {
      await tester.pumpWidget(MaterialApp(
        home: CalendarScreen(
          eventRepository: personalRepo,
          userId: 'render-wait-test',
          initialDate: _date,
          groupCalendarOverlayProvider: memory.overlay,
          groupInstructionInboxService: memory.inbox,
        ),
      ));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(_chosenDateVisible(), isTrue);
      // Observe screen-originated reads before any explicit post-unmount load.
      expect(personalRepo.listEventsCalls, greaterThanOrEqualTo(1));
      expect(memory.memoryGroups.listGroupsCalls, greaterThanOrEqualTo(1));
      expect(memory.memoryComments.unconfirmedForUserCalls,
          greaterThanOrEqualTo(1));
      expect(memory.context.error, isNull);
      expect(memory.overlay.error, isNull);
      expect(AppEnv.isSupabaseReady, isTrue);
      debugPrint('LOCAL_RENDER_READY_AUX_PASS '
          'group_list_calls=${memory.memoryGroups.listGroupsCalls} '
          'comment_unconfirmed_calls=${memory.memoryComments.unconfirmedForUserCalls} '
          'personal_list_calls=${personalRepo.listEventsCalls} '
          'context_error=${memory.context.error} '
          'overlay_error=${memory.overlay.error} '
          'ready=${AppEnv.isSupabaseReady}');
    } finally {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        void noopListener() {}
        expect(() => memory.overlay.addListener(noopListener), returnsNormally,
            reason: 'CalendarScreen must not dispose a borrowed overlay');
        memory.overlay.removeListener(noopListener);
        final previousListCalls = memory.memoryGroups.listGroupsCalls;
        await memory.overlay.loadForMonth(
          'render-wait-test',
          DateTime(_date.year, _date.month),
        );
        expect(memory.memoryGroups.listGroupsCalls,
            greaterThan(previousListCalls));
        expect(memory.context.error, isNull);
        expect(memory.overlay.error, isNull);
        debugPrint('LOCAL_AUX_CALLER_OWNERSHIP_PASS postUnmountLoad=true');
      } finally {
        await memory.disposeAfterWidgetUnmount();
      }
    }
  });

  testWidgets(
      'permanently pending real startup gate times out without URI-only success',
      (tester) async {
    final release = Completer<bool>();
    final client = _LocalSessionClient('render-wait-pending');
    final auth = AuthProvider(authService: client)..start();
    await tester.pump();
    expect(auth.hasResolvedInitialSession, isTrue);
    expect(auth.hasAttemptedStartupSync, isTrue);
    expect(auth.hasActiveSession, isTrue);
    expect(auth.userId, 'render-wait-pending');
    final gate = StartupRouteGate();
    final router = createAppRouter(
        authProviderOverride: auth,
        startupRouteGateOverride: gate,
        featureTourStore: _ControlledTourStore(release.future),
        runPostTourOnboardingStages: false,
        runShellStartupTasks: false);
    try {
      router.go(_location);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();
      expect(router.routeInformationProvider.value.uri.toString(), _location);
      await _mustTimeout(waitForNativeRouteRender(tester,
          isRendered: () =>
              router.routeInformationProvider.value.uri.toString() ==
                  _location &&
              _chosenDateVisible(),
          timeout: const Duration(milliseconds: 100),
          step: const Duration(milliseconds: 20)));
      expect(find.byType(CalendarScreen), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(gate.requiredSetupCompleteFor(auth.userId), isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!release.isCompleted) release.complete(false);
      await tester.pump();
      router.dispose();
      gate.dispose();
      auth.dispose();
      await client.dispose();
    }
  });

  testWidgets('wrong chosen date cannot satisfy render readiness',
      (tester) async {
    final router = GoRouter(initialLocation: _location, routes: [
      GoRoute(
          path: '/calendar',
          builder: (context, state) =>
              CalendarScreen(initialDate: _date.add(const Duration(days: 1)))),
    ]);
    try {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(router.routeInformationProvider.value.uri.toString(), _location);
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(_chosenDateVisible(), isFalse);
      await _mustTimeout(waitForNativeRouteRender(tester,
          isRendered: () =>
              router.routeInformationProvider.value.uri.toString() ==
                  _location &&
              _chosenDateVisible(),
          timeout: const Duration(milliseconds: 100),
          step: const Duration(milliseconds: 20)));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    }
  });

  testWidgets(
      'offstage correct-date calendar is diagnostic only, not rendered readiness',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
      Offstage(offstage: true, child: CalendarScreen(initialDate: _date)),
      const SizedBox.expand(),
    ])));
    expect(find.byType(CalendarScreen), findsNothing);
    expect(find.byType(CalendarScreen, skipOffstage: false), findsOneWidget);
    await _mustTimeout(waitForNativeRouteRender(tester,
        isRendered: _chosenDateVisible,
        timeout: const Duration(milliseconds: 100),
        step: const Duration(milliseconds: 20)));
    expect(find.byType(CalendarScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('login bounce observed during wait cannot satisfy readiness',
      (tester) async {
    var loginObserved = false;
    final view = ValueNotifier<int>(0);
    final router = GoRouter(initialLocation: _location, routes: [
      GoRoute(
          path: '/calendar',
          builder: (context, state) => ValueListenableBuilder<int>(
              valueListenable: view,
              builder: (context, value, child) => switch (value) {
                    1 => const LoginScreen(),
                    2 => CalendarScreen(initialDate: _date),
                    _ => const CircularProgressIndicator(),
                  })),
    ]);
    Timer? bounce;
    Timer? arrival;
    try {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      bounce = Timer(const Duration(milliseconds: 20), () => view.value = 1);
      arrival = Timer(const Duration(milliseconds: 60), () => view.value = 2);
      await _mustTimeout(waitForNativeRouteRender(tester,
          isRendered: () =>
              router.routeInformationProvider.value.uri.toString() ==
                  _location &&
              !loginObserved &&
              _chosenDateVisible(),
          onPump: () {
            loginObserved =
                loginObserved || find.byType(LoginScreen).evaluate().isNotEmpty;
          },
          timeout: const Duration(milliseconds: 100),
          step: const Duration(milliseconds: 20)));
      expect(loginObserved, isTrue);
      expect(_chosenDateVisible(), isTrue,
          reason: 'arrival alone must not erase a captured login bounce');
      expect(router.routeInformationProvider.value.uri.toString(), _location);
    } finally {
      bounce?.cancel();
      arrival?.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      view.dispose();
    }
  });
}
