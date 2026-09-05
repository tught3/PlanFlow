// Toss(AppsInToss) 로그인 Edge Function.
//
// 책임: Toss 로그인 콘솔이 발급한 authorizationCode를 받아
//   1) (미구현 — 아래 TODO 참조) Toss 서버와 mTLS로 토큰 교환 + 사용자정보 조회
//   2) 확보한 tossUserKey로 public.toss_identities를 조회/생성해 PlanFlow 계정과 연결
//   3) auth.admin.generateLink(magiclink)로 클라이언트가 세션을 발급받을 수 있는
//      hashed_token을 만들어 반환 (naver-userinfo-proxy와 달리, 이 함수는
//      브라우저 리다이렉트 없는 in-app 환경이라 클라이언트가 이 토큰으로
//      supabase.auth.verifyOtp({type:'magiclink', token_hash, email})를 호출해
//      세션을 완성한다).
//
// 보안:
//   - 이 엔드포인트는 verifyUser()(_shared/auth.ts)를 쓰지 않는다.
//     세션이 아직 없는 상태(로그인 자체를 시도하는 중)에서 호출되므로
//     "이미 로그인된 사용자인지"를 검증할 access_token이 존재하지 않는다.
//     클라이언트는 Supabase anon key만 들고 이 함수를 호출한다.
//   - anon key는 유효하게 서명된 JWT라 Supabase 게이트웨이의 verify_jwt를
//     통과한다(참고: _shared/auth.ts 파일 상단 주석 — openai-proxy/naver-geocode가
//     동일한 이유로 게이트웨이 검증만으로는 부족해 함수 내부 재검증을 추가했던 전례).
//     이 함수는 애초에 "로그인 여부"를 확인하는 게 아니라 "로그인을 발급"하는
//     엔드포인트이므로 anon key 호출 자체가 정상 사용 패턴이다 — 대신
//     실제 신원 증명은 Toss 서버가 발급한 authorizationCode가 담당한다
//     (이 코드를 mTLS로 Toss 서버와 교환해야만 유효한 tossUserKey를 얻을 수 있어,
//     authorizationCode 없이는 세션 발급까지 도달할 수 없다 — fail-closed).
//   - hashed_token, service_role 키, authorizationCode는 어떤 로그 경로에서도
//     출력하지 않는다(console.error에는 에러 코드/사유 문자열만 남긴다).
//   - env(SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY) 누락 시 500 server_misconfigured로
//     fail-closed 처리한다.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";
import {
  parseLoginRequest,
  resolveTossApiBase,
  supportsMtls,
  syntheticEmailFor,
  TOSS_LOGIN_ERROR_CODES,
  type TossReferrer,
} from "./logic.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}

/**
 * tossUserKey를 public.toss_identities에서 조회/연결하고, 그 결과로
 * Supabase Auth magiclink 토큰(hashed_token)을 발급한다.
 *
 * 이 함수는 mTLS 실호출부(Toss 토큰교환·사용자정보조회)가 완료되어
 * 유효한 tossUserKey를 확보한 "이후" 경로다. index.ts의 serve 핸들러와
 * 분리해 두어, mTLS 부분이 나중에 완성되더라도 이 연결 로직이 죽은 채
 * 방치되지 않게 한다(anti-patterns.md "만들어놨는데 연결이 안 됨" 방지).
 *
 * 반환:
 *   ok:true  -> { tokenHash, email, isNewUser }
 *   ok:false -> { error } (identity_link_failed | session_issue_failed)
 */
export async function linkAndIssueSession(
  adminClient: SupabaseClient,
  tossUserKey: string,
  referrer: TossReferrer,
): Promise<
  | { ok: true; tokenHash: string; email: string; isNewUser: boolean }
  | { ok: false; error: string }
