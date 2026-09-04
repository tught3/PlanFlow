#!/usr/bin/env bash
# Contract/regression tests for scripts/ios/simctl_discover.sh.
#
# These are NOT unit tests with mocks in the sense of stubbing out the
# script's own logic: each case runs the REAL simctl_discover.sh as a real
# subprocess, feeding it fixture `simctl list runtimes -j` / `simctl list
# devicetypes -j` JSON via the script's own SIMCTL_DISCOVER_*_JSON_FILE test
# seams, and (where needed) a fixture SDK version via
# SIMCTL_DISCOVER_SDK_VERSION or a fake `xcrun` stub on PATH. Per this repo's
# existing safety-gate convention ("a safety gate needs at least one test
# that passes real input through it, not just a test that mocks the thing
# the gate reads"), every case below exercises the script's real branching
# logic end to end; only the three live `xcrun`/`xcodebuild`/`simctl` calls
# are substituted, via the seams the script itself defines for this purpose.
#
# Background: GitHub Actions Run#4 real console logs showed 4 of 5
# ios-simulator-e2e.yml jobs hanging forever at
# "Waiting for VM Service port to be available...". Root cause: this script
# used to always pick the globally-newest available iOS simulator runtime
# via `sort_by(.version) | last`, with no regard for what iOS SDK ceiling
# the runner's actual active Xcode toolchain supports building against — a
# newer runtime than the active Xcode's SDK creates a CoreSimulator/Xcode
# generation mismatch that breaks VM Service discovery. This file locks in
# the fix: runtime selection is now bounded by the active Xcode's
# iphonesimulator SDK major version, and refuses to guess (fails closed)
# when that ceiling cannot be determined, rather than silently falling back
# to "pick the newest one anyway" (which is exactly the bug being fixed).
#
# Usage: bash scripts/ios/tests/simctl_discover_contract.sh
# Exit code: 0 if every case passes, 1 if any case fails.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
discover_script="$script_dir/../simctl_discover.sh"

if [ ! -f "$discover_script" ]; then
  echo "simctl_discover_contract.sh: cannot find simctl_discover.sh at $discover_script" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  # (Review round-2 fix, LOW: this previously said "...; skipping this
  # suite" while still exiting 1, which reads as though the missing-jq case
  # is harmless/skipped when it is actually a hard failure of this suite —
  # `exit 1` here is deliberate fail-closed behavior, not a skip.)
  echo "simctl_discover_contract.sh: jq is required to validate simctl_discover.sh's JSON output; failing this suite (jq required)" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

pass_count=0
fail_count=0

# --- Shared devicetypes fixture ---------------------------------------------
# One devicetype per category this script picks for (small/SE, mainstream/
# plain iPhone-N, large/Pro-Max, ipad/iPad Pro), reused by every runtime
# fixture below via matching `supportedDeviceTypes` identifiers.
devicetypes_file="$tmp_dir/devicetypes.json"
cat > "$devicetypes_file" <<'EOF'
{
  "devicetypes": [
    {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation", "name": "iPhone SE (3rd generation)"},
    {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "name": "iPhone 16"},
    {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max", "name": "iPhone 16 Pro Max"},
    {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4", "name": "iPad Pro 13-inch (M4)"}
  ]
}
EOF

devicetype_ids='["com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation","com.apple.CoreSimulator.SimDeviceType.iPhone-16","com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max","com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4"]'

# make_runtime_fixture <output_file> <runtime-spec>...
#
# Each <runtime-spec> is "version:identifier:isAvailable" (isAvailable is
# "true" or "false"). Every runtime gets the full shared devicetype id list
# as its supportedDeviceTypes, so any selected runtime always has a
# candidate in all four categories.
make_runtime_fixture() {
  local out_file="$1"
  shift
  local runtimes_arr="[]"
  for spec in "$@"; do
    local version="${spec%%:*}"
    local rest="${spec#*:}"
    local identifier="${rest%%:*}"
    local is_available="${rest#*:}"
    runtimes_arr="$(
      echo "$runtimes_arr" | jq -c \
        --arg version "$version" \
        --arg identifier "$identifier" \
        --argjson isAvailable "$is_available" \
        --argjson deviceTypeIds "$devicetype_ids" \
        '. + [{
          "version": $version,
          "identifier": $identifier,
          "isAvailable": $isAvailable,
          "name": ("iOS " + $version),
          "supportedDeviceTypes": [$deviceTypeIds[] | {"identifier": .}]
        }]'
    )"
  done
  echo "$runtimes_arr" | jq -c '{"runtimes": .}' > "$out_file"
}

