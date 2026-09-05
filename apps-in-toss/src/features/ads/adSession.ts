/**
 * 광고 노출 판단에 쓰는 세션 스코프 상태.
 *
 * 영속화하지 않는다 - 페이지가 새로 로드되면(앱 재시작 포함) 매번 초기
 * 상태로 리셋된다. src/appLayoutLogout.ts의 `nextLogoutState(state, action)
 * => newState` 순수 리듀서 패턴을 그대로 따른다(클래스/스토어 라이브러리
 * 아님).
 *
 * 상태 구성:
 * - sessionStartedAt: 세션(페이지 로드) 시작 시각.
 * - meaningfulActionCompleted: 이번 세션에서 "의미 있는 행동"(예: 일정 생성)이
 *   한 번이라도 발생했는지. 한 번 true가 되면 세션이 끝날 때까지(=페이지
 *   재로드 전까지) 다시 false로 돌아가지 않는다(sticky).
 * - modalOpen: 광고 모달이 현재 열려 있는지.
 */
export interface AdSessionState {
  sessionStartedAt: Date;
  meaningfulActionCompleted: boolean;
  modalOpen: boolean;
}

/** src/domain/datetime.ts의 `now?: Date` DI 컨벤션을 따른다(Clock 클래스 아님). */
export function createAdSessionState(now: Date = new Date()): AdSessionState {
  return {
    sessionStartedAt: now,
    meaningfulActionCompleted: false,
    modalOpen: false,
  };
}

export type AdSessionAction =
  | { type: 'meaningful-action' }
  | { type: 'modal-open' }
  | { type: 'modal-close' };

export function nextAdSessionState(
  state: AdSessionState,
  action: AdSessionAction,
): AdSessionState {
  switch (action.type) {
    case 'meaningful-action':
      // sticky: 이미 true면 굳이 새 객체를 만들 필요는 없지만, 항상 새
      // 객체를 반환하는 일관된 계약을 유지하기 위해 spread로 새 객체를 만든다.
      return { ...state, meaningfulActionCompleted: true };
    case 'modal-open':
      return { ...state, modalOpen: true };
    case 'modal-close':
      return { ...state, modalOpen: false };
    default:
      return state;
  }
}
