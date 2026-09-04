#!/usr/bin/env bash
# Contract/regression tests for scripts/ios/e2e_stage_markers.sh.
#
# These are NOT unit tests with mocks: each case writes a real fixture log
# file to a temp directory and runs the actual e2e_stage_markers.sh as a
# subprocess against it, then greps its real stdout. Per this repo's existing
# safety-gate convention ("a safety gate needs at least one test that passes
# real input through it, not just a test that mocks the thing the gate
# reads" — see scripts/ios/tests/e2e_script_contract.sh's own header), this
# file follows the same pattern for the new stage-marker script.
#
# Usage: bash scripts/ios/tests/e2e_stage_markers_contract.sh
# Exit code: 0 if every case passes, 1 if any case fails (each failure is
# printed with the fixture name, the expected substring, and the actual
# output so a failure is diagnosable without re-running by hand).

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
markers_script="$script_dir/../e2e_stage_markers.sh"

if [ ! -f "$markers_script" ]; then
  echo "e2e_stage_markers_contract.sh: cannot find e2e_stage_markers.sh at $markers_script" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

pass_count=0
fail_count=0

# assert_rc <case_name> <expected_rc> <actual_rc>
assert_rc() {
  local case_name="$1"
  local expected_rc="$2"
  local actual_rc="$3"

  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $case_name (rc=$actual_rc)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $case_name — expected rc=$expected_rc, got rc=$actual_rc"
    fail_count=$((fail_count + 1))
  fi
}

# assert_contains <case_name> <output> <expected_substring>
assert_contains() {
  local case_name="$1"
  local output="$2"
  local expected_substring="$3"

  if printf '%s' "$output" | grep -qF -- "$expected_substring"; then
    echo "PASS: $case_name (found: \"$expected_substring\")"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $case_name — expected substring not found: \"$expected_substring\""
    echo "  --- actual output ---"
    printf '%s\n' "$output" | sed 's/^/  /'
    echo "  --- end output ---"
    fail_count=$((fail_count + 1))
  fi
}

# assert_not_contains <case_name> <output> <forbidden_substring>
assert_not_contains() {
  local case_name="$1"
  local output="$2"
  local forbidden_substring="$3"

  if printf '%s' "$output" | grep -qF -- "$forbidden_substring"; then
    echo "FAIL: $case_name — forbidden substring found: \"$forbidden_substring\""
    echo "  --- actual output ---"
    printf '%s\n' "$output" | sed 's/^/  /'
    echo "  --- end output ---"
    fail_count=$((fail_count + 1))
  else
    echo "PASS: $case_name (confirmed absent: \"$forbidden_substring\")"
    pass_count=$((pass_count + 1))
  fi
}

echo "=== e2e_stage_markers.sh contract tests ==="
echo ""

# --- Case 1: Run#4 mainstream reproduction ----------------------------------
# Verbatim shape from the real Run#4 mainstream leg: the Xcode build
# completes, the built app is rsync'd into the iphonesimulator build
# directory, the Flutter tool starts waiting for the VM Service port, and
# then nothing else is ever logged before the watchdog (exit 124) kills the
# child. This is the exact regression this whole change exists to name.
case1_log="$tmp_dir/case1_mainstream_run4_hang.log"
cat >"$case1_log" <<'EOF'
[STEP] watchdog: elapsed=91s lines=59089 delta=+54376 last=[ +77 ms] Running pod install...
00:40 Xcode build done.
[STEP] watchdog: elapsed=761s lines=103996 delta=+44083 last=[ +14 ms] executing: rsync -8 -av --delete .../Runner.app /Users/runner/work/PlanFlow/PlanFlow/build/ios/iphonesimulator
[STEP] watchdog: elapsed=793s lines=104820 delta=+824 last=[ ] Waiting for VM Service port to be available...
EOF
case1_output="$(bash "$markers_script" "$case1_log" "TEST-UDID-CASE1" "124" 2>&1)"
case1_rc=$?
assert_rc "case1_exit_zero" "0" "$case1_rc"
assert_contains "case1_simulator_boot_pass" "$case1_output" "marker=SIMULATOR_BOOT status=PASS"
assert_contains "case1_app_build_pass" "$case1_output" "marker=APP_BUILD status=PASS"
assert_contains "case1_app_install_unknown" "$case1_output" "marker=APP_INSTALL status=UNKNOWN"
assert_contains "case1_app_launch_pass" "$case1_output" "marker=APP_LAUNCH status=PASS"
assert_contains "case1_flutter_attach_fail" "$case1_output" "marker=FLUTTER_ATTACH status=FAIL evidence=VM_SERVICE_WAIT_HANG"
assert_contains "case1_test_discovery_unknown" "$case1_output" "marker=TEST_DISCOVERY status=UNKNOWN"
assert_contains "case1_flow_execution_unknown" "$case1_output" "marker=FLOW_EXECUTION status=UNKNOWN"
assert_contains "case1_first_failed" "$case1_output" "E2E_STAGE_SUMMARY first_failed=FLUTTER_ATTACH"

echo ""

