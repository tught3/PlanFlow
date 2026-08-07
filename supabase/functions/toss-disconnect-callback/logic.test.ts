import {
  assert,
  assertEquals,
  assertFalse,
  assertRejects,
} from "jsr:@std/assert@1";
import {
  applyDisconnect,
  classifyReferrer,
  decodeBasicAuth,
  DISCONNECT_REFERRERS,
  type DisconnectPort,
  extractRawUserKeyLiteral,
  normalizeTossUserKey,
  parseDisconnectRequest,
  safeEqual,
} from "./logic.ts";

// ---------------------------------------------------------------------------
// P5 — decodeBasicAuth
// ---------------------------------------------------------------------------

Deno.test("decodeBasicAuth: valid Basic header decodes correctly", () => {
  const header = `Basic ${btoa("secret-token")}`;
  const result = decodeBasicAuth(header);
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.credentials, "secret-token");
  }
});

Deno.test("decodeBasicAuth: missing header -> ok:false", () => {
  const result = decodeBasicAuth(null);
  assertFalse(result.ok);
});

Deno.test("decodeBasicAuth: wrong scheme (Bearer) -> ok:false", () => {
  const result = decodeBasicAuth("Bearer xyz");
  assertFalse(result.ok);
});

Deno.test("decodeBasicAuth: malformed base64 -> ok:false", () => {
  const result = decodeBasicAuth("Basic !!!not-valid-base64!!!");
  assertFalse(result.ok);
});

// ---------------------------------------------------------------------------
// P5 — safeEqual
// ---------------------------------------------------------------------------

Deno.test("safeEqual: equal strings -> true", () => {
  assert(safeEqual("same-secret", "same-secret"));
});

Deno.test("safeEqual: different strings, same length -> false", () => {
  assertFalse(safeEqual("aaaaaaaa", "bbbbbbbb"));
});

Deno.test("safeEqual: different lengths -> false, does not throw", () => {
  let result: boolean | undefined;
  let threw = false;
  try {
    result = safeEqual("short", "much-longer-string");
  } catch (_err) {
    threw = true;
  }
  assertFalse(threw);
  assertEquals(result, false);
});

Deno.test("safeEqual: both empty strings -> true", () => {
  assert(safeEqual("", ""));
});

// ---------------------------------------------------------------------------
// P5 — parseDisconnectRequest
// ---------------------------------------------------------------------------

Deno.test("parseDisconnectRequest: GET missing userKey -> ok:false", () => {
  const result = parseDisconnectRequest({
    method: "GET",
    url: "https://example.com/cb?referrer=UNLINK",
    rawBody: null,
  });
  assertFalse(result.ok);
});

Deno.test("parseDisconnectRequest: GET missing referrer -> ok:false", () => {
  const result = parseDisconnectRequest({
    method: "GET",
    url: "https://example.com/cb?userKey=12345",
    rawBody: null,
  });
  assertFalse(result.ok);
});

Deno.test("parseDisconnectRequest: GET with known referrer -> ok:true, referrerClass 'known'", () => {
  const result = parseDisconnectRequest({
    method: "GET",
    url: "https://example.com/cb?userKey=12345&referrer=UNLINK",
    rawBody: null,
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.userKey, "12345");
    assertEquals(result.referrer, "UNLINK");
    assertEquals(result.referrerClass, "known");
  }
});

Deno.test("parseDisconnectRequest: POST with known referrer (JSON body) -> ok:true, referrerClass 'known'", () => {
  const result = parseDisconnectRequest({
    method: "POST",
    url: "https://example.com/cb",
    rawBody: JSON.stringify({ userKey: "12345", referrer: "UNLINK" }),
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.userKey, "12345");
    assertEquals(result.referrer, "UNLINK");
    assertEquals(result.referrerClass, "known");
  }
});