> {
  const normalizedKey = tossUserKey.trim();
  if (!normalizedKey) {
    return { ok: false, error: TOSS_LOGIN_ERROR_CODES.IDENTITY_LINK_FAILED };
  }

  // 1) 기존 매핑 조회.
  let email: string;
  let isNewUser = false;

  try {
    const { data: existing, error: selectError } = await adminClient
      .from("toss_identities")
      .select("user_id")
      .eq("toss_user_key", normalizedKey)
      .maybeSingle();

    if (selectError) {
      console.error(
        "toss_identities select error:",
        selectError.code,
        selectError.message,
      );
      return {
        ok: false,
        error: TOSS_LOGIN_ERROR_CODES.IDENTITY_LINK_FAILED,
      };
    }

    if (existing?.user_id) {
      // 기존 사용자 — auth.users에서 email을 가져와야 generateLink에 쓸 수 있다.
      const { data: userData, error: getUserError } = await adminClient.auth
        .admin.getUserById(existing.user_id as string);
      if (getUserError || !userData?.user?.email) {
        console.error(
          "auth.admin.getUserById failed for existing toss identity:",
          getUserError?.message ?? "no_email",
        );
        return {
          ok: false,
          error: TOSS_LOGIN_ERROR_CODES.IDENTITY_LINK_FAILED,
        };
      }
      email = userData.user.email;

      const { error: touchError } = await adminClient
        .from("toss_identities")
        .update({ last_login_at: new Date().toISOString(), referrer })
        .eq("user_id", existing.user_id);
      if (touchError) {
        // last_login_at 갱신 실패는 로그인 자체를 막을 이유가 아니다 — 감사만.
        console.error(
          "toss_identities last_login_at update failed (non-fatal):",
          touchError.code,
          touchError.message,
        );
      }
    } else {
      // 2) 신규 사용자 — synthetic 이메일로 auth.users 생성 후 매핑 insert.
      isNewUser = true;
      email = syntheticEmailFor(normalizedKey);

      const { data: created, error: createError } = await adminClient.auth
        .admin.createUser({
          email,
          email_confirm: true,
        });
      if (createError || !created?.user?.id) {
        console.error(
          "auth.admin.createUser failed for toss identity:",
          createError?.message ?? "no_user_id",
        );
        return {
          ok: false,
          error: TOSS_LOGIN_ERROR_CODES.IDENTITY_LINK_FAILED,
        };
      }

      const { error: insertError } = await adminClient
        .from("toss_identities")
        .insert({
          user_id: created.user.id,
          toss_user_key: normalizedKey,
          referrer,
          last_login_at: new Date().toISOString(),
        });
      if (insertError) {
        console.error(
          "toss_identities insert failed:",
          insertError.code,
          insertError.message,
        );
        return {
          ok: false,
          error: TOSS_LOGIN_ERROR_CODES.IDENTITY_LINK_FAILED,
        };
      }
    }
  } catch (err) {
    console.error(
      "linkAndIssueSession identity-link exception:",
      err instanceof Error ? err.message : String(err),
    );
    return { ok: false, error: TOSS_LOGIN_ERROR_CODES.IDENTITY_LINK_FAILED };
  }

  // 3) magiclink 토큰 발급.
  try {
    const { data: linkData, error: linkError } = await adminClient.auth.admin
      .generateLink({ type: "magiclink", email });
    const tokenHash = linkData?.properties?.hashed_token;
    if (linkError || !tokenHash) {
      console.error(
        "auth.admin.generateLink failed:",
        linkError?.message ?? "no_hashed_token",
      );
      return {
        ok: false,
        error: TOSS_LOGIN_ERROR_CODES.SESSION_ISSUE_FAILED,
      };
    }
    return { ok: true, tokenHash, email, isNewUser };
  } catch (err) {
    console.error(
      "linkAndIssueSession generateLink exception:",
      err instanceof Error ? err.message : String(err),
    );
    return { ok: false, error: TOSS_LOGIN_ERROR_CODES.SESSION_ISSUE_FAILED };
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch (_err) {
    return json(
      { error: TOSS_LOGIN_ERROR_CODES.INVALID_REQUEST },
      400,
    );
  }

  const parsed = parseLoginRequest(rawBody);
  if (!parsed.ok) {
    return json({ error: parsed.error }, 400);
  }
  const { authorizationCode, referrer } = parsed;

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json(
      { error: TOSS_LOGIN_ERROR_CODES.SERVER_MISCONFIGURED },
      500,
    );
  }

  const apiBaseResult = resolveTossApiBase(referrer, {
    TOSS_API_BASE_URL_DEFAULT: Deno.env.get("TOSS_API_BASE_URL_DEFAULT"),
    TOSS_API_BASE_URL_SANDBOX: Deno.env.get("TOSS_API_BASE_URL_SANDBOX"),
  });

  // mTLS 클라이언트 인증서 지원 여부(Deno.createHttpClient 존재) +
  // API base 설정 여부를 함께 확인한다. 둘 중 하나라도 없으면
  // 실제 Toss 서버 호출 없이 501로 fail-closed 응답한다.
  const mtlsAvailable = supportsMtls(Deno);
  const mtlsCertConfigured = Boolean(
    Deno.env.get("TOSS_MTLS_CLIENT_CERT") &&
      Deno.env.get("TOSS_MTLS_CLIENT_KEY"),
  );

  if (!apiBaseResult.ok || !mtlsAvailable || !mtlsCertConfigured) {
    return json(
      { error: TOSS_LOGIN_ERROR_CODES.MTLS_UNSUPPORTED },
      501,
    );
  }

  // ---------------------------------------------------------------------
  // TODO(콘솔값 필요): 아래 mTLS 실호출부는 아직 구현되지 않았다.
  // Toss 로그인 콘솔에서 다음 값/절차가 확정되기 전에는 실제 토큰 교환·
  // 사용자정보 조회를 수행할 수 없다:
  //
  //   (a) mTLS 클라이언트 인증서 발급 절차 미확인 — Toss 로그인 콘솔에서
  //       클라이언트 인증서(cert/key 쌍)를 어떻게 발급받는지, PFX인지
  //       PEM인지, 갱신 주기가 있는지가 문서화되어 있지 않다. 발급받으면
  //       TOSS_MTLS_CLIENT_CERT / TOSS_MTLS_CLIENT_KEY env로 주입한다.
  //
  //   (b) POST {base}/user/oauth2/generate-token
  //       요청 바디는 { authorizationCode, referrer } 두 필드만 사용한다
  //       (clientId 파라미터는 없음 — mTLS 클라이언트 인증서 자체가
  //       클라이언트 신원 증명을 대신하는 구조로 추정된다. 콘솔 문서로
  //       재확인 필요). 응답에서 tossUserKey(또는 동등 필드)를 추출해야
  //       linkAndIssueSession()에 전달한다.
  //
  //   (c) GET {base}/user/oauth2/login-me
  //       (b)에서 받은 액세스 토큰으로 사용자 프로필을 조회하는 엔드포인트로
  //       추정되나, 실제로 이 호출이 필수인지(또는 (b) 응답에 이미 필요한
  //       정보가 포함되는지) 콘솔 문서로 확인이 필요하다.
  //
  //   (d) Deno Edge Runtime에서 Deno.createHttpClient({cert, key, ...})로
  //       mTLS 아웃바운드 호출이 실제로 동작하는지 PoC가 필요하다.
  //       Supabase Edge Functions는 Deno Deploy 기반 격리 런타임이라
  //       일반 Deno CLI와 네트워크 스택 지원 범위가 다를 수 있다
  //       (예: createHttpClient 자체는 있어도 클라이언트 인증서 옵션이
  //       Edge Runtime에서 무시되거나 차단될 가능성 — 로컬 CLI에서
  //       supportsMtls()가 true여도 배포 환경에서 실제 mTLS 핸드셰이크가
  //       성공하는지는 별도로 검증해야 한다).
  //
  // 이 4가지가 확인되기 전까지 이 함수는 501 mtls_unsupported를 반환하며,
  // mtlsAvailable/mtlsCertConfigured 가드가 항상 이 TODO 블록 진입을 막는다
  // (env 미설정 상태에서는 절대 아래로 내려오지 않는다 — fail-closed).
  // ---------------------------------------------------------------------

  return json(
    { error: TOSS_LOGIN_ERROR_CODES.MTLS_UNSUPPORTED },
    501,
  );
});