# --- Case 2: full healthy completion ----------------------------------------
# Every anchor present, in a plausible order, and the watchdog exit code is 0
# (no timeout). All seven markers must report PASS and first_failed=NONE.
case2_log="$tmp_dir/case2_healthy_run.log"
cat >"$case2_log" <<'EOF'
00:01 Running pod install...
00:05 executing: xcrun simctl install TEST-UDID-CASE2 .../Runner.app
00:10 Launching lldb...
00:15 Xcode build done.
00:20 VM Service listening on http://127.0.0.1:12345/
00:21 running test package with arguments: [--no-color, --concurrency=1, --, file:///integration_test/flow01_cold_start_test.dart]
00:22 [CHECKPOINT] flow01_before_login
00:30 +12 -0: All tests passed!
EOF
case2_output="$(bash "$markers_script" "$case2_log" "TEST-UDID-CASE2" "0" 2>&1)"
case2_rc=$?
assert_rc "case2_exit_zero" "0" "$case2_rc"
assert_contains "case2_simulator_boot_pass" "$case2_output" "marker=SIMULATOR_BOOT status=PASS"
assert_contains "case2_app_build_pass" "$case2_output" "marker=APP_BUILD status=PASS"
assert_contains "case2_app_install_pass" "$case2_output" "marker=APP_INSTALL status=PASS"
assert_contains "case2_app_launch_pass" "$case2_output" "marker=APP_LAUNCH status=PASS"
assert_contains "case2_flutter_attach_pass" "$case2_output" "marker=FLUTTER_ATTACH status=PASS"
assert_contains "case2_test_discovery_pass" "$case2_output" "marker=TEST_DISCOVERY status=PASS"
assert_contains "case2_flow_execution_pass" "$case2_output" "marker=FLOW_EXECUTION status=PASS"
assert_contains "case2_first_failed_none" "$case2_output" "E2E_STAGE_SUMMARY first_failed=NONE"
assert_not_contains "case2_no_fail_markers" "$case2_output" "status=FAIL"

echo ""

# --- Case 3: empty log file -------------------------------------------------
# A log file that exists but has zero bytes (e.g. e2e_watchdog.sh created it
# via its truncate-on-start step but the child produced no output before
# being killed for an unrelated reason). Every log-derived marker must
# degrade to UNKNOWN — never fabricate a PASS or FAIL from nothing. Exit code
# must still be 0. SIMULATOR_BOOT is independent of the log file, so with a
# udid provided it still reports PASS.
case3_log="$tmp_dir/case3_empty.log"
: >"$case3_log"
case3_output="$(bash "$markers_script" "$case3_log" "TEST-UDID-CASE3" "1" 2>&1)"
case3_rc=$?
assert_rc "case3_exit_zero" "0" "$case3_rc"
assert_contains "case3_simulator_boot_pass" "$case3_output" "marker=SIMULATOR_BOOT status=PASS"
assert_contains "case3_app_build_unknown" "$case3_output" "marker=APP_BUILD status=UNKNOWN"
assert_contains "case3_app_install_unknown" "$case3_output" "marker=APP_INSTALL status=UNKNOWN"
assert_contains "case3_app_launch_unknown" "$case3_output" "marker=APP_LAUNCH status=UNKNOWN"
assert_contains "case3_flutter_attach_unknown" "$case3_output" "marker=FLUTTER_ATTACH status=UNKNOWN"
assert_contains "case3_test_discovery_unknown" "$case3_output" "marker=TEST_DISCOVERY status=UNKNOWN"
assert_contains "case3_flow_execution_unknown" "$case3_output" "marker=FLOW_EXECUTION status=UNKNOWN"
assert_contains "case3_first_failed_none" "$case3_output" "E2E_STAGE_SUMMARY first_failed=NONE"

echo ""

# --- Case 4: log file does not exist at all ---------------------------------
# Distinct from case 3: the path itself was never created (e.g. the run_tests
# step's watchdog invocation never even reached the point of creating
# E2E_WATCHDOG_LOG_FILE). Must not crash and must still exit 0, with the same
# UNKNOWN degradation as the empty-file case.
case4_log="$tmp_dir/case4_does_not_exist.log"
case4_output="$(bash "$markers_script" "$case4_log" "TEST-UDID-CASE4" "" 2>&1)"
case4_rc=$?
assert_rc "case4_exit_zero" "0" "$case4_rc"
assert_contains "case4_app_build_unknown" "$case4_output" "marker=APP_BUILD status=UNKNOWN"
assert_contains "case4_first_failed_none" "$case4_output" "E2E_STAGE_SUMMARY first_failed=NONE"

echo ""

# --- Case 5: credential-shaped text in matched anchor lines must be masked --
# Both the APP_INSTALL anchor line and the FLUTTER_ATTACH success anchor line
# carry credential-shaped text here on purpose, to prove evidence extraction
# never leaks raw secret text even when the secret sits directly inside a
# matched line.
case5_log="$tmp_dir/case5_secrets.log"
cat >"$case5_log" <<'EOF'
00:01 executing: xcrun simctl install TEST-UDID-CASE5 API_KEY=totallysecretvalue123 .../Runner.app
00:40 Xcode build done.
00:41 VM Service listening on http://127.0.0.1:12345/?jwt=eyJhbGciOiJIUzI1NiJ9.secretpayloadsecretpayload.sig
00:42 Waiting for VM Service port to be available...
EOF
case5_output="$(bash "$markers_script" "$case5_log" "TEST-UDID-CASE5" "0" 2>&1)"
case5_rc=$?
assert_rc "case5_exit_zero" "0" "$case5_rc"
assert_not_contains "case5_no_raw_api_key" "$case5_output" "totallysecretvalue123"
assert_not_contains "case5_no_raw_jwt_payload" "$case5_output" "secretpayloadsecretpayload"
assert_contains "case5_api_key_masked" "$case5_output" "API_KEY=<MASKED>"
assert_contains "case5_jwt_masked" "$case5_output" "<MASKED_JWT>"
# The install/attach anchors themselves must still have been found (masking
# must redact the secret text, not swallow the whole matched line).
assert_contains "case5_app_install_pass" "$case5_output" "marker=APP_INSTALL status=PASS"
assert_contains "case5_flutter_attach_pass" "$case5_output" "marker=FLUTTER_ATTACH status=PASS"

echo ""
echo "=== Results: $pass_count passed, $fail_count failed ==="

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
