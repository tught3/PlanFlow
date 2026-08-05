#!/usr/bin/env node
/**
 * scan-bundle.mjs
 *
 * Scans the built `dist/` output for leaked secrets before it ships to
 * Apps in Toss. Fails the build (exit 1) if it finds:
 *   - the literal string "service_role" (Supabase service-role key marker)
 *   - "eval(" (also disallowed by the Apps in Toss review checklist)
 *   - long hex/base64-looking tokens (32+ chars) that look like raw secrets
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
];

/**
 * Matches the contents of single/double-quoted or backtick string literals
 * on a line, so the long-token heuristic below only looks at actual string
 * data (not minified identifier soup like `Object.defineProperty,getOwn...`
 * which is long stretches of concatenated code, not a secret).
 * Does not attempt full JS string-escaping correctness — good enough for a
 * best-effort secret scan, not a JS parser.
 */
const STRING_LITERAL_PATTERN = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`((?:[^`\\]|\\.)*)`/g;

/**
 * A "long hex/base64-looking token" heuristic, scoped to string-literal
 * contents only. A token qualifies if:
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
  "long hex/base64-looking token found in a string literal (possible raw secret, 32+ chars)";

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
 * positives).
 * @param {string} token
 */
function looksLikeFalsePositive(token) {
  // All the same character repeated (e.g. filler chars, not a real secret)
  if (/^(.)\1+$/.test(token)) return true;
  return false;
}

/** Counts digit characters in a string. */
function digitCount(str) {
  const matches = str.match(/[0-9]/g);
  return matches ? matches.length : 0;
}

/**
 * Runs the long-token (hex/base64) heuristic against a single string
 * literal's contents and returns any qualifying tokens.
 * @param {string} literalContent
 * @returns {string[]}
 */
function findLongTokens(literalContent) {
  /** @type {string[]} */
  const tokens = [];

  HEX_TOKEN_PATTERN.lastIndex = 0;
  let m;
  while ((m = HEX_TOKEN_PATTERN.exec(literalContent)) !== null) {
    tokens.push(m[0]);
    if (m.index === HEX_TOKEN_PATTERN.lastIndex) HEX_TOKEN_PATTERN.lastIndex++;
  }

  BASE64_TOKEN_PATTERN.lastIndex = 0;
  while ((m = BASE64_TOKEN_PATTERN.exec(literalContent)) !== null) {
    const token = m[0];
    if (digitCount(token) >= 4) {
      tokens.push(token);
    }
    if (m.index === BASE64_TOKEN_PATTERN.lastIndex) BASE64_TOKEN_PATTERN.lastIndex++;
  }

  return tokens;
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

    const lines = content.split(/\r?\n/);

    lines.forEach((lineText, idx) => {
      // Line-scope rules (service_role, eval().
      for (const rule of LINE_RULES) {
        rule.pattern.lastIndex = 0;
        let match;
        while ((match = rule.pattern.exec(lineText)) !== null) {
          findings.push({
            file: relative(projectRoot, file),
            line: idx + 1,
            label: rule.label,
            snippet: lineText.trim().slice(0, 160),
          });
          if (match.index === rule.pattern.lastIndex) {
            rule.pattern.lastIndex++;
          }
        }
      }

      // Long-token rule, scoped to string literal contents only.
      STRING_LITERAL_PATTERN.lastIndex = 0;
      let literalMatch;
      while ((literalMatch = STRING_LITERAL_PATTERN.exec(lineText)) !== null) {
        const literalContent =
          literalMatch[1] ?? literalMatch[2] ?? literalMatch[3] ?? "";
        if (literalContent.length < 32) continue;
        const tokens = findLongTokens(literalContent).filter(
          (token) => !looksLikeFalsePositive(token),
        );
        for (const token of tokens) {
          findings.push({
            file: relative(projectRoot, file),
            line: idx + 1,
            label: LONG_TOKEN_LABEL,
            snippet: literalContent.slice(0, 160),
          });
        }
        if (literalMatch.index === STRING_LITERAL_PATTERN.lastIndex) {
          STRING_LITERAL_PATTERN.lastIndex++;
        }
      }
    });
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

main();
