import { createHandler, type ProxyDependencies } from "./handler.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function equal(actual: unknown, expected: unknown, message = "values differ") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    );
  }
}

const basePayload = () => ({
  model: "gpt-4o-mini",
  messages: [
    { role: "system", content: "Return a schedule as JSON." },
    { role: "user", content: "tomorrow at ten" },
  ],
});

type HarnessOptions = {
  env?: Record<string, string | undefined>;
  verifyUser?: ProxyDependencies["verifyUser"];
  response?: Response;
  fetchError?: Error;
  fetch?: ProxyDependencies["fetch"];
};

function harness(options: HarnessOptions = {}) {
  const calls: {
    url: string;
    init: RequestInit;
    payload: Record<string, unknown>;
  }[] = [];
  const logs: Record<string, unknown>[] = [];
  const env: Record<string, string | undefined> = {
    OPENAI_API_KEY: "test-upstream-key",
    ...options.env,
  };
  let time = 1_800_000_000_000;
  let authCalls = 0;
  const handler = createHandler({
    verifyUser: async (req) => {
      authCalls++;
      if (options.verifyUser) return await options.verifyUser(req);
      return {
        ok: true,
        userId: req.headers.get("x-test-user") ?? "private-user-id",
      };
    },
    env: (name) => env[name],
    fetch: async (input, init) => {
      await Promise.resolve();
      if (options.fetchError) throw options.fetchError;
      calls.push({
        url: String(input),
        init: init ?? {},
        payload: JSON.parse(String(init?.body)),
      });
      if (options.fetch) return await options.fetch(input, init);
      return options.response?.clone() ?? new Response(
        JSON.stringify({
          choices: [{ message: { content: "ok" } }],
          usage: { completion_tokens: 7 },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    },
    now: () => time,
    log: (entry) => logs.push(entry),
    requestId: () => "test-request-id",
  });
  return {
    handler,
    calls,
    logs,
    authCalls: () => authCalls,
    setTime: (value: number) => time = value,
    advance: (milliseconds: number) => time += milliseconds,
    request: (
      payload: unknown = basePayload(),
      headers: Record<string, string> = {},
    ) =>
      handler(
        new Request("https://proxy.test", {
          method: "POST",
          headers: {
            authorization: "Bearer fake-user-token",
            "content-type": "application/json",
            ...headers,
          },
          body: JSON.stringify(payload),
        }),
      ),
  };
}

async function json(response: Response): Promise<Record<string, unknown>> {
  return await response.json();
}

async function rejectedWithoutFetch(
  h: ReturnType<typeof harness>,
  payload: unknown,
  status = 400,
) {
  equal((await h.request(payload)).status, status);
  equal(h.calls.length, 0, "rejected requests must not reach upstream");
}

Deno.test("authenticated PlanFlow payload and successful response remain compatible", async () => {
  const h = harness();
  const response = await h.request({
    ...basePayload(),
    temperature: 0.2,
    response_format: { type: "json_object" },
  });
  equal(response.status, 200);
  equal(h.authCalls(), 1);
  equal(h.calls[0].payload.model, "gpt-4o-mini");
  equal(h.calls[0].payload.messages, basePayload().messages);
  equal(h.calls[0].payload.response_format, { type: "json_object" });
  equal((await json(response)).choices, [{ message: { content: "ok" } }]);
});

Deno.test("authenticated NexusFlow-shaped payload remains compatible", async () => {
  const h = harness();
  equal(
    (await h.request({
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "classify confidence" }],
      temperature: 0.1,
    })).status,
    200,
  );
  equal(h.calls.length, 1);
});

Deno.test("verifyUser rejection is preserved and anon cannot reach upstream", async () => {
  const h = harness({
    verifyUser: () =>
      Promise.resolve({
        ok: false,
        status: 401,
        error: "invalid_token",
      }),
  });
  const response = await h.request();
  equal(response.status, 401);
  equal((await json(response)).error, "invalid_token");
  equal(h.calls.length, 0);
});

Deno.test("unexpected auth exceptions fail closed without exposing details", async () => {
  const h = harness({
    verifyUser: () => {
      throw new Error("private-auth-detail");
    },
  });
  const response = await h.request();
  equal(response.status, 401);
  assert(!JSON.stringify(await json(response)).includes("private-auth-detail"));
  assert(!JSON.stringify(h.logs).includes("private-auth-detail"));
  equal(h.calls.length, 0);
});

Deno.test("declared body bytes over the default 64 KiB cap return 413", async () => {
  const h = harness();
  equal(
    (await h.request(basePayload(), { "content-length": "65537" })).status,
    413,
  );
  equal(h.calls.length, 0);
});

Deno.test("actual UTF-8 body bytes are capped even when content-length underreports", async () => {
  const h = harness({ env: { OPENAI_PROXY_MAX_BODY_BYTES: "256" } });
  const payload = {
    model: "gpt-4o-mini",
    messages: [{ role: "user", content: "한".repeat(100) }],
  };
  equal((await h.request(payload, { "content-length": "1" })).status, 413);
  equal(h.calls.length, 0);
});

Deno.test("the default actual-byte cap accepts 64 KiB and rejects one extra byte", async () => {
  const empty = {
    model: "gpt-4o-mini",
    messages: [{ role: "user", content: "" }],
  };
  const overhead = new TextEncoder().encode(JSON.stringify(empty)).byteLength;
  const h = harness();
  equal(
    (await h.request({
      ...empty,
      messages: [{ role: "user", content: "a".repeat(65_536 - overhead) }],
    })).status,
    200,
  );
  equal(
    (await h.request({
      ...empty,
      messages: [{ role: "user", content: "a".repeat(65_537 - overhead) }],
    })).status,
    413,
  );
  equal(h.calls.length, 1);
});

Deno.test("oversized streamed body is cancelled before the remaining tail is read", async () => {
  const h = harness({ env: { OPENAI_PROXY_MAX_BODY_BYTES: "128" } });
  let pulls = 0;
  let cancelled = false;
  const chunks = [
    new TextEncoder().encode(
      '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"' +
        "a".repeat(200),
    ),
    new TextEncoder().encode('"}]}'),
  ];
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (pulls < chunks.length) controller.enqueue(chunks[pulls++]);
      else controller.close();
    },
    cancel() {
      cancelled = true;
    },
  }, { highWaterMark: 0 });
  const response = await h.handler(
    new Request("https://proxy.test", { method: "POST", body: stream }),
  );
  equal(response.status, 413);
  assert(cancelled, "reader must cancel at the byte cap");
  equal(pulls, 1, "the tail must not be pulled after the cap");
  equal(h.calls.length, 0);
});

