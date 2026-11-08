import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/router.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/screens/onboarding/legacy_intro_screen.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:planflow/services/feature_tour_service.dart';
import 'package:planflow/services/oauth_callback_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/test_guide_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    AppEnv.markSupabaseInitialized();
    OAuthCallbackHandler.clearInMemoryPendingCallbackForTest();
    OAuthCallbackHandler.clearLatestUserMessage();
    ShellScreen.resetSessionOnboardingStateForTest();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
    OAuthCallbackHandler.clearInMemoryPendingCallbackForTest();
    ShellScreen.resetSessionOnboardingStateForTest();
  });

  testWidgets(
      'OAuth callback follows production router into required three-page intro',
      (tester) async {
    await Supabase.initialize(
      url: 'https://integration-test.supabase.co',
      anonKey: 'integration-test-anon-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
    AppEnv.markSupabaseInitialized();
    final authSession = _FakeAuthSessionClient();
    final auth = AuthProvider(authService: authSession);
    final routeGate = StartupRouteGate();
    // Use the real production store: the OAuth callback path runs against
    // SharedPreferencesFeatureTourStore so the test asserts the actual
    // `feature_tour_completed_v1` key rather than a parallel mock surface.
    final tourStore = const SharedPreferencesFeatureTourStore();
    final callbackAdapter = _FakeOAuthCallbackSessionAdapter(authSession);
    auth.start();
    final handler = OAuthCallbackHandler(
      authProviderOverride: auth,
      sessionAdapter: callbackAdapter,
      supabaseReadyOverride: true,
    );
    OAuthCallbackHandler.markPendingLogin(PlanFlowOAuthProvider.google);
    await OAuthCallbackHandler.flushPendingCallbackPersistenceForTest();
    final router = createAppRouter(
      authProviderOverride: auth,
      startupRouteGateOverride: routeGate,
      featureTourStore: tourStore,
      runPostTourOnboardingStages: false,
      runShellStartupTasks: false,
      supabaseReadyOverride: true,
    );
    addTearDown(() {
      router.dispose();
      auth.dispose();
      routeGate.dispose();
      authSession.dispose();
    });
    await tester.pumpWidget(
      TestGuideScope(
        auth: auth,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await _pumpUntil(
        tester,
        () =>
            router.routeInformationProvider.value.uri.path == AppRoutes.login);
    expect(router.routeInformationProvider.value.uri.path, AppRoutes.login);

    await tester.runAsync(() => handler.handleAuthCallbackUri(
          Uri.parse('planflow://auth-callback?code=integration-test-code'),
        ));
    await _pumpUntil(
        tester, () => find.byType(LegacyIntroScreen).evaluate().isNotEmpty);

    expect(callbackAdapter.receivedUri?.queryParameters['code'],
        'integration-test-code');
    expect(auth.isSignedIn, isTrue);
    expect(find.byType(LegacyIntroScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('legacy-intro-skip-button')), findsNothing);

    final next = find.byKey(const ValueKey('legacy-intro-next-button'));
    for (final title in [
      '말하면 일정이 정리돼요',
      'AI 대화로 일정도 고쳐요',
      '출발과 브리핑을 챙겨드려요',
    ]) {
      expect(find.text(title), findsOneWidget);
      expect(await tourStore.shouldShow(), isTrue,
          reason: 'only the final confirmation persists the intro');
      await tester.tap(next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }
    await _pumpUntil(tester,
        () => router.routeInformationProvider.value.uri.path == AppRoutes.home);
    // The route flips to home inside the Navigator pop, but the ShellScreen
    // build happens on a later frame. Pump until the protected shell is
    // actually in the tree.
    await _pumpUntil(
        tester, () => find.byType(ShellScreen).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));

    // Real persistence assertion: the production store key is written.
    expect(await tourStore.shouldShow(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(SharedPreferencesFeatureTourStore.completedKey),
        equals(true));

    // OAuth callback path: the required tour gate releases and the user
    // reaches the protected shell/calendar home.
    expect(router.routeInformationProvider.value.uri.path, AppRoutes.home);
    expect(find.byType(ShellScreen), findsOneWidget);
  });

  testWidgets('optional/profile tour (default) still shows Skip and completes',
      (tester) async {
    final store = _SkipProbeStore();
    await _pumpTourScreen(tester, FeatureTourScreen(store: store));
    final skip = find.byKey(const ValueKey('voice-tour-skip'));
    expect(skip, findsOneWidget);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(store.saved, isTrue);
  });

  testWidgets('required tour hides Skip and does not persist on build',
      (tester) async {
    final store = _SkipProbeStore();
    await _pumpTourScreen(tester,
        FeatureTourScreen(store: store, requireFinalConfirmation: true));
    expect(find.byKey(const ValueKey('voice-tour-skip')), findsNothing);
    expect(store.saved, isFalse);
  });
}

class _SkipProbeStore extends FeatureTourStore {
  bool saved = false;
  @override
  Future<bool> shouldShow() async => !saved;
  @override
  Future<void> markCompleted() async => saved = true;
  @override
  Future<bool> shouldShowTip(String tipId) async => true;
  @override
  Future<void> markTipShown(String tipId) async {}
}

Future<void> _pumpTourScreen(WidgetTester tester, FeatureTourScreen screen) =>
    tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: screen,
    ));

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 40 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _FakeOAuthCallbackSessionAdapter implements OAuthCallbackSessionAdapter {
  _FakeOAuthCallbackSessionAdapter(this.authSession);

  final _FakeAuthSessionClient authSession;
  Uri? receivedUri;

  @override
  bool get hasCurrentSession => authSession.currentSession != null;

  @override
  Future<OAuthCallbackSession> completeCallback(Uri callbackUri) async {
    receivedUri = callbackUri;
    authSession.completeOAuthSignIn();
    return const OAuthCallbackSession(userId: 'oauth-user-1');
  }
}

class _FakeAuthSessionClient implements AuthSessionClient {
  _FakeAuthSessionClient() {
    _authEvents = StreamController<AuthState>.broadcast(
      onListen: () {
        scheduleMicrotask(() => _authEvents.add(
              const AuthState(AuthChangeEvent.initialSession, null),
            ));
      },
    );
  }

  late final StreamController<AuthState> _authEvents;
  Session? _session;
  User? _user;

  @override
  Session? get currentSession => _session;

  @override
  User? get currentUser => _user;

  @override
  Stream<AuthState> get authStateChanges => _authEvents.stream;

  void completeOAuthSignIn() {
    _user = User(
      id: 'oauth-user-1',
      appMetadata: <String, dynamic>{'provider': 'google'},
      userMetadata: <String, dynamic>{'name': 'Integration User'},
      aud: 'authenticated',
      email: 'integration@example.com',
      createdAt: '2026-09-25T00:00:00Z',
      role: 'authenticated',
      updatedAt: '2026-09-25T00:00:00Z',
    );
    _session = Session(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      tokenType: 'bearer',
      user: _user!,
    );
    // The production callback handler calls AuthProvider.syncCurrentSession()
    // after exchange. Avoid a duplicate event racing GoRouter's redirect; the
    // real client session is already available through currentSession.
  }

  @override
  Future<void> refreshSession() async {
    if (_session == null) {
      throw const AuthException('no session to refresh', statusCode: '401');
    }
  }

  @override
  Future<void> ensureProfile([User? user]) async {}

  @override
  Future<void> signOut() async {
    _session = null;
    _user = null;
    _authEvents.add(const AuthState(AuthChangeEvent.signedOut, null));
  }

  Future<void> dispose() => _authEvents.close();
}
