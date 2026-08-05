/**
 * 토스 로그인(TossAuth) -> Edge Function(toss-login) -> Supabase 세션 발급 흐름.
 *
 * authorizationCode/token_hash 같은 민감값은 절대 console.* 등 로그로 넘기지 않는다.
 * 실제 브라우저/토스 SDK 의존성은 createDefaultTossLoginDeps()에서만 조립하고,
 * runTossLogin() 자체는 의존성 주입으로 순수하게 테스트 가능하게 유지한다.
 */
import { TossAuth } from '@apps-in-toss/web-framework';

import { supabase } from '../../lib/supabase.ts';

export type TossLoginErrorCode =
  | 'invalid_request'
  | 'toss_api_base_not_configured'
  | 'mtls_unsupported'
  | 'toss_token_exchange_failed'
  | 'toss_userinfo_failed'
  | 'identity_link_failed'
  | 'session_issue_failed'
  | 'server_misconfigured'
  | 'user_cancelled'
  | 'invoke_failed'
  | 'invalid_response';

export interface TossLoginDeps {
  login(): Promise<{ authorizationCode: string; referrer: 'DEFAULT' | 'SANDBOX' }>;
  invokeTossLogin(body: {
    authorizationCode: string;
    referrer: string;
  }): Promise<{ data: unknown; error: { message: string } | null }>;
  verifyOtp(params: { token_hash: string; type: 'email' }): Promise<{
    data: { user: { id: string } | null } | null;
    error: { message: string } | null;
  }>;
}

export type TossLoginResult =
  | { ok: true; userId: string; isNewUser: boolean }
  | { ok: false; code: TossLoginErrorCode; message: string };

const KOREAN_MESSAGES: Record<TossLoginErrorCode, string> = {
  invalid_request: '로그인 요청이 올바르지 않습니다. 다시 시도해주세요.',
  toss_api_base_not_configured: '서버 설정 오류로 로그인할 수 없습니다. 잠시 후 다시 시도해주세요.',
  mtls_unsupported: '서버 설정 오류로 로그인할 수 없습니다. 잠시 후 다시 시도해주세요.',
  toss_token_exchange_failed: '토스 인증에 실패했습니다. 다시 시도해주세요.',
  toss_userinfo_failed: '토스 사용자 정보를 가져오지 못했습니다. 다시 시도해주세요.',
  identity_link_failed: '계정 연결에 실패했습니다. 잠시 후 다시 시도해주세요.',
  session_issue_failed: '로그인 세션을 발급하지 못했습니다. 다시 시도해주세요.',
  server_misconfigured: '서버 설정 오류로 로그인할 수 없습니다. 잠시 후 다시 시도해주세요.',
  user_cancelled: '로그인이 취소되었습니다.',
  invoke_failed: '로그인 요청 중 오류가 발생했습니다. 다시 시도해주세요.',
  invalid_response: '서버 응답을 처리하지 못했습니다. 다시 시도해주세요.',
};

export function toKoreanMessage(code: TossLoginErrorCode): string {
  return KOREAN_MESSAGES[code];
}

/**
 * toss-login Edge Function이 정상 응답으로 내려줘야 하는 최소 형태.
 * isNewUser는 선택값(없으면 false로 취급)으로 둔다 - 서버 계약이 아직 확정 전이라
 * 필드가 누락돼도 로그인 자체는 막지 않되, token_hash 부재는 명백한 스키마 위반으로 본다.
 */
interface TossLoginInvokeData {
  token_hash: string;
  isNewUser?: boolean;
}

function isTossLoginInvokeData(value: unknown): value is TossLoginInvokeData {
  if (typeof value !== 'object' || value === null) return false;
  const record = value as Record<string, unknown>;
  return typeof record.token_hash === 'string' && record.token_hash.length > 0;
}

function isKnownErrorCode(value: unknown): value is TossLoginErrorCode {
  return (
    typeof value === 'string' &&
    Object.prototype.hasOwnProperty.call(KOREAN_MESSAGES, value)
  );
}

/**
 * Edge Function이 에러 메시지에 알려진 코드를 실어 보내면 그 코드를 그대로 쓰고,
 * 아니면 일반 invoke_failed로 폴백한다(서버 계약이 세분화되기 전까지의 보수적 기본값).
 */
function classifyInvokeError(message: string | undefined): TossLoginErrorCode {
  if (isKnownErrorCode(message)) return message;
  return 'invoke_failed';
}

export async function runTossLogin(deps: TossLoginDeps): Promise<TossLoginResult> {
  let authorizationCode: string;
  let referrer: 'DEFAULT' | 'SANDBOX';

  try {
    const loginResult = await deps.login();
    authorizationCode = loginResult.authorizationCode;
    referrer = loginResult.referrer;
  } catch {
    // 사용자가 토스 로그인 화면에서 취소했거나 SDK가 거부한 경우.
    // authorizationCode가 존재하지 않는 시점이므로 로그에 남길 민감값이 없다.
    return { ok: false, code: 'user_cancelled', message: toKoreanMessage('user_cancelled') };
  }

  if (!authorizationCode) {
    return { ok: false, code: 'invalid_request', message: toKoreanMessage('invalid_request') };
  }

  const invokeResult = await deps.invokeTossLogin({ authorizationCode, referrer });

  if (invokeResult.error) {
    const code = classifyInvokeError(invokeResult.error.message);
    return { ok: false, code, message: toKoreanMessage(code) };
  }

  if (!isTossLoginInvokeData(invokeResult.data)) {
    return { ok: false, code: 'invalid_response', message: toKoreanMessage('invalid_response') };
  }

  const { token_hash: tokenHash, isNewUser = false } = invokeResult.data;

  const verifyResult = await deps.verifyOtp({ token_hash: tokenHash, type: 'email' });

  if (verifyResult.error || !verifyResult.data?.user?.id) {
    return {
      ok: false,
      code: 'session_issue_failed',
      message: toKoreanMessage('session_issue_failed'),
    };
  }

  return { ok: true, userId: verifyResult.data.user.id, isNewUser };
}

export function createDefaultTossLoginDeps(): TossLoginDeps {
  return {
    login: () => TossAuth.login(),
    invokeTossLogin: (body) => supabase.functions.invoke('toss-login', { body }),
    verifyOtp: (params) => supabase.auth.verifyOtp(params),
  };
}
