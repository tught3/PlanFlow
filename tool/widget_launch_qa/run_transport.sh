#!/usr/bin/env bash
# Uses ONLY caller-owned UDID. Build/extension compile is separate from transport proof.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo WIDGET_TRANSPORT_SKIPPED; exit 1; }
: "${QA_OWNED_SIMULATOR_UDID:?Caller must supply owned simulator UDID}"
: "${QA_TRANSPORT_APP:?Caller must supply built QA Runner.app}"
: "${QA_TRANSPORT_OUT:?Caller must supply evidence directory}"
UDID="$QA_OWNED_SIMULATOR_UDID"
BUNDLE_ID="${IOS_BUNDLE_ID:-com.fluxstudio.planflow}"
mkdir -p "$QA_TRANSPORT_OUT"
LOG="$QA_TRANSPORT_OUT/transport.log"
# Flutter debugPrint reaches the simulator unified log for OS-triggered cold launches.
xcrun simctl spawn "$UDID" log stream --style compact --level debug --predicate 'process == "Runner"' > "$LOG" 2>&1 &
LOGGER=$!
trap 'kill "$LOGGER" 2>/dev/null || true' EXIT
xcrun simctl install "$UDID" "$QA_TRANSPORT_APP"
wait_marker() {
  local deadline=$((SECONDS+60))
  until grep -Fq "$1" "$LOG"; do
    (( SECONDS < deadline )) || { echo "BLOCKED_TRANSPORT_MARKER: $1"; exit 1; }
    sleep 1
  done
}
# NEVER launch before cold openURL. Unique tokens prevent old/warm events passing.
for plugin in applinks homewidget; do
  marker=''
  source="$plugin"
  [[ $plugin == homewidget ]] && marker='&homeWidget=1'
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl openurl "$UDID" "planflow://day/2026-10-14?qaToken=${plugin}_cold${marker}"
  wait_marker "WIDGET_TRANSPORT_RECEIVED source=${source}_initial token=${plugin}_cold"
  xcrun simctl openurl "$UDID" "planflow://voice-launcher?qaToken=${plugin}_warm${marker}"
  wait_marker "WIDGET_TRANSPORT_RECEIVED source=${source}_warm token=${plugin}_warm"
  xcrun simctl io "$UDID" screenshot "$QA_TRANSPORT_OUT/${plugin}-warm.png" >/dev/null
  upper="$(printf '%s' "$plugin" | tr '[:lower:]' '[:upper:]')"
  echo "WIDGET_TRANSPORT_${upper}_COLD_WARM_PASS external_openurl=true widget_tap=false routing_claim=false"
done
