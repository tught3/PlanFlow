import { describe, expect, it, vi } from 'vitest';

import { runTossLogin, toKoreanMessage } from './tossLogin.ts';
import type { TossLoginDeps } from './tossLogin.ts';

function createDeps(overrides: Partial<TossLoginDeps> = {}): TossLoginDeps {
  return {
    login: vi.fn(async () => ({ authorizationCode: 'auth-code-1', referrer: 'DEFAULT' as const })),
    invokeTossLogin: vi.fn(async () => ({ data: { token_hash: 'hash-1', isNewUser: false }, error: null })),
    verifyOtp: vi.fn(async () => ({ data: { user: { id: 'user-1' } }, error: null })),
    ...overrides,
  };
}

describe('runTossLogin', () => {
  it('성공 경로: authorizationCode -> invoke -> verifyOtp까지 이어져 userId를 반환한다', async () => {
    const deps = createDeps();

    const result = await runTossLogin(deps);

    expect(result).toEqual({ ok: true, userId: 'user-1', isNewUser: false });
    expect(deps.login).toHaveBeenCalledTimes(1);
    expect(deps.invokeTossLogin).toHaveBeenCalledWith({
      authorizationCode: 'auth-code-1',
      referrer: 'DEFAULT',
    });
    expect(deps.verifyOtp).toHaveBeenCalledWith({ token_hash: 'hash-1', type: 'email' });
  });

  it('신규 유저 플래그를 그대로 전달한다', async () => {
    const deps = createDeps({
      invokeTossLogin: vi.fn(async () => ({ data: { token_hash: 'hash-2', isNewUser: true }, error: null })),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({ ok: true, userId: 'user-1', isNewUser: true });
  });

  it('사용자 취소: login()이 reject되면 user_cancelled를 반환하고 후속 단계를 호출하지 않는다', async () => {
    const deps = createDeps({
      login: vi.fn(async () => {
        throw new Error('user closed toss login sheet');
      }),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({
      ok: false,
      code: 'user_cancelled',
      message: toKoreanMessage('user_cancelled'),
    });
    expect(deps.invokeTossLogin).not.toHaveBeenCalled();
    expect(deps.verifyOtp).not.toHaveBeenCalled();
  });

  it('authorizationCode가 빈 문자열이면 invalid_request로 즉시 실패한다', async () => {
    const deps = createDeps({
      login: vi.fn(async () => ({ authorizationCode: '', referrer: 'DEFAULT' as const })),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({
      ok: false,
      code: 'invalid_request',
      message: toKoreanMessage('invalid_request'),
    });
    expect(deps.invokeTossLogin).not.toHaveBeenCalled();
  });

  it('서버 에러: invoke가 알려진 에러 코드를 실어 보내면 그 코드로 분류한다', async () => {
    const deps = createDeps({
      invokeTossLogin: vi.fn(async () => ({
        data: null,
        error: { message: 'toss_token_exchange_failed' },
      })),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({
      ok: false,
      code: 'toss_token_exchange_failed',
      message: toKoreanMessage('toss_token_exchange_failed'),
    });
    expect(deps.verifyOtp).not.toHaveBeenCalled();
  });

  it('서버 에러: invoke가 알 수 없는 메시지를 보내면 invoke_failed로 폴백한다', async () => {
    const deps = createDeps({
      invokeTossLogin: vi.fn(async () => ({
        data: null,
        error: { message: 'unexpected 500' },
      })),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({
      ok: false,
      code: 'invoke_failed',
      message: toKoreanMessage('invoke_failed'),
    });
  });

  it('스키마 불일치: invoke 응답에 token_hash가 없으면 invalid_response를 반환한다', async () => {
    const deps = createDeps({
      invokeTossLogin: vi.fn(async () => ({ data: { foo: 'bar' }, error: null })),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({
      ok: false,
      code: 'invalid_response',
      message: toKoreanMessage('invalid_response'),
    });
    expect(deps.verifyOtp).not.toHaveBeenCalled();
  });

  it('verifyOtp 실패: error가 있으면 session_issue_failed를 반환한다', async () => {
    const deps = createDeps({
      verifyOtp: vi.fn(async () => ({ data: null, error: { message: 'otp expired' } })),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({
      ok: false,
      code: 'session_issue_failed',
      message: toKoreanMessage('session_issue_failed'),
    });
  });

  it('verifyOtp 실패: error는 없지만 user가 없으면 session_issue_failed를 반환한다', async () => {
    const deps = createDeps({
      verifyOtp: vi.fn(async () => ({ data: { user: null }, error: null })),
    });

    const result = await runTossLogin(deps);

    expect(result).toEqual({
      ok: false,
      code: 'session_issue_failed',
      message: toKoreanMessage('session_issue_failed'),
    });
  });
});
