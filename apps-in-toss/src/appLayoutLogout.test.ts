/**
 * router.tsx가 쓰는 로그아웃 상태 머신(src/appLayoutLogout.ts) 테스트.
 *
 * 이 프로젝트에는 jsdom/@testing-library/react가 설치되어 있지 않아
 * AppLayout 같은 컴포넌트를 직접 렌더링할 수 없다(ConfirmDialog.test.tsx/
 * LoginScreen.test.tsx와 동일한 제약). 게다가 router.tsx 자체는 최상단에서
 * createBrowserRouter(...)를 호출해 모듈 로드 시점에 document를 참조하므로
 * router.tsx를 그대로 import하면(jsdom 없는 이 프로젝트에서) 그 자체로
 * 테스트가 죽는다 - 그래서 이 테스트는 router.tsx가 아니라 순수 로직만 뺀
 * src/appLayoutLogout.ts를 직접 import한다.
 *
 * 핵심 계약: "확인 전에는 signOut을 호출하지 않는다." AppLayout의
 * useEffect는 logoutState === 'signing-out'일 때만 supabase.auth.signOut()을
 * 호출하므로, nextLogoutState가 오직 confirming 상태에서 confirm 이벤트를
 * 받았을 때만 'signing-out'을 반환한다는 것만 증명하면 이 계약이 성립한다.
 */
import { describe, expect, it } from 'vitest';

import { nextLogoutState } from './appLayoutLogout.ts';

describe('nextLogoutState', () => {
  it('idle 상태에서 open-dialog를 받으면 confirming으로 전이한다', () => {
    expect(nextLogoutState('idle', 'open-dialog')).toBe('confirming');
  });

  it('confirming 상태에서 confirm을 받아야만 signing-out으로 전이한다', () => {
    expect(nextLogoutState('confirming', 'confirm')).toBe('signing-out');
  });

  it('idle 상태(다이얼로그가 열리기 전)에서 confirm이 와도 signing-out으로 가지 않는다', () => {
    // 이 케이스가 "확인 전에는 signOut 미호출"을 보장하는 핵심 단언이다.
    expect(nextLogoutState('idle', 'confirm')).toBe('idle');
  });

  it('confirming 상태에서 cancel을 받으면 idle로 되돌아간다', () => {
    expect(nextLogoutState('confirming', 'cancel')).toBe('idle');
  });

  it('idle 상태에서 cancel은 아무 효과가 없다', () => {
    expect(nextLogoutState('idle', 'cancel')).toBe('idle');
  });

  it('signing-out 상태는 open-dialog/cancel로 되돌릴 수 없다(이미 진행 중)', () => {
    expect(nextLogoutState('signing-out', 'open-dialog')).toBe('signing-out');
    expect(nextLogoutState('signing-out', 'cancel')).toBe('signing-out');
    expect(nextLogoutState('signing-out', 'confirm')).toBe('signing-out');
  });

  it('confirming 상태에서 open-dialog는 아무 효과가 없다(이미 열려 있음)', () => {
    expect(nextLogoutState('confirming', 'open-dialog')).toBe('confirming');
  });
});
