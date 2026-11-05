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
