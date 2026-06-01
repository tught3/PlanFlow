import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1";
const HERMES_LOCAL_API_KEY = "hermes-local";

type ProxyErrorBody = {
  error: string;
  detail?: string;
};

function normalizeBaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function getOpenAIBaseUrl(): string | undefined {
  const value = Deno.env.get("OPENAI_BASE_URL")?.trim();
  return value ? normalizeBaseUrl(value) : undefined;
}

function getOpenAIApiKey(): string | undefined {
  const apiKey = Deno.env.get("OPENAI_API_KEY")?.trim();
  if (apiKey) {
    return apiKey;
  }
  return getOpenAIBaseUrl() ? HERMES_LOCAL_API_KEY : undefined;
}

function buildOpenAIUrl(pathname: string): string {
  const baseUrl = getOpenAIBaseUrl() ?? DEFAULT_OPENAI_BASE_URL;
  const normalizedPath = pathname.startsWith("/") ? pathname : `/${pathname}`;
  return `${normalizeBaseUrl(baseUrl)}${normalizedPath}`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const openAiApiKey = getOpenAIApiKey() ?? "";
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

  const response = await fetch(buildOpenAIUrl("/chat/completions"), {
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
