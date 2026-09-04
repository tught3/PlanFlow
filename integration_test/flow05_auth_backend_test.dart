import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/core/supabase_auth_options.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/auth_service.dart' show AuthService;
import 'package:planflow/services/oauth_callback_handler.dart'
    show OAuthCallbackHandler;
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import '_harness/app_harness.dart';
import '_harness/checkpoint_logger.dart';
import '_harness/fakes/fake_auth_service.dart';
import '_harness/network_guard.dart';

/// PlanFlow iOS Simulator E2E Phase P6 — FLOW5: Auth & Backend.
///
/// This file is split into two independently-gated groups.
///
/// **Group A (always runs, fake-based, zero real network calls)** exercises
/// `AuthProvider`'s session state transitions through the `AuthSessionClient`
/// DI seam (`lib/providers/auth_provider.dart:37`,
/// `AuthProvider({AuthSessionClient? authService, DateTime Function()?
/// clock})`) using `_harness/fakes/fake_auth_service.dart`'s `FakeAuthService`
/// — the same seam P3/P4 already established and used by
/// `test/providers/auth_provider_test.dart`.
///
/// OAuth (Google/Kakao/Naver) success/failure branching, however, is **not**
/// handled by `AuthSessionClient` — it lives in
/// `lib/services/oauth_callback_handler.dart`'s `OAuthCallbackHandler`, whose
/// actual callback exchange (`_handleUri`) is private and calls
/// `Supabase.instance.client` directly (not injectable) plus the global
/// `authProvider` singleton (same DI gap documented in
/// `flow01_cold_start_test.dart`). There is no seam to replay a fake OAuth
/// callback through the real exchange path without a live Supabase project.
/// Instead — following the exact pattern `flow03_navigation_routing_test.dart`
/// already established (call the real production **pure** function the
/// private handler delegates to, instead of the unreachable private handler
/// itself) — this file calls
/// `OAuthCallbackHandler.callbackErrorMessageFor` (`@visibleForTesting`,
/// pure, no I/O) directly with synthetic callback URIs to verify the
/// per-provider success/`access_denied` branching for all three providers.
///
/// **Group B (conditionally runs, real non-production Supabase)** only
/// executes when `--dart-define=E2E_REAL_BACKEND_TEST=1` is supplied. It
/// signs in to a real Supabase project with a dedicated, namespaced test
/// account (`planflow-e2e+...`), confirms a session was established, then
/// signs out. It does not create any schedule/event data — only the
/// inherent (idempotent) `users` table profile upsert that
/// `AuthService.signInWithEmail` always performs on any successful login is
/// exercised, no `일정` data is written.
///
/// Until the required GitHub secrets exist, `E2E_REAL_BACKEND_TEST` is not
/// set to `'1'` by `.github/workflows/ios-simulator-e2e.yml` (it defaults to
/// `'0'`), so Group B cleanly reports as **skipped** rather than failing.
///
/// Windows 로컬 환경에는 iOS 시뮬레이터가 없어 이 파일은 `dart analyze`로만
/// 검증됐다. 실제 실행·통과 여부는 CI(macOS 러너, `flow05-auth-backend`
/// job)에서 확인한다.
void main() {
  logCheckpoint('FLOW5_START');
  ensureIntegrationTestBinding();

  group('FLOW5 auth/backend — group A (fake, zero network)', () {
    setUpAll(() {
      AppEnv.markSupabaseInitialized();
    });

    tearDown(() {
      PlanFlowAuthLocalStorage.endExplicitSignOut();
    });

    testWidgets(
      '저장된 세션이 있으면 부팅 즉시 active 상태로 복원된다',
      (tester) async {
        logCheckpoint('FLOW5_GROUP_A_START');
        final networkRecorder = BlockingNetworkCallRecorder();
        final fake = FakeAuthService(
          initialSession: FixtureSession.build(
            userId: 'flow5-restore-user',
            email: 'restore@example.test',
          ),
        );
        final provider = AuthProvider(authService: fake);

        provider.start();
        await Future<void>.delayed(Duration.zero);

        expect(provider.hasResolvedInitialSession, isTrue);
        expect(provider.isSignedIn, isTrue);
        expect(provider.userId, 'flow5-restore-user');
        expect(provider.email, 'restore@example.test');

        provider.dispose();
        await fake.dispose();

        // network_guard.dart의 caveat(flow01 참고): 이 recorder는 어떤
        // 프로덕션 네트워크 호출 지점에도 배선돼 있지 않다. 이 assertion은
        // "이 테스트가 직접 recorder에 기록한 호출이 없다"는 항상-참인
        // 사실만 검증하며, FakeAuthService/AuthProvider 경로가 실제로
        // 네트워크를 안 쳤다는 것은 이 두 클래스가 fake 구현이라는 사실
        // 자체로 보장된다(FakeAuthService는 Supabase 클라이언트를 전혀
        // 참조하지 않는다).
        expectNoNetworkCalls(networkRecorder);
      },
    );

    testWidgets(
      '로그인 성공 이벤트가 오면 signedOut에서 active로 전이된다',
      (tester) async {
        final fake = FakeAuthService();
        final provider = AuthProvider(authService: fake);

        provider.start();
        await Future<void>.delayed(Duration.zero);
        expect(provider.isSignedIn, isFalse);

        fake.emitSignedIn(
          FixtureSession.build(
            userId: 'flow5-login-user',
            email: 'login@example.test',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(provider.isSignedIn, isTrue);
        expect(provider.sessionStatus, AuthSessionStatus.active);
        expect(provider.userId, 'flow5-login-user');
        expect(provider.email, 'login@example.test');

        provider.dispose();
        await fake.dispose();
      },
    );

    testWidgets(
      '로그인 세션 이벤트가 오지 않으면 signedOut 상태를 유지한다(로그인 실패)',
      (tester) async {
        final fake = FakeAuthService();
        final provider = AuthProvider(authService: fake);

        provider.start();
        await Future<void>.delayed(Duration.zero);

        expect(provider.hasResolvedInitialSession, isTrue);
        expect(provider.isSignedIn, isFalse);
        expect(provider.sessionStatus, AuthSessionStatus.signedOut);
        expect(provider.hasAccountSnapshot, isFalse);

        provider.dispose();
        await fake.dispose();
      },
    );

    testWidgets(
      '명시적 로그아웃 시 세션이 signedOut으로 전이되고 계정 스냅샷이 지워진다',
      (tester) async {
        final fake = FakeAuthService(
          initialSession: FixtureSession.build(
            userId: 'flow5-logout-user',
            email: 'logout@example.test',
          ),
        );
        final provider = AuthProvider(authService: fake);

        provider.start();
        await Future<void>.delayed(Duration.zero);
        expect(provider.isSignedIn, isTrue);

        // lib/services/auth_service.dart의 실제 AuthService.signOut()은
        // PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed로 감싸서
        // signOut을 호출한다. 이 래핑 없이 fake.signOut()만 부르면,
        // AuthProvider.start()의 리스너(lib/providers/auth_provider.dart)가
        // hasAccountSnapshot=true + isSessionRemovalAllowed=false 조건에서
        // "signedOut을 그대로 적용"하지 않고 세션 복구(syncCurrentSession)
        // 경로로 새어버려 이 테스트가 실제 로그아웃 흐름을 검증하지 못한다.
        await PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed(
          fake.signOut,
        );
        await Future<void>.delayed(Duration.zero);

        expect(provider.isSignedIn, isFalse);
        expect(provider.sessionStatus, AuthSessionStatus.signedOut);
        expect(provider.hasAccountSnapshot, isFalse);
        expect(fake.signOutCallCount, 1);

        provider.dispose();
        await fake.dispose();
      },
    );

    testWidgets(
      'OAuth 콜백 성공(에러 파라미터 없음)은 provider 3종 모두 에러 메시지를 만들지 않는다',
      (tester) async {
        final callbackUri = Uri.parse('planflow://auth-callback?code=abc123');

        for (final method in const ['google', 'kakao', 'naver']) {
          final message = OAuthCallbackHandler.callbackErrorMessageFor(
            callbackUri,
            pendingMethod: method,
          );
          expect(
            message,
            isNull,
            reason: 'provider=$method: 에러 파라미터가 없는 콜백은 '
                '사용자 노출 에러 메시지를 만들면 안 된다(성공 분기).',
          );
        }
      },
    );

    testWidgets(
      'OAuth 3종 각각 access_denied 콜백을 provider별로 다른 한국어 메시지로 분기한다',
      (tester) async {
        final deniedUri = Uri.parse(
          'planflow://auth-callback?error=access_denied&error_code=access_denied',
        );

        final googleMessage = OAuthCallbackHandler.callbackErrorMessageFor(
          deniedUri,
          pendingMethod: 'google',
        );
        final kakaoMessage = OAuthCallbackHandler.callbackErrorMessageFor(
          deniedUri,
          pendingMethod: 'kakao',
        );
        final naverMessage = OAuthCallbackHandler.callbackErrorMessageFor(
          deniedUri,
          pendingMethod: 'naver',
        );

        expect(googleMessage, isNotNull);
        expect(kakaoMessage, isNotNull);
        expect(naverMessage, isNotNull);

        // lib/services/oauth_callback_handler.dart의
        // callbackErrorMessageFor 분기: kakao/naver만 전용 라벨이 있고
        // google은 공용 '소셜' 라벨로 떨어진다. 3개 provider가 실제로 서로
        // 다른 pendingMethod 값으로 처리되고 있음을 이 라벨 차이로 확인한다.
        expect(googleMessage, contains('소셜'));
        expect(googleMessage, isNot(contains('카카오')));
        expect(googleMessage, isNot(contains('네이버')));

        expect(kakaoMessage, contains('카카오'));
        expect(naverMessage, contains('네이버'));
        logCheckpoint('FLOW5_GROUP_A_DONE');
      },
    );
  });

  group('FLOW5 auth/backend — group B (real non-production Supabase)', () {
    // 이 체크는 실제 `skip:` 파라미터(아래, 원문 그대로 미수정)와 별개로
    // 로깅 전용으로 동일한 환경변수를 다시 읽는다 — discovery 시점(그룹
    // 콜백이 동기 실행되는 시점)에 곧바로 찍히므로, Group A가 실제로
    // 실행을 마쳤는지와 무관하게 "이 파일이 Group B 등록까지 파싱됐다"만
    // 알려준다. Group B가 실제로 실행을 "시작"했는지는 아래 testWidgets
    // 본문 첫 줄의 체크포인트로 별도 확인한다.
    final groupBWillRun =
        const String.fromEnvironment('E2E_REAL_BACKEND_TEST') == '1';
    logCheckpoint(
      groupBWillRun ? 'FLOW5_GROUP_B_WILL_RUN' : 'FLOW5_GROUP_B_SKIPPED_OR_START',
    );

    testWidgets(
      '전용 테스트 계정으로 실제 Supabase에 로그인 -> 세션 확인 -> 로그아웃',
      (tester) async {
        logCheckpoint('FLOW5_GROUP_B_START');
        // 프로덕션 Supabase 프로젝트 ref
        // (lib/core/env.dart의 _defaultSupabaseUrl,
        // .github/workflows/ios-simulator-e2e.yml의 PROD_SUPABASE_REF와
        // 동일 문자열). FLOW5는 이 저장소에서 유일하게 실제 Supabase
        // 자격증명을 받는 시나리오이므로, PLANFLOW_SUPABASE_URL secret이
        // 실수로 프로덕션 프로젝트를 가리키면 곧바로 실패시켜 실제 사용자
        // 데이터에 접근하는 사고를 막는다. 이 리터럴은
        // ios-simulator-e2e.yml의 "PROD_SUPABASE_REF는 그 워크플로 파일
        // 안에 정확히 1회만 등장해야 한다" 불변식 대상이 아니다 — 그
        // 검사는 워크플로 YAML 파일 텍스트만 스캔하며 이 Dart 파일은
        // 검사 범위 밖이다.
        const prodSupabaseRef = 'xqvvfnvmytjlblcngipn';
        const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
        const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
        const testAccountEmail =
            String.fromEnvironment('E2E_TEST_ACCOUNT_EMAIL');
        const testAccountPassword =
            String.fromEnvironment('E2E_TEST_ACCOUNT_PASSWORD');

        expect(
          supabaseUrl.contains(prodSupabaseRef),
          isFalse,
          reason: 'BLOCKED_PROD_SUPABASE_IN_E2E: SUPABASE_URL for the FLOW5 '
              'real-backend test must never point at the production '
              'Supabase project ($prodSupabaseRef). Check the '
              'PLANFLOW_SUPABASE_URL GitHub secret.',
        );
        expect(
          supabaseUrl.trim().isNotEmpty,
          isTrue,
          reason: 'SUPABASE_URL dart-define is empty — the '
              'PLANFLOW_SUPABASE_URL secret appears to be missing even '
              'though E2E_REAL_BACKEND_TEST=1.',
        );
        expect(
          supabaseAnonKey.trim().isNotEmpty,
          isTrue,
          reason: 'SUPABASE_ANON_KEY dart-define is empty — the '
              'PLANFLOW_SUPABASE_ANON_KEY secret appears to be missing '
              'even though E2E_REAL_BACKEND_TEST=1.',
        );

        final hasNamespacePrefix =
            testAccountEmail.startsWith('planflow-e2e+');
        expect(
          hasNamespacePrefix,
          isTrue,
          reason: 'E2E_TEST_ACCOUNT_EMAIL must be a namespaced '
              '"planflow-e2e+..." test account — refusing to run this '
              'scenario against a non-namespaced (possibly real user) '
              'account. hasNamespacePrefix=$hasNamespacePrefix '
              '(value redacted).',
        );
        expect(
          testAccountPassword.trim().isNotEmpty,
          isTrue,
          reason: 'E2E_TEST_ACCOUNT_PASSWORD dart-define is empty.',
        );

        final client = SupabaseClient(supabaseUrl, supabaseAnonKey);
        final authService = AuthService(client: client);

        try {
          final response = await authService.signInWithEmail(
            email: testAccountEmail,
            password: testAccountPassword,
          );

          expect(
            response.session,
            isNotNull,
            reason: '실제 Supabase 로그인이 세션을 반환하지 못했다.',
          );
          expect(client.auth.currentSession, isNotNull);

          final signedInEmail =
              client.auth.currentUser?.email?.trim().toLowerCase();
          final expectedEmail = testAccountEmail.trim().toLowerCase();
          expect(
            signedInEmail == expectedEmail,
            isTrue,
            reason: '로그인 후 currentUser.email이 요청한 테스트 계정 '
                '이메일과 일치하지 않는다(값은 로그에 남기지 않음).',
          );

          await client.auth.signOut();
          expect(client.auth.currentSession, isNull);
        } finally {
          await client.dispose();
        }
      },
      // E2E_REAL_BACKEND_TEST가 '1'이 아니면(기본값, GitHub secret이 아직
      // 없을 때) 이 테스트는 실패가 아니라 skipped로 보고된다 — CI 전체는
      // 계속 그린이다.
      skip: const String.fromEnvironment('E2E_REAL_BACKEND_TEST') != '1',
    );
  });
}
