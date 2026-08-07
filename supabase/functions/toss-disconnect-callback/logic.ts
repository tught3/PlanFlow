// Toss(AppsInToss) 연동해제(disconnect) 콜백 Edge Function의 순수 로직 모듈.
//
// (a) 이 파일은 원격 import나 Deno 전역 API에 의존하지 않는 순수 TypeScript다.
//     toss-login/index.ts가 최상위에서 serve()를 호출해 deno test로 격리 검증이
//     불가능했던 실수(anti-patterns.md "만들어놨는데 연결이 안 됨" 계열)를
//     반복하지 않는다 — 모든 로직은 이 파일에 두고, index.ts는 Deno.serve/env를
//     이 파일의 순수 함수에 값으로 넘겨주는 얇은 wrapper로만 둔다(다른 에이전트가
//     작성 예정).
//
// (b) 이 파일의 `referrer`(UNLINK/WITHDRAWAL_TERMS/WITHDRAWAL_TOSS — 연동해제 사유)는
//     toss-login/logic.ts의 `TossReferrer`(DEFAULT/SANDBOX — 로그인 콘솔 environment
//     구분)와 필드명만 같을 뿐 완전히 다른 enum이다. 절대 혼동하거나 _shared/로
//     통합하지 말 것 — 의미가 다른 두 개념을 같은 이름으로 묶으면 나중에 값을
//     엇갈려 대입하는 조용한 버그로 이어진다.
//
// 공식 스펙(콘솔 문서 확인됨, 재확인 불필요):
//   Toss가 GET {url}?userKey=X&referrer=Y 또는 POST {url}
//   (JSON body {"userKey": X, "referrer": Y})로 호출한다.
//   인증: Authorization: Basic <base64> 헤더. base64 디코드한 평문을
//   서버 secret(그 자체도 평문 저장)과 비교한다.

/** Toss 연동해제 콜백의 알려진 referrer(사유) 값. */
export const DISCONNECT_REFERRERS = [
  "UNLINK",
  "WITHDRAWAL_TERMS",
  "WITHDRAWAL_TOSS",
] as const;

export type DisconnectReferrer = typeof DISCONNECT_REFERRERS[number];

/**
 * referrer 값을 분류한다.
 * - "malformed": 문자열이 아니거나 빈 문자열 (요청 자체가 잘못됨 — 400 대상)
 * - "unknown": 비어있지 않은 문자열이지만 알려진 3개 값에 없음
 *   (Toss가 향후 referrer 값을 추가할 수 있으므로, 이건 에러가 아니라
 *   "우리가 특별히 대응하지 않는 유효한 이벤트"로 취급해야 한다 — future-proofing)
 * - "known": DISCONNECT_REFERRERS 중 하나와 정확히 일치
 */
export function classifyReferrer(
  value: unknown,
): "known" | "unknown" | "malformed" {
  if (typeof value !== "string" || value.length === 0) {
    return "malformed";
  }
  return (DISCONNECT_REFERRERS as readonly string[]).includes(value)
    ? "known"
    : "unknown";
}

/** normalizeTossUserKey 성공 결과. */
export type NormalizedUserKey = { ok: true; key: string };
/** normalizeTossUserKey 실패 결과. */
export type NormalizedUserKeyError = { ok: false };

/**
 * Toss userKey(number | string)를 문자열 키로 정규화한다.
 * - number: Number.isSafeInteger가 아니면 거부, 통과하면 String()으로 변환.
 * - string: trim 후 비어있지 않아야 함.
 * - 그 외(null/undefined/object/boolean/unsafe-integer 등): 거부.
 */
export function normalizeTossUserKey(
  value: unknown,
): NormalizedUserKey | NormalizedUserKeyError {
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) {
      return { ok: false };
    }
    return { ok: true, key: String(value) };
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return { ok: false };
    }
    return { ok: true, key: trimmed };
  }
  return { ok: false };
}

/**
 * raw(파싱 전) JSON 바디 텍스트에서 "userKey": <digits> 리터럴을 정규식으로
 * 직접 추출한다. JS의 JSON.parse는 2^53을 넘는 정수 리터럴을 부동소수점으로
 * 반올림해 자릿수를 조용히 손상시킬 수 있으므로, 파싱된 JSON 값보다 이 원문
 * 추출을 우선한다. 매칭되는 숫자 리터럴이 없으면 null.
 */
export function extractRawUserKeyLiteral(rawBodyText: string): string | null {
  const match = rawBodyText.match(/"userKey"\s*:\s*(\d+)/);
  return match ? match[1] : null;
}

