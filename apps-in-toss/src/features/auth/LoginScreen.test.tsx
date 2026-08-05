/**
 * LoginScreen 화면 상태 변환 로직 테스트.
 *
 * 이 프로젝트에는 jsdom/@testing-library/react가 설치되어 있지 않아 컴포넌트를
 * 렌더링할 수 없다(EventForm.test.tsx와 동일한 제약). 대신 LoginScreen.tsx가
 * 컴포넌트와 함께 export하는 순수 함수 buildLoginScreenState를 직접 테스트한다.
 */
import { describe, expect, it } from 'vitest';

import { buildLoginScreenState } from './LoginScreen.tsx';
import type { TossLoginErrorCode, TossLoginResult } from './tossLogin.ts';
import { toKoreanMessage } from './tossLogin.ts';

function makeSuccessResult(overrides: Partial<Extract<TossLoginResult, { ok: true }>> = {}): TossLoginResult {
  return { ok: true, userId: 'user-1', isNewUser: false, ...overrides };
}

function makeFailureResult(code: TossLoginErrorCode): TossLoginResult {
  return { ok: false, code, message: toKoreanMessage(code) };
}

describe('buildLoginScreenState', () => {
  it('로그인 성공 시 재시도/종료 버튼 없이 성공 메시지를 반환한다', () => {
    const state = buildLoginScreenState(makeSuccessResult());

    expect(state.message).toBe('로그인되었습니다.');
    expect(state.canRetry).toBe(false);
    expect(state.shouldOfferExit).toBe(false);
  });

  it('사용자가 로그인을 거부(취소)하면 다시 시도+앱 종료 선택지를 함께 제공한다', () => {
    const state = buildLoginScreenState(makeFailureResult('user_cancelled'));

    expect(state.message).toBe(toKoreanMessage('user_cancelled'));
    expect(state.canRetry).toBe(true);
    expect(state.shouldOfferExit).toBe(true);
  });

  it('토큰 교환 실패 등 서버측 실패에도 다시 시도+앱 종료 선택지를 제공한다', () => {
    const state = buildLoginScreenState(makeFailureResult('toss_token_exchange_failed'));

    expect(state.message).toBe(toKoreanMessage('toss_token_exchange_failed'));
    expect(state.canRetry).toBe(true);
    expect(state.shouldOfferExit).toBe(true);
  });

  it('서버 설정 오류에도 동일하게 재시도/종료 선택지를 제공한다', () => {
    const state = buildLoginScreenState(makeFailureResult('server_misconfigured'));

    expect(state.canRetry).toBe(true);
    expect(state.shouldOfferExit).toBe(true);
  });

  it('세션 발급 실패에도 재시도/종료 선택지를 제공하고 메시지는 tossLogin.ts 코드 그대로 사용한다', () => {
    const state = buildLoginScreenState(makeFailureResult('session_issue_failed'));

    expect(state.message).toBe('로그인 세션을 발급하지 못했습니다. 다시 시도해주세요.');
    expect(state.canRetry).toBe(true);
    expect(state.shouldOfferExit).toBe(true);
  });
});
