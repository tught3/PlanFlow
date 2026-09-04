#!/usr/bin/env bash
# Discover the latest available iOS simulator runtime and pick one device type
# per category (small / mainstream / large / ipad) using only dynamic queries
# against `xcrun simctl`. No iOS version numbers or device names are
# hardcoded here — everything is selected from the live list output, bounded
# by whatever iOS SDK the runner's *active* Xcode actually supports.
#
# Run#4 root-cause fix: GitHub's macos-latest runner image can carry newer
# iOS simulator RUNTIMES than the Xcode version that is actually selected as
# the active developer directory supports building against. Before this fix
# this script picked the globally-latest available runtime regardless of
# that ceiling (observed: runtime iOS 26.5 selected while the active Xcode's
# iphonesimulator SDK topped out around 18.x), and the resulting
# Xcode<->CoreSimulator generation mismatch broke VM Service discovery,
# hanging every E2E job forever at
# "Waiting for VM Service port to be available...". This script now queries
# the active Xcode's iphonesimulator SDK ceiling and only considers runtimes
# whose major version is <= that ceiling. It never silently falls back to
# "pick the newest runtime anyway" when that ceiling can't be determined —
# that silent fallback is exactly the bug this fix closes.
#
# Requires: xcrun simctl (macOS only), jq (preinstalled on GitHub macOS
# runners). xcodebuild is used only as a fallback SDK-ceiling probe when
# `xcrun --sdk iphonesimulator --show-sdk-version` produces no output.
#
# Output: a single-line JSON array on stdout, one object per selected
# category, suitable for a GitHub Actions matrix:
#   [{"category":"small","runtime_id":"...","devicetype_id":"...","name":"..."}, ...]
#
# On total failure (no active SDK could be determined, or no runtime is
# compatible with it, or no runtime is available at all) this script prints
# a GitHub Actions error annotation and exits 1.
#
# --- Test seams (fixture injection, no live macOS/Xcode required) ----------
# These env vars let scripts/ios/tests/simctl_discover_contract.sh exercise
# every branch of this script's logic (including the SDK-probe-failure and
# no-compatible-runtime fail-closed paths) as real subprocess runs against
# fixture data, without needing a real `xcrun`/`simctl`/`xcodebuild` on the
# machine running the test:
#   SIMCTL_DISCOVER_SDK_VERSION            — use this value instead of
#                                             probing xcrun/xcodebuild for
#                                             the active iphonesimulator SDK
#                                             ceiling.
#   SIMCTL_DISCOVER_RUNTIMES_JSON_FILE     — read this file's contents
#                                             instead of running
#                                             `xcrun simctl list runtimes -j`.
#   SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE  — read this file's contents
#                                             instead of running
#                                             `xcrun simctl list devicetypes -j`.
#   SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME=1    — bypass the SDK-ceiling filter
#                                             entirely and restore the
#                                             pre-fix "pick the globally
#                                             newest available runtime"
#                                             behavior. This exists purely so
#                                             a future CI run can A/B this
#                                             fix (did the filter really fix
#                                             the hang, or was the filter's
#                                             own logic wrong?) without
#                                             reverting the script. It is NOT
#                                             meant to be left on in normal
#                                             operation.
# Each seam prints a warning/notice to stderr when used so a real CI run can
# never silently pick one of these paths up by accident. stdout stays
# JSON-only in every case — the workflow parses stdout with fromJson.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "::error title=BLOCKED_MISSING_JQ::jq is required to parse simctl JSON output" >&2
  exit 1
fi

allow_any_runtime="${SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME:-0}"

# Only require a real `xcrun` binary for whichever of the three live queries
# (SDK ceiling probe / runtimes list / devicetypes list) is NOT covered by a
# test seam above. This lets the contract test suite run entirely on a
# machine with no `xcrun` installed at all, as long as every query it
# exercises is seam-covered — while a real CI run on macOS, which never sets
# any of these seams, still gets the original hard requirement below.
need_xcrun=0
if [ "$allow_any_runtime" != "1" ] && [ -z "${SIMCTL_DISCOVER_SDK_VERSION:-}" ]; then
  need_xcrun=1
fi
if [ -z "${SIMCTL_DISCOVER_RUNTIMES_JSON_FILE:-}" ]; then
  need_xcrun=1
fi
if [ -z "${SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE:-}" ]; then
  need_xcrun=1
fi

if [ "$need_xcrun" = "1" ] && ! command -v xcrun >/dev/null 2>&1; then
  echo "::error title=BLOCKED_NO_XCRUN::xcrun is not available on this runner (requires macOS)" >&2
  exit 1
fi

if [ -n "${SIMCTL_DISCOVER_RUNTIMES_JSON_FILE:-}" ]; then
  echo "simctl_discover.sh: SIMCTL_DISCOVER_RUNTIMES_JSON_FILE set — reading fixture runtimes JSON from '$SIMCTL_DISCOVER_RUNTIMES_JSON_FILE' instead of running 'xcrun simctl list runtimes -j'" >&2
  runtimes_json="$(cat -- "$SIMCTL_DISCOVER_RUNTIMES_JSON_FILE")"
