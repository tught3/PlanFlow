import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planflow/core/env.dart' show AppEnv;
import 'package:planflow/main.dart' show runPlanFlowApp;

/// integration_test 스위트 전체가 공유하는 부트스트랩 헬퍼.
///
/// PlanFlow iOS Simulator E2E Phase P3(하네스 스캐폴딩) — 실제 시나리오
/// 테스트(P4+)는 이 파일을 재사용해 앱을 부팅한다.

/// `lib/core/env.dart`의 `AppEnv`는 `SUPABASE_URL`/`SUPABASE_ANON_KEY`가
/// dart-define으로 주입되지 않으면 **프로덕션 Supabase 프로젝트 값으로
/// 폴백**한다(`docs/ios/SIMULATOR_QA_MATRIX.md` "실측으로 정정된 사실" 참고).
/// E2E 스위트가 이 사실을 모른 채 dart-define 없이 실행되면 실제 프로덕션
/// 백엔드를 두드릴 위험이 있으므로, 하네스 진입 시점에 `E2E_MODE=1`
/// dart-define이 없으면 즉시 실패시켜 이 위험을 조기에 드러낸다.
///
/// 사용법: `flutter test integration_test/이름_test.dart
/// --dart-define=E2E_MODE=1 --dart-define=SUPABASE_URL=...
/// --dart-define=SUPABASE_ANON_KEY=...`
///
/// 2차 안전장치(리뷰 지적 반영): `E2E_MODE=1`이 있어도 dart-define으로 실제
/// **프로덕션** Supabase 값이 통째로 주입되는 실수(예: CI job env 배선
/// 오류로 실제 secret이 그대로 흘러들어오는 경우)까지는 위 1차 검사가
/// 잡지 못한다. `--dart-define=E2E_REAL_BACKEND_TEST=1`로 명시적으로
/// 실제 백엔드 시나리오임을 선언한 FLOW5 Group B(비프로덕션 전용 프로젝트를
/// 의도적으로 쓰는 유일한 경로)는 이 검사에서 제외하고, 그 외 모든
/// 시나리오는 `AppEnv.hasValidSupabaseConfig`가 true이면서 동시에 그
/// URL/키가 실제 프로덕션 프로젝트 참조(`_prodSupabaseRefFragment`,
/// `lib/core/env.dart`의 `AppEnv._defaultSupabaseUrl`/
/// `_defaultSupabaseAnonKey`에 박혀 있는 것과 동일한 project ref 문자열)를
/// 포함하면 즉시 fail한다.
void ensureE2eModeEnabled() {
  const isE2eMode = String.fromEnvironment('E2E_MODE') == '1';
  if (!isE2eMode) {
    throw StateError(
      'integration_test harness requires --dart-define=E2E_MODE=1. '
      'Without it, lib/core/env.dart AppEnv falls back to the production '
      'Supabase project (see docs/ios/SIMULATOR_QA_MATRIX.md, "환경변수" '
      'row). Refusing to start to avoid touching production data.',
    );
  }

  const isRealBackendTest =
      String.fromEnvironment('E2E_REAL_BACKEND_TEST') == '1';
  if (isRealBackendTest) {
    // FLOW5 Group B (dedicated non-production project) is the one
    // intentional exception — its own scenario code enforces that
    // PLANFLOW_SUPABASE_URL never points at the production ref
    // (`.github/workflows/ios-simulator-e2e.yml`'s "Resolve FLOW5 Supabase
    // dart-defines" step already fails closed on that before this even
    // runs), so no further check is needed here.
    return;
  }

  if (AppEnv.hasValidSupabaseConfig &&
      (AppEnv.supabaseUrl.contains(_prodSupabaseRefFragment) ||
          AppEnv.supabaseAnonKey.contains(_prodSupabaseRefFragment))) {
    throw StateError(
      'integration_test harness detected a real production Supabase '
      'credential (project ref "$_prodSupabaseRefFragment") wired into a '
      'non-FLOW5-Group-B scenario. Refusing to start to avoid touching '
      'production data. Pass placeholder dart-defines instead (see '
      '.github/workflows/ios-simulator-e2e.yml, '
      'E2E_SUPABASE_URL_PLACEHOLDER/E2E_SUPABASE_ANON_KEY_PLACEHOLDER), or '
      'if this really is the intentional FLOW5 real-backend scenario, also '
      'pass --dart-define=E2E_REAL_BACKEND_TEST=1.',
    );
  }
}

