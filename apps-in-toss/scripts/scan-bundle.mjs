#!/usr/bin/env node
/**
 * scan-bundle.mjs
 *
 * Scans the built `dist/` output for leaked secrets before it ships to
 * Apps in Toss. Fails the build (exit 1) if it finds:
 *   - a JWT whose decoded payload has role === "service_role" (Supabase
 *     service-role key — full DB bypass; see scanJwts() below)
 *   - the literal string "service_role" (Supabase service-role key marker)
 *   - "eval(" (also disallowed by the Apps in Toss review checklist)
 *   - "PLANFLOW_DEV_PREVIEW_ENABLED" (src/features/devPreview/'s dev-only
 *     preview mode marker — presence in a production bundle means the
 *     import.meta.env.DEV-gated dev-preview code path/module wasn't fully
 *     tree-shaken out, so this scanner treats it as a build failure to
 *     make that leak impossible to miss)
 *   - long hex/base64-looking tokens (32+ chars) that look like raw secrets
 *     and aren't part of a confirmed-safe JWT (e.g. a public Supabase
 *     "anon" key, which Vite's VITE_ prefix intentionally bundles
 *     client-side — RLS protects it, not secrecy)
 *
 * Usage: node scripts/scan-bundle.mjs
 * Exit code 0 = clean, 1 = findings, 2 = dist/ missing.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, extname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const projectRoot = join(__dirname, "..");
const distDir = join(projectRoot, "dist");

const SCAN_EXTENSIONS = new Set([".js", ".html", ".mjs", ".cjs"]);

/**
 * Line-scope rules: applied to the full line, anywhere in the file
 * (not just inside string literals) because these markers are meaningful
 * regardless of surrounding syntax.
 * @type {{ pattern: RegExp, label: string }[]}
 */
