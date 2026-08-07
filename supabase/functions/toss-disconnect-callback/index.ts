// Toss(AppsInToss) 연동해제(disconnect) 콜백 Edge Function.
//
// 책임: Toss 서버가 사용자 연동해제(탈퇴/연결끊기) 시 이 엔드포인트를 호출하면,
//   Basic Auth로 인증한 뒤 logic.ts의 순수 함수(parseDisconnectRequest,
//   applyDisconnect 등)에 위임해 public.toss_identities의 disconnected_at을
//   갱신한다. 이 파일 자체는 결정 로직을 갖지 않는 얇은 wrapper다 — 모든
//   판단은 logic.ts에 있고(테스트도 거기서 순수 함수로 검증됨), 여기서는
//   Deno.serve/env/Supabase client를 그 순수 함수에 값으로 연결만 한다.
//
// ⚠️ 배포 필수: 이 함수는 `supabase functions deploy toss-disconnect-callback
//   --no-verify-jwt`로 배포해야 한다. Toss는 Supabase JWT도 apikey도 보내지
//   않고 오직 `Authorization: Basic <base64>` 헤더만 보낸다. --no-verify-jwt
//   없이 배포하면 Supabase 게이트웨이가 이 코드가 실행되기도 전에 모든 요청을
//   401로 거부한다. 따라서 아래의 Basic Auth 검사(decodeBasicAuth + safeEqual)가
//   이 엔드포인트의 유일한 인증 경계다 — 게이트웨이 JWT 검증에 기대지 않는다.
//
// 응답 상태 코드는 Toss 공식 문서가 명시하지 않아 우리가 추론한 관례다:
//   200 = 성공적으로 처리됨(no-op성 결과 포함: already_disconnected,
//         unknown_user, ignored_unknown_referrer도 전부 "에러 아님"으로 200)
//   401 = 인증 실패(Basic Auth 자격증명 불일치/누락)
//   400 = 요청 형식 오류(malformed userKey/referrer, JSON 파싱 실패 등)
//   405 = 허용되지 않는 HTTP 메서드
//   500 = 서버 설정 오류(env 미설정) 또는 DB 갱신 실패
//
// ⚠️ referrer 명칭 충돌 주의: 이 파일의 `referrer`(UNLINK/WITHDRAWAL_TERMS/
//   WITHDRAWAL_TOSS — 연동해제 사유)는 toss-login/logic.ts의 같은 이름
//   `TossReferrer`(DEFAULT/SANDBOX — 로그인 콘솔 environment 구분)와 필드명만
//   같을 뿐 완전히 다른 enum이다. 절대 혼동하지 말 것(logic.ts 파일 헤더 주석도
//   동일하게 경고함).
//
// PII/secret 비로깅 규율(toss-login/index.ts와 동일 원칙 적용):
//   userKey, Authorization 헤더 원문, 디코드된 credentials, Basic Auth
//   secret 값은 어떤 로그 경로(성공/실패/에러 포함)에도 절대 출력하지 않는다.
//   console.error에는 에러 코드/사유 문자열, DB 에러 코드만 남긴다.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";
import {
  applyDisconnect,
  decodeBasicAuth,
  type DisconnectPort,
  parseDisconnectRequest,
  safeEqual,
  TOSS_DISCONNECT_ERROR_CODES,
} from "./logic.ts";

// 앱인토스 콘솔의 "테스트하기" 버튼은 브라우저(콘솔 웹페이지)에서 fetch로
// 이 엔드포인트를 직접 호출하는 것으로 실측 확인됨(Edge Function 로그에
// 우리가 보낸 적 없는 "OPTIONS | 405" 요청이 찍혀 있었음 — 이 콜백은
// 원래 서버-to-서버 웹훅이라 CORS가 불필요하다고 가정했으나, 콘솔 테스트
// 도구 자체가 브라우저 오리진에서 호출하므로 CORS preflight(OPTIONS)를
// 반드시 처리해야 한다). 실제 Toss 프로덕션 서버 호출은 브라우저가 아니라
// CORS 제약이 없으므로, 이 헤더는 콘솔 테스트 도구 지원을 위한 것이다.
const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-max-age": "86400",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}

/**
 * Supabase service_role 클라이언트를 이용한 DisconnectPort 구현.
 * logic.ts의 DisconnectPort 인터페이스가 의도적으로 이 두 메서드만
 * 노출하므로, 여기서도 그 범위를 벗어나는 쿼리를 추가하지 않는다.
 */
