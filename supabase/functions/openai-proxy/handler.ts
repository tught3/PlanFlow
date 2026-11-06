export type AuthResult =
  | { ok: true; userId: string }
  | { ok: false; status: number; error: string };

export type ProxyDependencies = {
  verifyUser: (req: Request) => Promise<AuthResult>;
  env?: (name: string) => string | undefined;
  fetch?: typeof globalThis.fetch;
  now?: () => number;
  log?: (entry: Record<string, unknown>) => void;
  requestId?: () => string;
};
const DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1";
// banned-ok: Existing local Hermes placeholder, not a real credential.
const HERMES_LOCAL_API_KEY = "hermes-local";
const MINUTE_MS = 60_000;
const DAY_MS = 86_400_000;
const MODEL_IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;
const MESSAGE_ROLES = new Set(["system", "developer", "user", "assistant"]);

type Env = (name: string) => string | undefined;
type Payload = Record<string, unknown> & { model: string };
type Validation<T> = { ok: true; value: T } | {
  ok: false;
  error: string;
  status: number;
};

function positiveInteger(env: Env, name: string, fallback: number): number {
  const raw = env(name)?.trim();
  const value = raw && /^\d+$/.test(raw) ? Number(raw) : NaN;
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

function normalizeBaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function allowedOrigins(env: Env): Set<string> {
  const origins = new Set<string>();
  for (const value of (env("OPENAI_PROXY_ALLOWED_ORIGINS") ?? "").split(",")) {
    const origin = value.trim();
    try {
      const url = new URL(origin);
      if (
        (url.protocol === "https:" || url.protocol === "http:") &&
        url.origin === origin
      ) {
        origins.add(origin);
      }
    } catch { /* Invalid configuration never permits an Origin. */ }
  }
  return origins;
}

async function readPayload(
  req: Request,
  maxBytes: number,
): Promise<Validation<unknown>> {
  const declared = req.headers.get("content-length");
  if (declared !== null) {
    if (!/^\d+$/.test(declared.trim())) {
      return { ok: false, error: "invalid_content_length", status: 400 };
    }
    if (Number(declared) > maxBytes) {
      return { ok: false, error: "body_too_large", status: 413 };
    }
  }
  if (!req.body) return { ok: false, error: "invalid_json_body", status: 400 };

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      bytes += next.value.byteLength;
      if (bytes > maxBytes) {
        await reader.cancel().catch(() => {});
        return { ok: false, error: "body_too_large", status: 413 };
      }
      chunks.push(next.value);
    }
    const body = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) {
      body.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return {
      ok: true,
      value: JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body)),
    };
  } catch {
    return { ok: false, error: "invalid_json_body", status: 400 };
  } finally {
    reader.releaseLock();
  }
}

function normalizePayload(
  value: unknown,
  maxMessages: number,
  maxTokens: number,
): Validation<Payload> {
  const invalid = (error: string): Validation<Payload> => ({
    ok: false,
    error,
    status: 400,
  });
  if (!isObject(value)) return invalid("invalid_request_body");
  if (typeof value.model !== "string" || !MODEL_IDENTIFIER.test(value.model)) {
    return invalid("invalid_model");
  }
  if (
    !Array.isArray(value.messages) || value.messages.length === 0 ||
    value.messages.length > maxMessages
  ) {
    return invalid("invalid_messages");
  }
  const messages: { role: string; content: string }[] = [];
  for (const message of value.messages) {
    if (
      !isObject(message) || typeof message.role !== "string" ||
      !MESSAGE_ROLES.has(message.role) || typeof message.content !== "string"
    ) {
      return invalid("invalid_messages");
    }
    // Rebuild text messages so nested tools/audio and other unapproved fields cannot pass through.
    messages.push({ role: message.role, content: message.content });
  }
  const payload: Payload = {
    model: value.model,
    messages,
    n: 1,
    stream: false,
  };
  for (const field of ["max_tokens", "max_completion_tokens"] as const) {
    if (value[field] !== undefined) {
      const tokens = value[field];
      if (
        typeof tokens !== "number" || !Number.isSafeInteger(tokens) ||
        tokens <= 0
      ) return invalid("invalid_token_limit");
      payload[field] = Math.min(tokens, maxTokens);
    }
  }
  if (
    payload.max_tokens === undefined &&
    payload.max_completion_tokens === undefined
  ) payload.max_tokens = maxTokens;
  for (const [field, upper] of [["temperature", 2], ["top_p", 1]] as const) {
    if (value[field] !== undefined) {
      const number = value[field];
      if (
        typeof number !== "number" || !Number.isFinite(number) || number < 0 ||
        number > upper
      ) return invalid("invalid_sampling_parameter");
      payload[field] = number;
    }
  }
  const responseFormat = value.response_format;
  if (responseFormat !== undefined) {
    if (
      !isObject(responseFormat) ||
      typeof responseFormat.type !== "string" ||
      !["text", "json_object", "json_schema"].includes(responseFormat.type)
    ) {
      return invalid("invalid_response_format");
    }
    payload.response_format = responseFormat;
  }
  return { ok: true, value: payload };
}

