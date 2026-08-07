import { describe, expect, it } from "vitest";
import { scanContent } from "./scan-bundle.mjs";

/**
 * Regression test for the quote-pairing desync bug.
 *
 * Before the fix, scan-bundle.mjs first extracted string-literal contents
 * with a quote-pairing regex (`/"((?:[^"\\]|\\.)*)"|'...'|\`...\`/g`) and
 * only ran the long-token (hex/base64) heuristic on the extracted text. On
 * a large, single-line minified bundle — exactly what a real production
 * build produces — a single quote-imbalance anywhere earlier in the line
 * (e.g. an escaped quote inside a template-literal `${...}` expression, or
 * a quote character inside a regex literal) shifts or drops every
 * string-literal match for the rest of the line, including the one holding
 * the actual secret. This was reproduced directly against a real `vite
 * build` bundle: a JWT-shaped secret was NOT flagged inside a 70KB+
 * single-line minified chunk, while the same secret WAS flagged in a small
 * hand-written file.
 *
 * The fix removes the quote-pairing/string-extraction step entirely and
 * runs the token patterns directly against the raw line text. These fixture
 * tests simulate the failure condition (a long single "minified" line with
 * quote-desyncing constructs before the secret) without requiring an actual
 * build.
 */
describe("scanContent — long-token (hex/base64) secret detection", () => {
  it("flags a raw (non-JWT-shaped) secret embedded in a large single-line minified bundle, even after quote-desyncing constructs", () => {
    // A digit-dense base64-looking secret (NOT dot-separated, so it can't
    // be classified as a JWT and safe-listed — see the dedicated JWT tests
    // below for that path). 40+ chars, base64 alphabet, digit-dense.
    const secret = "SflKxwRJ9012SMeKKF2QT4fwpMeJf36POk6yJV345adQssw5c";

    // Simulate a real minified bundle: lots of concatenated code on ONE
    // line, including constructs that desync naive quote-pairing regexes —
    // a template literal with an interpolated expression containing a
    // nested quote, and a regex literal containing a quote character —
    // BEFORE the secret appears later in the same line.
    const minifiedLine =
      `function a(e){return e}const b=\`prefix-\${e.x?"y":'z'}-suffix\`;` +
      `const re=/[a-z"]+/g;` +
      `var SESSION_TOKEN="${secret}";` +
      `function c(t){return t.map(x=>x*2)}`;

    const findings = scanContent(minifiedLine, "dist/assets/index-abc123.js");

    const tokenFindings = findings.filter((f) => f.label.includes("hex/base64"));
    expect(tokenFindings.length).toBeGreaterThan(0);
    const flaggedTheSecret = tokenFindings.some((f) => f.snippet.includes(secret));
    expect(flaggedTheSecret).toBe(true);
  });

  it("flags a raw 32+ char hex token in a large minified line", () => {
    const hexSecret = "a".repeat(20) + "1234567890abcdef"; // 36 hex chars total, digit-dense
    const minifiedLine = `const x=1;var API_KEY="${hexSecret}";function y(){return x}`;

    const findings = scanContent(minifiedLine, "dist/assets/index-def456.js");
    const tokenFindings = findings.filter((f) => f.label.includes("hex/base64"));
    expect(tokenFindings.length).toBeGreaterThan(0);
    expect(tokenFindings.some((f) => f.snippet.includes(hexSecret))).toBe(true);
  });

  it("does not flag a clean minified bundle line with no secrets", () => {
    // Realistic-looking minified code: camelCase identifiers, no
    // digit-dense base64/hex runs of 32+ chars.
    const cleanLine =
      "function App(){const[e,t]=useState(null);useEffect(()=>{fetchData().then(t)},[]);" +
      "return React.createElement(Provider,{value:e},React.createElement(Router,null))}" +
      "export{App as default,useState as u,useEffect as v};";

    const findings = scanContent(cleanLine, "dist/assets/index-clean.js");
    expect(findings).toEqual([]);
  });

  it("still flags service_role and eval( markers regardless of line length", () => {
    const line =
      "x".repeat(500) +
      'const client=createClient(url,"service_role-key-here");eval("1+1")' +
      "y".repeat(500);

    const findings = scanContent(line, "dist/assets/index-markers.js");
    expect(findings.some((f) => f.label.includes("service_role"))).toBe(true);
    expect(findings.some((f) => f.label.includes("eval("))).toBe(true);
  });

  it("does not flag a long run of a single repeated character (false-positive suppression)", () => {
    const line = `const filler="${"a".repeat(50)}";`;
    const findings = scanContent(line, "dist/assets/index-filler.js");
    expect(findings).toEqual([]);
  });

  it("does not flag a base64/base64url alphabet lookup table constant (observed in supabase-js's own base64 codec)", () => {
    // Exactly the 64-char base64url alphabet, no repeated characters —
    // observed directly in a real `npm run build` output.
    const alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const line = `const vc=\`${alphabet}\`.split(\`\`);`;
    const findings = scanContent(line, "dist/assets/index-alphabet.js");
    expect(findings).toEqual([]);
  });

  it("does not flag a URL path fragment with multiple slashes caught mid-string (e.g. a sourcemap/comment URL)", () => {
    // Observed directly in a real `npm run build` output: a GitHub
    // discussion URL embedded in a library's error message / comment.
    // The leading "https://github." is broken up by the `.`, but the path
    // segment after it still matches the base64-alphabet character class.
    const line =
      "throw Error(`See https://github.com/orgs/supabase/discussions/45715 for details`)";
    const findings = scanContent(line, "dist/assets/index-url.js");
    expect(findings).toEqual([]);
  });

  it("still flags a real digit-dense base64 secret that happens to contain a single slash", () => {
    // Sanity check that the slash-based false-positive filter only
    // suppresses tokens with 2+ slashes, not any slash at all.
    const secret = "AbCdEf0123456789/AbCdEf0123456789AbCdEf01234567";
    const line = `const leaked="${secret}";`;
    const findings = scanContent(line, "dist/assets/index-oneslash.js");
    const tokenFindings = findings.filter((f) => f.label.includes("hex/base64"));
    expect(tokenFindings.some((f) => f.snippet.includes(secret))).toBe(true);
  });
});

