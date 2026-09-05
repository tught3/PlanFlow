#!/usr/bin/env bash
# Static contract checks for the official XCTest-host E2E runner.
#
# This deliberately inspects the real workflow and runner source.  It does
# not claim a macOS/Xcode build passed; that evidence can only come from the
# macOS workflow itself.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null 2>&1 && pwd)"
workflow="$repo_root/.github/workflows/ios-simulator-e2e.yml"
runner="$repo_root/scripts/ios/e2e_xctest_flow.sh"
podfile="$repo_root/ios/Podfile"
pbxproj="$repo_root/ios/Runner.xcodeproj/project.pbxproj"
objc_runner="$repo_root/ios/RunnerTests/RunnerTests.m"
host_flow="$repo_root/test/ios_e2e_flow05_fake_test.dart"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

for required in "$workflow" "$runner" "$podfile" "$pbxproj" "$objc_runner" "$host_flow"; do
  [ -f "$required" ] || fail "missing required file: $required"
done

workflow_text="$(cat "$workflow")"
runner_text="$(cat "$runner")"

workflow_runs_on="$(printf '%s\n' "$workflow_text" | grep -E '^[[:space:]]+runs-on:' || true)"
if printf '%s\n' "$workflow_runs_on" | grep -qF -- 'macos-latest'; then
  fail 'simulator E2E workflow must not float onto the Xcode 26 macos-latest image'
fi
if [ "$(printf '%s\n' "$workflow_runs_on" | grep -cF -- 'runs-on: macos-15')" -ne 3 ]; then
  fail 'simulator E2E workflow must pin preflight, FLOW5 host, and simulator jobs to macos-15'
fi
pass 'simulator E2E jobs are pinned to the Xcode 16 macOS image'

if printf '%s' "$workflow_text" | grep -qE -- 'flutter[[:space:]]+test.*-d|-d.*flutter[[:space:]]+test'; then
  fail 'workflow still contains a flutter test device-runner invocation'
fi
if printf '%s' "$workflow_text" | grep -qF -- 'flutter drive'; then
  fail 'workflow still contains flutter drive'
fi
if printf '%s' "$runner_text" | grep -qF -- 'flutter test'; then
  fail 'XCTest runner still contains flutter test'
fi
if printf '%s' "$runner_text" | grep -qF -- 'flutter drive'; then
  fail 'XCTest runner still contains flutter drive'
fi
pass 'legacy device runners absent from workflow and runner'

expected_stages=(
  SIMULATOR_BOOT APP_BUILD APP_INSTALL APP_LAUNCH APP_READY
  TEST_DRIVER_ATTACH TEST_DISCOVERY FLOW_EXECUTION TEARDOWN
)
previous=0
for stage in "${expected_stages[@]}"; do
  line="$(printf '%s\n' "$runner_text" | grep -nF -- "$stage" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$line" ] || fail "stage missing from runner: $stage"
  if [ "$line" -lt "$previous" ]; then
    fail "stage order is not monotonic at $stage"
  fi
  previous="$line"
done
pass 'nine bounded stages are declared in the required order'

printf '%s' "$runner_text" | grep -qF -- 'e2e_watchdog.sh' || fail 'runner is not bounded by e2e_watchdog.sh'
printf '%s' "$runner_text" | grep -qF -- 'E2E_WATCHDOG_HEARTBEAT_INTERVAL' || fail 'runner does not enable heartbeat diagnostics'
printf '%s' "$runner_text" | grep -qF -- 'derivedDataPath' || fail 'runner does not isolate derived data'
printf '%s' "$runner_text" | grep -qF -- '-resultBundlePath' || fail 'runner does not produce an xcresult bundle'
printf '%s' "$runner_text" | grep -qF -- 'test-without-building' || fail 'runner does not use XCTest test-without-building'
printf '%s' "$runner_text" | grep -qF -- 'only-testing:RunnerTests' || fail 'runner target is not scoped to RunnerTests'
printf '%s' "$runner_text" | grep -qF -- '-parallel-testing-enabled NO' || fail 'XCTest runner does not disable parallel test clones'
pass 'bounded xcodebuild and xcresult contract present'