Deno.test("invalid JSON returns 400 without upstream", async () => {
  const h = harness();
  const response = await h.handler(
    new Request("https://proxy.test", { method: "POST", body: "{" }),
  );
  equal(response.status, 400);
  equal(h.calls.length, 0);
});

for (const payload of [null, [], "text", 1]) {
  Deno.test(`non-object payload ${JSON.stringify(payload)} is rejected`, async () => {
    await rejectedWithoutFetch(harness(), payload);
  });
}

Deno.test("model enforcement defaults to log-only and never guesses another model", async () => {
  const h = harness();
  equal(
    (await h.request({ ...basePayload(), model: "future-model" })).status,
    200,
  );
  equal(h.calls[0].payload.model, "future-model");
  assert(
    h.logs.some((entry) => entry.model === "future-model"),
    "out-of-list model must be observed",
  );
  assert(
    h.logs.some((entry) =>
      typeof entry.caller_hash === "string" &&
      /^[a-f0-9]{64}$/.test(String(entry.caller_hash))
    ),
    "caller must be SHA-256 hashed",
  );
});

Deno.test("enforced model allowlist rejects out-of-list models", async () => {
  const h = harness({ env: { OPENAI_PROXY_MODEL_ENFORCE: "true" } });
  const response = await h.request({ ...basePayload(), model: "future-model" });
  equal(response.status, 400);
  equal((await json(response)).error, "model_not_allowed");
  equal(h.calls.length, 0);
});

Deno.test("configured model allowlist is honored in enforcement mode", async () => {
  const h = harness({
    env: {
      OPENAI_PROXY_MODEL_ENFORCE: "true",
      OPENAI_PROXY_ALLOWED_MODELS: "gpt-4o-mini, local/model-v2",
    },
  });
  equal(
    (await h.request({ ...basePayload(), model: "local/model-v2" })).status,
    200,
  );
});

for (
  const model of [undefined, "", "prompt\r\nsecret text", "x".repeat(129), {
    name: "gpt-4o-mini",
  }]
) {
  Deno.test(`unsafe model identifier ${JSON.stringify(model)} is rejected before logging`, async () => {
    const h = harness();
    await rejectedWithoutFetch(h, { ...basePayload(), model });
    assert(!JSON.stringify(h.logs).includes("secret text"));
  });
}

Deno.test("default output token cap is injected when neither token field is set", async () => {
  const h = harness();
  equal((await h.request()).status, 200);
  equal(h.calls[0].payload.max_tokens, 1500);
});

Deno.test("max_tokens and max_completion_tokens are independently clamped", async () => {
  const h = harness({ env: { OPENAI_PROXY_MAX_TOKENS: "100" } });
  equal(
    (await h.request({
      ...basePayload(),
      max_tokens: 9000,
      max_completion_tokens: 8000,
    })).status,
    200,
  );
  equal(h.calls[0].payload.max_tokens, 100);
  equal(h.calls[0].payload.max_completion_tokens, 100);
});

Deno.test("valid small token requests remain unchanged", async () => {
  const h = harness();
  await h.request({ ...basePayload(), max_tokens: 20 });
  equal(h.calls[0].payload.max_tokens, 20);
});

for (const field of ["max_tokens", "max_completion_tokens"]) {
  for (const value of [0, -1, 1.5, "100", null]) {
    Deno.test(`invalid ${field} count ${JSON.stringify(value)} is rejected`, async () => {
      await rejectedWithoutFetch(harness(), {
        ...basePayload(),
        [field]: value,
      });
    });
  }
}

Deno.test("a completion-only token request does not gain a conflicting token field", async () => {
  const h = harness();
  await h.request({ ...basePayload(), max_completion_tokens: 20 });
  equal(h.calls[0].payload.max_completion_tokens, 20);
  assert(!("max_tokens" in h.calls[0].payload));
});