/** parseDisconnectRequest 성공 결과. */
export type ParsedDisconnectRequest = {
  ok: true;
  userKey: string;
  referrer: string;
  referrerClass: "known" | "unknown";
};
/** parseDisconnectRequest 실패 결과. */
export type ParsedDisconnectRequestError = { ok: false; reason: string };

/**
 * Toss 연동해제 콜백 요청(GET 쿼리스트링 또는 POST JSON 바디)을 파싱한다.
 *
 * - GET: `source.url`의 쿼리스트링에서 userKey/referrer를 읽는다.
 * - POST: `source.rawBody`를 JSON으로 파싱한다. userKey는
 *   extractRawUserKeyLiteral을 우선 사용하고(원문에서 큰 정수 손실 방지),
 *   실패하면 파싱된 JSON 값을 normalizeTossUserKey로 정규화해 폴백한다.
 *
 * userKey 누락/malformed 이거나 referrer가 malformed(문자열 아님/빈 문자열)이면
 * `{ok:false, reason:...}`을 반환한다(400 대상). referrer가 "unknown" 분류여도
 * 이는 파싱 실패가 아니라 유효한 요청이므로 `{ok:true, referrerClass:'unknown'}`을
 * 반환한다 — 우리가 특별히 처리하지 않는 이벤트 종류일 뿐이다(P3 참조).
 */
export function parseDisconnectRequest(
  source: { method: string; url: string; rawBody: string | null },
): ParsedDisconnectRequest | ParsedDisconnectRequestError {
  const method = source.method.toUpperCase();

  let rawUserKeyValue: unknown;
  let rawReferrerValue: unknown;
  let rawUserKeyLiteral: string | null = null;

  if (method === "GET") {
    let parsedUrl: URL;
    try {
      parsedUrl = new URL(source.url);
    } catch (_err) {
      return { ok: false, reason: "invalid_url" };
    }
    rawUserKeyValue = parsedUrl.searchParams.get("userKey") ?? undefined;
    rawReferrerValue = parsedUrl.searchParams.get("referrer") ?? undefined;
  } else {
    if (!source.rawBody) {
      return { ok: false, reason: "missing_body" };
    }
    rawUserKeyLiteral = extractRawUserKeyLiteral(source.rawBody);

    let parsedBody: unknown;
    try {
      parsedBody = JSON.parse(source.rawBody);
    } catch (_err) {
      return { ok: false, reason: "invalid_json" };
    }
    if (
      typeof parsedBody !== "object" || parsedBody === null ||
      Array.isArray(parsedBody)
    ) {
      return { ok: false, reason: "invalid_body_shape" };
    }
    const record = parsedBody as Record<string, unknown>;
    rawUserKeyValue = record.userKey;
    rawReferrerValue = record.referrer;
  }

  // userKey: 원문 리터럴 추출이 성공했으면 그 문자열을 그대로 신뢰한다
  // (JSON.parse의 큰 정수 반올림을 우회하기 위함). 없으면 파싱된 값을 정규화한다.
  let userKey: string;
  if (rawUserKeyLiteral !== null) {
    userKey = rawUserKeyLiteral;
  } else {
    const normalized = normalizeTossUserKey(rawUserKeyValue);
    if (!normalized.ok) {
      return { ok: false, reason: "invalid_user_key" };
    }
    userKey = normalized.key;
  }

  const referrerClass = classifyReferrer(rawReferrerValue);
  if (referrerClass === "malformed") {
    return { ok: false, reason: "invalid_referrer" };
  }

  return {
    ok: true,
    userKey,
    referrer: rawReferrerValue as string,
    referrerClass,
  };
}

/** decodeBasicAuth 성공 결과. */
export type DecodedBasicAuth = { ok: true; credentials: string };
/** decodeBasicAuth 실패 결과. */
export type DecodedBasicAuthError = { ok: false };

/**
 * `Authorization: Basic <base64>` 헤더를 디코드해 평문 credentials 문자열을
 * 반환한다. 헤더 부재, scheme 불일치("Basic "이 아님), base64 디코드 실패는
 * 전부 ok:false로 fail-closed 처리한다.
 */
export function decodeBasicAuth(
  header: string | null,
): DecodedBasicAuth | DecodedBasicAuthError {
  if (!header) {
    return { ok: false };
  }
  const prefix = "Basic ";
  if (!header.startsWith(prefix)) {
    return { ok: false };
  }
  const encoded = header.slice(prefix.length).trim();
  if (encoded.length === 0) {
    return { ok: false };
  }
  try {
    const credentials = atob(encoded);
    return { ok: true, credentials };
  } catch (_err) {
    return { ok: false };
  }
}

