#!/usr/bin/env bash
# Production-plist launch probe.
#
# Motivation (R1): lib/main.dart calls AdService.instance.initialize() with no
# platform branch, which on iOS reaches ad_service.dart's UMP ensureReady()
# and then MobileAds.instance.initialize(). The PRODUCTION ios/Runner/
# Info.plist deliberately has NO GADApplicationIdentifier key (enforced by
# scripts/ios/tests/e2e_admob_contract.sh's "production Runner Info.plist
# contains GADApplicationIdentifier" -> fail assertion). The Google Mobile Ads
# iOS SDK's documented behavior when that key is missing is a native crash
# that Dart try/catch cannot intercept.
#
# NONE of the existing iOS CI can observe this:
#   - scripts/ios/e2e_xctest_flow.sh injects a test GAD app id into the plist
#     before building and restores it afterward (inject_e2e_admob_app_id /
#     restore_runner_plist) — it has never once built or launched against the
#     real production plist state.
#   - Its own APP_LAUNCH stage only checks `xcrun simctl launch`'s exit code,
#     i.e. that the launch request was *accepted*, not that the process
#     stayed alive afterward.
#   - Its own APP_READY stage queries `launchctl print system` (the
#     simulator's launchd service overall), then immediately terminates the
#     app — it never checks whether the Runner process itself was still
#     running at any point.
#
# This script closes that gap. It builds/installs/launches the REAL,
# unmodified ios/Runner/Info.plist (this script never writes to it — see the
# "does not touch the plist" contract enforced by
# scripts/ios/tests/prod_plist_launch_probe_contract.sh) and then, after a
# configurable wait, checks two independent things:
#   1. Is the app process still registered/alive in the simulator's launchd?
#   2. Did a new native crash report appear for it since launch?
#
# Usage:
#   prod_plist_launch_probe.sh <udid> <bundle-id> <derived-data> \
#     <artifact-dir> [wait-seconds] [stage-timeout-seconds]
#
# wait-seconds:        whole seconds to wait after launch before checking
#                       liveness/crash state (default 20, also overridable via
#                       PROD_PLIST_PROBE_WAIT_SECONDS when the argument is
#                       omitted).
# stage-timeout-seconds: bound applied to the build/install/launch stages via
#                       scripts/ios/e2e_watchdog.sh (default 900).
#
# This script requires macOS (xcrun/simctl/xcodebuild/launchctl). It is safe
# to run on a non-macOS host only for the static shell-contract checks in
# scripts/ios/tests/prod_plist_launch_probe_contract.sh.

set -uo pipefail

readonly EXIT_USAGE=125
readonly DEFAULT_STAGE_TIMEOUT=900
readonly DEFAULT_WAIT_SECONDS=20
readonly STAGES=(
  SIMULATOR_BOOT
  APP_BUILD
  APP_INSTALL
  APP_LAUNCH
  PROD_PLIST_APP_ALIVE
  PROD_PLIST_NO_CRASH
  TEARDOWN
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
watchdog="$script_dir/e2e_watchdog.sh"

if [ "$#" -lt 4 ] || [ "$#" -gt 6 ]; then
  echo "Usage: $0 <udid> <bundle-id> <derived-data> <artifact-dir> [wait-seconds] [stage-timeout-seconds]" >&2
  exit "$EXIT_USAGE"
fi

udid="$1"
bundle_id="$2"
derived_data="$3"
artifact_dir="$4"
wait_seconds="${5:-${PROD_PLIST_PROBE_WAIT_SECONDS:-$DEFAULT_WAIT_SECONDS}}"
stage_timeout="${6:-$DEFAULT_STAGE_TIMEOUT}"

case "$wait_seconds" in
  ''|*[!0-9]*)
    echo "::error title=BLOCKED_INVALID_PROBE_WAIT::wait-seconds must be a positive whole number (got '$wait_seconds')" >&2
    exit "$EXIT_USAGE"
    ;;
