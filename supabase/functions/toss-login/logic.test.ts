import {
  assert,
  assertEquals,
  assertFalse,
} from "jsr:@std/assert@1";
import {
  parseLoginRequest,
  resolveTossApiBase,
  supportsMtls,
  syntheticEmailFor,
  TOSS_LOGIN_ERROR_CODES,
} from "./logic.ts";

// ---------------------------------------------------------------------------
// parseLoginRequest
// ---------------------------------------------------------------------------

Deno.test("parseLoginRequest: valid DEFAULT referrer", () => {
  const result = parseLoginRequest({
    authorizationCode: "abc123",
    referrer: "DEFAULT",
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.authorizationCode, "abc123");
    assertEquals(result.referrer, "DEFAULT");
  }
});

Deno.test("parseLoginRequest: valid SANDBOX referrer", () => {
  const result = parseLoginRequest({
    authorizationCode: "xyz789",
    referrer: "SANDBOX",
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.referrer, "SANDBOX");
  }
});

Deno.test("parseLoginRequest: trims authorizationCode whitespace", () => {
  const result = parseLoginRequest({
    authorizationCode: "  padded-code  ",
    referrer: "DEFAULT",
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.authorizationCode, "padded-code");
  }
});

Deno.test("parseLoginRequest: rejects empty authorizationCode", () => {
  const result = parseLoginRequest({
    authorizationCode: "",
    referrer: "DEFAULT",
  });
  assertFalse(result.ok);
  if (!result.ok) {
    assertEquals(result.error, "invalid_request");
  }
});

Deno.test("parseLoginRequest: rejects whitespace-only authorizationCode", () => {
  const result = parseLoginRequest({
    authorizationCode: "   ",
    referrer: "DEFAULT",
  });
  assertFalse(result.ok);
});

Deno.test("parseLoginRequest: rejects non-string authorizationCode", () => {
  const result = parseLoginRequest({
    authorizationCode: 12345,
    referrer: "DEFAULT",
  });
  assertFalse(result.ok);
  if (!result.ok) {
    assertEquals(result.error, "invalid_request");
  }
});

Deno.test("parseLoginRequest: rejects missing authorizationCode", () => {
  const result = parseLoginRequest({ referrer: "DEFAULT" });
  assertFalse(result.ok);
});

Deno.test("parseLoginRequest: rejects unknown referrer", () => {
  const result = parseLoginRequest({
    authorizationCode: "abc123",
    referrer: "PRODUCTION",
  });
  assertFalse(result.ok);
  if (!result.ok) {
    assertEquals(result.error, "invalid_request");
  }
});

Deno.test("parseLoginRequest: rejects missing referrer", () => {
  const result = parseLoginRequest({ authorizationCode: "abc123" });
  assertFalse(result.ok);
});

Deno.test("parseLoginRequest: rejects null body", () => {
  const result = parseLoginRequest(null);
  assertFalse(result.ok);
});

Deno.test("parseLoginRequest: rejects non-object body (string)", () => {
  const result = parseLoginRequest("abc123");
  assertFalse(result.ok);
});

Deno.test("parseLoginRequest: rejects array body", () => {
  const result = parseLoginRequest(["abc123", "DEFAULT"]);
  assertFalse(result.ok);
});

Deno.test("parseLoginRequest: rejects undefined body", () => {
  const result = parseLoginRequest(undefined);
  assertFalse(result.ok);
});

// ---------------------------------------------------------------------------
// resolveTossApiBase
// ---------------------------------------------------------------------------

Deno.test("resolveTossApiBase: DEFAULT reads TOSS_API_BASE_URL_DEFAULT", () => {
  const result = resolveTossApiBase("DEFAULT", {
    TOSS_API_BASE_URL_DEFAULT: "https://api.toss.example",
    TOSS_API_BASE_URL_SANDBOX: "https://sandbox.toss.example",
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.base, "https://api.toss.example");
  }
});

Deno.test("resolveTossApiBase: SANDBOX reads TOSS_API_BASE_URL_SANDBOX", () => {
  const result = resolveTossApiBase("SANDBOX", {
    TOSS_API_BASE_URL_DEFAULT: "https://api.toss.example",
    TOSS_API_BASE_URL_SANDBOX: "https://sandbox.toss.example",
  });
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.base, "https://sandbox.toss.example");
  }
});

Deno.test("resolveTossApiBase: fails when env var missing (fail-closed)", () => {
  const result = resolveTossApiBase("DEFAULT", {});
  assertFalse(result.ok);
  if (!result.ok) {
    assertEquals(result.error, "toss_api_base_not_configured");
  }
});