app_build_block="$(printf '%s\n' "$runner_text" | awk '/flutter build ios --config-only/,/xcodebuild build-for-testing/ { print }')"
printf '%s' "$app_build_block" | grep -qF -- 'flutter build ios --config-only' || fail 'runner missing the config-only Flutter build'
printf '%s' "$app_build_block" | grep -qF -- '--simulator' || fail 'config-only Flutter build does not explicitly target the simulator path'
if printf '%s' "$app_build_block" | grep -qF -- 'flutter build ios --config-only' \
  && ! printf '%s' "$app_build_block" | grep -qF -- '--simulator'; then
  fail 'config-only Flutter build regressed to device-only targeting'
fi
pass 'config-only Flutter build is explicitly simulator-targeted'

printf '%s' "$runner_text" | grep -qF -- 'trap - EXIT' || fail 'runner exit handler does not detach its own EXIT trap'
printf '%s' "$runner_text" | grep -qF -- 'if [ "$exit_status" -ne 0 ]; then' || fail 'runner exit handler does not preserve nonzero exit status'
printf '%s' "$runner_text" | grep -qF -- 'if [ "$cleanup_rc" -ne 0 ]; then' || fail 'runner exit handler does not inspect cleanup failure'
printf '%s' "$runner_text" | grep -qF -- 'exit "$cleanup_rc"' || fail 'runner exit handler does not propagate cleanup failure'
if printf '%s' "$runner_text" | grep -qF -- 'trap cleanup EXIT'; then
  fail 'runner still uses the recursive cleanup EXIT trap'
fi
pass 'exit handler propagates cleanup failure without recursion'

printf '%s' "$podfile" >/dev/null
runner_target_start="$(grep -nF -- "target 'Runner' do" "$podfile" | head -n 1 | cut -d: -f1)"
runner_tests_start="$(grep -nF -- "target 'RunnerTests' do" "$podfile" | head -n 1 | cut -d: -f1 || true)"
[ -n "$runner_tests_start" ] || fail 'Podfile does not define RunnerTests'
runner_target_end="$(awk -v start="$runner_target_start" 'NR > start && /^[[:space:]]*end[[:space:]]*$/ { print NR; exit }' "$podfile")"
[ -n "$runner_target_end" ] || fail 'Podfile Runner target has no closing end'
if [ "$runner_tests_start" -lt "$runner_target_end" ]; then
  fail 'RunnerTests must be a top-level target, not nested under Runner'
fi
runner_tests_block="$(awk -v start="$runner_tests_start" 'NR >= start { print; if (NR > start && /^[[:space:]]*end[[:space:]]*$/) exit }' "$podfile")"
printf '%s\n' "$runner_tests_block" | grep -qF -- 'use_frameworks! :linkage => :static' || fail 'RunnerTests does not declare its own static framework linkage'
printf '%s\n' "$runner_tests_block" | grep -qF -- 'use_modular_headers!' || fail 'RunnerTests does not declare modular headers for integration_test'
printf '%s\n' "$runner_tests_block" | grep -qF -- 'flutter_install_ios_engine_pod File.dirname(File.realpath(__FILE__))' || fail 'RunnerTests does not install the Flutter engine-only pod helper'
printf '%s\n' "$runner_tests_block" | grep -qF -- "pod 'integration_test', :path => '.symlinks/plugins/integration_test/ios'" || fail 'RunnerTests does not explicitly add the integration_test pod from the Flutter helper-compatible path'
if printf '%s\n' "$runner_tests_block" | grep -qF -- 'inherit!'; then
  fail 'RunnerTests must not use parent pod inheritance directives'
fi
if printf '%s\n' "$runner_tests_block" | grep -qF -- "flutter_install_all_ios_pods"; then
  fail 'RunnerTests must not install the Runner app pod set'
fi
if printf '%s\n' "$runner_tests_block" | grep -E -- '^[[:space:]]*pod ' | grep -vF -- "pod 'integration_test', :path => '.symlinks/plugins/integration_test/ios'" | grep -q .; then
  fail 'RunnerTests must not declare app or plugin pods beyond integration_test'
fi
pass 'RunnerTests is an independent aggregate target with only integration_test'