/**
 * JWT role-aware detection.
 *
 * scan-bundle.mjs decodes JWT-shaped tokens (header.payload.signature) and
 * inspects the payload's `role` claim before ever handing them to the
 * generic long-token heuristic:
 *   - role === "service_role" -> hard failure (Supabase service-role key —
 *     full DB bypass, must never ship to a client bundle)
 *   - any other successfully-decoded JWT (role "anon", missing role, etc.)
 *     -> confirmed safe, e.g. a public Supabase anon key. Vite's VITE_
 *     prefix intentionally bundles this client-side; Supabase RLS is what
 *     protects it, not secrecy. A normal `npm run build` always embeds
 *     VITE_SUPABASE_ANON_KEY in dist/, so if the scanner flagged it, the
 *     gate would fail on every clean build.
 */
describe("scanContent — JWT role-aware detection", () => {
  // header: {"alg":"HS256","typ":"JWT"}
  const JWT_HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
  // A plausible signature segment (not cryptographically real, but
  // base64url-shaped like a real one — the scanner never validates the
  // signature, only the payload claims).
  const JWT_SIGNATURE = "AbCdEf0123456789AbCdEf0123456789AbCdEf01";

  // payload: {"iss":"supabase","ref":"xqvvfnvmytjlblcngipnabcd","role":"anon","iat":1700000000,"exp":2015576000}
  const ANON_PAYLOAD =
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhxdnZmbnZteXRqbGJsY25naXBuYWJjZCIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjIwMTU1NzYwMDB9";
  // payload: same but "role":"service_role"
  const SERVICE_ROLE_PAYLOAD =
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhxdnZmbnZteXRqbGJsY25naXBuYWJjZCIsInJvbGUiOiJzZXJ2aWNlX3JvbGUiLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAxNTU3NjAwMH0";

  const ANON_JWT = `${JWT_HEADER}.${ANON_PAYLOAD}.${JWT_SIGNATURE}`;
  const SERVICE_ROLE_JWT = `${JWT_HEADER}.${SERVICE_ROLE_PAYLOAD}.${JWT_SIGNATURE}`;

  it("does NOT flag a normal Supabase anon-key JWT (this is what every clean `npm run build` embeds via VITE_SUPABASE_ANON_KEY)", () => {
    const line = `const supabaseUrl="https://xqvv.supabase.co";const supabaseAnonKey="${ANON_JWT}";createClient(supabaseUrl,supabaseAnonKey);`;

    const findings = scanContent(line, "dist/assets/index-env.js");

    expect(findings).toEqual([]);
  });

  it("flags a service_role JWT (decoded payload role === \"service_role\") as a hard failure", () => {
    const line = `const leaked="${SERVICE_ROLE_JWT}";`;

    const findings = scanContent(line, "dist/assets/index-leak.js");

    const serviceRoleFindings = findings.filter((f) =>
      f.label.includes("service_role"),
    );
    expect(serviceRoleFindings.length).toBeGreaterThan(0);
    expect(
      serviceRoleFindings.some((f) => f.label.includes("JWT")),
    ).toBe(true);
  });

  it("still flags a bare \"service_role\" literal string even with no JWT present", () => {
    const line = `const roleName="service_role";`;

    const findings = scanContent(line, "dist/assets/index-literal.js");

    expect(
      findings.some(
        (f) => f.label.includes("service_role") && !f.label.includes("JWT"),
      ),
    ).toBe(true);
  });

  it("does not double-count an anon JWT's segments as separate hex/base64 long-token findings", () => {
    const line = `var k="${ANON_JWT}";`;
    const findings = scanContent(line, "dist/assets/index-anon-nolongtoken.js");
    const tokenFindings = findings.filter((f) => f.label.includes("hex/base64"));
    expect(tokenFindings).toEqual([]);
  });

  it("falls through to the generic long-token heuristic for a non-decodable, JWT-shaped (three dot-separated segments) string", () => {
    // Looks like a JWT (three dot-separated base64url-alphabet segments)
    // but the middle segment does not decode to valid JSON, so it isn't
    // classified as a JWT and must still be caught by the generic
    // hex/base64 heuristic as an opaque possible secret.
    const notReallyAJwt =
      "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVoxMjM0NTY3ODkw.bm90LXZhbGlkLWpzb24tcGF5bG9hZC1oZXJlLWJ1dC1sb25nMTIzNA.QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVoxMjM0NTY3ODkw";
    const line = `const x="${notReallyAJwt}";`;

    const findings = scanContent(line, "dist/assets/index-notjwt.js");

    expect(findings.some((f) => f.label.includes("hex/base64"))).toBe(true);
  });
});

