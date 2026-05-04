import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const query = url.searchParams.get("query")?.trim() ?? "";
  if (!query) {
    return json({ addresses: [] }, 200);
  }

  const clientId = Deno.env.get("NAVER_MAP_CLIENT_ID") ?? "";
  const clientSecret = Deno.env.get("NAVER_MAP_CLIENT_SECRET") ?? "";
  if (!clientId || !clientSecret) {
    return json({ error: "NAVER_MAP_CLIENT_ID/SECRET is not configured." }, 500);
  }

  const naverUrl = new URL("https://naveropenapi.apigw.ntruss.com/map-geocode/v2/geocode");
  naverUrl.searchParams.set("query", query);

  const response = await fetch(naverUrl, {
    headers: {
      "X-NCP-APIGW-API-KEY-ID": clientId,
      "X-NCP-APIGW-API-KEY": clientSecret,
      accept: "application/json",
    },
  });

  return new Response(await response.text(), {
    status: response.status,
    headers: {
      ...corsHeaders,
      "content-type": response.headers.get("content-type") ?? "application/json",
    },
  });
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