# run_discover <extra env NAME=value pairs...> -- (nothing else; script path is fixed)
#
# Runs the real simctl_discover.sh as a subprocess with the given
# environment additions, capturing stdout, stderr, and exit code separately
# into globals so callers can assert on any of them. Always passes the
# shared devicetypes fixture unless the caller's own env already set
# SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE (case4 needs this NOT set to a
# working file in one sub-scenario — but in practice every case here does
# want the shared fixture, so callers simply don't need to override it).
DISCOVER_STDOUT=""
DISCOVER_STDERR=""
DISCOVER_RC=0
run_discover() {
  local stderr_file="$tmp_dir/last_stderr.txt"
  DISCOVER_STDOUT="$(env "$@" bash "$discover_script" 2>"$stderr_file")"
  DISCOVER_RC=$?
  DISCOVER_STDERR="$(cat -- "$stderr_file")"
}

# assert_rc <case_name> <expected_rc>
assert_rc() {
  local case_name="$1"
  local expected_rc="$2"
  if [ "$expected_rc" = "$DISCOVER_RC" ]; then
    echo "PASS: $case_name (rc=$DISCOVER_RC)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $case_name — expected rc=$expected_rc, got rc=$DISCOVER_RC"
    echo "  --- stdout ---"; printf '%s\n' "$DISCOVER_STDOUT" | sed 's/^/  /'
    echo "  --- stderr ---"; printf '%s\n' "$DISCOVER_STDERR" | sed 's/^/  /'
    fail_count=$((fail_count + 1))
  fi
}

# assert_stderr_contains <case_name> <expected_substring>
assert_stderr_contains() {
  local case_name="$1"
  local expected="$2"
  if printf '%s' "$DISCOVER_STDERR" | grep -qF -- "$expected"; then
    echo "PASS: $case_name (stderr contains: \"$expected\")"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $case_name — stderr does not contain: \"$expected\""
    echo "  --- stderr ---"; printf '%s\n' "$DISCOVER_STDERR" | sed 's/^/  /'
    fail_count=$((fail_count + 1))
  fi
}

# assert_stdout_empty <case_name>
assert_stdout_empty() {
  local case_name="$1"
  if [ -z "$DISCOVER_STDOUT" ]; then
    echo "PASS: $case_name (stdout is empty — no runtime JSON was printed)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $case_name — expected empty stdout (no fallback runtime should ever be printed on this failure path), got:"
    printf '%s\n' "$DISCOVER_STDOUT" | sed 's/^/  /'
    fail_count=$((fail_count + 1))
  fi
}

# assert_selected_runtime <case_name> <expected_runtime_id>
#
# Parses DISCOVER_STDOUT as the script's JSON array and asserts every
# element's runtime_id equals expected_runtime_id (all categories always
# share one selected runtime per run).
assert_selected_runtime() {
  local case_name="$1"
  local expected_id="$2"
  local actual_ids
  actual_ids="$(printf '%s' "$DISCOVER_STDOUT" | jq -r '[.[].runtime_id] | unique | join(",")' 2>/dev/null)"
  if [ "$actual_ids" = "$expected_id" ]; then
    echo "PASS: $case_name (selected runtime_id: $actual_ids)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $case_name — expected runtime_id '$expected_id', got '$actual_ids'"
    echo "  --- stdout ---"; printf '%s\n' "$DISCOVER_STDOUT" | sed 's/^/  /'
    fail_count=$((fail_count + 1))
  fi
}

echo "=== simctl_discover.sh contract tests ==="
echo ""

