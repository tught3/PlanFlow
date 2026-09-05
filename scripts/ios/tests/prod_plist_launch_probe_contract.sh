#!/usr/bin/env bash
# Static, macOS-independent contract checks for
# scripts/ios/prod_plist_launch_probe.sh.
#
# This probe exists specifically to observe the REAL, unmodified production
# ios/Runner/Info.plist (see prod_plist_launch_probe.sh's own header comment
# for the full R1 motivation). Its entire value depends on never writing to
# that plist and never hardcoding a GAD Application ID that would make its
# build behave like the E2E-only injected-plist path
# (scripts/ios/e2e_xctest_flow.sh) instead. These checks are the safety net
# for that invariant, plus a couple of basic sanity checks (syntax, stage
# marker names actually present) that do not require macOS to run.
#
# Usage: bash scripts/ios/tests/prod_plist_launch_probe_contract.sh
# Exit code: 0 if every case passes, 1 if any case fails.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
probe_script="$script_dir/../prod_plist_launch_probe.sh"

pass_count=0
fail_count=0

pass() {
  echo "PASS: $1"
  pass_count=$((pass_count + 1))
}

fail() {
  echo "FAIL: $1"
  fail_count=$((fail_count + 1))
}

if [ ! -f "$probe_script" ]; then
  echo "prod_plist_launch_probe_contract.sh: cannot find prod_plist_launch_probe.sh at $probe_script" >&2
  exit 1
fi

probe_text="$(cat "$probe_script")"

echo "=== prod_plist_launch_probe.sh contract checks ==="
echo ""

# --- 1. The probe must never contain a PlistBuddy write command ------------
# `Set :Key` and `Add :Key <type> <value>` are PlistBuddy's only two mutating
# verbs (the third, `Delete`, is also checked for completeness even though
# this probe has no reason to delete a key either). `Print` (read-only) is
# explicitly allowed and NOT checked for here.
if printf '%s' "$probe_text" | grep -qE -- '/usr/libexec/PlistBuddy[^\n]*-c[^\n]*"(Set|Add|Delete) :'; then
  fail "probe script contains a PlistBuddy write command (Set/Add/Delete)"
else
  pass "probe script contains no PlistBuddy write command"
fi

# Belt-and-suspenders: also reject any literal invocation of the PlistBuddy
# binary itself (its full path, as any real invocation must use), since a
# read-only Print call has no legitimate reason to exist in a script whose
# only interaction with the plist file should be "read it via a normal
# build", not "inspect a specific key via PlistBuddy". This deliberately
# checks the binary PATH, not the bare word "PlistBuddy", so this script's own
# explanatory comments (which reference the word without invoking the binary)
# do not trip a false failure.
if printf '%s' "$probe_text" | grep -qF -- '/usr/libexec/PlistBuddy'; then
  fail "probe script invokes the PlistBuddy binary at all; it must only read the plist implicitly via the normal build"
else
  pass "probe script never invokes the PlistBuddy binary"
fi

# --- 2. No GAD Application ID literal anywhere in the probe -----------------
# Matches the "ca-app-pub-<publisher>~<app>" shape used by both the official
# Google sample IDs (scripts/ios/e2e_xctest_flow.sh, e2e_admob_contract.sh)
# and any real production ID. This probe must observe whatever the committed
# plist already has -- or does not have -- never supply its own.
if printf '%s' "$probe_text" | grep -qE -- 'ca-app-pub-[0-9]+~[0-9]+'; then
  fail "probe script contains a GAD Application ID literal"
else
  pass "probe script contains no GAD Application ID literal"
fi

# --- 3. The probe must not write to ios/Runner/Info.plist at all -----------
# Complementary to check 1: guards against a future edit that mutates the
# plist through some other mechanism (sed/plutil/cp over the original path)
# instead of PlistBuddy. `cp -p -- "$runner_plist" ...` (reading FROM the
# plist, as a backup source) is fine; writing back TO $runner_plist is not.
if printf '%s' "$probe_text" | grep -qE -- '(plutil|sed)[^\n]*"?\$runner_plist"?'; then
  fail "probe script appears to write to \$runner_plist via plutil/sed"
else
  pass "probe script has no plutil/sed write path targeting \$runner_plist"
fi
if printf '%s' "$probe_text" | grep -qE -- '>[[:space:]]*"?\$runner_plist"?'; then
  fail "probe script appears to redirect output into \$runner_plist"
else
  pass "probe script never redirects output into \$runner_plist"
fi

# --- 4. Shell syntax is valid --------------------------------------------------
if bash -n "$probe_script" 2>/tmp/prod_plist_probe_syntax_err.$$; then
  pass "probe script passes bash -n syntax check"
else
  fail "probe script failed bash -n syntax check: $(cat /tmp/prod_plist_probe_syntax_err.$$ 2>/dev/null)"
fi
rm -f -- "/tmp/prod_plist_probe_syntax_err.$$" 2>/dev/null || true

# --- 5. Both required stage marker names are actually present --------------
if printf '%s' "$probe_text" | grep -qF -- 'PROD_PLIST_APP_ALIVE'; then
  pass "probe script defines the PROD_PLIST_APP_ALIVE stage marker"
else
  fail "probe script is missing the PROD_PLIST_APP_ALIVE stage marker"
fi
if printf '%s' "$probe_text" | grep -qF -- 'PROD_PLIST_NO_CRASH'; then
  pass "probe script defines the PROD_PLIST_NO_CRASH stage marker"
else
  fail "probe script is missing the PROD_PLIST_NO_CRASH stage marker"
fi

echo ""
echo "=== Results: $pass_count passed, $fail_count failed ==="

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