Deno.test("invalid numeric configuration falls back to the safe default", async () => {
  const h = harness({ env: { OPENAI_PROXY_MAX_TOKENS: "-2" } });
  await h.request();
  equal(h.calls[0].payload.max_tokens, 1500);
});

Deno.test("only whitelisted payload fields are sent upstream", async () => {
  const h = harness();
  await h.request({
    ...basePayload(),
    temperature: 0.2,
    top_p: 0.9,
    tools: [{ type: "function" }],
    functions: [{}],
    logit_bias: { 1: 100 },
    audio: { voice: "alloy" },
    metadata: { secret: "value" },
  });
  const payload = h.calls[0].payload;
  for (
    const field of ["tools", "functions", "logit_bias", "audio", "metadata"]
  ) {
    assert(!(field in payload), `${field} must be stripped`);
  }
  equal(payload.temperature, 0.2);
  equal(payload.top_p, 0.9);
});

Deno.test("n and stream are always forced to one non-streamed response", async () => {
  const h = harness();
  await h.request({ ...basePayload(), n: 15, stream: true });
  equal(h.calls[0].payload.n, 1);
  equal(h.calls[0].payload.stream, false);
});

Deno.test("message count honors its configured cap", async () => {
  const h = harness({ env: { OPENAI_PROXY_MAX_MESSAGES: "2" } });
  await rejectedWithoutFetch(h, {
    ...basePayload(),
    messages: [{ role: "user", content: "one" }, {
      role: "assistant",
      content: "two",
    }, { role: "user", content: "three" }],
  });
});

Deno.test("the default message cap accepts twenty and rejects twenty-one", async () => {
  const h = harness();
  const messages = Array.from(
    { length: 20 },
    () => ({ role: "user", content: "text" }),
  );
  equal((await h.request({ ...basePayload(), messages })).status, 200);
  equal(
    (await h.request({
      ...basePayload(),
      messages: [...messages, messages[0]],
    })).status,
    400,
  );
  equal(h.calls.length, 1);
});

Deno.test("developer text messages remain supported", async () => {
  const h = harness();
  equal(
    (await h.request({
      ...basePayload(),
      messages: [{ role: "developer", content: "text" }],
    })).status,
    200,
  );
});

for (
  const extra of [
    { temperature: 3 },
    { top_p: -1 },
    { temperature: "prompt" },
    { response_format: { type: "audio" } },
  ]
) {
  Deno.test(`invalid optional parameter ${JSON.stringify(extra)} is rejected`, async () => {
    await rejectedWithoutFetch(harness(), { ...basePayload(), ...extra });
  });
}

for (
  const { name, type } of [
    { name: "an object", type: { toString: null } },
    { name: "an array", type: ["json_object"] },
  ]
) {
  Deno.test(`response_format rejects ${name} as its type`, async () => {
    const h = harness();
    const response = await h.request({
      ...basePayload(),
      response_format: { type },
    });
    equal(response.status, 400);
    equal(await json(response), {
      error: "invalid_response_format",
      request_id: "test-request-id",
    });
    equal(response.headers.get("x-request-id"), "test-request-id");
    equal(h.calls.length, 0);
  });
}

for (
  const messages of [[], null, {}, [{ role: "tool", content: "tool result" }], [
    {
      role: "user",
      content: [{
        type: "image_url",
        image_url: { url: "https://private.test" },
      }],
    },
  ]]
) {
  Deno.test(`invalid or non-text messages ${JSON.stringify(messages)} are rejected`, async () => {
    await rejectedWithoutFetch(harness(), { ...basePayload(), messages });
  });
}

Deno.test("nested message tool and audio fields are not forwarded", async () => {
  const h = harness();
  await h.request({
    ...basePayload(),
    messages: [{
      role: "assistant",
      content: "text",
      tool_calls: [{}],
      audio: { id: "id" },
      private: "value",
    }],
  });
  equal(h.calls[0].payload.messages, [{ role: "assistant", content: "text" }]);
});

Deno.test("per-minute sliding quota returns Retry-After and skips upstream", async () => {
  const h = harness({
    env: {
      OPENAI_PROXY_RATE_LIMIT_PER_MINUTE: "2",
      OPENAI_PROXY_RATE_LIMIT_PER_DAY: "100",
    },
  });
  equal((await h.request()).status, 200);
  equal((await h.request()).status, 200);
  const response = await h.request();
  equal(response.status, 429);
  assert(Number(response.headers.get("retry-after")) >= 1);
  equal(h.calls.length, 2);
  h.advance(60_000);
  equal((await h.request()).status, 200);
});

Deno.test("daily sliding quota remains after the minute window expires", async () => {
  const h = harness({
    env: {
      OPENAI_PROXY_RATE_LIMIT_PER_MINUTE: "100",
      OPENAI_PROXY_RATE_LIMIT_PER_DAY: "2",
    },
  });
  await h.request();
  h.advance(61_000);
  await h.request();
  const response = await h.request();
  equal(response.status, 429);
  assert(Number(response.headers.get("retry-after")) > 60);
  equal(h.calls.length, 2);
  h.advance(86_400_000);
  equal((await h.request()).status, 200);
});