else
  runtimes_json="$(xcrun simctl list runtimes -j)"
fi

if [ -n "${SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE:-}" ]; then
  echo "simctl_discover.sh: SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE set — reading fixture devicetypes JSON from '$SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE' instead of running 'xcrun simctl list devicetypes -j'" >&2
  devicetypes_json="$(cat -- "$SIMCTL_DISCOVER_DEVICETYPES_JSON_FILE")"
else
  devicetypes_json="$(xcrun simctl list devicetypes -j)"
fi

# --- SDK ceiling probe -------------------------------------------------
# Determine the active Xcode's iphonesimulator SDK version, so the runtime
# filter below can bound its selection to SDK-compatible major versions
# only. Two-step probe, in order:
#   1. `xcrun --sdk iphonesimulator --show-sdk-version` — a single clean
#      version string, the most reliable source.
#   2. Fallback (only tried if step 1 produced nothing): `xcodebuild
#      -showsdks` text output, grepped for an `iphonesimulator<version>`
#      token, taking the highest one found. `xcodebuild -showsdks -json`
#      support could not be confirmed available in every environment this
#      script runs in, so this fallback intentionally parses the stable text
#      format rather than relying on an unverified `-json` flag.
# Never falls back further than this — if both probes come up empty, that is
# a hard failure (BLOCKED_NO_ACTIVE_IOS_SDK) at the call site below, not
# "assume the newest runtime is fine". Silently falling back to the newest
# runtime is the exact pre-fix bug this whole change closes.
determine_sdk_version() {
  if [ -n "${SIMCTL_DISCOVER_SDK_VERSION:-}" ]; then
    echo "simctl_discover.sh: SIMCTL_DISCOVER_SDK_VERSION='$SIMCTL_DISCOVER_SDK_VERSION' set — using this instead of probing xcrun/xcodebuild for the active iphonesimulator SDK version" >&2
    printf '%s' "$SIMCTL_DISCOVER_SDK_VERSION"
    return 0
  fi

  local probed=""
  if command -v xcrun >/dev/null 2>&1; then
    probed="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true)"
  fi

  if [ -z "$probed" ] && command -v xcodebuild >/dev/null 2>&1; then
    probed="$(
      xcodebuild -showsdks 2>/dev/null \
        | grep -oE 'iphonesimulator[0-9]+(\.[0-9]+)*' \
        | sed -E 's/^iphonesimulator//' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -n1
    )"
  fi

  printf '%s' "$probed"
}

sdk_major=""
if [ "$allow_any_runtime" = "1" ]; then
  echo "::warning title=SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME_ENABLED::SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME=1: SDK 호환성 필터 우회됨 — 최신 사용 가능 런타임을 무조건 선택합니다 (fix 이전 동작으로 복귀; A/B 대조 목적 이외에는 사용 금지)" >&2
else
  sdk_version="$(determine_sdk_version)"
  if [ -z "$sdk_version" ]; then
    echo "::error title=BLOCKED_NO_ACTIVE_IOS_SDK::Could not determine the active Xcode's iphonesimulator SDK version via 'xcrun --sdk iphonesimulator --show-sdk-version' or the 'xcodebuild -showsdks' fallback. Refusing to guess a runtime." >&2
    exit 1
  fi
  sdk_major="${sdk_version%%.*}"
  case "$sdk_major" in
    ''|*[!0-9]*)
      echo "::error title=BLOCKED_NO_ACTIVE_IOS_SDK::Probed SDK version '$sdk_version' does not start with a numeric major component; cannot bound runtime selection safely" >&2
      exit 1
      ;;
  esac
fi

