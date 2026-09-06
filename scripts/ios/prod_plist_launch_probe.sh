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
# configurable wait, checks three independent things:
#   1. Is the launched app PROCESS (by the pid simctl launch reported) still
#      alive?
#   2. Is there evidence about whether the R1 code path
#      (MobileAds.instance.initialize()) was actually REACHED, as opposed to
#      being skipped by one of the three early returns before it? Survival
#      alone cannot distinguish "no R1 crash" from "never got to R1".
#   3. Did a new native crash report appear for it since launch?
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
  PROD_PLIST_ADS_INIT_REACHED
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
# Records which crash-report directories existed at scan time, so the next real
# macOS run measures which tree simulator crashes actually land in instead of
# leaving it a guess (review fix, MEDIUM-1).
crash_scan_census="$artifact_dir/crash-scan-dirs.log"

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
# `xcrun simctl launch` prints the launched process's host PID on success, in
# the form "<bundle-id>: <pid>". run_bounded sends the child's stdout+stderr to
# "$stage_log_dir/<stage>.log" (see e2e_watchdog.sh's E2E_WATCHDOG_LOG_FILE
# handling), so that PID is recoverable from the APP_LAUNCH stage log below.
# Capturing it is what lets PROD_PLIST_APP_ALIVE check THIS process rather than
# a launchd job label (review fix, HIGH-2).
launch_epoch=0
launch_pid=""
if [ "$current_failure" -eq 0 ]; then
  launch_epoch="$(date +%s)"
  run_bounded APP_LAUNCH xcrun simctl launch "$udid" "$bundle_id"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    launch_pid="$(sed -n 's/^[[:space:]]*'"$bundle_id"':[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
      "$stage_log_dir/APP_LAUNCH.log" 2>/dev/null | tail -n 1)"
    if [ -n "$launch_pid" ]; then
      emit_stage APP_LAUNCH PASS "simctl launch accepted the Runner bundle against the unmodified production plist (pid=$launch_pid)"
    else
      emit_stage APP_LAUNCH PASS "simctl launch accepted the Runner bundle against the unmodified production plist (pid not parsed from launch output; PROD_PLIST_APP_ALIVE falls back to the launchctl PID column)"
    fi
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
# Liveness must mean "the launched PROCESS is still running", not "a launchd job
# with this label is still registered" (review fix, HIGH-2).
#
# `launchctl list` output is three columns -- PID, Status, Label -- and an app
# is registered under a "UIKitApplication:<bundle-id>[...]" label. A plain
# `grep -F <bundle-id>` matches the LABEL column only, so it still succeeded
# when the process was already dead and the PID column had degraded to "-"
# (job loaded, no process). That turned a crash into a PASS, which is exactly
# the failure mode this probe exists to detect.
#
# Primary check: the PID captured from `simctl launch` above. Simulator apps
# run as host macOS processes, so `kill -0 <pid>` from this shell is a direct,
# unambiguous liveness test on the very process that was launched.
# Fallback (only when the PID could not be parsed): require the launchctl PID
# COLUMN to be numeric for the matching label, instead of accepting a bare
# label match.
# Fail-closed: if neither path can produce positive evidence of a live
# process, this stage is FAIL/UNKNOWN -- never PASS.
if [ "$current_failure" -eq 0 ]; then
  if [ -n "$launch_pid" ]; then
    if kill -0 "$launch_pid" 2>/dev/null; then
      emit_stage PROD_PLIST_APP_ALIVE PASS "launched pid $launch_pid is still alive after ${wait_seconds}s"
    else
      emit_stage PROD_PLIST_APP_ALIVE FAIL "launched pid $launch_pid is no longer running after ${wait_seconds}s; the app crashed or exited"
      current_failure=1
    fi
  else
    E2E_UDID="$udid" E2E_BUNDLE_ID="$bundle_id" \
      run_bounded PROD_PLIST_APP_ALIVE bash -c '
        set -uo pipefail
        xcrun simctl spawn "$E2E_UDID" launchctl list \
          | awk -v bid="$E2E_BUNDLE_ID" '"'"'index($3, bid) > 0 && $1 ~ /^[0-9]+$/ { found = 1; print } END { exit(found ? 0 : 1) }'"'"'
      '
    rc=$?
    if [ "$rc" -eq 0 ]; then
      emit_stage PROD_PLIST_APP_ALIVE PASS "launch pid unavailable; launchctl list reported a numeric PID column for a $bundle_id job after ${wait_seconds}s"
    else
      emit_stage PROD_PLIST_APP_ALIVE FAIL "launch pid unavailable and no launchctl job for $bundle_id had a numeric PID column after ${wait_seconds}s (exit=$rc); treated as not-alive (fail-closed)"
      current_failure=1
    fi
  fi