# --- Case 1: SDK major=18, candidates {17.5, 18.4, 26.5} -> 18.4 selected,
#     26.5 (newer major generation than the active SDK) rejected -----------
case1_runtimes="$tmp_dir/case1_runtimes.json"
make_runtime_fixture "$case1_runtimes" \
  "17.5:com.apple.CoreSimulator.SimRuntime.iOS-17-5:true" \
  "18.4:com.apple.CoreSimulator.SimRuntime.iOS-18-4:true" \
  "26.5:com.apple.CoreSimulator.SimRuntime.iOS-26-5:true"

run_discover \
  SIMCTL_DISCOVER_SDK_VERSION=18.5 \
  SIMCTL_DISCOVER_RUNTIMES_JSON_FILE="$case1_runtimes" \
  SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE="$devicetypes_file"
assert_rc "case1_bounded_selection_rc" "0"
assert_selected_runtime "case1_bounded_selection_picks_18_4_not_26_5" "com.apple.CoreSimulator.SimRuntime.iOS-18-4"
assert_stderr_contains "case1_diagnostic_mentions_sdk_major" "active Xcode iphonesimulator SDK major=18"

echo ""

# --- Case 2: same-major, higher-minor runtime IS allowed (SDK 18.5, runtime
#     18.6 is not excluded merely for having a higher minor than the SDK
#     itself — the filter compares MAJOR version only) --------------------
case2_runtimes="$tmp_dir/case2_runtimes.json"
make_runtime_fixture "$case2_runtimes" \
  "18.4:com.apple.CoreSimulator.SimRuntime.iOS-18-4:true" \
  "18.6:com.apple.CoreSimulator.SimRuntime.iOS-18-6:true" \
  "26.5:com.apple.CoreSimulator.SimRuntime.iOS-26-5:true"

run_discover \
  SIMCTL_DISCOVER_SDK_VERSION=18.5 \
  SIMCTL_DISCOVER_RUNTIMES_JSON_FILE="$case2_runtimes" \
  SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE="$devicetypes_file"
assert_rc "case2_same_major_higher_minor_allowed_rc" "0"
assert_selected_runtime "case2_same_major_higher_minor_allowed_picks_18_6" "com.apple.CoreSimulator.SimRuntime.iOS-18-6"

echo ""

# --- Case 3: filtering leaves zero candidates -> BLOCKED_NO_COMPATIBLE_RUNTIME,
#     exit 1 --------------------------------------------------------------
case3_runtimes="$tmp_dir/case3_runtimes.json"
make_runtime_fixture "$case3_runtimes" \
  "17.5:com.apple.CoreSimulator.SimRuntime.iOS-17-5:true" \
  "18.4:com.apple.CoreSimulator.SimRuntime.iOS-18-4:true" \
  "26.5:com.apple.CoreSimulator.SimRuntime.iOS-26-5:true"

run_discover \
  SIMCTL_DISCOVER_SDK_VERSION=10.0 \
  SIMCTL_DISCOVER_RUNTIMES_JSON_FILE="$case3_runtimes" \
  SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE="$devicetypes_file"
assert_rc "case3_no_compatible_runtime_rc" "1"
assert_stderr_contains "case3_no_compatible_runtime_error_title" "BLOCKED_NO_COMPATIBLE_RUNTIME"
assert_stdout_empty "case3_no_compatible_runtime_stdout_empty"

echo ""

# --- Case 4: SDK probe itself fails (active Xcode SDK ceiling cannot be
#     determined) -> BLOCKED_NO_ACTIVE_IOS_SDK, exit 1, and — critically —
#     NEVER falls back to picking the newest runtime anyway. A fake `xcrun`
#     stub is put on PATH ahead of any real one so this exercises the
#     script's real probe-failure branch (real `xcrun --show-sdk-version`
#     failing) rather than a fixture value standing in for a version. -----
fakebin_dir="$tmp_dir/fakebin"
mkdir -p "$fakebin_dir"
cat > "$fakebin_dir/xcrun" <<'EOF'
#!/usr/bin/env bash
# Fixture stub: every invocation fails with no stdout, simulating a runner
# where `xcrun --sdk iphonesimulator --show-sdk-version` cannot resolve an
# active Xcode SDK. Never called for the runtimes/devicetypes list queries
# in this case because those are seam-covered by JSON fixture files instead.
exit 1
EOF
chmod +x "$fakebin_dir/xcrun"

