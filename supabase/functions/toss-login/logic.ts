// Toss(AppsInToss) 로그인 Edge Function의 순수 로직 모듈.
//
// 이 파일은 원격 import나 Deno 전역 API에 의존하지 않는 순수 TypeScript다.
// (Deno.env, Deno.createHttpClient 등은 index.ts 같은 실행 진입점에서 값을 읽어
//  이 모듈의 함수에 파라미터로 넘겨줘야 한다.) 그래야 deno test로 격리 검증이 가능하다.
//
// 배경: Toss 로그인 콘솔의 실제 API 호스트가 아직 미확정이라, 이 모듈은
// referrer(DEFAULT/SANDBOX)별 API base URL을 env에서만 읽고 하드코딩하지 않는다
// (anti-patterns.md "리디렉트 allowlist에 추측 도메인 등록 금지" 원칙과 동일 맥락 —
//  실측/설정 없는 값을 신뢰하지 않는다).

/** Toss 로그인 콘솔 environment 구분. */
export type TossReferrer = "DEFAULT" | "SANDBOX";

const VALID_REFERRERS: readonly TossReferrer[] = ["DEFAULT", "SANDBOX"];

function isTossReferrer(value: unknown): value is TossReferrer {
  return typeof value === "string" &&
    (VALID_REFERRERS as readonly string[]).includes(value);
}

/** parseLoginRequest 성공 결과. */
export type ParsedLoginRequest = {
  ok: true;
  authorizationCode: string;
  referrer: TossReferrer;
};

/** parseLoginRequest 실패 결과. */
export type ParsedLoginRequestError = {
  ok: false;
  error: "invalid_request";
};

/**
 * 클라이언트가 보낸 로그인 요청 바디를 검증한다.
 * fail-closed: authorizationCode가 비어있거나 타입이 안 맞거나,
 * referrer가 미지의 값이면 전부 거부한다.
 */
export function parseLoginRequest(
  body: unknown,
): ParsedLoginRequest | ParsedLoginRequestError {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_request" };
  }

  const record = body as Record<string, unknown>;
  const rawCode = record.authorizationCode;
  const rawReferrer = record.referrer;

  if (typeof rawCode !== "string") {
    return { ok: false, error: "invalid_request" };
  }
  const authorizationCode = rawCode.trim();
  if (authorizationCode.length === 0) {
    return { ok: false, error: "invalid_request" };
  }

  if (!isTossReferrer(rawReferrer)) {
    return { ok: false, error: "invalid_request" };
  }

  return { ok: true, authorizationCode, referrer: rawReferrer };
}

/** resolveTossApiBase 성공 결과. */
export type ResolvedTossApiBase = { ok: true; base: string };

/** resolveTossApiBase 실패 결과. */
export type ResolvedTossApiBaseError = {
  ok: false;
  error: "toss_api_base_not_configured";
};

/**
 * referrer(DEFAULT/SANDBOX)에 맞는 Toss API base URL을 env에서 읽는다.
 * 실제 콘솔 호스트가 미확정이므로 하드코딩하지 않고, 값이 없으면 실패한다
 * (fail-closed — 추측 도메인을 신뢰하지 않는다).
 */
export function resolveTossApiBase(
  referrer: TossReferrer,
  env: Record<string, string | undefined>,
): ResolvedTossApiBase | ResolvedTossApiBaseError {
  const key = referrer === "SANDBOX"
    ? "TOSS_API_BASE_URL_SANDBOX"
    : "TOSS_API_BASE_URL_DEFAULT";
  const raw = env[key];
  const base = raw?.trim();
  if (!base) {
    return { ok: false, error: "toss_api_base_not_configured" };
  }
  return { ok: true, base };
}

/**
 * tossUserKey로부터 결정적 synthetic 이메일을 만든다.
 * naver-userinfo-proxy의 관례(naver-${sub}@users.planflow.local)를 따른다.
 * 키는 소문자화하고, 이메일 로컬파트에 안전한 문자만 남긴다([a-z0-9._-]).
 */
export function syntheticEmailFor(tossUserKey: string): string {
  const normalized = tossUserKey
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "");
  return `toss-${normalized}@users.planflow.local`;
}

/**
 * 전달받은 Deno 전역 객체(또는 그 일부)가 createHttpClient(mTLS 클라이언트 인증서
 * 지원)를 노출하는지 순수하게 검사한다. 부작용은 없다 — 실제 클라이언트 생성은
 * 이 함수의 책임이 아니다.
 */
export function supportsMtls(globalDeno: unknown): boolean {
  if (typeof globalDeno !== "object" || globalDeno === null) {
    return false;
  }
  const candidate = (globalDeno as Record<string, unknown>).createHttpClient;
  return typeof candidate === "function";
}

/** Toss 로그인 흐름에서 사용하는 에러 코드 집합. */
export const TOSS_LOGIN_ERROR_CODES = {
  INVALID_REQUEST: "invalid_request",
  TOSS_API_BASE_NOT_CONFIGURED: "toss_api_base_not_configured",
  MTLS_UNSUPPORTED: "mtls_unsupported",
  TOSS_TOKEN_EXCHANGE_FAILED: "toss_token_exchange_failed",
  TOSS_USERINFO_FAILED: "toss_userinfo_failed",
  IDENTITY_LINK_FAILED: "identity_link_failed",
  SESSION_ISSUE_FAILED: "session_issue_failed",
  SERVER_MISCONFIGURED: "server_misconfigured",
} as const;

export type TossLoginErrorCode =
  typeof TOSS_LOGIN_ERROR_CODES[keyof typeof TOSS_LOGIN_ERROR_CODES];