Deno.test("parseDisconnectRequest: GET and POST with equivalent data produce the same parsed result (parity)", () => {
  const getResult = parseDisconnectRequest({
    method: "GET",
    url: "https://example.com/cb?userKey=12345&referrer=WITHDRAWAL_TERMS",
    rawBody: null,
  });
  const postResult = parseDisconnectRequest({
    method: "POST",
    url: "https://example.com/cb",
    rawBody: JSON.stringify({
      userKey: "12345",
      referrer: "WITHDRAWAL_TERMS",
    }),
  });
  assert(getResult.ok);
  assert(postResult.ok);
  if (getResult.ok && postResult.ok) {
    assertEquals(getResult.userKey, postResult.userKey);
    assertEquals(getResult.referrer, postResult.referrer);
    assertEquals(getResult.referrerClass, postResult.referrerClass);
  }
});

Deno.test("parseDisconnectRequest: unknown (but valid, non-empty) referrer -> ok:true, referrerClass 'unknown' (not a parse failure)", () => {
  const result = parseDisconnectRequest({
    method: "GET",
    url:
      "https://example.com/cb?userKey=12345&referrer=SOME_FUTURE_REFERRER",
    rawBody: null,
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.referrerClass, "unknown");
    assertEquals(result.referrer, "SOME_FUTURE_REFERRER");
  }
});

// ---------------------------------------------------------------------------
// P5 — normalizeTossUserKey / extractRawUserKeyLiteral (big-integer safety)
// ---------------------------------------------------------------------------

Deno.test("extractRawUserKeyLiteral: recovers exact digit string beyond Number.MAX_SAFE_INTEGER", () => {
  const rawBody = '{"userKey": 9007199254740993, "referrer": "UNLINK"}';
  const literal = extractRawUserKeyLiteral(rawBody);
  assertEquals(literal, "9007199254740993");
});

Deno.test("parseDisconnectRequest: POST body with unsafe-integer userKey literal is not corrupted by JSON.parse float rounding", () => {
  const rawBody = '{"userKey": 9007199254740993, "referrer": "UNLINK"}';
  const result = parseDisconnectRequest({
    method: "POST",
    url: "https://example.com/cb",
    rawBody,
  });
  assert(result.ok);
  if (result.ok) {
    // If JSON.parse's float rounding had been used instead of the raw
    // literal extraction, this would come out as "9007199254740992" (or a
    // rounded/exponential form) rather than the exact input digits.
    assertEquals(result.userKey, "9007199254740993");
  }
});

Deno.test("normalizeTossUserKey: rejects an unsafe-integer number (raw-literal recovery not applicable)", () => {
  // 2 ** 53 is the first integer above Number.MAX_SAFE_INTEGER (2**53 - 1).
  const unsafeInteger = 2 ** 53;
  assertFalse(Number.isSafeInteger(unsafeInteger));
  const result = normalizeTossUserKey(unsafeInteger);
  assertFalse(result.ok);
});

Deno.test("normalizeTossUserKey: accepts a safe integer number", () => {
  const result = normalizeTossUserKey(12345);
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.key, "12345");
  }
});

Deno.test("normalizeTossUserKey: accepts and trims a non-empty string", () => {
  const result = normalizeTossUserKey("  abc123  ");
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.key, "abc123");
  }
});

Deno.test("normalizeTossUserKey: rejects an empty/whitespace-only string", () => {
  assertFalse(normalizeTossUserKey("").ok);
  assertFalse(normalizeTossUserKey("   ").ok);
});

Deno.test("normalizeTossUserKey: rejects non-string/non-number values", () => {
  assertFalse(normalizeTossUserKey(null).ok);
  assertFalse(normalizeTossUserKey(undefined).ok);
  assertFalse(normalizeTossUserKey({}).ok);
  assertFalse(normalizeTossUserKey(true).ok);
});

// ---------------------------------------------------------------------------
// P5 — classifyReferrer
// ---------------------------------------------------------------------------

Deno.test("classifyReferrer: each known DISCONNECT_REFERRERS value -> 'known'", () => {
  for (const referrer of DISCONNECT_REFERRERS) {
    assertEquals(classifyReferrer(referrer), "known");
  }
});

Deno.test("classifyReferrer: empty string -> 'malformed'", () => {
  assertEquals(classifyReferrer(""), "malformed");
});

Deno.test("classifyReferrer: non-string values -> 'malformed'", () => {
  assertEquals(classifyReferrer(123), "malformed");
  assertEquals(classifyReferrer(null), "malformed");
  assertEquals(classifyReferrer(undefined), "malformed");
  assertEquals(classifyReferrer({}), "malformed");
});