case4_runtimes="$tmp_dir/case4_runtimes.json"
make_runtime_fixture "$case4_runtimes" \
  "18.4:com.apple.CoreSimulator.SimRuntime.iOS-18-4:true" \
  "26.5:com.apple.CoreSimulator.SimRuntime.iOS-26-5:true"

run_discover \
  PATH="$fakebin_dir:$PATH" \
  SIMCTL_DISCOVER_RUNTIMES_JSON_FILE="$case4_runtimes" \
  SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE="$devicetypes_file"
assert_rc "case4_sdk_probe_failure_rc" "1"
assert_stderr_contains "case4_sdk_probe_failure_error_title" "BLOCKED_NO_ACTIVE_IOS_SDK"
assert_stdout_empty "case4_sdk_probe_failure_never_falls_back_to_newest"

echo ""

# --- Case 5: SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME=1 bypasses the SDK filter and
#     restores "pick the globally newest available runtime" -------------
case5_runtimes="$tmp_dir/case5_runtimes.json"
make_runtime_fixture "$case5_runtimes" \
  "17.5:com.apple.CoreSimulator.SimRuntime.iOS-17-5:true" \
  "18.4:com.apple.CoreSimulator.SimRuntime.iOS-18-4:true" \
  "26.5:com.apple.CoreSimulator.SimRuntime.iOS-26-5:true"

run_discover \
  SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME=1 \
  SIMCTL_DISCOVER_RUNTIMES_JSON_FILE="$case5_runtimes" \
  SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE="$devicetypes_file"
assert_rc "case5_allow_any_runtime_bypass_rc" "0"
assert_selected_runtime "case5_allow_any_runtime_bypass_picks_newest_26_5" "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
assert_stderr_contains "case5_allow_any_runtime_bypass_warns" "SDK 호환성 필터 우회됨"

echo ""

# --- Case 6: stdout JSON schema is exactly the 4-field contract the
#     workflow's fromJson() parses (category/runtime_id/devicetype_id/name),
#     unchanged by this fix ------------------------------------------------
run_discover \
  SIMCTL_DISCOVER_SDK_VERSION=18.5 \
  SIMCTL_DISCOVER_RUNTIMES_JSON_FILE="$case1_runtimes" \
  SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE="$devicetypes_file"
assert_rc "case6_schema_rc" "0"
schema_check="$(printf '%s' "$DISCOVER_STDOUT" | jq -e '
  (length > 0) and
  (all(.[]; (keys | sort) == ["category","devicetype_id","name","runtime_id"]))
' >/dev/null 2>&1; echo $?)"
if [ "$schema_check" = "0" ]; then
  echo "PASS: case6_schema_exactly_four_fields"
  pass_count=$((pass_count + 1))
else
  echo "FAIL: case6_schema_exactly_four_fields — stdout JSON schema changed"
  echo "  --- stdout ---"; printf '%s\n' "$DISCOVER_STDOUT" | sed 's/^/  /'
  fail_count=$((fail_count + 1))
fi

echo ""

# --- Case 7: an isAvailable=false runtime is excluded even if it is the
#     newest — proven under the ALLOW_ANY_RUNTIME bypass so this assertion
#     is isolated from the SDK-major filter added by this fix (i.e. this
#     proves the pre-existing availability filter still works unchanged,
#     independent of whether the new major-version filter is active) -----
case7_runtimes="$tmp_dir/case7_runtimes.json"
make_runtime_fixture "$case7_runtimes" \
  "18.4:com.apple.CoreSimulator.SimRuntime.iOS-18-4:true" \
  "99.9:com.apple.CoreSimulator.SimRuntime.iOS-99-9:false"

run_discover \
  SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME=1 \
  SIMCTL_DISCOVER_RUNTIMES_JSON_FILE="$case7_runtimes" \
  SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE="$devicetypes_file"
assert_rc "case7_unavailable_runtime_excluded_rc" "0"
assert_selected_runtime "case7_unavailable_runtime_excluded_even_when_newest" "com.apple.CoreSimulator.SimRuntime.iOS-18-4"

echo ""
echo "=== Results: $pass_count passed, $fail_count failed ==="

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
