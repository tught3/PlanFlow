/**
 * AuthGate/LoginRoute의 세션 기반 라우팅 판정을 순수 함수로 뺀 파일.
 *
 * router.tsx를 그대로 vitest로 import하면 최상단의
 * `createBrowserRouter([...])`가 모듈 로드 시점에 `document`(브라우저 전역)를
 * 참조해 "ReferenceError: document is not defined"로 스위트 전체가 죽는다
 * (이 프로젝트에는 jsdom이 설치되어 있지 않다). src/appLayoutLogout.ts가
 * 로그아웃 상태 머신을 같은 이유로 분리한 전례를 그대로 따라, 세션 상태
 * ({userId, loading})만 입력으로 받아 'wait'|'render'|'redirect' 판정
 * 문자열만 반환하는 순수 함수로 분리했다. router.tsx는 이 함수의 반환값을
 * switch로 받아 실제 컴포넌트(Spinner/Navigate/Outlet 등)로 매핑만 한다.
 *
 * 불변식(두 함수 모두 반드시 지켜야 함): loading === true이면 무조건
 * 'wait'를 반환한다 - loading 중에는 절대 'redirect'를 반환하지 않는다.
 * 이게 깨지면 loading 완료 전 아직 정해지지 않은 userId 값(초기 null)을
 * 근거로 리다이렉트가 발생해, AuthGate가 /login으로 보내는 순간
 * LoginRoute가 다시 /today로 보내는 식의 리다이렉트 레이스/루프가 생길 수
 * 있다.
 */

export type AuthRouteDecision = 'wait' | 'render' | 'redirect';

export interface SessionState {
  userId: string | null;
  loading: boolean;
}

/**
 * AuthGate(로그인 필요 영역)의 판정.
 * loading -> 'wait' (Spinner)
 * userId === null -> 'redirect' (/login으로)
 * else -> 'render' (Outlet)
 */
export function resolveAuthGateDecision(state: SessionState): AuthRouteDecision {
  if (state.loading) {
    return 'wait';
  }
  if (state.userId === null) {
    return 'redirect';
  }
  return 'render';
}

/**
 * /login 라우트(LoginRoute)의 판정.
 *
 * 기존 LoginRoute는 세션 상태를 전혀 확인하지 않고 항상 LoginScreen을
 * 렌더링했다 - 이미 로그인된 사용자가 /login으로 진입(또는 로그인 후 뒤로가기
 * 등)하면 불필요하게 로그인 화면이 다시 보이는 버그였다. 이 함수는 그 버그를
 * 고치기 위한 새 판정 로직이다.
 *
 * loading -> 'wait' (Spinner - 세션 확인 전 로그인 화면이 잠깐 보이는 깜빡임 방지)
 * userId !== null -> 'redirect' (이미 세션이 있으므로 /today로, 로그인 UI 건너뜀)
 * userId === null -> 'render' (LoginScreen)
 */
export function resolveLoginRouteDecision(state: SessionState): AuthRouteDecision {
  if (state.loading) {
    return 'wait';
  }
  if (state.userId !== null) {
    return 'redirect';
  }
  return 'render';
}