else
  mark_skipped PROD_PLIST_APP_ALIVE
fi

# --- PROD_PLIST_ADS_INIT_REACHED ----------------------------------------------
# Why this stage exists (review fix, HIGH-1): APP_ALIVE=PASS alone does NOT
# clear R1. The app can survive either because (a) there is no R1 crash, or
# because (b) execution never REACHED the R1 code at all -- there are three
# early returns before lib/services/ad_service.dart:483's
# `MobileAds.instance.initialize()` (:446 rewardedAdEnabled off, :468 UMP
# unavailable, and the priming try/catch in lib/main.dart). Mapping PASS/PASS
# straight to R1_CLEARED silently assumes (a). This stage exists to look for
# evidence of which branch actually ran.
#
# IMPORTANT, measured limitation -- read before extending this stage:
# the reason strings 'ump_unavailable' (ad_service.dart:464) and
# 'post_prime_not_initialized' (main.dart:184) are NOT observable at runtime.
# They are passed as the `reason:` PARAMETER to
# AnalyticsService.logAdLoadFailed, and lib/core/analytics_service.dart's
# _logEvent (:10-18) is a no-op that prints only
#   "Analytics event skipped (<event-name>): analytics disabled"
# discarding `parameters` entirely. So all four early-exit reasons collapse to
# the SAME console line carrying the event name 'ad_load_failed' (:143) and
# nothing that distinguishes them. Only the literals below actually appear in
# output; do not add a grep for a `reason:` value, it can never match.
#
# Consequence: a positive "reached" proof exists (the initialize() catch block
# at ad_service.dart:487 logs a distinct literal), but "reached and succeeded"
# leaves no marker at all. This stage therefore reports UNDETERMINED whenever
# it cannot positively prove reach, and UNDETERMINED must NOT be read as
# CLEARED (see docs/ios/R1-admob-launch-risk.md's verdict table).
#
# UNDETERMINED deliberately does not set current_failure: it is missing
# diagnostic evidence, not a probe malfunction. The fail-closed behavior lives
# in the R1 verdict mapping, which refuses to clear without a REACHED result.
ads_log_file="$artifact_dir/app-log.txt"
if [ "$launch_epoch" -ne 0 ]; then
  log_window=$((wait_seconds + 10))
  E2E_UDID="$udid" E2E_LOG_WINDOW="${log_window}s" E2E_ADS_LOG_FILE="$ads_log_file" \
    run_bounded PROD_PLIST_ADS_INIT_REACHED bash -c '
      set -uo pipefail
      xcrun simctl spawn "$E2E_UDID" log show \
        --style compact \
        --last "$E2E_LOG_WINDOW" \
        --predicate '"'"'processImagePath CONTAINS "Runner"'"'"' \
        > "$E2E_ADS_LOG_FILE" 2>/dev/null
    '
  rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$ads_log_file" ]; then
    emit_stage PROD_PLIST_ADS_INIT_REACHED UNDETERMINED "could not capture app log (exit=$rc); cannot tell whether MobileAds init was reached, so R1 must not be cleared from this run"
  elif grep -qF -- 'AdService.initialize failed:' "$ads_log_file"; then
    # ad_service.dart:487 -- only reachable from inside the try block that
    # wraps :483, i.e. MobileAds.instance.initialize() was actually invoked.
    emit_stage PROD_PLIST_ADS_INIT_REACHED PASS "found 'AdService.initialize failed:' (ad_service.dart:487): MobileAds init was reached and threw; R1 code path is exercised"
  elif grep -qF -- 'AdService initialize skipped:' "$ads_log_file"; then
    # main.dart:190 -- the priming try/catch swallowed a throw.
    emit_stage PROD_PLIST_ADS_INIT_REACHED UNDETERMINED "found 'AdService initialize skipped:' (main.dart:190): priming threw before completing; reach not proven"
  elif grep -qF -- 'Analytics event skipped (ad_load_failed)' "$ads_log_file"; then
    emit_stage PROD_PLIST_ADS_INIT_REACHED UNDETERMINED "an ad_load_failed analytics event was logged during the launch window; one of the four early-exit branches likely ran, but the reason parameter is discarded by analytics_service.dart:10-18 so the branch is indistinguishable and reach is not proven"
  else
    emit_stage PROD_PLIST_ADS_INIT_REACHED UNDETERMINED "no ad-init marker found in the captured log; 'reached and succeeded' leaves no marker, so this is indistinguishable from an early exit and R1 must not be cleared from this run"
  fi
