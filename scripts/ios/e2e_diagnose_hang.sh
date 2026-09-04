#!/usr/bin/env bash
# On-timeout diagnostic dump for the iOS Simulator E2E hang.
#
# `flutter test integration_test/*.dart -d <UDID>` has been observed going
# completely silent immediately after the Xcode build finishes and then
# staying that way until the GitHub job-level hard timeout tears the runner
# down - leaving no evidence behind. This script is meant to be invoked at the
# moment scripts/ios/e2e_watchdog.sh reports a timeout (exit code 124), while
# the simulator is still up, to capture what the state actually was.
#
# Usage: e2e_diagnose_hang.sh <udid> <output_dir>
#   udid:       simulator device UDID (from `xcrun simctl list devices`)
#   output_dir: directory to write diagnostic files into (created if absent)
#
# This script is BEST-EFFORT by design and always exits 0. Every capture step
# is independently guarded, so one failing step neither aborts the others nor
# turns into a second, confusing failure on top of the real one. Per-step
# outcomes are recorded in <output_dir>/diagnose_manifest.txt.
#
# SECRET SAFETY (the most important property of this script):
#   - The environment is NEVER dumped. No `env`, no `printenv`, no `export -p`.
#   - Process listings are piped through mask_secrets() before being written,
#     because the flow05 auth leg passes a real (non-production) Supabase
#     credential as a `--dart-define`, which appears verbatim in the child
#     process command line and would otherwise land in an uploaded artifact.
#     GitHub Actions secret-masking does not cover artifact file contents.
#   - Simulator log output is masked the same way, since app logs are not a
#     trusted-to-be-clean source either.
# Masking is deliberately over-broad: losing a bit of diagnostic detail is an
# acceptable price for not leaking a credential into a build artifact.

set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <udid> <output_dir>" >&2
  exit 1
fi

udid="$1"
output_dir="$2"

if [ -z "$udid" ]; then
  echo "::error title=BLOCKED_MISSING_UDID::A simulator UDID is required" >&2
  exit 1
fi

if [ -z "$output_dir" ]; then
  echo "::error title=BLOCKED_MISSING_OUTPUT_DIR::An output directory is required" >&2
  exit 1
fi

if ! mkdir -p "$output_dir" 2>/dev/null; then
  echo "::error title=BLOCKED_OUTPUT_DIR_UNWRITABLE::Could not create output directory '${output_dir}'" >&2
  exit 1
fi

readonly MANIFEST="${output_dir}/diagnose_manifest.txt"

# Whole-second upper bounds for each capture, so the diagnostic dump can never
# itself become the thing that hangs the job.
readonly LOG_SHOW_TIMEOUT_SECONDS=120
readonly PS_TIMEOUT_SECONDS=30
readonly SIMCTL_DIAGNOSE_TIMEOUT_SECONDS=180

# Window of simulator log history to pull back. Kept short on purpose: the
# hang is observed right after the build step, so recent history is what
# matters, and an unbounded window makes `log show` itself slow.
readonly LOG_SHOW_WINDOW='10m'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
watchdog="${script_dir}/e2e_watchdog.sh"
mask_secrets_lib="${script_dir}/e2e_mask_secrets.sh"

note() {
  echo "[STEP] $*"
  echo "$*" >>"$MANIFEST"
}

# Run a command under the shared watchdog when it is available, so a wedged
# capture is bounded too. Falls back to running it unbounded rather than
# skipping the capture entirely.
run_bounded() {
  local seconds="$1"
  shift
  if [ -f "$watchdog" ]; then
    bash "$watchdog" "$seconds" "$@"
  else
    "$@"
  fi
}

# mask_secrets() lives in e2e_mask_secrets.sh, shared with other iOS E2E
# diagnostic scripts. Sourcing is REQUIRED, not best-effort: if the shared
# module cannot be loaded, mask_secrets is undefined and every capture step
# below must be skipped rather than silently writing unmasked output
# (fail-closed - see mask_secrets_available guard used by each step).
mask_secrets_available=0
if [ -f "$mask_secrets_lib" ] && source "$mask_secrets_lib" 2>/dev/null; then
  mask_secrets_available=1