runner_tests_config_list="$(awk '/Build configuration list for PBXNativeTarget "RunnerTests"/,/^[[:space:]]*};$/' "$pbxproj")"
for config_name in Debug Release Profile; do
  config_id="$(printf '%s\n' "$runner_tests_config_list" | grep -F -- "/* $config_name */" | sed -E 's/^[[:space:]]*([^ ]+).*/\1/' | head -n 1)"
  [ -n "$config_id" ] || fail "RunnerTests configuration list is missing $config_name"
  config_block="$(awk -v id="$config_id" '$0 ~ "^[[:space:]]*" id " /\\*" { found=1 } found { print } found && /^[[:space:]]*};$/ { exit }' "$pbxproj")"
  printf '%s\n' "$config_block" | grep -qF -- "RunnerTests-$config_name.xcconfig" || fail "RunnerTests $config_name does not use its target-specific xcconfig"
done
pass 'RunnerTests Debug/Release/Profile use target-specific base configurations'

for config_name in Debug Release Profile; do
  config_file="$repo_root/ios/Flutter/RunnerTests-$config_name.xcconfig"
  [ -f "$config_file" ] || fail "missing RunnerTests target xcconfig: $config_file"
  config_text="$(cat "$config_file")"
  printf '%s\n' "$config_text" | grep -qF -- "Pods/Target Support Files/Pods-RunnerTests/Pods-RunnerTests.$(printf '%s' "$config_name" | tr '[:upper:]' '[:lower:]').xcconfig" || fail "RunnerTests $config_name does not include Pods-RunnerTests support config"
  printf '%s\n' "$config_text" | grep -qF -- '#include? ' || fail "RunnerTests $config_name Pods include is not optional"
  printf '%s\n' "$config_text" | grep -qF -- '#include "PlanFlow-Identity.xcconfig"' || fail "RunnerTests $config_name loses PlanFlow identity settings"
  printf '%s\n' "$config_text" | grep -qF -- '#include "Generated.xcconfig"' || fail "RunnerTests $config_name loses Flutter generated settings"
done
pass 'RunnerTests xcconfigs are optional CocoaPods-compatible and preserve identity/generated settings'

if printf '%s\n' "$runner_tests_config_list" | grep -E -q -- 'Debug\.xcconfig|Release\.xcconfig([^[:alnum:]_-]|$)'; then
  fail 'RunnerTests configuration list still references shared Runner xcconfigs'
fi
for protected in "$repo_root/ios/Flutter/Debug.xcconfig" "$repo_root/ios/Flutter/Release.xcconfig"; do
  git -C "$repo_root" diff --quiet -- "$protected" || fail "protected shared xcconfig has an uncommitted change: $protected"
done
pass 'shared Runner Debug/Release xcconfigs remain protected and unchanged'

grep -qF -- 'INTEGRATION_TEST_IOS_RUNNER(RunnerTests)' "$objc_runner" || fail 'official integration_test XCTest macro missing'
grep -qF -- '@import integration_test;' "$objc_runner" || fail 'integration_test module import missing'
grep -qF -- 'RunnerTests.m' "$pbxproj" || fail 'pbxproj does not reference RunnerTests.m'
if grep -qF -- 'RunnerTests.swift' "$pbxproj"; then
  fail 'pbxproj still references the Swift XCTest stub'
fi
pass 'official Objective-C integration_test host wiring present'

grep -qF -- 'E2E_REAL_BACKEND_TEST=0' "$workflow" || fail 'workflow does not force fake-only FLOW5 mode'
grep -qF -- 'ios_e2e_flow05_fake_test.dart' "$workflow" || fail 'host FLOW5 test is not wired'
if grep -qE -- 'PLANFLOW_SUPABASE|E2E_TEST_ACCOUNT|SUPABASE_ANON_KEY=.*\$\{\{ *secrets' "$workflow"; then
  fail 'host-only workflow carries backend secret wiring'
fi
if grep -qF -- 'com.fluxstudio.planflow' "$host_flow"; then
  fail 'host fake FLOW5 test unexpectedly hardcodes an iOS bundle id'
fi
pass 'FLOW5 host fake path is secret-free and non-production'

for forbidden in 'app-storeconnect' 'altool' 'Transporter' 'testflight' 'upload-to'; do
  if printf '%s' "$workflow_text" | grep -qiF -- "$forbidden"; then
    fail "forbidden upload term appears in simulator E2E workflow: $forbidden"
  fi
done
pass 'simulator E2E workflow has no upload path'

echo 'e2e_xctest_runner_contract.sh: all checks passed'