Deno.test("classifyReferrer: plausible but unlisted string -> 'unknown'", () => {
  assertEquals(classifyReferrer("SOME_FUTURE_REFERRER"), "unknown");
});

// ---------------------------------------------------------------------------
// P6 — applyDisconnect (fake DisconnectPort)
// ---------------------------------------------------------------------------

Deno.test("applyDisconnect: known referrer + unconnected user -> 'disconnected', markDisconnected called once with correct args", async () => {
  const markCalls: Array<{ userId: string; referrer: string; nowIso: string }> =
    [];
  const port: DisconnectPort = {
    findByTossUserKey: async (key) => {
      assertEquals(key, "toss-key-1");
      return { userId: "u1", disconnectedAt: null };
    },
    markDisconnected: async (userId, referrer, nowIso) => {
      markCalls.push({ userId, referrer, nowIso });
      return { ok: true };
    },
  };

  const result = await applyDisconnect(
    port,
    "toss-key-1",
    "UNLINK",
    "known",
    "2026-08-07T00:00:00Z",
  );

  assertEquals(result, "disconnected");
  assertEquals(markCalls.length, 1);
  assertEquals(markCalls[0], {
    userId: "u1",
    referrer: "UNLINK",
    nowIso: "2026-08-07T00:00:00Z",
  });
});

Deno.test("applyDisconnect: user not found -> 'unknown_user', markDisconnected not called", async () => {
  let markCalled = 0;
  const port: DisconnectPort = {
    findByTossUserKey: async () => null,
    markDisconnected: async () => {
      markCalled++;
      return { ok: true };
    },
  };

  const result = await applyDisconnect(
    port,
    "no-such-key",
    "UNLINK",
    "known",
    "2026-08-07T00:00:00Z",
  );

  assertEquals(result, "unknown_user");
  assertEquals(markCalled, 0);
});

Deno.test("applyDisconnect: already disconnected -> idempotent no-op, original timestamp untouched", async () => {
  const existingRecord = { userId: "u1", disconnectedAt: "2026-08-01T00:00:00Z" };
  let markCalled = 0;
  const port: DisconnectPort = {
    findByTossUserKey: async () => ({ ...existingRecord }),
    markDisconnected: async () => {
      markCalled++;
      return { ok: true };
    },
  };

  const result = await applyDisconnect(
    port,
    "toss-key-1",
    "UNLINK",
    "known",
    "2026-08-07T00:00:00Z",
  );

  assertEquals(result, "already_disconnected");
  assertEquals(markCalled, 0);
  // The original record (and thus the original timestamp) must be untouched.
  assertEquals(existingRecord.disconnectedAt, "2026-08-01T00:00:00Z");
});

Deno.test("applyDisconnect: findByTossUserKey rejection propagates (no internal try/catch in applyDisconnect)", async () => {
  const port: DisconnectPort = {
    findByTossUserKey: async () => {
      throw new Error("db unavailable");
    },
    markDisconnected: async () => ({ ok: true }),
  };

  await assertRejects(
    () =>
      applyDisconnect(
        port,
        "toss-key-1",
        "UNLINK",
        "known",
        "2026-08-07T00:00:00Z",
      ),
    Error,
    "db unavailable",
  );
});

Deno.test("applyDisconnect: markDisconnected returns ok:false -> 'error'", async () => {
  const port: DisconnectPort = {
    findByTossUserKey: async () => ({ userId: "u1", disconnectedAt: null }),
    markDisconnected: async () => ({ ok: false, error: "write failed" }),
  };

  const result = await applyDisconnect(
    port,
    "toss-key-1",
    "UNLINK",
    "known",
    "2026-08-07T00:00:00Z",
  );

  assertEquals(result, "error");
});