/**
 * 타이밍 세이프 문자열 비교. 두 입력의 길이가 다르더라도 실제 secret 길이
 * 범위(<= 수백 바이트)에서 관측 가능한 타이밍으로 길이 차이가 새지 않도록,
 * 두 문자열 중 더 긴 길이를 기준으로 전체를 XOR-누적 비교한다(짧은 쪽은
 * 존재하지 않는 인덱스를 0으로 취급 — 반드시 불일치가 되지만 비교 루프
 * 자체는 조기 종료 없이 끝까지 돈다).
 */
export function safeEqual(a: string, b: string): boolean {
  const maxLen = Math.max(a.length, b.length);
  let mismatch = a.length === b.length ? 0 : 1;
  for (let i = 0; i < maxLen; i++) {
    const ca = i < a.length ? a.charCodeAt(i) : 0;
    const cb = i < b.length ? b.charCodeAt(i) : 0;
    mismatch |= ca ^ cb;
  }
  return mismatch === 0;
}

/** Toss 연동해제 콜백 흐름에서 사용하는 에러 코드 집합. */
export const TOSS_DISCONNECT_ERROR_CODES = {
  INVALID_REQUEST: "invalid_request",
  UNAUTHORIZED: "unauthorized",
  SERVER_MISCONFIGURED: "server_misconfigured",
} as const;

export type TossDisconnectErrorCode =
  typeof TOSS_DISCONNECT_ERROR_CODES[keyof typeof TOSS_DISCONNECT_ERROR_CODES];

/** 사용자 노출용 한국어 메시지(toss-login과 동일 관례). */
export const KOREAN_MESSAGES: Record<TossDisconnectErrorCode, string> = {
  invalid_request: "요청 형식이 올바르지 않습니다.",
  unauthorized: "인증에 실패했습니다.",
  server_misconfigured: "서버 설정 오류입니다.",
};

// ---------------------------------------------------------------------------
// P3 — 연동해제 적용 로직 (port 인터페이스를 통한 의존성 주입)
// ---------------------------------------------------------------------------

/**
 * 연동해제 적용에 필요한 최소 데이터 접근 포트.
 * 의도적으로 이 두 메서드만 노출한다(events/users 등 다른 접근 메서드를
 * 추가하지 않는다 — 타입 레벨에서 이 흐름이 손댈 수 있는 데이터 범위를
 * 최소화하는 격리 보장이다).
 */
export interface DisconnectPort {
  findByTossUserKey(
    key: string,
  ): Promise<{ userId: string; disconnectedAt: string | null } | null>;
  markDisconnected(
    userId: string,
    referrer: string,
    nowIso: string,
  ): Promise<{ ok: true } | { ok: false; error: string }>;
}

export type ApplyDisconnectResult =
  | "disconnected"
  | "already_disconnected"
  | "unknown_user"
  | "ignored_unknown_referrer"
  | "error";

/**
 * 연동해제 요청을 실제로 적용한다.
 *
 * - referrerClass === "unknown" 이면 markDisconnected를 전혀 호출하지 않고
 *   즉시 "ignored_unknown_referrer"를 반환한다(우리가 특별히 대응하지 않는
 *   이벤트 — 조용히 무시하되 200 응답은 정상적으로 나가야 하므로 에러가 아님).
 * - findByTossUserKey로 조회했는데 없으면 "unknown_user"(에러 아님 — Toss가
 *   PlanFlow와 연결된 적 없는 userKey에 대해서도 콜백을 보낼 수 있음).
 * - 조회 결과 disconnectedAt이 이미 non-null이면 markDisconnected를 다시
 *   호출하지 않고 "already_disconnected"를 반환한다(멱등 no-op — 원래
 *   타임스탬프를 보존하고 중복 처리로 인한 부작용을 막는다).
 * - disconnectedAt이 null이면 markDisconnected를 호출해 결과에 따라
 *   "disconnected" 또는 "error"를 반환한다.
 */
export async function applyDisconnect(
  port: DisconnectPort,
  tossUserKey: string,
  referrer: string,
  referrerClass: "known" | "unknown",
  nowIso: string,
): Promise<ApplyDisconnectResult> {
  if (referrerClass === "unknown") {
    return "ignored_unknown_referrer";
  }

  const identity = await port.findByTossUserKey(tossUserKey);
  if (!identity) {
    return "unknown_user";
  }

  if (identity.disconnectedAt !== null) {
    return "already_disconnected";
  }

  const result = await port.markDisconnected(
    identity.userId,
    referrer,
    nowIso,
  );
  return result.ok ? "disconnected" : "error";
}