const LINE_RULES = [
  {
    label: "service_role string found (Supabase service-role key marker)",
    pattern: /service_role/g,
  },
  {
    label: "eval( call found (disallowed dynamic code execution)",
    pattern: /eval\(/g,
  },
  {
    label:
      "PLANFLOW_DEV_PREVIEW_ENABLED marker found (dev-only preview mode leaked into production bundle — see src/features/devPreview/devPreview.ts)",
    pattern: /PLANFLOW_DEV_PREVIEW_ENABLED/g,
  },
];

/**
 * JWT-shaped tokens (header.payload.signature, each segment base64url) get
 * decoded and classified by their payload's `role` claim before the generic
 * long-token heuristic below ever sees them:
 *   - role === "service_role"        -> hard failure (Supabase service-role
 *                                        key; full DB bypass, must never
 *                                        ship to a client bundle)
 *   - decodes to JSON, any other role
 *     (e.g. "anon"), missing role, or
 *     any other value                -> confirmed safe (a real, inspected
 *                                        JWT — most commonly a public
 *                                        Supabase anon key, which Vite's
 *                                        VITE_ prefix intentionally bundles
 *                                        client-side and which RLS is
 *                                        responsible for protecting)
 *   - doesn't decode to JSON at all   -> not actually a JWT; left alone
 *                                        here and falls through to the
 *                                        generic long-token heuristic like
 *                                        any other opaque token
 *
 * A confirmed-safe JWT's character range is excluded from the generic
 * hex/base64 long-token scan below, so its three base64 segments (each
 * individually 32+ chars) don't also get flagged as "possible raw secrets".
 */
const SERVICE_ROLE_JWT_LABEL =
  "service_role JWT found (Supabase service-role key — full DB bypass, must not ship to client bundle)";

const JWT_PATTERN = /[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}/g;

/**
 * Decodes a base64url string (JWT segments omit `=` padding) to a utf8
 * string. Returns null if the segment can't be a valid base64 length.
 * @param {string} segment
 * @returns {string | null}
 */
function decodeBase64Url(segment) {
  let b64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  const remainder = b64.length % 4;
  if (remainder === 1) return null; // impossible base64 length
  if (remainder === 2) b64 += "==";
  else if (remainder === 3) b64 += "=";
  try {
    return Buffer.from(b64, "base64").toString("utf8");
  } catch {
    return null;
  }
}

/**
 * Attempts to decode a JWT payload segment and parse it as a JSON object.
 * Returns the parsed object, or null if the segment isn't a decodable JSON
 * object payload — i.e. it's not really a JWT, just three dot-separated
 * tokens that happen to look like one (e.g. `React.Component.prototype`).
 * @param {string} segment
 * @returns {Record<string, unknown> | null}
 */
function decodeJwtPayload(segment) {
  const decoded = decodeBase64Url(segment);
  if (decoded == null) return null;
  try {
    const parsed = JSON.parse(decoded);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed;
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Finds JWT-shaped tokens in a line, decodes+classifies each one, and
 * returns any service_role findings plus the character ranges of
 * confirmed-safe JWTs (to exclude from the generic long-token heuristic).
 * @param {string} lineText
 * @returns {{ findings: { label: string, snippet: string }[], safeRanges: [number, number][] }}
 */
function scanJwts(lineText) {
  /** @type {{ label: string, snippet: string }[]} */
  const findings = [];
  /** @type {[number, number][]} */
  const safeRanges = [];

  JWT_PATTERN.lastIndex = 0;
  let m;
  while ((m = JWT_PATTERN.exec(lineText)) !== null) {
    const full = m[0];
    const start = m.index;
    const end = start + full.length;
    const segments = full.split(".");
    if (segments.length === 3) {
      const payload = decodeJwtPayload(segments[1]);
      if (payload) {
        // Successfully decoded to a JSON object -> this is a real JWT.
        // Exclude its range from the generic long-token scan regardless
        // of role (we've actually inspected it, so it's not an opaque
        // "possible secret" anymore).
        safeRanges.push([start, end]);
        if (payload.role === "service_role") {
          findings.push({
            label: SERVICE_ROLE_JWT_LABEL,
            snippet: full.slice(0, 160),
          });
        }
      }
    }
    if (m.index === JWT_PATTERN.lastIndex) JWT_PATTERN.lastIndex++;
  }

  return { findings, safeRanges };
}

/**
 * True if [start, end) falls entirely inside one of the given ranges.
 * @param {number} start
 * @param {number} end
 * @param {[number, number][]} ranges
 */
function isWithinSafeRange(start, end, ranges) {
  return ranges.some(([s, e]) => start >= s && end <= e);
}

/**
 * A "long hex/base64-looking token" heuristic, applied directly to the raw
 * line text (NOT scoped to string-literal contents via quote-pairing).
 *
 * Earlier versions of this scanner tried to first extract string-literal
 * contents with a quote-pairing regex
 * (`/"((?:[^"\\]|\\.)*)"|'...'|`...`/g`) and only ran the long-token
 * heuristic on that extracted text. That approach silently desyncs on real
 * production bundles: a single production build minifies the entire app
 * into one 70KB+ line, and if that line contains even one place where the
 * naive quote-pairing regex miscounts a quote (escaped quotes inside
 * template-literal `${...}` expressions, regex literals containing quote
 * characters, or just backtracking giving up partway through a huge line),
 * every string-literal match after that point in the line is shifted or
 * dropped entirely — including the one holding the actual secret. This was
 * reproduced directly: a JWT-shaped secret placed in a large minified
 * single-line bundle was NOT flagged, while the same secret in a small
 * hand-written file WAS flagged.
 *
 * Fix: don't try to reconstruct "what's inside a string literal" at all.
 * Run the token patterns directly against the full line text. This can't
 * desync because there's no quote-state to track — every hex/base64-looking
 * run of 32+ chars anywhere on the line is found, regardless of what
 * surrounds it. It trades a bit of specificity (a token embedded in a
 * non-string context, e.g. a very long minified identifier, could in theory
 * match) for guaranteed detection, which is the correct tradeoff for a
 * fail-closed secret scanner — see looksLikeFalsePositive() and the digit
 * threshold below for the (deliberately narrow) false-positive suppression.
 *
 * A token qualifies if:
 *   - it's 32+ hex chars (0-9a-fA-F only), OR
 *   - it's 32+ base64-alphabet chars AND contains at least 4 digits
 *     (real secrets/API keys/JWT segments are digit-dense; long runs of
 *     camelCase identifiers concatenated in string literals — e.g. an
 *     exported symbol list — are not, so this keeps false positives down
 *     without needing a full entropy calculation).
 */
const HEX_TOKEN_PATTERN = /\b[0-9a-fA-F]{32,}\b/g;
const BASE64_TOKEN_PATTERN = /[A-Za-z0-9+/_-]{32,}={0,2}/g;

const LONG_TOKEN_LABEL =
  "long hex/base64-looking token found (possible raw secret, 32+ chars)";

/**
 * Recursively collects files under a directory.
 * @param {string} dir
 * @returns {string[]}
 */
function collectFiles(dir) {
  /** @type {string[]} */
  const results = [];
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return results;
  }
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...collectFiles(fullPath));
    } else if (entry.isFile()) {
      results.push(fullPath);
    }
  }
  return results;
}