Deno.test("resolveTossApiBase: fails when env var is empty string", () => {
  const result = resolveTossApiBase("DEFAULT", {
    TOSS_API_BASE_URL_DEFAULT: "",
  });
  assertFalse(result.ok);
});

Deno.test("resolveTossApiBase: fails when env var is whitespace only", () => {
  const result = resolveTossApiBase("SANDBOX", {
    TOSS_API_BASE_URL_SANDBOX: "   ",
  });
  assertFalse(result.ok);
});

Deno.test("resolveTossApiBase: does not fall back across referrers", () => {
  // SANDBOX 요청인데 DEFAULT만 설정돼 있으면 실패해야 한다 (추측 금지).
  const result = resolveTossApiBase("SANDBOX", {
    TOSS_API_BASE_URL_DEFAULT: "https://api.toss.example",
  });
  assertFalse(result.ok);
});

// ---------------------------------------------------------------------------
// syntheticEmailFor
// ---------------------------------------------------------------------------

Deno.test("syntheticEmailFor: builds toss- prefixed local.planflow email", () => {
  const email = syntheticEmailFor("abc123");
  assertEquals(email, "toss-abc123@users.planflow.local");
});

Deno.test("syntheticEmailFor: lowercases the key", () => {
  const email = syntheticEmailFor("ABC123XYZ");
  assertEquals(email, "toss-abc123xyz@users.planflow.local");
});

Deno.test("syntheticEmailFor: strips disallowed characters", () => {
  const email = syntheticEmailFor("abc!123@#$xyz");
  assertEquals(email, "toss-abc123xyz@users.planflow.local");
});

Deno.test("syntheticEmailFor: is deterministic for the same key", () => {
  const first = syntheticEmailFor("stable-key-1");
  const second = syntheticEmailFor("stable-key-1");
  assertEquals(first, second);
});

Deno.test("syntheticEmailFor: different keys produce different emails", () => {
  const a = syntheticEmailFor("user-a");
  const b = syntheticEmailFor("user-b");
  assert(a !== b);
});

// ---------------------------------------------------------------------------
// supportsMtls
// ---------------------------------------------------------------------------

Deno.test("supportsMtls: true when createHttpClient is a function", () => {
  const fakeDeno = { createHttpClient: () => ({}) };
  assert(supportsMtls(fakeDeno));
});

Deno.test("supportsMtls: false when createHttpClient is missing", () => {
  const fakeDeno = {};
  assertFalse(supportsMtls(fakeDeno));
});

Deno.test("supportsMtls: false when createHttpClient is not a function", () => {
  const fakeDeno = { createHttpClient: "not-a-function" };
  assertFalse(supportsMtls(fakeDeno));
});

Deno.test("supportsMtls: false for null input", () => {
  assertFalse(supportsMtls(null));
});

Deno.test("supportsMtls: false for undefined input", () => {
  assertFalse(supportsMtls(undefined));
});

Deno.test("supportsMtls: false for primitive input", () => {
  assertFalse(supportsMtls("Deno"));
});

Deno.test("supportsMtls: has no side effects (does not call the function)", () => {
  let called = false;
  const fakeDeno = {
    createHttpClient: () => {
      called = true;
      return {};
    },
  };
  supportsMtls(fakeDeno);
  assertFalse(called);
});

// ---------------------------------------------------------------------------
// TOSS_LOGIN_ERROR_CODES
// ---------------------------------------------------------------------------

Deno.test("TOSS_LOGIN_ERROR_CODES: exposes all expected error codes", () => {
  assertEquals(TOSS_LOGIN_ERROR_CODES.INVALID_REQUEST, "invalid_request");
  assertEquals(
    TOSS_LOGIN_ERROR_CODES.TOSS_API_BASE_NOT_CONFIGURED,
    "toss_api_base_not_configured",
  );
  assertEquals(TOSS_LOGIN_ERROR_CODES.MTLS_UNSUPPORTED, "mtls_unsupported");
  assertEquals(
    TOSS_LOGIN_ERROR_CODES.TOSS_TOKEN_EXCHANGE_FAILED,
    "toss_token_exchange_failed",
  );
  assertEquals(
    TOSS_LOGIN_ERROR_CODES.TOSS_USERINFO_FAILED,
    "toss_userinfo_failed",
  );
  assertEquals(
    TOSS_LOGIN_ERROR_CODES.IDENTITY_LINK_FAILED,
    "identity_link_failed",
  );
  assertEquals(
    TOSS_LOGIN_ERROR_CODES.SESSION_ISSUE_FAILED,
    "session_issue_failed",
  );
  assertEquals(
    TOSS_LOGIN_ERROR_CODES.SERVER_MISCONFIGURED,
    "server_misconfigured",
  );
});
