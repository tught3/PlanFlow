// PlanFlow 회원 탈퇴(계정 삭제) Edge Function.
//
// 책임:
//   1) verifyUser()로 요청 JWT가 실제 로그인 사용자인지 검증 (anon key 차단).
//   2) service_role 클라이언트로 delete_user_account(userId) RPC 호출.
//      - 그룹 리더인 active 그룹이 있으면 409 + 그룹 목록 반환 (사용자가 먼저 정리).
//      - 성공 시 사용자 개인 데이터가 단일 트랜잭션으로 일괄 삭제됨.
//   3) 데이터 삭제 성공 후 auth.admin.deleteUser(userId) 호출.
//      (auth.users는 이 단계에서만 삭제되며, 실패하면 데이터만 지워지고
//       사용자는 여전히 로그인 가능 상태로 남게 됨 — 이때는 사용자에게
//       "다시 시도"를 안내하고, 데이터는 이미 정리됐음을 알림.)
//
// 보안:
//   - service_role 키는 Deno.env로만 접근 (클라이언트 노출 X).
//   - verifyUser 게이트: Authorization 헤더의 access_token을 Supabase Auth 서버로 검증.
//   - fail-closed: 인증 실패, env 누락, RPC 실패, auth.admin 실패 모두 에러 응답.
//   - 어떤 경우에도 데이터 없이 success 응답하지 않음.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyUser } from "../_shared/auth.ts";

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

type DeleteAccountRpcRow = {
  success: boolean;
  blocked_reason: string | null;
  leader_groups: unknown;
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // 1) 사용자 검증 (anon key 등 비사용자 토큰 차단).
  const auth = await verifyUser(req);
  if (!auth.ok) {
    return json({ error: auth.error }, auth.status);
  }
  const userId = auth.userId;

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "server_misconfigured" }, 500);
  }

  // service_role 클라이언트: RLS 무시 + admin API 접근 가능.
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 2) 데이터 삭제 RPC 호출.
  let rpcRows: DeleteAccountRpcRow[];
  try {
    const rpcResponse = await adminClient
      .rpc("delete_user_account", { target_user_id: userId })
      .select();

    if (rpcResponse.error) {
      // PostgrestError — RLS/함수 예외/등. 사용자에게 message만 노출.
      console.error(
        "delete_user_account RPC error:",
        rpcResponse.error.code,
        rpcResponse.error.message,
      );
      return json(
        {
          success: false,
          error: "data_delete_failed",
          message: rpcResponse.error.message,
        },
        500,
      );
    }

    rpcRows = (rpcResponse.data ?? []) as DeleteAccountRpcRow[];
  } catch (err) {
    console.error("delete_user_account RPC exception:", err);
    return json(
      { success: false, error: "data_delete_exception" },
      500,
    );
  }

  const rpcResult = rpcRows[0];
  if (!rpcResult) {
    // RPC가 빈 응답을 반환 — 정상 상황이 아님 (fail-closed).
    console.error("delete_user_account RPC empty result");
    return json({ success: false, error: "rpc_empty_result" }, 500);
  }

  if (!rpcResult.success) {
    // 차단 사유가 있으면 사용자에게 친절하게 안내.
    if (rpcResult.blocked_reason === "leader_groups") {
      return json(
        {
          success: false,
          blockedReason: "leader_groups",
          leaderGroups: rpcResult.leader_groups ?? [],
        },
        409,
      );
    }
    return json(
      {
        success: false,
        blockedReason: rpcResult.blocked_reason ?? "unknown",
      },
      409,
    );
  }

  // 3) auth.admin.deleteUser 호출. 데이터는 이미 삭제됨.
  try {
    const { error: deleteAuthError } = await adminClient.auth.admin.deleteUser(
      userId,
    );
    if (deleteAuthError) {
      // 데이터는 삭제됐지만 auth.users 삭제 실패.
      // 사용자는 여전히 로그인 가능하지만 모든 개인 데이터가 날아간 상태.
      // 재시도 시도 없이 사용자에게 안내하고, 서버 로그로 감사.
      console.error(
        "auth.admin.deleteUser failed (data already deleted):",
        deleteAuthError.message,
      );
      return json(
        {
          success: false,
          error: "auth_user_delete_failed",
          message:
            "개인 데이터는 삭제됐지만 인증 계정 정리에 실패했습니다. 잠시 후 다시 시도해 주세요.",
          dataDeleted: true,
        },
        500,
      );
    }
  } catch (err) {
    console.error("auth.admin.deleteUser exception:", err);
    return json(
      {
        success: false,
        error: "auth_user_delete_exception",
        dataDeleted: true,
      },
      500,
    );
  }

  return json({ success: true });
});