/**
 * Returns true if the matched token looks like a legitimate non-secret
 * (e.g. a content hash in a filename reference, a long identifier made of a
 * single repeated character, or a well-known non-secret constant). This
 * keeps the heuristic from being *completely* unusable, while staying
 * fail-closed by default (only excludes a narrow set of obvious false
 * positives observed in real production bundles).
 * @param {string} token
 */
function looksLikeFalsePositive(token) {
  // All the same character repeated (e.g. filler chars, not a real secret)
  if (/^(.)\1+$/.test(token)) return true;

  // Every character in the token is distinct (no repeats at all). Real
  // random secrets 32+ chars long drawn from a <=64-symbol alphabet are, by
  // the birthday paradox, astronomically unlikely to have zero repeated
  // characters — a hex token (16-symbol alphabet) can't even be 32 chars
  // with no repeats (pigeonhole). A token with zero repeats is almost
  // always a literal enumerated character set baked into a library, e.g.
  // the base64/base64url alphabet lookup table used internally by
  // supabase-js's own base64 encoder/decoder implementation (observed
  // directly in a real production bundle: "ABCDEFGHIJ...xyz0123456789-_",
  // 64 unique chars) — not a secret.
  if (new Set(token).size === token.length) return true;

  // Two or more `/` characters. `/` is a valid base64 alphabet character,
  // so it's not excluded outright, but a token with multiple slashes is far
  // more likely to be a URL path fragment caught mid-string (e.g. a
  // sourcemap comment linking to a GitHub discussion,
  // ".../orgs/supabase/discussions/45715" — observed directly in a real
  // production bundle) than a genuine base64 secret, which essentially
  // never contains multiple literal `/` characters in practice.
  if ((token.match(/\//g) || []).length >= 2) return true;

  return false;
}

/** Counts digit characters in a string. */
function digitCount(str) {
  const matches = str.match(/[0-9]/g);
  return matches ? matches.length : 0;
}

/**
 * Runs the long-token (hex/base64) heuristic directly against a line of raw
 * text (no quote-pairing / string-extraction step — see the comment above
 * HEX_TOKEN_PATTERN for why) and returns any qualifying tokens, with their
 * character positions (so callers can exclude ranges already confirmed safe
 * by scanJwts()).
 * @param {string} lineText
 * @returns {{ token: string, start: number, end: number }[]}
 */
function findLongTokens(lineText) {
  /** @type {{ token: string, start: number, end: number }[]} */
  const tokens = [];

  HEX_TOKEN_PATTERN.lastIndex = 0;
  let m;
  while ((m = HEX_TOKEN_PATTERN.exec(lineText)) !== null) {
    tokens.push({ token: m[0], start: m.index, end: m.index + m[0].length });
    if (m.index === HEX_TOKEN_PATTERN.lastIndex) HEX_TOKEN_PATTERN.lastIndex++;
  }

  BASE64_TOKEN_PATTERN.lastIndex = 0;
  while ((m = BASE64_TOKEN_PATTERN.exec(lineText)) !== null) {
    const token = m[0];
    if (digitCount(token) >= 4) {
      tokens.push({ token, start: m.index, end: m.index + token.length });
    }
    if (m.index === BASE64_TOKEN_PATTERN.lastIndex) BASE64_TOKEN_PATTERN.lastIndex++;
  }

  return tokens;
}

/**
 * Scans a single file's text content for secret-shaped findings. Pure
 * function (no fs access, no process.exit) so it can be unit-tested
 * directly against fixture strings — including large single-line
 * "minified bundle" fixtures — without needing a real `dist/` build.
 *
 * @param {string} content
 * @param {string} fileLabel label used for `file` on findings (e.g. a
 *   relative path); tests can pass anything, e.g. "fixture.js"
 * @returns {{ file: string, line: number, label: string, snippet: string }[]}
 */
export function scanContent(content, fileLabel) {
  /** @type {{ file: string, line: number, label: string, snippet: string }[]} */
  const findings = [];

  const lines = content.split(/\r?\n/);

  lines.forEach((lineText, idx) => {
    // Line-scope rules (service_role, eval().
    for (const rule of LINE_RULES) {
      rule.pattern.lastIndex = 0;
      let match;
      while ((match = rule.pattern.exec(lineText)) !== null) {
        findings.push({
          file: fileLabel,
          line: idx + 1,
          label: rule.label,
          snippet: lineText.trim().slice(0, 160),
        });
        if (match.index === rule.pattern.lastIndex) {
          rule.pattern.lastIndex++;
        }
      }
    }

    // JWT-shaped tokens (header.payload.signature) are decoded and
    // classified by their payload's `role` claim — service_role is a hard
    // failure, everything else that decodes cleanly (anon, missing role,
    // etc.) is confirmed safe and excluded from the generic long-token scan
    // below. See scanJwts() for why.
    const { findings: jwtFindings, safeRanges } = scanJwts(lineText);
    for (const jf of jwtFindings) {
      findings.push({
        file: fileLabel,
        line: idx + 1,
        label: jf.label,
        snippet: jf.snippet,
      });
    }

    // Long-token rule, applied directly to the raw line text (no
    // quote-pairing / string-extraction step — see comment above
    // HEX_TOKEN_PATTERN for why that approach was removed). Tokens that
    // fall entirely inside a confirmed-safe JWT range (above) are skipped —
    // they're not opaque "possible secrets" anymore, they're inspected JWT
    // segments.
    if (lineText.length >= 32) {
      const tokens = findLongTokens(lineText).filter(
        ({ token, start, end }) =>
          !looksLikeFalsePositive(token) &&
          !isWithinSafeRange(start, end, safeRanges),
      );
      for (const { token } of tokens) {
        findings.push({
          file: fileLabel,
          line: idx + 1,
          label: LONG_TOKEN_LABEL,
          snippet: token.slice(0, 160),
        });
      }
    }
  });

  return findings;
}

function main() {
  let distStat;
  try {
    distStat = statSync(distDir);
  } catch {
    console.error(
      `[scan-bundle] dist/ not found at ${distDir}. Run "npm run build" first.`,
    );
    process.exit(2);
  }
  if (!distStat.isDirectory()) {
    console.error(`[scan-bundle] ${distDir} is not a directory.`);
    process.exit(2);
  }

  const files = collectFiles(distDir).filter((file) =>
    SCAN_EXTENSIONS.has(extname(file).toLowerCase()),
  );

  /** @type {{ file: string, line: number, label: string, snippet: string }[]} */
  const findings = [];

  for (const file of files) {
    let content;
    try {
      content = readFileSync(file, "utf8");
    } catch (err) {
      console.error(`[scan-bundle] Could not read ${file}: ${err}`);
      continue;
    }

    findings.push(...scanContent(content, relative(projectRoot, file)));
  }

  if (findings.length > 0) {
    console.error(
      `[scan-bundle] FAILED — found ${findings.length} potential secret leak(s) in dist/:\n`,
    );
    for (const f of findings) {
      console.error(`  ${f.file}:${f.line} — ${f.label}`);
      console.error(`    ${f.snippet}`);
    }
    process.exit(1);
  }

  console.log(
    `[scan-bundle] OK — scanned ${files.length} file(s) in dist/, no secrets found.`,
  );
  process.exit(0);
}

// Only run when executed directly (`node scripts/scan-bundle.mjs`), not
// when imported by tests.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
