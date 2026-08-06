/**
 * 로그아웃 확인/실행 상태 머신.
 *
 * router.tsx 안에 있던 이 로직을 별도 파일로 뺀 이유는 테스트 때문이다 -
 * router.tsx 최상단에는 `export const router = createBrowserRouter([...])`가
 * 있는데, createBrowserRouter는 모듈 로드 시점에 즉시 `document`(브라우저
 * 전역)를 참조한다. 이 프로젝트에는 jsdom이 설치되어 있지 않아(다른 테스트
 * 파일들의 주석 참고), router.tsx를 vitest(node 환경)에서 import만 해도
 * "ReferenceError: document is not defined"로 테스트 스위트 자체가 죽는다.
 * 그래서 순수 상태 전이 로직만 이 파일로 분리해 router.tsx는 그대로 두고,
 * 테스트는 이 파일만 import한다.
 *
 * 핵심 계약: "확인 전에는 signOut을 호출하지 않는다." router.tsx의 AppLayout은
 * useEffect에서 logoutState === 'signing-out'일 때만 supabase.auth.signOut()을
 * 호출하므로, 이 함수가 confirming 상태에서 confirm 이벤트를 받았을 때만
 * 'signing-out'을 반환한다는 것만 증명하면 그 계약이 성립한다.
 *
 * - idle: 평상시. 로그아웃 버튼을 누르면 confirming으로 전이한다.
 * - confirming: ConfirmDialog가 열려 있다. confirm 이벤트가 와야만
 *   signing-out으로 전이한다. cancel 이벤트는 idle로 되돌린다.
 * - signing-out: signOut() 요청이 진행 중이다. 이 상태에서는 재확인
 *   다이얼로그를 다시 열거나 취소로 되돌릴 수 없다.
 */
export type LogoutUiState = 'idle' | 'confirming' | 'signing-out';
export type LogoutEvent = 'open-dialog' | 'confirm' | 'cancel';

export function nextLogoutState(current: LogoutUiState, event: LogoutEvent): LogoutUiState {
  switch (event) {
    case 'open-dialog':
      return current === 'idle' ? 'confirming' : current;
    case 'confirm':
      // confirming 상태가 아닐 때(예: 다이얼로그가 열리기 전) 들어온 confirm
      // 이벤트는 무시한다 - "확인 전에는 signOut을 호출하지 않는다"는 계약을
      // 이 한 줄이 보장한다.
      return current === 'confirming' ? 'signing-out' : current;
    case 'cancel':
      return current === 'confirming' ? 'idle' : current;
    default:
      return current;
  }
}