Deno.test("quotas are keyed by verified userId and do not use caller IP", async () => {
  const h = harness({ env: { OPENAI_PROXY_RATE_LIMIT_PER_MINUTE: "1" } });
  equal(
    (await h.request(basePayload(), {
      "x-test-user": "user-a",
      "x-forwarded-for": "1.2.3.4",
    })).status,
    200,
  );
  equal(
    (await h.request(basePayload(), {
      "x-test-user": "user-a",
      "x-forwarded-for": "9.8.7.6",
    })).status,
    429,
  );
  equal(
    (await h.request(basePayload(), {
      "x-test-user": "user-b",
      "x-forwarded-for": "1.2.3.4",
    })).status,
    200,
  );
});

Deno.test("parallel requests cannot consume more than the quota", async () => {
  const h = harness({
    env: {
      OPENAI_PROXY_RATE_LIMIT_PER_MINUTE: "2",
      OPENAI_PROXY_RATE_LIMIT_PER_DAY: "100",
    },
  });
  const statuses = (await Promise.all([h.request(), h.request(), h.request()]))
    .map((response) => response.status).sort();
  equal(statuses, [200, 200, 429]);
  equal(h.calls.length, 2);
});

Deno.test("bounded caller state fails closed at capacity and removes expired callers", async () => {
  const h = harness({
    env: {
      OPENAI_PROXY_RATE_LIMIT_MAX_USERS: "2",
      OPENAI_PROXY_RATE_LIMIT_PER_MINUTE: "10",
    },
  });
  equal(
    (await h.request(basePayload(), { "x-test-user": "user-a" })).status,
    200,
  );
  equal(
    (await h.request(basePayload(), { "x-test-user": "user-b" })).status,
    200,
  );
  equal(
    (await h.request(basePayload(), { "x-test-user": "user-c" })).status,
    429,
  );
  equal(
    (await h.request(basePayload(), { "x-test-user": "user-a" })).status,
    200,
  );
  h.advance(86_400_000);
  equal(
    (await h.request(basePayload(), { "x-test-user": "user-c" })).status,
    200,
  );
  equal(h.calls.length, 4);
});

Deno.test("native requests have no wildcard CORS response", async () => {
  const h = harness();
  equal((await h.request()).headers.get("access-control-allow-origin"), null);
});

Deno.test("browser Origin is rejected by default", async () => {
  const h = harness();
  equal(
    (await h.request(basePayload(), { origin: "https://untrusted.test" }))
      .status,
    403,
  );
  equal(h.calls.length, 0);
});

Deno.test("configured Origin is echoed exactly and varies by Origin", async () => {
  const h = harness({
    env: { OPENAI_PROXY_ALLOWED_ORIGINS: "https://allowed.test" },
  });
  const response = await h.request(basePayload(), {
    origin: "https://allowed.test",
  });
  equal(response.status, 200);
  equal(
    response.headers.get("access-control-allow-origin"),
    "https://allowed.test",
  );
  assert(response.headers.get("vary")?.split(/,\s*/).includes("Origin"));
  equal(
    (await h.request(basePayload(), {
      origin: "https://allowed.test.evil.test",
    })).status,
    403,
  );
});

Deno.test("preflight obeys the same Origin allowlist", async () => {
  const h = harness({
    env: { OPENAI_PROXY_ALLOWED_ORIGINS: "https://allowed.test" },
  });
  const allowed = await h.handler(
    new Request("https://proxy.test", {
      method: "OPTIONS",
      headers: { origin: "https://allowed.test" },
    }),
  );
  equal(allowed.status, 200);
  equal(
    allowed.headers.get("access-control-allow-origin"),
    "https://allowed.test",
  );
  const denied = await h.handler(
    new Request("https://proxy.test", {
      method: "OPTIONS",
      headers: { origin: "https://blocked.test" },
    }),
  );
  equal(denied.status, 403);
  equal(h.calls.length, 0);
});

Deno.test("wildcard and null Origin configuration never enable browser access", async () => {
  const h = harness({ env: { OPENAI_PROXY_ALLOWED_ORIGINS: "*, null" } });
  equal(
    (await h.request(basePayload(), { origin: "https://untrusted.test" }))
      .status,
    403,
  );
  equal((await h.request(basePayload(), { origin: "null" })).status, 403);
  equal(h.calls.length, 0);
});

Deno.test("missing upstream key is generic and has a request id", async () => {
  const h = harness({ env: { OPENAI_API_KEY: undefined } });
  const response = await h.request();
  equal(response.status, 500);
  const body = await json(response);
  equal(body.request_id, "test-request-id");
  assert(!JSON.stringify(body).includes("OPENAI_API_KEY"));
  assert(!JSON.stringify(body).includes("Supabase"));
  equal(h.calls.length, 0);
});

Deno.test("upstream failure preserves status but hides the upstream body", async () => {
  const h = harness({
    response: new Response('{"error":"private-upstream-body"}', {
      status: 429,
    }),
  });
  const response = await h.request();
  equal(response.status, 429);
  const body = await json(response);
  equal(body.request_id, "test-request-id");
  assert(!JSON.stringify(body).includes("private-upstream-body"));
});