esac
if [ "$wait_seconds" -le 0 ]; then
  echo "::error title=BLOCKED_INVALID_PROBE_WAIT::wait-seconds must be greater than zero" >&2
  exit "$EXIT_USAGE"
fi

case "$stage_timeout" in
  ''|*[!0-9]*)
    echo "::error title=BLOCKED_INVALID_PROBE_TIMEOUT::stage timeout must be a positive whole number (got '$stage_timeout')" >&2
    exit "$EXIT_USAGE"
    ;;
esac
if [ "$stage_timeout" -le 0 ]; then
  echo "::error title=BLOCKED_INVALID_PROBE_TIMEOUT::stage timeout must be greater than zero" >&2
  exit "$EXIT_USAGE"
fi

mkdir -p -- "$artifact_dir" "$derived_data"
stage_log_dir="$artifact_dir/stages"
mkdir -p -- "$stage_log_dir"
stage_evidence_file="$artifact_dir/stage-evidence.log"
crash_copy_dir="$artifact_dir/crash-reports"

overall_start="$(date +%s)"
current_failure=0
cleanup_started=0
app_path="$derived_data/Build/Products/Debug-iphonesimulator/Runner.app"

# This script is a READ-ONLY consumer of ios/Runner/Info.plist. It must never
# write to it — that is the entire point of this probe (see the header
# comment). No PlistBuddy Set/Add call exists anywhere below, deliberately,
# and scripts/ios/tests/prod_plist_launch_probe_contract.sh statically
# enforces that this stays true.
runner_plist="$script_dir/../../ios/Runner/Info.plist"

emit_stage() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  detail="${detail//$'\n'/ }"
  detail="${detail:0:240}"
  marker="E2E_STAGE stage=$name status=$status evidence=${detail:-none}"
  printf '%s\n' "$marker"
  printf '%s\n' "$marker" >> "$stage_evidence_file"
}

mark_skipped() {
  local name="$1"
  emit_stage "$name" "SKIPPED" "blocked by an earlier stage"
}

run_bounded() {
  local stage="$1"
  shift
  local log_file="$stage_log_dir/$stage.log"
  local tail_file="$stage_log_dir/$stage.tail.log"
  local start end rc
  start="$(date +%s)"
  E2E_WATCHDOG_HEARTBEAT_INTERVAL="${E2E_WATCHDOG_HEARTBEAT_INTERVAL:-30}" \
  E2E_WATCHDOG_LOG_FILE="$log_file" \
  E2E_WATCHDOG_TAIL_FILE="$tail_file" \
    bash "$watchdog" "$stage_timeout" "$@"
  rc=$?
  end="$(date +%s)"
  printf 'E2E_STAGE_TIMING stage=%s duration_seconds=%s exit=%s\n' "$stage" "$((end - start))" "$rc"
  return "$rc"
}

cleanup() {
  local cleanup_rc=0
  if [ -n "$udid" ] && command -v xcrun >/dev/null 2>&1; then
    E2E_UDID="$udid" E2E_BUNDLE_ID="$bundle_id" \
      run_bounded TEARDOWN bash -c '
        xcrun simctl terminate "$E2E_UDID" "$E2E_BUNDLE_ID" >/dev/null 2>&1 || true
      ' || cleanup_rc=$?
  else
    emit_stage TEARDOWN PASS "simctl unavailable; no owned app process to terminate"
  fi
  if [ "$cleanup_rc" -eq 0 ] && [ -n "$udid" ] && command -v xcrun >/dev/null 2>&1; then
    emit_stage TEARDOWN PASS "owned app process terminated; child watchdogs reaped"
  elif [ "$cleanup_rc" -ne 0 ]; then
    emit_stage TEARDOWN FAIL "owned app termination watchdog exit=$cleanup_rc"
  fi
  return "$cleanup_rc"
}

on_exit() {
  local exit_status="${1:-0}"
  local cleanup_rc=0

  if [ "$cleanup_started" -eq 1 ]; then
    return 0
  fi
  cleanup_started=1
  trap - EXIT INT TERM HUP
  cleanup || cleanup_rc=$?

  if [ "$exit_status" -ne 0 ]; then
    exit "$exit_status"
  fi
  if [ "$cleanup_rc" -ne 0 ]; then
    exit "$cleanup_rc"
  fi
  exit 0
}

