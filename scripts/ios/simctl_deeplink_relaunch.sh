#!/usr/bin/env bash
# Purpose: exercise the "cold start receives a deep link" path that cannot be
# reproduced by in-process integration_test (which always runs inside an
# already-running app process) — fires representative deep links, then
# force-terminates and cold-launches the app via simctl.
#
# Usage: simctl_deeplink_relaunch.sh <udid> <bundle_id>

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <udid> <bundle_id>" >&2
  exit 1
fi

udid="$1"
bundle_id="$2"

if [ -z "$udid" ]; then
  echo "::error title=BLOCKED_MISSING_UDID::A simulator UDID is required" >&2
  exit 1
fi

if [ -z "$bundle_id" ]; then
  echo "::error title=BLOCKED_MISSING_BUNDLE_ID::A bundle id is required" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "::error title=BLOCKED_NO_XCRUN::xcrun is not available on this runner (requires macOS)" >&2
  exit 1
fi

today_utc="$(date -u +%Y-%m-%d)"

deeplinks=(
  "planflow://schedule/e2e-fixture-1"
  "planflow://day/${today_utc}"
  "planflow://group-calendar?groupId=e2e-fixture-group"
  "planflow://auth-callback"
)

for uri in "${deeplinks[@]}"; do
  echo "[STEP] openurl ${uri}"
  xcrun simctl openurl "$udid" "$uri"
  echo "[STEP] openurl ${uri} dispatched"
  sleep 1
done

echo "[STEP] terminate ${bundle_id}"
# Terminate can legitimately fail if the app was not already running; do not
# abort the relaunch sequence in that case.
if xcrun simctl terminate "$udid" "$bundle_id"; then
  echo "[STEP] terminate ${bundle_id} completed"
else
  echo "[STEP] terminate ${bundle_id} skipped (app was not running)"
fi

echo "[STEP] launch ${bundle_id} (cold start)"
xcrun simctl launch "$udid" "$bundle_id"
echo "[STEP] launch ${bundle_id} completed"
