#!/usr/bin/env bash
# Discover the latest available iOS simulator runtime and pick one device type
# per category (small / mainstream / large / ipad) using only dynamic queries
# against `xcrun simctl`. No iOS version numbers or device names are
# hardcoded here — everything is selected from the live list output.
#
# Requires: xcrun simctl (macOS only), jq (preinstalled on GitHub macOS runners).
#
# Output: a single-line JSON array on stdout, one object per selected
# category, suitable for a GitHub Actions matrix:
#   [{"category":"small","runtime_id":"...","devicetype_id":"...","name":"..."}, ...]
#
# On total failure (no available iOS runtime at all) this script prints a
# GitHub Actions error annotation and exits 1.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "::error title=BLOCKED_MISSING_JQ::jq is required to parse simctl JSON output" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "::error title=BLOCKED_NO_XCRUN::xcrun is not available on this runner (requires macOS)" >&2
  exit 1
fi

runtimes_json="$(xcrun simctl list runtimes -j)"
devicetypes_json="$(xcrun simctl list devicetypes -j)"

# Pick the latest available iOS runtime. simctl reports runtimes already
# sorted oldest->newest for a given platform in most Xcode versions, but we
# do not rely on that ordering — we sort by version explicitly.
runtime_id="$(
  echo "$runtimes_json" | jq -r '
    [.runtimes[]
      | select(.isAvailable == true)
      | select((.name // "") | test("iOS"))
    ]
    | sort_by(.version | split(".") | map(tonumber? // 0))
    | last
    | .identifier // empty
  '
)"

runtime_name="$(
  echo "$runtimes_json" | jq -r --arg rid "$runtime_id" '
    [.runtimes[] | select(.identifier == $rid)] | first | .name // empty
  '
)"

if [ -z "$runtime_id" ]; then
  echo "::error title=BLOCKED_NO_SIMULATOR_RUNTIME::No available iOS simulator runtime found on this runner" >&2
  exit 1
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