class SlidingWindowLimiter {
  private readonly users = new Map<string, number[]>();
  private lastSweep = -Infinity;

  constructor(
    private perMinute: number,
    private perDay: number,
    private maxUsers: number,
  ) {}

  // No await may be introduced between the quota check and insertion.
  consume(userId: string, now: number): number | undefined {
    const cutoff = now - DAY_MS;
    if (now - this.lastSweep >= MINUTE_MS || this.users.size >= this.maxUsers) {
      for (const [key, times] of this.users) {
        if (times[times.length - 1] <= cutoff) this.users.delete(key);
      }
      this.lastSweep = now;
    }
    const times = (this.users.get(userId) ?? []).filter((time) =>
      time > cutoff
    );
    if (times.length >= this.perDay) {
      return Math.max(1, Math.ceil((times[0] + DAY_MS - now) / 1000));
    }
    const minuteTimes = times.filter((time) => time > now - MINUTE_MS);
    if (minuteTimes.length >= this.perMinute) {
      return Math.max(1, Math.ceil((minuteTimes[0] + MINUTE_MS - now) / 1000));
    }
    if (!this.users.has(userId) && this.users.size >= this.maxUsers) {
      let earliest = now + DAY_MS;
      for (const entries of this.users.values()) {
        earliest = Math.min(earliest, entries[entries.length - 1] + DAY_MS);
      }
      return Math.max(1, Math.ceil((earliest - now) / 1000));
    }
    times.push(now);
    this.users.set(userId, times);
    return undefined;
  }
}

async function hashUser(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(userId),
  );
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

function responseTokens(rawBody: string): number | undefined {
  try {
    const body = JSON.parse(rawBody);
    const tokens = body?.usage?.total_tokens ?? body?.usage?.completion_tokens;
    return typeof tokens === "number" && Number.isSafeInteger(tokens) &&
        tokens >= 0
      ? tokens
      : undefined;
  } catch {
    return undefined;
  }
}

