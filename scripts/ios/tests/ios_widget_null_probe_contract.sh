#!/usr/bin/env bash
# Static, macOS-independent contract checks for the HomeWidget null-storage
# native probe pair: integration_test/ios_widget_nullable_storage_test.dart
# and .github/workflows/ios-widget-null-probe.yml.
#
# The probe exists to prove, on a real iOS simulator only, that the patched
# production adapter (lib/services/home_widget_platform_io.dart) never lets a
# Dart null reach home_widget's iOS UserDefaults setValue as NSNull. This
# contract keeps that promise auditable from any host (including Windows):
# it pins the real-SDK-only, fail-closed, QA-branch-scoped shape of the pair
# without executing Flutter, Xcode, or a simulator.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null 2>&1 && pwd)"
probe_dart="$repo_root/integration_test/ios_widget_nullable_storage_test.dart"
workflow="$repo_root/.github/workflows/ios-widget-null-probe.yml"
identity_xcconfig="$repo_root/ios/Flutter/PlanFlow-Identity.xcconfig"
qa_branch="fix/pre-ring-departure-eta-20261008"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

[ -f "$probe_dart" ] || fail "probe integration test is missing: $probe_dart"
[ -f "$workflow" ] || fail "probe workflow is missing: $workflow"
[ -f "$identity_xcconfig" ] || fail "ios/Flutter/PlanFlow-Identity.xcconfig is missing"

dart_text="$(cat "$probe_dart")"
workflow_text="$(cat "$workflow")"

# --- Probe integration test: real SDK, real iOS gate, honest markers -------

printf '%s' "$dart_text" | grep -qF -- 'IntegrationTestWidgetsFlutterBinding.ensureInitialized()' || \
  fail 'probe test does not initialize the official integration test binding'
printf '%s' "$dart_text" | grep -qF -- "import 'dart:io'" || \
  fail 'probe test must gate on dart:io Platform, not debug overrides'
printf '%s' "$dart_text" | grep -qF -- '!Platform.isIOS' || \
  fail 'probe test is missing the dart:io.Platform.isIOS fail-closed gate'
printf '%s' "$dart_text" | grep -qF -- 'markTestSkipped(' || \
  fail 'probe test must report a non-iOS host as skipped, never as green'
printf '%s' "$dart_text" | grep -qF -- 'IOS_NATIVE_WIDGET_NULL_PROBE_SKIPPED' || \
  fail 'probe test is missing the SKIPPED anti-green marker'

printf '%s' "$dart_text" | grep -qF -- 'createHomeWidgetPlatformImpl()' || \
  fail 'probe test must use the production IO adapter factory'
printf '%s' "$dart_text" | grep -qF -- 'platform.setAppGroupId' || \
  fail 'probe test must initialize the real app group through the production adapter'
printf '%s' "$dart_text" | grep -qF -- 'HomeWidget.saveWidgetData' || \
  fail 'probe test must seed values through the real home_widget SDK'
printf '%s' "$dart_text" | grep -qF -- 'HomeWidget.getWidgetData' || \
  fail 'probe test must verify typed native readback through the real SDK'

marker_count="$(printf '%s' "$dart_text" | grep -F -- 'IOS_NATIVE_WIDGET_NULL_PROBE_PASS' | grep -cvE '^[[:space:]]*//' || true)"
[ "$marker_count" -eq 1 ] || \
  fail "probe PASS marker must appear exactly once as a code literal (found $marker_count)"

app_group="$(sed -nE 's/^PLANFLOW_IOS_APP_GROUP = ([^[:space:]]+).*/\1/p' "$identity_xcconfig" | head -n1)"
[ -n "$app_group" ] || fail 'could not read PLANFLOW_IOS_APP_GROUP from ios/Flutter/PlanFlow-Identity.xcconfig'
printf '%s' "$dart_text" | grep -qF -- "const String _probeAppGroup = '$app_group';" || \
  fail "probe app group literal does not match ios/Flutter/PlanFlow-Identity.xcconfig value '$app_group'"