Deno.test("an observed out-of-list model records the actual failed status", async () => {
  const h = harness({
    response: new Response("private-upstream-body", { status: 503 }),
  });
  equal(
    (await h.request({ ...basePayload(), model: "future-model" })).status,
    503,
  );
  equal(h.logs.length, 1);
  equal(h.logs[0].event, "model_not_allowed_log_only");
  equal(h.logs[0].status, 503);
});

Deno.test("fetch exceptions return a generic 502 without internal details", async () => {
  const h = harness({
    fetchError: new Error("private-network-detail test-upstream-key"),
  });
  const response = await h.request();
  equal(response.status, 502);
  const body = await json(response);
  equal(body.request_id, "test-request-id");
  assert(!JSON.stringify(body).includes("private-network-detail"));
});

Deno.test("logs contain aggregates without prompt, userId, key, or raw headers", async () => {
  const h = harness();
  await h.request({
    ...basePayload(),
    messages: [{ role: "user", content: "private-prompt-phrase" }],
  });
  assert(h.logs.length > 0, "request outcome must be logged");
  const logs = JSON.stringify(h.logs);
  for (
    const secret of [
      "private-prompt-phrase",
      "private-user-id",
      "test-upstream-key",
      "fake-user-token",
    ]
  ) {
    assert(!logs.includes(secret), `${secret} must not be logged`);
  }
  const allowed = new Set([
    "event",
    "caller_type",
    "caller_hash",
    "model",
    "max_tokens",
    "max_completion_tokens",
    "tokens",
    "status",
    "request_id",
  ]);
  for (const entry of h.logs) {
    assert(
      Object.keys(entry).every((key) => allowed.has(key)),
      "log fields must be explicitly bounded",
    );
  }
});

Deno.test("local OPENAI_BASE_URL and Hermes key fallback remain compatible", async () => {
  const h = harness({
    env: {
      OPENAI_API_KEY: undefined,
      OPENAI_BASE_URL: "http://127.0.0.1:8080/v1///",
    },
  });
  equal((await h.request()).status, 200);
  equal(h.calls[0].url, "http://127.0.0.1:8080/v1/chat/completions");
  equal(
    new Headers(h.calls[0].init.headers).get("authorization"),
    "Bearer hermes-local",
  );
});

Deno.test("unsupported methods still return 405 without auth or upstream", async () => {
  const h = harness();
  equal(
    (await h.handler(new Request("https://proxy.test", { method: "GET" })))
      .status,
    405,
  );
  equal(h.authCalls(), 0);
  equal(h.calls.length, 0);
});

// Synthetic fixtures only. The handler reads the configured value by name.
const fakeAnonKey = "test-public-anon-value";
// banned-ok: Runtime-generated synthetic token used only by this test file.
const fakeAnonToken = crypto.randomUUID();
const anonHeaders = { authorization: `Bearer ${fakeAnonKey}` };
const invalidToken = () =>
  Promise.resolve({ ok: false, status: 401, error: "invalid_token" } as const);

function bridgeHarness(options: HarnessOptions = {}) {
  return harness({
    verifyUser: invalidToken,
    ...options,
    env: {
      OPENAI_PROXY_ALLOW_ANON: "true",
      SUPABASE_ANON_KEY: fakeAnonKey,
      ...options.env,
    },
  });
}

function forwarded(ip: string) {
  return { ...anonHeaders, "x-forwarded-for": ip };
}

async function rateLimited(response: Response, seconds: number) {
  equal(response.status, 429);
  equal(response.headers.get("retry-after"), String(seconds));
  equal((await json(response)).error, "rate_limited");
}

Deno.test("S2 anon bridge requires the exact opt-in switch", async () => {
  for (const value of [undefined, "false", "TRUE", " true "]) {
    const h = bridgeHarness({ env: { OPENAI_PROXY_ALLOW_ANON: value } });
    const response = await h.request(basePayload(), anonHeaders);
    equal(response.status, 401);
    equal((await json(response)).error, "invalid_token");
    equal(h.calls.length, 0);
  }
});

Deno.test("S2 anon bridge admits the exact key and applies existing payload limits", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_MAX_TOKENS: "80" } });
  const response = await h.request({
    model: "gpt-4o-mini",
    messages: [{ role: "user", content: "text", extra: "drop" }],
    max_tokens: 200,
    max_completion_tokens: 300,
    n: 4,
    stream: true,
    tools: [{}],
  }, anonHeaders);
  equal(response.status, 200);
  equal(h.authCalls(), 1);
  equal(h.calls.length, 1);
  equal(h.calls[0].payload, {
    model: "gpt-4o-mini",
    messages: [{ role: "user", content: "text" }],
    n: 1,
    stream: false,
    max_tokens: 80,
    max_completion_tokens: 80,
  });
});

Deno.test("S2 anon bridge rejects missing, arbitrary, and same-length incorrect bearer tokens", async () => {
  const h = bridgeHarness();
  for (
    const authorization of [
      undefined,
      "Bearer invalid",
      `Bearer ${fakeAnonKey.slice(0, -1)}X`,
      `Bearer ${fakeAnonKey},${fakeAnonKey}`,
      `Basic ${fakeAnonKey}`,
    ]
  ) {
    const response = await h.handler(
      new Request("https://proxy.test", {
        method: "POST",
        headers: authorization ? { authorization } : {},
        body: JSON.stringify(basePayload()),
      }),
    );
    equal(response.status, 401);
    equal((await json(response)).error, "invalid_token");
  }
  equal(h.calls.length, 0);
});