# All available iOS runtimes on this runner, sorted oldest->newest. Not
# assumed to already be sorted by simctl — sorted explicitly.
all_ios_runtimes="$(
  echo "$runtimes_json" | jq -c '
    [.runtimes[]
      | select(.isAvailable == true)
      | select((.name // "") | test("iOS"))
    ]
    | sort_by(.version | split(".") | map(tonumber? // 0))
  '
)"

if [ -n "$sdk_major" ]; then
  # Bound by SDK major version only — a same-major, higher-minor runtime
  # (e.g. SDK 18.5 with runtime 18.6) is still allowed; only a runtime from a
  # NEWER major generation than the active Xcode's SDK is excluded.
  # Major-version comparison (not full dotted-version comparison) is
  # deliberate: the observed failure mode this fix targets is a
  # major-generation gap between the active Xcode's SDK and the selected
  # runtime (SDK 18.x vs. runtime 26.5), not a same-major minor-version
  # difference — comparing majors closes exactly that gap without also
  # rejecting a legitimate same-major minor bump.
  eligible_runtimes="$(
    echo "$all_ios_runtimes" | jq -c --argjson sdkmajor "$sdk_major" '
      [.[] | select(((.version // "0") | split(".")[0] | tonumber? // -1) <= $sdkmajor)]
    '
  )"
else
  eligible_runtimes="$all_ios_runtimes"
fi

runtime_id="$(echo "$eligible_runtimes" | jq -r 'last | .identifier // empty')"
runtime_name="$(echo "$eligible_runtimes" | jq -r 'last | .name // empty')"

if [ -z "$runtime_id" ]; then
  all_versions="$(echo "$all_ios_runtimes" | jq -r '[.[].version] | join(", ")')"
  if [ -n "$sdk_major" ]; then
    echo "::error title=BLOCKED_NO_COMPATIBLE_RUNTIME::No available iOS simulator runtime has a major version <= $sdk_major (this runner's active Xcode iphonesimulator SDK ceiling). Available runtime version(s) on this runner: [${all_versions:-none}]" >&2
  else
    echo "::error title=BLOCKED_NO_SIMULATOR_RUNTIME::No available iOS simulator runtime found on this runner" >&2
  fi
  exit 1
fi

candidate_count="$(echo "$eligible_runtimes" | jq 'length')"
if [ -n "$sdk_major" ]; then
  rejected_versions="$(
    echo "$all_ios_runtimes" | jq -r --argjson sdkmajor "$sdk_major" '
      [.[] | select(((.version // "0") | split(".")[0] | tonumber? // -1) > $sdkmajor) | .version]
      | join(", ")
    '
  )"
  echo "simctl_discover.sh: active Xcode iphonesimulator SDK major=$sdk_major; compatible runtime candidates=$candidate_count; selected runtime='$runtime_name' ($runtime_id); rejected (newer than active SDK)=[${rejected_versions:-none}]" >&2
else
  echo "simctl_discover.sh: SDK compatibility filter bypassed (SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME=1); candidates=$candidate_count; selected runtime='$runtime_name' ($runtime_id)" >&2
fi

# Device types supported by the selected runtime, as identifier strings.
supported_devicetype_ids="$(
  echo "$runtimes_json" | jq -r --arg rid "$runtime_id" '
    [.runtimes[] | select(.identifier == $rid)] | first
    | (.supportedDeviceTypes // [])
    | .[].identifier
  '
)"

pick_small() {
  # Prefer identifiers containing "SE" (e.g. iPhone-SE-3rd-generation).
  echo "$supported_devicetype_ids" | grep -i 'SE' | head -n1 || true
}

pick_mainstream() {
  # Prefer standard iPhone-N devicetypes (not Plus/Pro/Max/SE), choosing the
  # highest numbered generation available. Falls back to any iPhone if no
  # clean "iPhone-<N>" pattern is found.
  local candidates
  candidates="$(echo "$supported_devicetype_ids" | grep -i '^com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-' || true)"
  local plain
  plain="$(echo "$candidates" | grep -vi -E 'Plus|Pro|Max|SE' || true)"
  if [ -n "$plain" ]; then
    echo "$plain" \
      | sed -E 's/^.*iPhone-([0-9]+).*$/\1 &/' \
      | sort -t' ' -k1,1nr \
      | head -n1 \
      | awk '{print $2}'
    return 0
  fi
  echo "$candidates" | head -n1 || true
}

pick_large() {
  # Prefer "Pro-Max" identifiers.
  echo "$supported_devicetype_ids" | grep -i 'Pro-Max' | head -n1 || true
}

pick_ipad() {
  # Prefer iPad Pro identifiers, fall back to any iPad.
  local pro
  pro="$(echo "$supported_devicetype_ids" | grep -i 'iPad' | grep -i 'Pro' | head -n1 || true)"
  if [ -n "$pro" ]; then
    echo "$pro"
    return 0
  fi
  echo "$supported_devicetype_ids" | grep -i 'iPad' | head -n1 || true
}

name_for_devicetype() {
  local id="$1"
  echo "$devicetypes_json" | jq -r --arg id "$id" '
    [.devicetypes[] | select(.identifier == $id)] | first | .name // empty
  '
}

results="[]"

for category in small mainstream large ipad; do
  case "$category" in
    small) devicetype_id="$(pick_small)" ;;
    mainstream) devicetype_id="$(pick_mainstream)" ;;
    large) devicetype_id="$(pick_large)" ;;
    ipad) devicetype_id="$(pick_ipad)" ;;
  esac

  if [ -z "${devicetype_id:-}" ]; then
    # No candidate in this category on this runtime/runner — skip it, do
    # not fail the whole script for a missing category.
    continue
  fi

  dt_name="$(name_for_devicetype "$devicetype_id")"

  results="$(echo "$results" | jq -c \
    --arg category "$category" \
    --arg runtime_id "$runtime_id" \
    --arg devicetype_id "$devicetype_id" \
    --arg name "$dt_name ($runtime_name)" \
    '. + [{"category":$category,"runtime_id":$runtime_id,"devicetype_id":$devicetype_id,"name":$name}]'
  )"
done

count="$(echo "$results" | jq 'length')"
if [ "$count" -eq 0 ]; then
  echo "::error title=BLOCKED_NO_SIMULATOR_RUNTIME::Runtime $runtime_id has no matching device types in any category" >&2
  exit 1
fi

echo "$results" | jq -c '.'