on_signal() {
  on_exit "$1"
}
trap 'on_exit "$?"' EXIT
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP

# --- SIMULATOR_BOOT ----------------------------------------------------------
if [ -z "$udid" ]; then
  emit_stage SIMULATOR_BOOT FAIL "no simulator udid supplied"
  current_failure=1
else
  run_bounded SIMULATOR_BOOT xcrun simctl bootstatus "$udid" -b
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_stage SIMULATOR_BOOT PASS "simctl bootstatus completed for supplied simulator"
  else
    emit_stage SIMULATOR_BOOT FAIL "simctl bootstatus exit=$rc"
    current_failure=1
  fi
fi

# --- APP_BUILD ---------------------------------------------------------------
# Intentionally never injects, edits, or restores ios/Runner/Info.plist —
# whatever GADApplicationIdentifier state is committed to the production
# plist is exactly what gets built and launched below. Supabase values here
# are the same fixed, non-production placeholders scripts/ios/e2e_xctest_flow.sh
# already uses for its simulator builds (this probe is about AdMob/plist
# launch survival, not backend behavior, and must never reach a real backend).
if [ "$current_failure" -eq 0 ]; then
  if [ ! -f "$runner_plist" ]; then
    emit_stage APP_BUILD FAIL "production Runner Info.plist not found at $runner_plist"
    current_failure=1
  fi
fi

if [ "$current_failure" -eq 0 ]; then
  E2E_UDID="$udid" E2E_DERIVED_DATA="$derived_data" \
    run_bounded APP_BUILD bash -c '
      set -euo pipefail
      flutter build ios --config-only --simulator \
        --dart-define=E2E_MODE=1 \
        --dart-define=SUPABASE_URL=https://your-project.supabase.co \
        --dart-define=SUPABASE_ANON_KEY=your-supabase-anon-key
      xcodebuild build \
        -workspace ios/Runner.xcworkspace \
        -scheme Runner \
        -configuration Debug \
        -sdk iphonesimulator \
        -destination "id=$E2E_UDID" \
        -derivedDataPath "$E2E_DERIVED_DATA"
    '
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_stage APP_BUILD PASS "config-only and xcodebuild build completed against the unmodified production plist"
  else
    emit_stage APP_BUILD FAIL "build stage exit=$rc"
    current_failure=1
  fi
else
  mark_skipped APP_BUILD
fi

# --- APP_INSTALL ---------------------------------------------------------------
if [ "$current_failure" -eq 0 ]; then
  if [ ! -d "$app_path" ]; then
    emit_stage APP_INSTALL FAIL "Runner.app not found at derived-data product path"
    current_failure=1
  else
    run_bounded APP_INSTALL xcrun simctl install "$udid" "$app_path"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      emit_stage APP_INSTALL PASS "simctl install completed for Runner.app"
    else
      emit_stage APP_INSTALL FAIL "simctl install exit=$rc"
      current_failure=1
    fi
  fi
else
  mark_skipped APP_INSTALL
fi

# --- APP_LAUNCH ---------------------------------------------------------------
launch_epoch=0
if [ "$current_failure" -eq 0 ]; then
  launch_epoch="$(date +%s)"
  run_bounded APP_LAUNCH xcrun simctl launch "$udid" "$bundle_id"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_stage APP_LAUNCH PASS "simctl launch accepted the Runner bundle against the unmodified production plist"
  else
    emit_stage APP_LAUNCH FAIL "simctl launch exit=$rc"
    current_failure=1
  fi
else
  mark_skipped APP_LAUNCH
fi

# --- Post-launch wait ----------------------------------------------------------
# A native SDK crash from a missing GADApplicationIdentifier can happen
# synchronously during MobileAds.instance.initialize() or shortly after
# `initialize()` runs on the Dart side; this wait gives that failure mode time
# to surface before the two checks below run.
if [ "$current_failure" -eq 0 ]; then
  sleep "$wait_seconds"