Deno.test("S2.1 anon bridge admits the configured override token", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_TOKEN: fakeAnonToken } });
  const response = await h.request(basePayload(), {
    authorization: `Bearer ${fakeAnonToken}`,
  });
  equal(response.status, 200);
  equal(h.calls.length, 1);
});

Deno.test("S2.1 anon bridge rejects the Supabase key while the override is set", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_TOKEN: fakeAnonToken } });
  const response = await h.request(basePayload(), anonHeaders);
  equal(response.status, 401);
  equal((await json(response)).error, "invalid_token");
  equal(h.calls.length, 0);
});

Deno.test("S2.1 an empty override rejects the Supabase key", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_TOKEN: "" } });
  const response = await h.request(basePayload(), anonHeaders);
  equal(response.status, 401);
  equal((await json(response)).error, "invalid_token");
  equal(h.calls.length, 0);
});

Deno.test("S2.1 an unset override preserves the Supabase key fallback", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_TOKEN: undefined } });
  const response = await h.request(basePayload(), anonHeaders);
  equal(response.status, 200);
  equal(h.calls.length, 1);
});

Deno.test("S2.1 the override rejects wrong tokens of different and equal lengths", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_TOKEN: fakeAnonToken } });
  for (const token of ["invalid", fakeAnonToken.slice(0, -1) + "X"]) {
    const response = await h.request(basePayload(), {
      authorization: `Bearer ${token}`,
    });
    equal(response.status, 401);
    equal((await json(response)).error, "invalid_token");
  }
  equal(h.calls.length, 0);
});

Deno.test("S2 anon bridge rejects an absent or empty configured key", async () => {
  for (const key of [undefined, ""]) {
    const h = bridgeHarness({ env: { SUPABASE_ANON_KEY: key } });
    const response = await h.request(basePayload(), anonHeaders);
    equal(response.status, 401);
    equal((await json(response)).error, "invalid_token");
    equal(h.calls.length, 0);
  }
});

Deno.test("S2 anon bridge does not relax other auth failures or exceptions", async () => {
  for (
    const [status, error] of [
      [500, "auth_not_configured"],
      [401, "missing_authorization"],
      [500, "invalid_token"],
    ] as const
  ) {
    const h = bridgeHarness({
      verifyUser: () => Promise.resolve({ ok: false, status, error }),
    });
    const response = await h.request(basePayload(), anonHeaders);
    equal(response.status, status);
    equal((await json(response)).error, error);
    equal(h.calls.length, 0);
  }
  const h = bridgeHarness({
    verifyUser: () => {
      throw new Error("mock auth failure");
    },
  });
  equal((await h.request(basePayload(), anonHeaders)).status, 401);
  equal(h.calls.length, 0);
});

Deno.test("S2 anon model allowlist is enforced even when user enforcement is false", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_MODEL_ENFORCE: "false" } });
  const response = await h.request({
    ...basePayload(),
    model: "outside-the-list",
  }, anonHeaders);
  equal(response.status, 400);
  equal((await json(response)).error, "model_not_allowed");
  equal(h.calls.length, 0);
});

Deno.test("S2 verified users keep model log-only behavior when the bridge is enabled", async () => {
  const h = bridgeHarness({
    verifyUser: () => Promise.resolve({ ok: true, userId: "verified-user" }),
    env: { OPENAI_PROXY_MODEL_ENFORCE: "false" },
  });
  const response = await h.request({
    ...basePayload(),
    model: "outside-the-list",
  }, anonHeaders);
  equal(response.status, 200);
  equal(h.calls.length, 1);
  equal(h.logs[0].event, "model_not_allowed_log_only");
  equal(h.logs[0].caller_type, "user");
});

Deno.test("S2 rejected anon model values do not appear in logs", async () => {
  const h = bridgeHarness();
  const ip = "192.0.2.123";
  const response = await h.request({
    ...basePayload(),
    model: ip,
  }, forwarded(ip));
  equal(response.status, 400);
  equal((await json(response)).error, "model_not_allowed");
  equal(h.calls.length, 0);
  equal(h.logs.length, 1);
  equal(h.logs[0].caller_type, "anon");
  assert(!JSON.stringify(h.logs).includes(ip), "raw IP was logged");
});

Deno.test("S2 anon IP minute quota prefers CF and otherwise uses the first forwarded IP", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_PER_MINUTE: "1" } });
  const request = (headers: Record<string, string>) =>
    h.request(basePayload(), { ...anonHeaders, ...headers });
  equal(
    (await request({
      "cf-connecting-ip": "192.0.2.1",
      "x-forwarded-for": "192.0.2.9",
    })).status,
    200,
  );
  await rateLimited(
    await request({
      "cf-connecting-ip": "192.0.2.1",
      "x-forwarded-for": "192.0.2.8",
    }),
    60,
  );
  equal(
    (await request({ "x-forwarded-for": "192.0.2.9, 192.0.2.8" })).status,
    200,
  );
  await rateLimited(
    await request({ "x-forwarded-for": "192.0.2.9, 192.0.2.7" }),
    60,
  );
  equal(h.calls.length, 2);
  h.advance(60_000);
  equal((await request({ "x-forwarded-for": "192.0.2.9" })).status, 200);
});