fi

{
  echo "# iOS Simulator E2E hang diagnostics"
  echo "udid: ${udid}"
  echo "captured_at_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'unknown')"
  echo ""
} >"$MANIFEST"

# ---------------------------------------------------------------------------
# Step 1: process snapshot (portable - runs anywhere, so it is done first and
# is the one capture guaranteed to produce something even without Xcode).
# ---------------------------------------------------------------------------
ps_out="${output_dir}/processes.txt"
if [ "$mask_secrets_available" -ne 1 ]; then
  note "SKIP processes: mask_secrets unavailable (${mask_secrets_lib} missing or failed to source) - refusing to write unmasked process listing"
elif run_bounded "$PS_TIMEOUT_SECONDS" ps aux >"${ps_out}.raw" 2>/dev/null \
  || run_bounded "$PS_TIMEOUT_SECONDS" ps -ef >"${ps_out}.raw" 2>/dev/null; then
  grep -E 'flutter|xcodebuild|dart|Simulator|simctl|CoreSimulator|launchd_sim' "${ps_out}.raw" \
    | mask_secrets >"$ps_out" 2>/dev/null || true
  rm -f "${ps_out}.raw" 2>/dev/null || true
  # Report the match count rather than a bare OK: "captured successfully" and
  # "actually found relevant processes" are different facts, and a zero-match
  # snapshot is itself a meaningful signal when investigating a hang.
  ps_matches="$(wc -l <"$ps_out" 2>/dev/null | tr -d '[:space:]')"
  note "OK   processes -> $(basename "$ps_out") (masked, ${ps_matches:-0} matching lines)"
else
  rm -f "${ps_out}.raw" 2>/dev/null || true
  note "FAIL processes: could not capture a process listing"
fi

# ---------------------------------------------------------------------------
# Steps 2 and 3 are macOS-only (`xcrun`). Absence is reported, not fatal.
# ---------------------------------------------------------------------------
if ! command -v xcrun >/dev/null 2>&1; then
  note "SKIP simulator_log + simctl_diagnose: xcrun unavailable (requires macOS)"
  echo "[STEP] diagnostics written to ${output_dir}"
  exit 0
fi

# Step 2: recent simulator system log.
log_out="${output_dir}/simulator_log.txt"
if [ "$mask_secrets_available" -ne 1 ]; then
  note "SKIP simulator_log: mask_secrets unavailable (${mask_secrets_lib} missing or failed to source) - refusing to write unmasked simulator log"
elif run_bounded "$LOG_SHOW_TIMEOUT_SECONDS" \
    xcrun simctl spawn "$udid" log show --last "$LOG_SHOW_WINDOW" --style compact \
    2>"${log_out}.err" \
    | mask_secrets >"$log_out"; then
  note "OK   simulator_log (last ${LOG_SHOW_WINDOW}) -> $(basename "$log_out") (masked)"
else
  note "FAIL simulator_log: log show failed or exceeded ${LOG_SHOW_TIMEOUT_SECONDS}s (see simulator_log.txt.err)"
fi

# Step 3: full simctl diagnose bundle.
#
# Flags are kept minimal and the whole call is best-effort: exact `simctl
# diagnose` flag support varies by Xcode version, and this must not become a
# hard dependency of the diagnostic path.
diag_dir="${output_dir}/simctl_diagnose"
mkdir -p "$diag_dir" 2>/dev/null || true
if run_bounded "$SIMCTL_DIAGNOSE_TIMEOUT_SECONDS" \
    xcrun simctl diagnose -b --output "$diag_dir" \
    >"${diag_dir}.log" 2>&1; then
  note "OK   simctl_diagnose -> $(basename "$diag_dir")/"
else
  note "FAIL simctl_diagnose: failed or exceeded ${SIMCTL_DIAGNOSE_TIMEOUT_SECONDS}s (see simctl_diagnose.log)"
fi

echo "[STEP] diagnostics written to ${output_dir}"
exit 0