Deno.test("applyDisconnect: unknown referrer class -> 'ignored_unknown_referrer', zero DB calls (fail-safe toward no-action)", async () => {
  let findCalled = 0;
  let markCalled = 0;
  const port: DisconnectPort = {
    findByTossUserKey: async () => {
      findCalled++;
      return null;
    },
    markDisconnected: async () => {
      markCalled++;
      return { ok: true };
    },
  };

  const result = await applyDisconnect(
    port,
    "toss-key-1",
    "SOME_FUTURE_REFERRER",
    "unknown",
    "2026-08-07T00:00:00Z",
  );

  assertEquals(result, "ignored_unknown_referrer");
  assertEquals(findCalled, 0);
  assertEquals(markCalled, 0);
});

Deno.test("applyDisconnect: disconnect -> reconnect (state reset) -> disconnect again works (not a one-shot)", async () => {
  const state: { userId: string; disconnectedAt: string | null } = {
    userId: "u1",
    disconnectedAt: null,
  };
  let markCalled = 0;
  const port: DisconnectPort = {
    findByTossUserKey: async () => ({ ...state }),
    markDisconnected: async (_userId, _referrer, nowIso) => {
      markCalled++;
      state.disconnectedAt = nowIso;
      return { ok: true };
    },
  };

  const first = await applyDisconnect(
    port,
    "toss-key-1",
    "UNLINK",
    "known",
    "2026-08-07T00:00:00Z",
  );
  assertEquals(first, "disconnected");
  assertEquals(state.disconnectedAt, "2026-08-07T00:00:00Z");

  // Simulate a future reconnect flow (out of scope for this module) resetting
  // the disconnected flag on the underlying identity.
  state.disconnectedAt = null;

  const second = await applyDisconnect(
    port,
    "toss-key-1",
    "UNLINK",
    "known",
    "2026-08-08T00:00:00Z",
  );
  assertEquals(second, "disconnected");
  assertEquals(state.disconnectedAt, "2026-08-08T00:00:00Z");
  assertEquals(markCalled, 2);
});

// ---------------------------------------------------------------------------
// P7 — data isolation
// ---------------------------------------------------------------------------

Deno.test("applyDisconnect: data isolation - disconnecting one user's tossUserKey does not touch other users' records", async () => {
  const db = new Map<string, { userId: string; disconnectedAt: string | null }>([
    ["k1", { userId: "user-1", disconnectedAt: null }],
    ["k2", { userId: "user-2", disconnectedAt: null }],
    ["k3", { userId: "user-3", disconnectedAt: null }],
  ]);
  const before = new Map(
    Array.from(db.entries()).map(([key, record]) => [key, { ...record }]),
  );
  const markCalls: Array<{ userId: string }> = [];

  const port: DisconnectPort = {
    findByTossUserKey: async (key) => {
      const record = db.get(key);
      return record ? { ...record } : null;
    },
    markDisconnected: async (userId, _referrer, nowIso) => {
      markCalls.push({ userId });
      for (const record of db.values()) {
        if (record.userId === userId) {
          record.disconnectedAt = nowIso;
        }
      }
      return { ok: true };
    },
  };

  const result = await applyDisconnect(
    port,
    "k2",
    "UNLINK",
    "known",
    "2026-08-07T00:00:00Z",
  );

  assertEquals(result, "disconnected");
  // markDisconnected must be called exactly once, and only for k2's userId.
  assertEquals(markCalls.length, 1);
  assertEquals(markCalls[0].userId, "user-2");

  // k1 and k3's records must be byte-identical to their pre-call state.
  assertEquals(db.get("k1"), before.get("k1"));
  assertEquals(db.get("k3"), before.get("k3"));

  // Only k2 should have actually changed.
  assert(db.get("k2")!.disconnectedAt !== null);
  assertEquals(db.get("k2")!.disconnectedAt, "2026-08-07T00:00:00Z");
});

// DisconnectPort is a TypeScript interface with exactly two methods
// (findByTossUserKey, markDisconnected). This is a type-level isolation
// guarantee enforced by the compiler / interface shape: any implementation
// of DisconnectPort structurally cannot expose additional methods to
// applyDisconnect's callers beyond these two, so the disconnect flow has no
// type-level path to reach other tables (e.g. events, auth.users) through
// this port. A meaningful runtime echo of this isn't natural here since
// structural typing has no runtime representation to assert against; the
// data-isolation test above instead verifies the *behavioral* consequence
// (only the targeted user's record is touched) using a fake that exposes
// exactly this interface's two methods.
