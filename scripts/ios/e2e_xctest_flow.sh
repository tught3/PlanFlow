#!/usr/bin/env bash
# Run one PlanFlow iOS integration_test file through Flutter's official
# XCTest host runner.  This deliberately does not use a Flutter VM-service
# device runner: the XCTest host waits for integration_test's native plugin
# result and produces an xcresult bundle.
#
# Usage:
#   e2e_xctest_flow.sh <flow.dart> <udid> <bundle-id> <derived-data> \
#     <result.xcresult> <artifact-dir> [stage-timeout-seconds]
#
# The script owns every child it starts through e2e_watchdog.sh and always
# emits the same bounded stage sequence.  It is safe to run on a Windows host
# only for shell-contract checks; the commands themselves require macOS.

set -uo pipefail

readonly EXIT_USAGE=125
readonly DEFAULT_STAGE_TIMEOUT=600
readonly E2E_ADMOB_TEST_APP_ID="ca-app-pub-3940256099942544~1458002511"
readonly STAGES=(
  SIMULATOR_BOOT
  APP_BUILD
  APP_INSTALL
  APP_LAUNCH
  APP_READY
  TEST_DRIVER_ATTACH
  TEST_DISCOVERY
  FLOW_EXECUTION
  TEARDOWN
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
watchdog="$script_dir/e2e_watchdog.sh"

if [ "$#" -lt 6 ] || [ "$#" -gt 7 ]; then
  echo "Usage: $0 <flow.dart> <udid> <bundle-id> <derived-data> <result.xcresult> <artifact-dir> [stage-timeout-seconds]" >&2
  exit "$EXIT_USAGE"
fi

flow_file="$1"
udid="$2"
bundle_id="$3"
derived_data="$4"
result_bundle="$5"
artifact_dir="$6"
stage_timeout="${7:-$DEFAULT_STAGE_TIMEOUT}"

case "$stage_timeout" in
  ''|*[!0-9]*)
    echo "::error title=BLOCKED_INVALID_XCTEST_TIMEOUT::stage timeout must be a positive whole number (got '$stage_timeout')" >&2
    exit "$EXIT_USAGE"
    ;;
esac
if [ "$stage_timeout" -le 0 ]; then
  echo "::error title=BLOCKED_INVALID_XCTEST_TIMEOUT::stage timeout must be greater than zero" >&2
  exit "$EXIT_USAGE"
fi

mkdir -p -- "$artifact_dir" "$derived_data"
stage_log_dir="$artifact_dir/stages"
mkdir -p -- "$stage_log_dir"
stage_evidence_file="$artifact_dir/stage-evidence.log"

flow_name="$(basename -- "$flow_file" .dart)"
overall_start="$(date +%s)"
current_failure=0
test_status=125
app_path="$derived_data/Build/Products/Debug-iphonesimulator/Runner.app"
runner_plist="$script_dir/../../ios/Runner/Info.plist"
runner_plist_backup="$artifact_dir/.Runner-Info.plist.$$.backup"
runner_plist_backup_active=0
cleanup_started=0

emit_stage() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  # Stage details are paths or fixed command outcomes.  Do not print command
  # environments or Dart defines here; this script is also used for the
  # secret-free FLOW5 host contract.
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

inject_e2e_admob_app_id() {
  if [ ! -f "$runner_plist" ]; then
    return 1
  fi

  cp -p -- "$runner_plist" "$runner_plist_backup" || return 1
  runner_plist_backup_active=1

  if /usr/libexec/PlistBuddy -c 'Print :GADApplicationIdentifier' "$runner_plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :GADApplicationIdentifier $E2E_ADMOB_TEST_APP_ID" "$runner_plist"
  else
    /usr/libexec/PlistBuddy -c "Add :GADApplicationIdentifier string $E2E_ADMOB_TEST_APP_ID" "$runner_plist"
  fi
}

restore_runner_plist() {
  if [ "$runner_plist_backup_active" -eq 0 ]; then
    return 0
  fi

  cp -p -- "$runner_plist_backup" "$runner_plist" || return 1
  rm -f -- "$runner_plist_backup" || return 1
  runner_plist_backup_active=0
}

