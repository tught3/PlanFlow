import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:planflow/core/env.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/auth/login_screen.dart';
import 'package:planflow/services/auth_service.dart';
import 'package:planflow/services/oauth_callback_handler.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    try {
      Supabase.instance;
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

  setUp(() {
    AppEnv.resetSupabaseInitializationState();
  });

  // 주의: 이 테스트는 AppEnv.isSupabaseReady가 아직 false인 상태에서 시작해야
  // 회귀를 재현할 수 있다(setUp에서 매번 reset하므로 실행 순서와 무관하게 안전함).
  // widget._authService를 넘기지 않아야 initState에서 _authService가 null로
  // 대입된 뒤, 아래에서 실제로 재대입(AuthService())이 시도된다.
  testWidgets(
      'LoginScreen re-initializes AuthService once Supabase becomes ready '
      'after initState without throwing LateInitializationError',
      (tester) async {
    addTearDown(() => authProvider.setUser(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: LoginScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Supabase 초기화가 initState 이후 뒤늦게 완료되는 상황을 재현한다.
    // (기존 버그: _authService가 late final이라 initState에서 한 번 대입된
    // 뒤 여기서 다시 대입하려 하면 LateInitializationError가 던져졌다.)
    AppEnv.markSupabaseInitialized();
    authProvider.setUser('user-1');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('이메일 로그인'), findsOneWidget);
  });

  testWidgets('LoginScreen shows the Naver social login button',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: LoginScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('이메일 로그인'), findsOneWidget);
    expect(find.text('간편 로그인'), findsOneWidget);
    expect(find.text('네이버로 계속하기'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('이메일 로그인')).dy,
      lessThan(tester.getTopLeft(find.text('간편 로그인')).dy),
    );
    expect(
      find.textContaining('Supabase 빌드 설정값을 먼저 주입해야 로그인할 수 있습니다.'),
      findsNothing,
    );
  });

  testWidgets(
      'cancelling a provider chooser releases login and stale completion cannot block retry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(OAuthCallbackHandler.clearPendingCallback);

    final authService = _PendingOAuthAuthService();
    AppEnv.markSupabaseInitialized();
    await tester.pumpWidget(
      MaterialApp(home: LoginScreen(authService: authService)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Google로 계속하기'));
    await tester.pump();
    expect(find.byKey(const ValueKey('cancel-social-login')), findsOneWidget);
    expect(OAuthCallbackHandler.pendingLoginMethod, 'google');
    final canceledGoogleRevision = OAuthCallbackHandler.pendingLoginRevision!;

    await tester.tap(find.byKey(const ValueKey('cancel-social-login')));
    await tester.pumpAndSettle();
    expect(OAuthCallbackHandler.pendingLoginMethod, isNull);
    expect(find.text('로그인이 취소되었습니다. 다른 로그인 방법을 선택할 수 있어요.'), findsOneWidget);

    await tester.tap(find.text('카카오로 계속하기'));
    await tester.pump();
    expect(OAuthCallbackHandler.pendingLoginMethod, 'kakao');
    final kakaoRevision = OAuthCallbackHandler.pendingLoginRevision!;

    OAuthCallbackHandler.setLatestUserMessageForRevision(
      '이전 Google 로그인에서 늦게 도착한 오류',
      canceledGoogleRevision,
    );
    await tester.pump();
    expect(OAuthCallbackHandler.pendingLoginRevision, kakaoRevision);
    expect(find.text('이전 Google 로그인에서 늦게 도착한 오류'), findsNothing);
    expect(find.byKey(const ValueKey('cancel-social-login')), findsOneWidget);

    authService.launchResults[0].complete(true);
    await tester.pump();
    expect(OAuthCallbackHandler.pendingLoginMethod, 'kakao');
    expect(find.byKey(const ValueKey('cancel-social-login')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cancel-social-login')));
    await tester.pumpAndSettle();
    expect(OAuthCallbackHandler.pendingLoginMethod, isNull);
    expect(find.text('네이버로 계속하기'), findsOneWidget);
  });

  testWidgets(
      'returning from a dismissed provider chooser releases login and allows another provider',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(OAuthCallbackHandler.clearPendingCallback);

    final authService = _PendingOAuthAuthService();
    AppEnv.markSupabaseInitialized();
    await tester.pumpWidget(
      MaterialApp(home: LoginScreen(authService: authService)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Google로 계속하기'));
    await tester.pump();
    expect(OAuthCallbackHandler.pendingLoginMethod, 'google');
    expect(find.byKey(const ValueKey('cancel-social-login')), findsOneWidget);

    // Simulate the account chooser being dismissed externally and the app
    // returning to the foreground without an OAuth callback.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 901));
    await tester.pumpAndSettle();

    expect(OAuthCallbackHandler.pendingLoginMethod, isNull);
    expect(find.byKey(const ValueKey('cancel-social-login')), findsNothing);
    expect(find.textContaining('Google 인증이 완료되지 않았어요.'), findsOneWidget);

    await tester.tap(find.text('카카오로 계속하기'));
    await tester.pump();
    expect(OAuthCallbackHandler.pendingLoginMethod, 'kakao');
    expect(find.byKey(const ValueKey('cancel-social-login')), findsOneWidget);
  });

  testWidgets('LoginScreen surfaces Supabase init failures', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    AppEnv.markSupabaseInitializationFailed('Supabase 초기화에 실패했습니다: timeout');

    await tester.pumpWidget(
      const MaterialApp(
        home: LoginScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.textContaining('로그인 서비스를 초기화하지 못했습니다'),
      findsOneWidget,
    );
  });

  testWidgets('LoginScreen sanitizes platform channel failures',
      (tester) async {
    AppEnv.markSupabaseInitializationFailed(
      PlatformException(
        code: 'channel-error',
        message: 'Unable to establish SharedPreferencesApi.getAll',
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('channel-error'), findsNothing);
    expect(find.textContaining('앱 초기화가 지연되고 있습니다'), findsOneWidget);
  });

  testWidgets('password reset mode has an explicit back-to-login action',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('비밀번호를 잊으셨나요?'));
    await tester.pumpAndSettle();

    final backButton =
        find.byKey(const ValueKey('password-reset-back-to-login'));
    expect(backButton, findsOneWidget);

    await tester.tap(backButton);
    await tester.pumpAndSettle();

    expect(find.text('이메일 로그인'), findsOneWidget);
    expect(find.text('비밀번호를 잊으셨나요?'), findsOneWidget);
  });

  testWidgets('LoginScreen shows safer email sign-up guidance', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final authService = _FakeAuthService();
    AppEnv.markSupabaseInitialized();
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(authService: authService),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();

    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), '홍길동');
    await tester.enterText(fields.at(1), 'tester@example.com');
    await tester.enterText(fields.at(2), 'password123');
    await tester.enterText(fields.at(3), 'password123');
    final submitButton = find.widgetWithText(FilledButton, '이메일로 회원가입');
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(authService.signUpCallCount, 1);
    expect(find.textContaining('인증 메일을 보냈습니다'), findsOneWidget);
    expect(find.textContaining('이미 가입된 이메일이라면'), findsOneWidget);
    expect(find.textContaining('비밀번호 찾기'), findsOneWidget);
    final messageBox = find.textContaining('인증 메일을 보냈습니다');
    expect(tester.getTopLeft(messageBox).dy, greaterThanOrEqualTo(0));
    expect(tester.getBottomLeft(messageBox).dy, lessThan(1200));
    expect(find.text('비밀번호를 잊으셨나요?'), findsOneWidget);
  });
}

class _FakeAuthService extends AuthService {
  _FakeAuthService()
      : super(
          client: SupabaseClient(
            'https://example.com',
            'public-anon-key',
            authOptions: const FlutterAuthClientOptions(
              detectSessionInUri: false,
              autoRefreshToken: false,
            ),
          ),
        );

  var signUpCallCount = 0;

  @override
  Future<AuthResponse> signUpWithEmail({
    required String email,
    required String password,
    String? name,
  }) async {
    signUpCallCount += 1;
    return AuthResponse();
  }
}

class _PendingOAuthAuthService extends _FakeAuthService {
  final List<Completer<bool>> launchResults = <Completer<bool>>[];

  @override
  Future<bool> signInWithOAuth(PlanFlowOAuthProvider provider,
      {bool forceConsent = false, bool forCalendar = false}) {
    final result = Completer<bool>();
    launchResults.add(result);
    // Match the production service's duplicate pending mark at OAuth launch.
    OAuthCallbackHandler.markPendingLogin(provider);
    return result.future;
  }
}
