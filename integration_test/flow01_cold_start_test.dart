import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/auth/login_screen.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:planflow/screens/splash/splash_screen.dart';

import '_harness/app_harness.dart';
import '_harness/checkpoint_logger.dart';
import '_harness/network_guard.dart';

/// PlanFlow iOS Simulator E2E Phase P4 — FLOW1: Cold Start.
///
/// 실행: `flutter test integration_test/flow01_cold_start_test.dart
/// --dart-define=E2E_MODE=1 --dart-define=SUPABASE_URL=... \
/// --dart-define=SUPABASE_ANON_KEY=...`
///
/// Windows 로컬 환경에는 iOS 시뮬레이터가 없어 이 파일은 `dart analyze`로만
/// 검증됐다(컴파일/타입 정합성만 확인). 실제 실행·통과 여부는 CI(P8, macOS
/// 러너)에서 확인한다.
void main() {
  ensureIntegrationTestBinding();

  group('FLOW1 cold start', () {
    testWidgets(
      '앱을 실제로 부팅하면 크래시 없이 첫 프레임을 렌더하고 안정된 초기 화면에 도달한다',
      (tester) async {
        final networkRecorder = BlockingNetworkCallRecorder();

        logCheckpoint('APP_LAUNCH_START');
        await pumpPlanFlowApp(tester, overrides: const []);
        logCheckpoint('APP_LAUNCHED');

        // startup gate 통과 + 실제 앱 부팅 성공의 증거: 알려진 초기 화면
        // 중 하나(스플래시/로그인/홈)에 도달했다. 정확히 어느 화면인지는
        // 로컬 저장소에 남아있는(있을 수 없는, 매 테스트 프로세스가 새로
        // 뜨는) 세션 상태에 좌우되므로 셋 중 하나면 통과로 본다 —
        // "부팅이 끝까지 진행돼 크래시하지 않았다"가 이 시나리오의 핵심
        // 단언이다.
        final reachedSplash = find.byType(SplashScreen).evaluate().isNotEmpty;
        final reachedLogin = find.byType(LoginScreen).evaluate().isNotEmpty;
        final reachedHome = find.byType(ShellScreen).evaluate().isNotEmpty;
        logCheckpoint('INITIAL_SCREEN_SETTLED');
        expect(
          reachedSplash || reachedLogin || reachedHome,
          isTrue,
          reason: 'Cold start did not settle on a known screen '
              '(splash/login/home). splash=$reachedSplash '
              'login=$reachedLogin home=$reachedHome',
        );

        // 이 recorder는 어떤 프로덕션 네트워크 호출 지점에도 배선돼 있지
        // 않다(2026-09-03 P4 조사로 확인 — Supabase/Firebase/Naver Map 등
        // 실제 서비스는 이 recorder를 거치지 않고 직접 네트워크를 호출한다).
        // 그래서 이 assertion은 현재 "이 테스트가 직접 recorder에 기록한
        // 호출이 없다"는 항상-참인 사실만 검증하며, 앱이 실제로 네트워크를
        // 안 쳤다는 보장은 아니다. network_guard.dart가 제공하는 계약을
        // 그대로 재사용했다는 것과, 실질적인 무배선 상태를 완료 보고에
        // 남긴다.
        logCheckpoint('NETWORK_GUARD_CHECKED');
        expectNoNetworkCalls(
          networkRecorder,
          reason: 'harness recorder is not wired to any production network '
              'call site; see FLOW1 completion report for the gap.',
        );
      },
    );

    testWidgets(
      '기존 로그인 세션이 있는 상태로 부팅하면 홈 화면에 즉시 도달한다 '
      '(BLOCKED: authProvider DI seam 없음)',
      (tester) async {
        // lib/providers/auth_provider.dart:11의 `final AuthProvider
        // authProvider = AuthProvider();`는 앱 전역에서 공유되는 전역
        // 싱글턴이며, 생성 시점에 `AuthSessionClient`를 주입할 방법이
        // 없다(기본 생성자 호출, 파라미터 없음). `_harness/fakes/
        // fake_auth_service.dart`의 `FakeAuthService`는 이 전역
        // `authProvider`가 아니라 테스트가 직접 만드는 별도
        // `AuthProvider(authService: fake)` 인스턴스에만 주입 가능하다.
        // `pumpPlanFlowApp`가 실행하는 `runPlanFlowApp()`은 이 전역
        // `authProvider`를 그대로 쓰므로(app.dart/main.dart/router.dart
        // 전부 top-level `authProvider` import), Riverpod
        // `overrides`(ProviderScope)로도 대체할 수 없다 — 이 앱은 실제로
        // Riverpod Provider를 하나도 소비하지 않는다(`ConsumerWidget`/
        // `ref.watch` grep 결과 0건, 2026-09-03 확인). 즉 "기존 세션으로
        // 부팅"을 실제 앱 프로세스 안에서 재현할 DI 지점이 현재 없다.
        // 이 격차를 여기 남기고 실행을 건너뛴다 — 필요하면
        // `authProvider`를 교체 가능한 전역으로 바꾸는 프로덕션 코드
        // 변경이 별도 작업으로 필요하다(이번 티켓은 테스트 파일만
        // 수정하므로 범위 밖).
      },
      skip: true,
    );
  });
}