fi

# --- PROD_PLIST_APP_ALIVE ------------------------------------------------------
# The simulator's own launchd is queried (via `xcrun simctl spawn ... launchctl
# list`) for a job matching the app's bundle id. A crashed/exited app is
# unloaded from launchd, so an entry disappearing here is direct evidence the
# process did not survive the wait above -- unlike e2e_xctest_flow.sh's
# APP_READY stage, which only ever confirmed the simulator's launchd service
# was reachable in general, never that this specific app was still running.
if [ "$current_failure" -eq 0 ]; then
  E2E_UDID="$udid" E2E_BUNDLE_ID="$bundle_id" \
    run_bounded PROD_PLIST_APP_ALIVE bash -c '
      set -euo pipefail
      xcrun simctl spawn "$E2E_UDID" launchctl list | grep -F -- "$E2E_BUNDLE_ID"
    '
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_stage PROD_PLIST_APP_ALIVE PASS "launchctl list reported a live job for $bundle_id after ${wait_seconds}s"
  else
    emit_stage PROD_PLIST_APP_ALIVE FAIL "no live launchctl job found for $bundle_id after ${wait_seconds}s (exit=$rc); the app likely crashed or exited"
    current_failure=1
  fi
else
  mark_skipped PROD_PLIST_APP_ALIVE
fi

# --- PROD_PLIST_NO_CRASH ------------------------------------------------------
# macOS's crash reporter writes a diagnostic report for the Runner process
# (simulator apps run as host processes under macOS's own reporter) named
# after the executable, e.g. "Runner-2026-09-06-101530.ips". This stage scans
# for any such report created at or after this run's launch, independent of
# whether PROD_PLIST_APP_ALIVE above already failed, so a crash is diagnosable
# even in a partial-failure run.
find_new_crash_reports() {
  local since_epoch="$1"
  local since_ts
  local dir
  local dirs=(
    "$HOME/Library/Logs/DiagnosticReports"
    "$HOME/Library/Logs/DiagnosticReports/Retired"
  )
  # BSD `date -r <epoch>` (macOS) formats an epoch seconds value; this is
  # deliberately NOT portable to GNU date (`-r` means "use file mtime" there)
  # because this whole script only ever runs on a macOS CI runner (see the
  # header comment).
  since_ts="$(date -r "$since_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  if [ -z "$since_ts" ]; then
    return 0
  fi
  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      find "$dir" -type f \
        \( -iname 'Runner-*' -o -iname 'Runner_*' -o -iname 'Runner.*' \) \
        -newermt "$since_ts" 2>/dev/null || true
    fi
  done
}

if [ "$launch_epoch" -ne 0 ]; then
  mkdir -p -- "$crash_copy_dir"
  crash_reports="$(find_new_crash_reports "$launch_epoch")"
  if [ -n "$crash_reports" ]; then
    while IFS= read -r report; do
      [ -z "$report" ] && continue
      cp -p -- "$report" "$crash_copy_dir/" 2>/dev/null || true
    done <<EOF
$crash_reports
EOF
    report_count="$(printf '%s\n' "$crash_reports" | grep -c . || true)"
    emit_stage PROD_PLIST_NO_CRASH FAIL "found $report_count new crash report(s) since launch; copied to $crash_copy_dir"
    current_failure=1
  else
    emit_stage PROD_PLIST_NO_CRASH PASS "no new crash report for Runner found since launch (checked ~/Library/Logs/DiagnosticReports and its Retired subdirectory)"
  fi
else
  mark_skipped PROD_PLIST_NO_CRASH
fi

overall_end="$(date +%s)"
printf 'E2E_TIMING flow=prod_plist_launch_probe duration_seconds=%s exit=%s\n' "$((overall_end - overall_start))" "$([ "$current_failure" -eq 0 ] && echo 0 || echo 1)"

if [ "$current_failure" -ne 0 ]; then
  exit 1
fi
exit 0