Deno.test("S2 anon requests with no IP share the unknown bucket", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_PER_MINUTE: "1" } });
  equal((await h.request(basePayload(), anonHeaders)).status, 200);
  await rateLimited(await h.request(basePayload(), anonHeaders), 60);
  await rateLimited(await h.request(basePayload(), forwarded("unknown")), 60);
  equal(h.calls.length, 1);
});

Deno.test("S2 anon IP day quota outlasts the minute window", async () => {
  const h = bridgeHarness({ env: { OPENAI_PROXY_ANON_PER_DAY: "1" } });
  const ip = forwarded("192.0.2.1");
  equal((await h.request(basePayload(), ip)).status, 200);
  h.advance(60_000);
  await rateLimited(await h.request(basePayload(), ip), 86_340);
  equal((await h.request(basePayload(), forwarded("192.0.2.2"))).status, 200);
  h.advance(86_340_000);
  equal((await h.request(basePayload(), ip)).status, 200);
  equal(h.calls.length, 3);
});

Deno.test("S2 anon global minute quota caps concurrent callers rotating IPs", async () => {
  const h = bridgeHarness({
    env: { OPENAI_PROXY_ANON_GLOBAL_PER_MINUTE: "2" },
  });
  const responses = await Promise.all(
    [1, 2, 3].map((i) => h.request(basePayload(), forwarded(`192.0.2.${i}`))),
  );
  equal(responses.map(({ status }) => status).sort(), [200, 200, 429]);
  await rateLimited(responses.find(({ status }) => status === 429)!, 60);
  equal(h.calls.length, 2);
  h.advance(60_000);
  equal((await h.request(basePayload(), forwarded("192.0.2.4"))).status, 200);
});

Deno.test("S2 anon global day quota cannot be bypassed by rotating IPs", async () => {
  const h = bridgeHarness({
    env: { OPENAI_PROXY_ANON_GLOBAL_PER_DAY: "2" },
  });
  for (const i of [1, 2]) {
    equal(
      (await h.request(basePayload(), forwarded(`192.0.2.${i}`))).status,
      200,
    );
    h.advance(60_000);
  }
  await rateLimited(
    await h.request(basePayload(), forwarded("192.0.2.3")),
    86_280,
  );
  equal(h.calls.length, 2);
  h.advance(86_280_000);
  equal((await h.request(basePayload(), forwarded("192.0.2.4"))).status, 200);
});

Deno.test("S2 anon quota rejections do not charge the other window ledger", async () => {
  const h = bridgeHarness({
    env: {
      OPENAI_PROXY_ANON_PER_MINUTE: "1",
      OPENAI_PROXY_ANON_PER_DAY: "1",
      OPENAI_PROXY_ANON_GLOBAL_PER_MINUTE: "2",
    },
  });
  const request = (i: number) =>
    h.request(basePayload(), forwarded(`192.0.2.${i}`));
  equal((await request(1)).status, 200);
  await rateLimited(await request(1), 86_400);
  equal((await request(2)).status, 200);
  await rateLimited(await request(3), 60);
  h.advance(60_000);
  equal((await request(3)).status, 200);
  equal(h.calls.length, 3);
});

Deno.test("S2 anon and authenticated quotas stay isolated in both directions", async () => {
  const ip = "192.0.2.7";
  for (const anonFirst of [true, false]) {
    const h = bridgeHarness({
      verifyUser: (req) =>
        req.headers.get("authorization") === anonHeaders.authorization
          ? invalidToken()
          : Promise.resolve({ ok: true, userId: ip }),
      env: {
        OPENAI_PROXY_RATE_LIMIT_PER_MINUTE: "1",
        OPENAI_PROXY_ANON_PER_MINUTE: "1",
        OPENAI_PROXY_ANON_GLOBAL_PER_MINUTE: "1",
      },
    });
    const anon = () => h.request(basePayload(), forwarded(ip));
    const user = () => h.request(basePayload(), { "x-forwarded-for": ip });
    const [first, second] = anonFirst ? [anon, user] : [user, anon];
    equal((await first()).status, 200);
    await rateLimited(await first(), 60);
    equal((await second()).status, 200);
    await rateLimited(await second(), 60);
    equal(h.calls.length, 2);
    equal(
      h.logs.map((entry) => entry.caller_type),
      anonFirst
        ? ["anon", "anon", "user", "user"]
        : ["user", "user", "anon", "anon"],
    );
  }
});

Deno.test("S2 anon ledger caps active IP entries without eviction", async () => {
  const h = bridgeHarness({
    env: {
      OPENAI_PROXY_ANON_GLOBAL_PER_MINUTE: "20000",
      OPENAI_PROXY_ANON_GLOBAL_PER_DAY: "20000",
    },
  });
  const request = (index: number) =>
    h.request(null, forwarded(`2001:db8::${index.toString(16)}`));
  for (let i = 0; i < 10_000; i++) {
    equal((await request(i)).status, 400);
  }
  await rateLimited(await request(10_000), 86_400);
  equal((await request(0)).status, 400);
  await rateLimited(await request(10_000), 86_400);
  h.advance(86_400_000);
  equal((await request(10_000)).status, 400);
  equal(h.calls.length, 0);
});

