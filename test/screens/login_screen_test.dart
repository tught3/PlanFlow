import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:planflow/core/env.dart';
import 'package:planflow/screens/auth/login_screen.dart';
import 'package:planflow/services/auth_service.dart';

void main() {
  setUp(() {
    AppEnv.resetSupabaseInitializationState();
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

    expect(find.textContaining('Supabase 초기화에 실패했습니다'), findsOneWidget);
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