function buildDisconnectPort(adminClient: SupabaseClient): DisconnectPort {
  return {
    async findByTossUserKey(key: string) {
      const { data, error } = await adminClient
        .from("toss_identities")
        .select("user_id, disconnected_at")
        .eq("toss_user_key", key)
        .maybeSingle();

      if (error) {
        // 조회 실패는 "찾을 수 없음"과 구분해야 하지만, DisconnectPort의
        // findByTossUserKey는 null만 반환할 수 있는 계약이다. 조회 자체가
        // 실패하면 applyDisconnect가 "unknown_user"로 오판하지 않도록,
        // 에러를 던져 상위(serve 핸들러)에서 500으로 fail-closed 처리한다.
        console.error(
          "toss_identities select error:",
          error.code,
          error.message,
        );
        throw new Error("find_by_toss_user_key_failed");
      }

      if (!data) {
        return null;
      }

      return {
        userId: data.user_id as string,
        disconnectedAt: (data.disconnected_at as string | null) ?? null,
      };
    },

    async markDisconnected(userId: string, referrer: string, nowIso: string) {
      const { error } = await adminClient
        .from("toss_identities")
        .update({
          disconnected_at: nowIso,
          disconnect_referrer: referrer,
          updated_at: nowIso,
        })
        .eq("user_id", userId);

      if (error) {
        console.error(
          "toss_identities markDisconnected error:",
          error.code,
          error.message,
        );
        return { ok: false as const, error: error.message };
      }
      return { ok: true as const };
    },
  };
}

serve(async (req) => {
  // CORS preflight — 콘솔 테스트 도구(브라우저)가 실제 POST/GET 전에 보낸다.
  // 인증 없이 204만 반환한다(실제 인증은 본 요청에서 Basic Auth로 수행).
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // --- 1) Basic Auth 검사 — 바디 파싱보다 먼저 수행한다. ---
  const secret = Deno.env.get("TOSS_DISCONNECT_CALLBACK_BASIC_AUTH");
  if (!secret) {
    // 서버 secret 자체가 없는 것은 호출자의 잘못이 아니라 우리 배포 설정
    // 실수다. 401(호출자 자격증명 오류로 오인될 수 있음) 대신 500으로
    // "운영 측에서 고쳐야 재시도 가능"임을 신호한다.
    return json(
      { error: TOSS_DISCONNECT_ERROR_CODES.SERVER_MISCONFIGURED },
      500,
    );
  }

  const decoded = decodeBasicAuth(req.headers.get("authorization"));
  if (!decoded.ok || !safeEqual(decoded.credentials, secret)) {
    return json({ error: TOSS_DISCONNECT_ERROR_CODES.UNAUTHORIZED }, 401);
  }

  // --- 2) 요청 파싱. POST는 rawBody를 텍스트로 먼저 읽는다(req.json()을
  //     바로 쓰지 않는다 — parseDisconnectRequest/extractRawUserKeyLiteral이
  //     JSON.parse의 큰 정수 반올림 손실을 피하려면 원문 텍스트가 필요하다). ---
  let rawBody: string | null = null;
  if (req.method === "POST") {
    try {
      rawBody = await req.text();
    } catch (_err) {
      return json({ error: TOSS_DISCONNECT_ERROR_CODES.INVALID_REQUEST }, 400);
    }
  }

  const parsed = parseDisconnectRequest({
    method: req.method,
    url: req.url,
    rawBody,
  });
  if (!parsed.ok) {
    return json(
      { error: TOSS_DISCONNECT_ERROR_CODES.INVALID_REQUEST, reason: parsed.reason },
      400,
    );
  }

  // --- 3) env 확인 + Supabase admin client 구성. ---
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json(
      { error: TOSS_DISCONNECT_ERROR_CODES.SERVER_MISCONFIGURED },
      500,
    );
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey);
  const port = buildDisconnectPort(adminClient);

  // --- 4) 연동해제 적용 + 결과에 따른 응답. ---
  try {
    const result = await applyDisconnect(
      port,
      parsed.userKey,
      parsed.referrer,
      parsed.referrerClass,
      new Date().toISOString(),
    );

    if (result === "error") {
      // markDisconnected 내부 실패는 이미 buildDisconnectPort에서 로깅됐다.
      // 여기서는 DB 에러 상세를 응답 바디에 노출하지 않는다.
      return json({ error: "disconnect_apply_failed" }, 500);
    }

    // disconnected / already_disconnected / unknown_user /
    // ignored_unknown_referrer — 전부 "에러 아님" 결과이므로 200.
    return json({ ok: true, result });
  } catch (_err) {
    // findByTossUserKey가 조회 실패 시 throw하는 경로(위 buildDisconnectPort
    // 주석 참조) — 이미 내부에서 로깅됐으므로 여기서는 500만 반환한다.
    return json({ error: "disconnect_apply_failed" }, 500);
  }
});