Deno.test("S2 anon logs include caller type and IP hash without raw inputs", async () => {
  const h = bridgeHarness();
  const ip = "192.0.2.123";
  const prompt = "private anon prompt phrase";
  const response = await h.request({
    ...basePayload(),
    messages: [{ role: "user", content: prompt }],
  }, forwarded(ip));
  equal(response.status, 200);
  equal(h.logs.length, 1);
  equal(h.logs[0].caller_type, "anon");
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(ip),
  );
  equal(
    h.logs[0].caller_hash,
    Array.from(
      new Uint8Array(hash),
      (byte) => byte.toString(16).padStart(2, "0"),
    ).join(""),
  );
  const logs = JSON.stringify(h.logs);
  for (const privateInput of [ip, fakeAnonKey, prompt, "test-upstream-key"]) {
    assert(!logs.includes(privateInput), "private input was logged");
  }
});

function trackedBody(headers: Record<string, string> = {}) {
  let pulls = 0;
  const request = new Request("https://proxy.test", {
    method: "POST",
    headers,
    body: new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls++;
        controller.enqueue(
          new TextEncoder().encode(JSON.stringify(basePayload())),
        );
        controller.close();
      },
    }, { highWaterMark: 0 }),
  });
  return { request, pulls: () => pulls };
}

Deno.test("S2 auth rejection does not pull a request body stream", async () => {
  const h = harness({ verifyUser: invalidToken });
  const body = trackedBody();
  equal((await h.handler(body.request)).status, 401);
  equal(body.pulls(), 0);
  equal(h.calls.length, 0);
});

Deno.test("S2 auth rejection takes precedence over malformed JSON", async () => {
  const h = harness({ verifyUser: invalidToken });
  const response = await h.handler(
    new Request("https://proxy.test", {
      method: "POST",
      body: "{",
    }),
  );
  equal(response.status, 401);
  equal((await json(response)).error, "invalid_token");
  equal(h.calls.length, 0);
});

Deno.test("S2 user quota rejection does not pull a request body stream", async () => {
  const h = harness({ env: { OPENAI_PROXY_RATE_LIMIT_PER_MINUTE: "1" } });
  equal((await h.request()).status, 200);
  const body = trackedBody();
  await rateLimited(await h.handler(body.request), 60);
  equal(body.pulls(), 0);
  equal(h.calls.length, 1);
});

Deno.test("S2 anon global quota rejection does not pull a request body stream", async () => {
  const h = bridgeHarness({
    env: { OPENAI_PROXY_ANON_GLOBAL_PER_MINUTE: "1" },
  });
  equal((await h.request(basePayload(), forwarded("192.0.2.1"))).status, 200);
  const body = trackedBody(forwarded("192.0.2.2"));
  await rateLimited(await h.handler(body.request), 60);
  equal(body.pulls(), 0);
  equal(h.calls.length, 1);
});

Deno.test("S2 upstream timeout aborts fetch and returns a sanitized 504", async () => {
  const h = harness({
    env: { OPENAI_PROXY_UPSTREAM_TIMEOUT_MS: "10" },
    fetch: async (_input, init) => {
      const signal = init?.signal;
      assert(signal instanceof AbortSignal, "upstream fetch must get a signal");
      await new Promise<never>((_resolve, reject) => {
        const onAbort = () => {
          clearTimeout(watchdog);
          reject(new Error("private upstream timeout details"));
        };
        const watchdog = setTimeout(() => {
          signal.removeEventListener("abort", onAbort);
          reject(new Error("upstream signal did not abort"));
        }, 500);
        if (signal.aborted) onAbort();
        else signal.addEventListener("abort", onAbort, { once: true });
      });
      throw new Error("unreachable");
    },
  });
  const response = await h.request();
  equal(response.status, 504);
  equal(await json(response), {
    error: "upstream_timeout",
    request_id: "test-request-id",
  });
  equal(h.calls.length, 1);
  equal(h.logs[0].status, 504);
  assert(!JSON.stringify(h.logs).includes("private upstream timeout details"));
});

Deno.test("S2 upstream timeout signal preserves normal successful responses", async () => {
  const h = harness({
    fetch: (_input, init) => {
      assert(init?.signal instanceof AbortSignal);
      assert(!init.signal.aborted);
      return Promise.resolve(new Response('{"result":"ok"}'));
    },
  });
  const response = await h.request();
  equal(response.status, 200);
  equal(await json(response), { result: "ok" });
  equal(h.calls.length, 1);
});

Deno.test("S2 missing or invalid upstream timeout settings use 30 seconds", async () => {
  const timeout = AbortSignal.timeout;
  const delays: number[] = [];
  AbortSignal.timeout = (delay) => {
    delays.push(delay);
    return timeout(delay);
  };
  try {
    for (const value of [undefined, "0", "-1", "1.5", "bad", "2147483648"]) {
      const h = harness({ env: { OPENAI_PROXY_UPSTREAM_TIMEOUT_MS: value } });
      equal((await h.request()).status, 200);
    }
    equal(delays, Array(6).fill(30_000));
  } finally {
    AbortSignal.timeout = timeout;
  }
});