else
  mark_skipped PROD_PLIST_ADS_INIT_REACHED
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
  # Simulator app crashes have been reported in BOTH the host-wide
  # DiagnosticReports tree and a per-device CoreSimulator tree; which one is
  # authoritative has not been measured on a real runner from this (Windows)
  # host, so all three are scanned (review fix, MEDIUM-1). A non-existent
  # directory is skipped by the `-d` test below, so adding the CoreSimulator
  # path is side-effect free if it turns out never to be used. The
  # per-directory census written by the caller records which paths existed and
  # what each contributed, so the next real run measures this instead of
  # guessing.
  local dirs=(
    "$HOME/Library/Logs/DiagnosticReports"
    "$HOME/Library/Logs/DiagnosticReports/Retired"
    "$HOME/Library/Logs/CoreSimulator/$udid"
  )
  # BSD `date -r <epoch>` (macOS) formats an epoch seconds value; this is
  # deliberately NOT portable to GNU date (`-r` means "use file mtime" there)
  # because this whole script only ever runs on a macOS CI runner (see the
  # header comment).
  since_ts="$(date -r "$since_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  if [ -z "$since_ts" ]; then
    # Fail-closed (review fix, MEDIUM-2). Returning 0 with no output here used
    # to make the caller see "no crash reports" and emit PASS, i.e. a failure
    # to compute the cutoff timestamp was silently indistinguishable from a
    # clean run. Exit non-zero instead so the caller reports UNKNOWN.
    return 2
  fi
  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      printf 'CRASH_SCAN_DIR path=%s state=present\n' "$dir" >> "$crash_scan_census" 2>/dev/null || true
      find "$dir" -type f \
        \( -iname 'Runner-*' -o -iname 'Runner_*' -o -iname 'Runner.*' \) \
        -newermt "$since_ts" 2>/dev/null || true
    else
      printf 'CRASH_SCAN_DIR path=%s state=absent\n' "$dir" >> "$crash_scan_census" 2>/dev/null || true
    fi
  done
}

if [ "$launch_epoch" -ne 0 ]; then
  mkdir -p -- "$crash_copy_dir"
  crash_scan_rc=0
  crash_reports="$(find_new_crash_reports "$launch_epoch")" || crash_scan_rc=$?
  if [ "$crash_scan_rc" -ne 0 ]; then
    emit_stage PROD_PLIST_NO_CRASH UNKNOWN "could not compute the crash-report cutoff timestamp (date -r exit path, rc=$crash_scan_rc); crash state is unverified and must not be read as clean"
    current_failure=1
  elif [ -n "$crash_reports" ]; then
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
    emit_stage PROD_PLIST_NO_CRASH PASS "no new crash report for Runner found since launch (checked ~/Library/Logs/DiagnosticReports, its Retired subdirectory, and ~/Library/Logs/CoreSimulator/<udid>; per-directory presence recorded in $crash_scan_census)"
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
