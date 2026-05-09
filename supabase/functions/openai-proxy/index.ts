import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ProxyErrorBody = {
  error: string;
  detail?: string;
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const openAiApiKey = Deno.env.get("OPENAI_API_KEY")?.trim() ?? "";
  if (!openAiApiKey) {
    return json(
      {
        error: "missing_openai_api_key",
        detail: "OPENAI_API_KEY is not configured in Supabase Edge Function secrets.",
      },
      500,
    );
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch (_) {
    return json({ error: "invalid_json_body" }, 400);
  }

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${openAiApiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const rawBody = await response.text();
  return new Response(rawBody, {
    status: response.status,
    headers: {
      ...corsHeaders,
      "content-type": response.headers.get("content-type") ?? "application/json",
    },
  });
});

function json(body: ProxyErrorBody, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json",
    },
  });
}
