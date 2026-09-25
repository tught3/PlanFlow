import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/router.dart';
import 'package:planflow/core/startup_route_gate.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:planflow/services/feature_tour_service.dart';
import 'package:planflow/services/oauth_callback_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      'OAuth callback follows production router into required three-page tour',
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
    final tourStore = _MemoryFeatureTourStore();
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
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await _pumpUntil(tester,
        () => router.routeInformationProvider.value.uri.path == AppRoutes.login);
    expect(router.routeInformationProvider.value.uri.path, AppRoutes.login);

    await tester.runAsync(() => handler.handleAuthCallbackUri(
          Uri.parse('planflow://auth-callback?code=integration-test-code'),
        ));
    await _pumpUntil(
        tester, () => find.byType(FeatureTourScreen).evaluate().isNotEmpty);

    expect(callbackAdapter.receivedUri?.queryParameters['code'],
        'integration-test-code');
    expect(auth.isSignedIn, isTrue);
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(find.text('말하면 일정이 정리돼요'), findsOneWidget);
    expect(tourStore.completed, isFalse);
    expect(
        find.byKey(const ValueKey('feature-tour-skip-button')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await _pumpUntil(tester, () => find.text('AI 대화로 일정도 고쳐요')
        .evaluate()
        .isNotEmpty);
    expect(find.text('AI 대화로 일정도 고쳐요'), findsOneWidget);
    expect(tourStore.completed, isFalse);

    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await _pumpUntil(tester, () => find.text('출발과 브리핑을 챙겨드려요')
        .evaluate()
        .isNotEmpty);
    expect(find.text('출발과 브리핑을 챙겨드려요'), findsOneWidget);
    expect(tourStore.completed, isFalse);

    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tourStore.completed, isTrue);
    expect(router.routeInformationProvider.value.uri.path, AppRoutes.home);
    expect(find.byType(ShellScreen), findsOneWidget);
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _MemoryFeatureTourStore extends FeatureTourStore {
  bool completed = false;

  @override
  Future<bool> shouldShow() async => !completed;

  @override
  Future<void> markCompleted() async => completed = true;

  @override
  Future<bool> shouldShowTip(String tipId) async => false;

  @override
  Future<void> markTipShown(String tipId) async {}
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
