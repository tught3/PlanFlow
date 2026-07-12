// PlanFlow 클라이언트 요청 인증 게이트.
//
// 배경: openai-proxy/naver-geocode가 게이트웨이 verify_jwt만 믿고 있었는데,
// Supabase anon key 자체가 유효하게 서명된 JWT라 게이트웨이 검증을 그대로 통과한다.
// 즉 로그인 여부와 무관하게 anon key만 있으면 비용이 드는 프록시를 호출할 수 있었다.
// 이 파일이 함수 내부에서 실제 로그인 사용자인지 auth.getUser()로 재검증한다.
//
// fail-closed 원칙: 헤더가 없거나 토큰이 무효하거나 에러가 나면 항상 실패로 처리한다.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export type AuthResult =
  | { ok: true; userId: string }
  | { ok: false; status: number; error: string };

/**
 * Authorization: Bearer <access_token> 헤더를 Supabase Auth 서버로 검증한다.
 * service-role 클라이언트로 auth.getUser(token)을 호출해, 실제 로그인 세션의
 * access token인지 판정한다(anon key 등 비사용자 토큰은 invalid_token으로 거부됨).
 */
export async function verifyUser(req: Request): Promise<AuthResult> {
  const authHeader = req.headers.get("authorization") || "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return { ok: false, status: 401, error: "missing_authorization" };
  }

  const token = authHeader.slice("bearer ".length).trim();
  if (!token) {
    return { ok: false, status: 401, error: "missing_authorization" };
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return { ok: false, status: 500, error: "auth_not_configured" };
  }

  try {
    const client = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await client.auth.getUser(token);
    if (error || !data?.user?.id) {
      return { ok: false, status: 401, error: "invalid_token" };
    }
    return { ok: true, userId: data.user.id };
  } catch (_err) {
    // 네트워크/런타임 에러도 fail-closed — 절대 ok:true로 넘어가지 않는다.
    return { ok: false, status: 401, error: "invalid_token" };
  }
}