/**
 * P11: test-mode ad group id (`ait-ad-test-*`, from `TEST_AD_GROUP_IDS` in
 * src/features/ads/adConfig.ts) detection.
 *
 * resolveAdGroupIds() is only supposed to select these when
 * `import.meta.env.DEV` is true, which Vite folds to a literal `false` in a
 * production build — the same build-time constant-folding mechanism the
 * devPreview gate (import.meta.env leak check above) relies on. If one of
 * the 4 known test ad ids shows up in dist/, that folding didn't happen for
 * this call site and production traffic could request test ad inventory
 * instead of real ads.
 */
describe("scanContent — test-mode ad group id detection (P11)", () => {
  const KNOWN_TEST_AD_IDS = [
    "ait-ad-test-interstitial-id",
    "ait-ad-test-rewarded-id",
    "ait-ad-test-banner-id",
    "ait-ad-test-native-image-id",
  ];

  it.each(KNOWN_TEST_AD_IDS)(
    "flags %s if it appears in dist/ output",
    (testAdId) => {
      const line = `var groupId="${testAdId}";callAd(groupId);`;

      const findings = scanContent(line, "dist/assets/index-testad.js");

      const adFindings = findings.filter((f) =>
        f.label.includes("test-mode ad group id"),
      );
      expect(adFindings.length).toBeGreaterThan(0);
      expect(adFindings.some((f) => f.snippet.includes(testAdId))).toBe(true);
    },
  );

  it("flags a test ad id even embedded in a large single-line minified bundle", () => {
    const minifiedLine =
      `function a(e){return e}const b=\`prefix-\${e.x?"y":'z'}-suffix\`;` +
      `var GROUP="ait-ad-test-rewarded-id";function c(t){return t.map(x=>x*2)}`;

    const findings = scanContent(minifiedLine, "dist/assets/index-abc123.js");

    expect(
      findings.some((f) => f.label.includes("test-mode ad group id")),
    ).toBe(true);
  });

  it("does not flag a clean bundle line containing none of the known test-mode ad ids", () => {
    const line =
      "function App(){const[e,t]=useState(null);requestAd('production-banner');" +
      "return React.createElement(Provider,null)}";

    const findings = scanContent(line, "dist/assets/index-clean-ads.js");
    expect(
      findings.some((f) => f.label.includes("test-mode ad group id")),
    ).toBe(false);
  });

  it("does not false-positive on a similar-but-different ad id (different suffix, not just prefix match)", () => {
    const line = `var groupId="ait-ad-real-banner-id";callAd(groupId);`;

    const findings = scanContent(line, "dist/assets/index-real-banner.js");
    expect(
      findings.some((f) => f.label.includes("test-mode ad group id")),
    ).toBe(false);
  });

  it("does not false-positive on a truncated/partial test-id prefix that isn't one of the 4 exact known strings", () => {
    const line = `var groupId="ait-ad-test-unknown-suffix";callAd(groupId);`;

    const findings = scanContent(line, "dist/assets/index-partial.js");
    expect(
      findings.some((f) => f.label.includes("test-mode ad group id")),
    ).toBe(false);
  });
});