/// `lib/core/env.dart`의 `AppEnv._defaultSupabaseUrl`/
/// `_defaultSupabaseAnonKey`에 박혀 있는 프로덕션 Supabase project ref와
/// 동일한 문자열. `.github/workflows/ios-simulator-e2e.yml`의
/// `PROD_SUPABASE_REF`와 값이 같아야 하며, 두 곳 모두 이 값이 정확히
/// 한 번씩만 정의(리터럴)되도록 유지한다.
const _prodSupabaseRefFragment = 'xqvvfnvmytjlblcngipn';

/// 각 시나리오 `_test.dart`의 `main()` 최상단에서 1회 호출하는 바인딩
/// 초기화 헬퍼. `flutter test integration_test/`와 `flutter drive` 양쪽
/// 실행 경로 모두 이 바인딩이 필요하다.
IntegrationTestWidgetsFlutterBinding ensureIntegrationTestBinding() {
  return IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// `runPlanFlowApp`(`lib/main.dart`의 `@visibleForTesting` 진입점, main()과
/// 100% 동일 로직)을 통해 앱을 실제로 부팅하고 첫 프레임까지 pump한다.
///
/// [overrides]는 Riverpod `ProviderScope`에 그대로 전달된다. 각 시나리오는
/// 여기에 `_harness/fakes/`의 fake 구현체를 override로 넣어 네트워크/네이티브
/// 의존성을 제거한다. `runPlanFlowApp` 자체는 override를 강제하지 않으므로,
/// fake를 빠뜨리면 실제 서비스가 그대로 호출된다 — 시나리오 작성자가 이
/// 하네스를 호출하기 전에 [ensureE2eModeEnabled]가 이미 dart-define 누락을
/// 잡아주지만, override 누락까지는 이 함수가 대신 판단해주지 않는다.
Future<void> pumpPlanFlowApp(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  ensureE2eModeEnabled();
  await runPlanFlowApp(overrides: overrides);
  // `pumpAndSettle`의 1번째 인자는 타임아웃이 아니라 pump 간격이다 —
  // 기본 호출(인자 없음)은 3번째 인자(`timeout`)가 기본값 10분으로
  // 남아있어 사실상 무제한 대기다(Flutter SDK `widget_tester.dart`
  // `WidgetTester.pumpAndSettle` 실측 확인, 로컬 3.41.9와 CI가 쓰는
  // 3.47.2 태그 양쪽 소스 대조 완료 — 시그니처 동일). E2E hang 조사
  // 목적상, 이 하네스가 정말 멈췄다면 10분씩 기다리는 대신 훨씬 짧은
  // 시간 안에 명확한 `FlutterError('pumpAndSettle timed out')`로
  // 실패시켜야 원인 파악이 빨라진다.
  //
  // 60초로 잡은 근거(`lib/main.dart`의 실제 부팅 경로 실측):
  // `runApp()`은 `_initializePlatformServices()`를 `unawaited`로
  // 넘기므로 첫 프레임 자체는 네트워크를 기다리지 않지만, 백그라운드
  // 초기화 체인의 최악 시나리오는 `_initializeSupabase()`가 최대 3회
  // 재시도 x 10초 타임아웃(~30초, 재시도 사이 delay 별도)을 거친 뒤
  // `Future.wait([...])`로 NaverMap(8초 타임아웃) 등이 뒤따르는 구조라
  // 합계 최대 약 40초에 이른다. 이 백그라운드 체인이 상태 변경을 통해
  // 위젯 재빌드를 계속 스케줄하면 `pumpAndSettle`이 그 시간만큼
  // 버틸 수 있으므로, 정상적인 실제 기기 부팅(각 시나리오가 fake
  // override로 이 네트워크 호출들을 대체하지 못한 예외 경로 포함)을
  // 오탐으로 끊지 않으면서도 무제한 대기보다는 훨씬 짧게 끊기도록
  // 여유를 두어 60초로 설정한다.
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 60),
  );
}
