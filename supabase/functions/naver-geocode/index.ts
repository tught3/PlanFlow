import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { verifyUser } from "../_shared/auth.ts";
import { parseProxyContract } from "./proxy_contract.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "GET") return json({ error: "Method not allowed." }, 405);

  const auth = await verifyUser(req);
  if (!auth.ok) {
    return json({ error: auth.error }, auth.status);
  }

  const url = new URL(req.url);
  const contract = parseProxyContract(url.searchParams);
  if (contract.kind === "unsupported_mode") {
    return json(
      {
        error: "Transit directions are not supported by this proxy.",
        code: "unsupported_transit",
      },
      501,
    );
  }
  if (contract.kind === "invalid") return json({ error: contract.error }, 400);

  if (contract.kind === "geocode") {
    if (!contract.query) return json({ addresses: [] }, 200);
    const clientId = Deno.env.get("NAVER_MAP_CLIENT_ID") ?? "";
    const clientSecret = Deno.env.get("NAVER_MAP_CLIENT_SECRET") ?? "";
    if (!clientId || !clientSecret) return json({ error: "Naver map credentials are not configured." }, 500);
    const naverUrl = new URL("https://naveropenapi.apigw.ntruss.com/map-geocode/v2/geocode");
    naverUrl.searchParams.set("query", contract.query);
    let response: Response;
    try {
      response = await fetch(naverUrl, { headers: { "X-NCP-APIGW-API-KEY-ID": clientId, "X-NCP-APIGW-API-KEY": clientSecret, accept: "application/json" } });
    } catch (_err) {
      return json({ error: "Upstream geocode request failed." }, 502);
    }
    return new Response(await response.text(), { status: response.status, headers: { ...corsHeaders, "content-type": response.headers.get("content-type") ?? "application/json" } });
  }

  const clientId = Deno.env.get("NAVER_MAP_CLIENT_ID") ?? "";
  const clientSecret = Deno.env.get("NAVER_MAP_CLIENT_SECRET") ?? "";
  if (!clientId || !clientSecret) return json({ error: "Naver map credentials are not configured." }, 500);
  const naverUrl = new URL("https://naveropenapi.apigw.ntruss.com/map-direction/v1/driving");
  naverUrl.searchParams.set("start", contract.start);
  naverUrl.searchParams.set("goal", contract.goal);
  naverUrl.searchParams.set("option", contract.option);
  let response: Response;
  try {
    response = await fetch(naverUrl, { headers: { "X-NCP-APIGW-API-KEY-ID": clientId, "X-NCP-APIGW-API-KEY": clientSecret, accept: "application/json" } });
  } catch (_err) {
    return json({ error: "Upstream directions request failed." }, 502);
  }
  return new Response(await response.text(), { status: response.status, headers: { ...corsHeaders, "content-type": response.headers.get("content-type") ?? "application/json" } });
});

function json(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json",
    },
  });
}
