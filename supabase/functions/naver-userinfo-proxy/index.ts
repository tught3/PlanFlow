import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type NaverProfileResponse = {
  resultcode?: string;
  message?: string;
  response?: {
    id?: string;
    email?: string;
    name?: string;
    nickname?: string;
    profile_image?: string;
  };
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "GET") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const authorization = req.headers.get("authorization");
  if (!authorization?.toLowerCase().startsWith("bearer ")) {
    return json({ error: "missing_authorization" }, 401);
  }

  const naverResponse = await fetch("https://openapi.naver.com/v1/nid/me", {
    headers: {
      authorization,
      accept: "application/json",
    },
  });

  const rawBody = await naverResponse.text();
  if (!naverResponse.ok) {
    return new Response(rawBody, {
      status: naverResponse.status,
      headers: {
        ...corsHeaders,
        "content-type": naverResponse.headers.get("content-type") ?? "application/json",
      },
    });
  }

  let profile: NaverProfileResponse;
  try {
    profile = JSON.parse(rawBody) as NaverProfileResponse;
  } catch (_) {
    return json({ error: "invalid_naver_profile_response" }, 502);
  }

  const naverUser = profile.response;
  const subject = naverUser?.id?.trim();
  const rawEmail = naverUser?.email?.trim().toLowerCase() ?? "";
  if (!subject) {
    return json({ error: "missing_provider_id" }, 502);
  }
  const email = rawEmail || `naver-${subject}@users.planflow.local`;

  return json(
    {
      sub: subject,
      id: subject,
      email,
      email_verified: rawEmail.length > 0,
      name: naverUser?.name ?? naverUser?.nickname ?? "",
      nickname: naverUser?.nickname ?? "",
      picture: naverUser?.profile_image ?? "",
      provider: "naver",
    },
    200,
  );
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json",
    },
  });
}
