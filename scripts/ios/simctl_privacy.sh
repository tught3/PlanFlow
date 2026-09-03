#!/usr/bin/env bash
# Grant or revoke a TCC privacy permission on an iOS simulator, restricted to
# an explicit allowlist of services this project actually exercises in E2E
# tests. Unsupported/unknown service names fail fast instead of being passed
# through to `simctl` unchecked.
#
# Usage: simctl_privacy.sh <grant|revoke> <service> <udid> <bundle_id>
#   action:  grant | revoke
#   service: microphone | photos | location | contacts | calendar
#   udid:    simulator device UDID (from `xcrun simctl list devices`)
#   bundle_id: target app bundle identifier

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <grant|revoke> <service> <udid> <bundle_id>" >&2
  exit 1
fi

action="$1"
service="$2"
udid="$3"
bundle_id="$4"

case "$action" in
  grant|revoke) ;;
  *)
    echo "::error title=BLOCKED_INVALID_ACTION::Unsupported action '$action' (expected grant|revoke)" >&2
    exit 1
    ;;
esac

case "$service" in
  microphone|photos|location|contacts|calendar) ;;
  *)
    echo "::error title=BLOCKED_INVALID_SERVICE::Unsupported privacy service '$service' (expected one of: microphone photos location contacts calendar)" >&2
    exit 1
    ;;
esac

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

echo "[STEP] simctl privacy ${action} ${service} for ${bundle_id} on ${udid}"
xcrun simctl privacy "$udid" "$action" "$service" "$bundle_id"
echo "[STEP] simctl privacy ${action} ${service} completed"