for probe_key in next_event_id next_event_start_at gw_testname next_event_travel_buffer_minutes; do
  printf '%s' "$dart_text" | grep -qF -- "'$probe_key'" || \
    fail "probe test is missing production nullable key '$probe_key'"
done

# Fake/mock isolation: no channel mocks, no fake platforms, no production
# app bootstrap, no harness coupling. (Checked against import/call shapes
# on code lines; prose comments may reference what is being avoided.)
if printf '%s' "$dart_text" | grep -vE '^[[:space:]]*//' | grep -nE -- "setMockMethodCallHandler|TestDefaultBinaryMessenger|_CapturingHomeWidgetPlatform|import '_harness|import 'package:planflow/app\.dart'|import 'package:http/|import 'package:supabase_flutter/" ; then
  fail 'probe test must not mock the method channel or pull app/backend code'
fi
if printf '%s' "$dart_text" | grep -vE '^[[:space:]]*//' | grep -qF -- 'runApp'; then
  fail 'probe test must not boot the production app; only a minimal MaterialApp scaffold is allowed'
fi
pass 'probe integration test: official binding, dart:io iOS gate, real SDK calls, unique markers'

# --- Workflow: manual + QA-branch-scoped push, fail-closed evidence --------

printf '%s' "$workflow_text" | grep -qF -- 'workflow_dispatch:' || \
  fail 'workflow must keep a manual workflow_dispatch trigger'
printf '%s' "$workflow_text" | grep -qE -- '^  (pull_request|schedule):' && \
  fail 'workflow must not auto-run on pull_request or a schedule'
printf '%s' "$workflow_text" | grep -qF -- 'runs-on: macos-15' || \
  fail 'workflow must stay pinned to the validated macos-15 runner generation'
printf '%s' "$workflow_text" | grep -qF -- 'macos-latest' && \
  fail 'workflow must not use the unvalidated macos-latest image'
printf '%s' "$workflow_text" | grep -qF -- 'Xcode_16.4.app' || \
  fail 'workflow must prefer the known Xcode 16.4 toolchain explicitly'
printf '%s' "$workflow_text" | grep -qF -- 'BLOCKED_XCODE16_MISSING' || \
  fail 'workflow must fail closed when no Xcode 16 toolchain is installed'
printf '%s' "$workflow_text" | grep -qF -- 'DEVELOPER_DIR=' || \
  fail 'workflow must pin the selected Xcode via DEVELOPER_DIR for every later step'
printf '%s' "$workflow_text" | grep -qF -- 'xcodebuild -version' || \
  fail 'workflow must persist an xcodebuild -version receipt'
printf '%s' "$workflow_text" | grep -qF -- '--show-sdk-version' || \
  fail 'workflow must persist the iphonesimulator SDK version receipt'
printf '%s' "$workflow_text" | grep -qF -- 'simctl list runtimes' || \
  fail 'workflow must persist the simulator runtime receipt'
printf '%s' "$workflow_text" | grep -qF -- 'flutter-version: 3.47.2' || \
  fail 'workflow must pin the validated Flutter version 3.47.2'
printf '%s' "$workflow_text" | grep -qF -- 'cache: true' || \
  fail 'workflow must reuse the cached flutter-action setup (no new tool installs)'

branch_block="$(sed -n '/^    branches:/,/^    paths:/p' "$workflow" | grep -E '^      - ' | sed -E "s/^      - ['\"]?([^'\" ]+).*/\1/")"
branch_count="$(printf '%s' "$branch_block" | grep -c . || true)"
[ "$branch_count" -eq 1 ] || \
  fail "push trigger must list exactly one branch (found $branch_count)"
[ "$branch_block" = "$qa_branch" ] || \
  fail "push trigger branch must be exactly '$qa_branch' (found '$branch_block')"

paths_block="$(sed -n '/^    paths:/,/^[a-z][a-z_]*:/p' "$workflow" | grep -E '^      - ' | sed -E "s/^      - ['\"]//; s/['\"]$//")"
for required_path in integration_test/ios_widget_nullable_storage_test.dart scripts/ios/tests/ios_widget_null_probe_contract.sh lib/services/home_widget_platform_io.dart .github/workflows/ios-widget-null-probe.yml; do
  printf '%s' "$paths_block" | grep -qx -- "$required_path" || \
    fail "push paths filter must include '$required_path'"