export function createHandler(dependencies: ProxyDependencies) {
  const env = dependencies.env ?? ((name: string) => Deno.env.get(name));
  const fetchUpstream = dependencies.fetch ?? globalThis.fetch;
  const now = dependencies.now ?? Date.now;
  const logger = dependencies.log ??
    ((entry) => console.info(JSON.stringify(entry)));
  const requestId = dependencies.requestId ?? (() => crypto.randomUUID());
  const maxBytes = positiveInteger(env, "OPENAI_PROXY_MAX_BODY_BYTES", 65_536);
  // banned-ok: Numeric token ceiling configuration, not a credential.
  const maxTokens = positiveInteger(env, "OPENAI_PROXY_MAX_TOKENS", 1500);
  const maxMessages = positiveInteger(env, "OPENAI_PROXY_MAX_MESSAGES", 20);
  const origins = allowedOrigins(env);
  const models = new Set(
    (env("OPENAI_PROXY_ALLOWED_MODELS") ?? "gpt-4o-mini").split(",").map((
      value,
    ) => value.trim()).filter((value) => MODEL_IDENTIFIER.test(value)),
  );
  const enforceModels =
    env("OPENAI_PROXY_MODEL_ENFORCE")?.trim().toLowerCase() === "true";
  const limiter = new SlidingWindowLimiter(
    positiveInteger(env, "OPENAI_PROXY_RATE_LIMIT_PER_MINUTE", 20),
    positiveInteger(env, "OPENAI_PROXY_RATE_LIMIT_PER_DAY", 300),
    positiveInteger(env, "OPENAI_PROXY_RATE_LIMIT_MAX_USERS", 10_000),
  );

  return async (req: Request): Promise<Response> => {
    const id = requestId();
    const origin = req.headers.get("origin");
    const headers = new Headers({ "vary": "Origin", "x-request-id": id });
    if (origin !== null && origins.has(origin)) {
      headers.set("access-control-allow-origin", origin);
      headers.set(
        "access-control-allow-headers",
        "authorization, x-client-info, apikey, content-type",
      );
      headers.set("access-control-allow-methods", "POST, OPTIONS");
    }
    let callerHash: string | undefined = undefined;
    let payload: Payload | undefined = undefined;
    let modelLogOnly = false;
    const record = (
      status: number,
      event = modelLogOnly ? "model_not_allowed_log_only" : "request",
      tokens?: number,
    ) => {
      const entry: Record<string, unknown> = { event, status, request_id: id };
      if (callerHash !== undefined) entry.caller_hash = callerHash;
      if (payload !== undefined) {
        entry.model = payload.model;
        if (payload.max_tokens !== undefined) {
          // banned-ok: Numeric output-token aggregate only; no credential or content.
          entry.max_tokens = payload.max_tokens;
        }
        if (payload.max_completion_tokens !== undefined) {
          // banned-ok: Numeric output-token aggregate only; no credential or content.
          entry.max_completion_tokens = payload.max_completion_tokens;
        }
      }
      if (tokens !== undefined) entry.tokens = tokens;
      try {
        logger(entry);
      } catch { /* Logging cannot expose data through another error path. */ }
    };
    const error = (
      code: string,
      status: number,
      retryAfter?: number,
    ): Response => {
      record(status);
      const errorHeaders = new Headers(headers);
      errorHeaders.set("content-type", "application/json");
      errorHeaders.set("cache-control", "no-store");
      if (retryAfter !== undefined) {
        errorHeaders.set("retry-after", String(retryAfter));
      }
      return new Response(JSON.stringify({ error: code, request_id: id }), {
        status,
        headers: errorHeaders,
      });
    };

    if (origin !== null && !origins.has(origin)) {
      return error("origin_not_allowed", 403);
    }
    if (req.method === "OPTIONS") return new Response("ok", { headers });
    if (req.method !== "POST") return error("method_not_allowed", 405);

    let auth: AuthResult;
    try {
      auth = await dependencies.verifyUser(req);
    } catch {
      return error("invalid_token", 401);
    }
    if (!auth.ok) return error(auth.error, auth.status);
    callerHash = await hashUser(auth.userId);
    const retryAfter = limiter.consume(auth.userId, now());
    if (retryAfter !== undefined) return error("rate_limited", 429, retryAfter);

    const raw = await readPayload(req, maxBytes);
    if (!raw.ok) return error(raw.error, raw.status);
    const normalized = normalizePayload(raw.value, maxMessages, maxTokens);
    if (!normalized.ok) return error(normalized.error, normalized.status);
    payload = normalized.value;
    if (!models.has(payload.model)) {
      if (enforceModels) return error("model_not_allowed", 400);
      modelLogOnly = true;
    }

    const baseUrlValue = env("OPENAI_BASE_URL")?.trim();
    const baseUrl = baseUrlValue
      ? normalizeBaseUrl(baseUrlValue)
      : DEFAULT_OPENAI_BASE_URL;
    const apiKey = env("OPENAI_API_KEY")?.trim() ||
      (baseUrlValue ? HERMES_LOCAL_API_KEY : undefined);
    if (!apiKey) return error("service_unavailable", 500);

    try {
      const response = await fetchUpstream(`${baseUrl}/chat/completions`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      });
      if (!response.ok) {
        await response.body?.cancel().catch(() => {});
        return error("upstream_error", response.status);
      }
      const rawBody = await response.text();
      headers.set(
        "content-type",
        response.headers.get("content-type") ?? "application/json",
      );
      record(response.status, undefined, responseTokens(rawBody));
      return new Response(rawBody, { status: response.status, headers });
    } catch {
      return error("upstream_unavailable", 502);
    }
  };
}