cleanup() {
  local cleanup_rc=0
  # xcodebuild normally tears down the test host.  This extra termination is
  # idempotent and prevents a smoke-launch process surviving a failed test.
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

  if ! restore_runner_plist; then
    echo "::error title=BLOCKED_E2E_PLIST_RESTORE::could not restore the original Runner Info.plist" >&2
    cleanup_rc=1
  fi

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

if [ ! -f "$flow_file" ]; then
  emit_stage SIMULATOR_BOOT FAIL "flow file not found: $flow_file"
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

if [ "$current_failure" -eq 0 ]; then
  if ! inject_e2e_admob_app_id; then
    emit_stage APP_BUILD FAIL "E2E-only AdMob test plist injection failed"
    current_failure=1
  fi
fi

if [ "$current_failure" -eq 0 ]; then
  # These values are intentionally fixed placeholders.  The simulator suite
  # must never fall back to lib/core/env.dart's production Supabase defaults.
  # Keep config generation and native compilation in one APP_BUILD log so a
  # failed config step cannot be hidden by a later log truncation.  Target
  # the simulator path explicitly so Flutter generates simulator config
  # instead of device-only ios-release signing material.
  E2E_FLOW_FILE="$flow_file" E2E_UDID="$udid" E2E_DERIVED_DATA="$derived_data" \
    run_bounded APP_BUILD bash -c '
      set -euo pipefail
      flutter build ios --config-only --simulator "$E2E_FLOW_FILE" \
        --dart-define=E2E_MODE=1 \
        --dart-define=SUPABASE_URL=https://your-project.supabase.co \
        --dart-define=SUPABASE_ANON_KEY=your-supabase-anon-key
      xcodebuild build-for-testing \
        -workspace ios/Runner.xcworkspace \
        -scheme Runner \
        -configuration Debug \
      -sdk iphonesimulator \
      -destination "id=$E2E_UDID" \
      -derivedDataPath "$E2E_DERIVED_DATA"
    '
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_stage APP_BUILD PASS "config-only and xcodebuild build-for-testing completed"
  else
    emit_stage APP_BUILD FAIL "build stage exit=$rc"
    current_failure=1
  fi
else
  mark_skipped APP_BUILD
fi

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

if [ "$current_failure" -eq 0 ]; then
  run_bounded APP_LAUNCH xcrun simctl launch "$udid" "$bundle_id"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_stage APP_LAUNCH PASS "simctl launch accepted the Runner bundle"
  else
    emit_stage APP_LAUNCH FAIL "simctl launch exit=$rc"
    current_failure=1
  fi
else
  mark_skipped APP_LAUNCH
fi

if [ "$current_failure" -eq 0 ]; then
  # A successful launch is the app-ready probe.  launchctl is queried only to
  # prove the simulator service remains responsive; it is not used to select
  # a Widget extension process.  The smoke-launched Runner is terminated
  # before XCTest starts so it cannot pre-consume the configured Dart test.
  E2E_UDID="$udid" E2E_BUNDLE_ID="$bundle_id" \
    run_bounded APP_READY bash -c '
      set -euo pipefail
      xcrun simctl spawn "$E2E_UDID" launchctl print system >/dev/null
      xcrun simctl terminate "$E2E_UDID" "$E2E_BUNDLE_ID" >/dev/null 2>&1 || true
    '
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_stage APP_READY PASS "simulator launch service responded after Runner launch"
  else
    emit_stage APP_READY FAIL "simulator launch service probe exit=$rc"
    current_failure=1
  fi
else
  mark_skipped APP_READY
fi

if [ "$current_failure" -eq 0 ]; then
  test_log="$stage_log_dir/XCTEST.log"
  test_tail="$stage_log_dir/XCTEST.tail.log"
  test_start="$(date +%s)"
  E2E_WATCHDOG_HEARTBEAT_INTERVAL="${E2E_WATCHDOG_HEARTBEAT_INTERVAL:-30}" \
  E2E_WATCHDOG_LOG_FILE="$test_log" \
  E2E_WATCHDOG_TAIL_FILE="$test_tail" \
    bash "$watchdog" "$stage_timeout" \
      xcodebuild test-without-building \
      -workspace ios/Runner.xcworkspace \
      -scheme Runner \
      -configuration Debug \
      -destination "id=$udid" \
      -derivedDataPath "$derived_data" \
      -resultBundlePath "$result_bundle" \
      -parallel-testing-enabled NO \
      -only-testing:RunnerTests
  test_status=$?
  test_end="$(date +%s)"
  printf 'E2E_STAGE_TIMING stage=XCTEST_EXECUTION flow=%s duration_seconds=%s exit=%s\n' "$flow_name" "$((test_end - test_start))" "$test_status"

  if grep -qF "Test Suite 'RunnerTests.xctest'" "$test_log" 2>/dev/null; then
    emit_stage TEST_DRIVER_ATTACH PASS "RunnerTests XCTest host was started; no Flutter VM-service attach"
  else
    emit_stage TEST_DRIVER_ATTACH FAIL "RunnerTests XCTest host start was not observed"
    current_failure=1
  fi

  if grep -qE "Test (Case|Suite) '" "$test_log" 2>/dev/null; then
    emit_stage TEST_DISCOVERY PASS "XCTest discovered RunnerTests cases"
  else
    emit_stage TEST_DISCOVERY FAIL "no XCTest case or suite discovery evidence"
    current_failure=1
  fi

  if [ "$test_status" -eq 0 ] && grep -qE "TEST SUCCEEDED|Test Suite .* passed" "$test_log" 2>/dev/null; then
    emit_stage FLOW_EXECUTION PASS "XCTest reported the configured flow passed"
  else
    emit_stage FLOW_EXECUTION FAIL "XCTest flow exit=$test_status"
    current_failure=1
  fi
else
  mark_skipped TEST_DRIVER_ATTACH
  mark_skipped TEST_DISCOVERY
  mark_skipped FLOW_EXECUTION
fi

overall_end="$(date +%s)"
printf 'E2E_TIMING flow=%s duration_seconds=%s exit=%s\n' "$flow_name" "$((overall_end - overall_start))" "$([ "$current_failure" -eq 0 ] && echo 0 || echo 1)"

if [ "$current_failure" -ne 0 ]; then
  exit 1
fi
exit 0