done
path_count="$(printf '%s' "$paths_block" | grep -c . || true)"
[ "$path_count" -eq 4 ] || \
  fail "push paths filter must stay scoped to the probe pair + IO patch + the workflow itself (found $path_count entries)"
printf '%s' "$paths_block" | grep -qF -- '**' && \
  fail 'push paths filter must not use catch-all globs'

printf '%s' "$workflow_text" | grep -qF -- 'permissions:' || \
  fail 'workflow must declare least-privilege permissions'
printf '%s' "$workflow_text" | grep -qE -- '^  contents: read' || \
  fail 'workflow must be contents: read only'
printf '%s' "$workflow_text" | grep -qE -- '\$\{\{[[:space:]]*secrets\.' && \
  fail 'probe workflow must not reference any repository secrets'
printf '%s' "$workflow_text" | grep -qiE -- 'testflight|fastlane|altool|notariz|upload-release' && \
  fail 'probe workflow must not deploy or publish anything'

printf '%s' "$workflow_text" | grep -qF -- 'scripts/ios/simctl_discover.sh' || \
  fail 'workflow must reuse the validated simulator discovery helper'
printf '%s' "$workflow_text" | grep -qF -- 'category == "mainstream"' || \
  fail 'workflow must select the discovered phone (mainstream) category'
printf '%s' "$workflow_text" | grep -qF -- 'category == "ipad"' || \
  fail 'workflow must select the discovered tablet (ipad) category'
printf '%s' "$workflow_text" | grep -qF -- '"$count" -ne 2' || \
  fail 'workflow must require exactly two probe simulators (phone + tablet)'
printf '%s' "$workflow_text" | grep -qF -- '"$mainstream_count" -ne 1' || \
  fail 'workflow must require exactly one mainstream (phone) simulator'
printf '%s' "$workflow_text" | grep -qF -- '"$ipad_count" -ne 1' || \
  fail 'workflow must require exactly one ipad (tablet) simulator'
printf '%s' "$workflow_text" | grep -qF -- 'exit "${status:-1}"' && \
  fail 'boot failure branch must exit 1 even when watchdog status is 0 with an empty udid'
if ! printf '%s' "$workflow_text" | grep -A2 -F -- '-ne 0 || -z "$udid"' | grep -qF -- 'exit 1'; then
  fail 'boot failure branch must exit 1 when the udid is empty'
fi
printf '%s' "$workflow_text" | grep -qF -- 'xcrun simctl shutdown' || \
  fail 'workflow must always shut down its own simulator'
printf '%s' "$workflow_text" | grep -qF -- 'xcrun simctl delete' || \
  fail 'workflow must always delete its own simulator'
printf '%s' "$workflow_text" | grep -qF -- 'scripts/ios/e2e_xctest_flow.sh' || \
  fail 'workflow must run the probe through the official XCTest host helper'
printf '%s' "$workflow_text" | grep -qF -- 'integration_test/ios_widget_nullable_storage_test.dart' || \
  fail 'workflow must run the probe integration test file'

printf '%s' "$workflow_text" | grep -qF -- "grep -qF 'IOS_NATIVE_WIDGET_NULL_PROBE_PASS'" || \
  fail 'workflow must fail closed unless the native PASS marker is grepped from the logs'
printf '%s' "$workflow_text" | grep -qF -- "grep -qF 'IOS_NATIVE_WIDGET_NULL_PROBE_SKIPPED'" || \
  fail 'workflow must fail closed when the probe reports SKIPPED'
printf '%s' "$workflow_text" | grep -qF -- 'Executed [1-9][0-9]* tests?' || \
  fail 'workflow must require executed (non-zero) XCTest cases, not just build success'
pass 'probe workflow: scoped triggers, pinned runner, owned-sim lifecycle, fail-closed native evidence'

echo 'ios_widget_null_probe_contract.sh: all checks passed'
