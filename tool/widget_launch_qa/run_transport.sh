#!/usr/bin/env bash
# QA-only, caller-owned simulator. Unified log is auxiliary, never pass evidence.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo WIDGET_TRANSPORT_SKIPPED; exit 1; }
: "${QA_OWNED_SIMULATOR_UDID:?Caller must supply owned simulator UDID}"
: "${QA_TRANSPORT_APP:?Caller must supply built QA Runner.app}"
: "${QA_TRANSPORT_OUT:?Caller must supply evidence directory}"
UDID="$QA_OWNED_SIMULATOR_UDID"
BUNDLE_ID="${IOS_BUNDLE_ID:-com.fluxstudio.planflow}"
DIAGNOSTICS="$(cd "$(dirname "$0")" && pwd)/host_diagnostics.mjs"
CHECKER="$(cd "$(dirname "$0")" && pwd)/verify_transport_receipts.mjs"
mkdir -p "$QA_TRANSPORT_OUT"
# Do not overwrite prior native artifacts even if the output folder is reused.
RUN_OUT="$QA_TRANSPORT_OUT/receipts-$(node "$CHECKER" nonce)"
mkdir "$RUN_OUT"
xcrun simctl spawn "$UDID" log stream --style compact --level debug --predicate 'process == "Runner"' > "$RUN_OUT/transport.log" 2>&1 &
LOGGER=$!
ACTIVE_CASE=''
FAILURE_CAPTURED=0
finish_transport() {
  local original="$1"
  trap - EXIT
  if [[ "$original" != 0 && -n "$ACTIVE_CASE" && "$FAILURE_CAPTURED" == 0 ]]; then
    FAILURE_CAPTURED=1
    node "$DIAGNOSTICS" failure "$UDID" "$RUN_OUT/$ACTIVE_CASE-failure.png" "$RUN_OUT/$ACTIVE_CASE-host-failure.json" "$RECEIPTS" >/dev/null 2>&1 || true
  fi
  kill "$LOGGER" 2>/dev/null || true
  exit "$original"
}
trap 'finish_transport "$?"' EXIT
xcrun simctl install "$UDID" "$QA_TRANSPORT_APP"
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
RECEIPTS="$(node "$CHECKER" container "$CONTAINER" "$UDID")"
observe_process() {
  local destination="$1"
  if ! xcrun simctl spawn "$UDID" launchctl list > "$destination.new"; then
    rm -f "$destination.new"
    echo BLOCKED_TRANSPORT_PROCESS_OBSERVATION
    exit 1
  fi
  if ! mv "$destination.new" "$destination"; then
    echo BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH
    exit 1
  fi
}
observe_first_process() {
  # Reuse publication guards; bound only this additional diagnostic query.
  (
    xcrun() {
      node "$DIAGNOSTICS" process "$@"
    }
    observe_process "$RUN_OUT/$ACTIVE_CASE-first-process.txt"
  )
}
open_qa_url() {
  local launch_status=0
  ACTIVE_CASE="$1"
  node "$DIAGNOSTICS" launch "$UDID" "$2" "$RUN_OUT/$ACTIVE_CASE-host-launch.json" || launch_status=$?
  # A failed OS request remains failed, independently of diagnostic capture.
  if [[ "$launch_status" != 0 ]]; then
    # A failed request can still leave an app process; observe without masking it.
    observe_first_process || true
    exit "$launch_status"
  fi
  observe_first_process
}
prove_absent() {
  if ! observe_process "$RUN_OUT/lifecycle-current.txt"; then
    echo BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH
    exit 1
  fi
  node "$CHECKER" absent "$RUN_OUT/lifecycle-current.txt" "$BUNDLE_ID"
}
wait_receipt() {
  local deadline=$((SECONDS+60))
  local poll=0
  while true; do
    observe_process "$RUN_OUT/lifecycle-running.txt"
    poll=$((poll+1))
    if [[ "$poll" == 1 || "$poll" == 15 ]]; then
      if ! cp "$RUN_OUT/lifecycle-running.txt" "$RUN_OUT/$ACTIVE_CASE-poll-$poll-process.txt"; then
        echo BLOCKED_LIFECYCLE_OBSERVATION_PUBLISH
        exit 1
      fi
    fi
    if node "$CHECKER" verify "$@" "$RUN_OUT/lifecycle-running.txt" "$BUNDLE_ID" "$UDID" "$CONTAINER" 2> "$RUN_OUT/check-last.txt"; then cp "$RUN_OUT/lifecycle-running.txt" "$6.process.txt"; return; fi
    (( SECONDS < deadline )) || { cp "$RUN_OUT/lifecycle-running.txt" "$RUN_OUT/$ACTIVE_CASE-timeout-process.txt" || exit 1; node "$CHECKER" snapshot "$RECEIPTS" "$RUN_OUT/blocked-safe-receipts.json" || true; echo BLOCKED_TRANSPORT_RECEIPTS_BOOT_FILE_CHECK; exit 1; }
    sleep 1
  done
}
for plugin in applinks homewidget; do
  ACTIVE_CASE=''
  marker=''
  [[ $plugin == homewidget ]] && marker='&homeWidget=1'
  # A terminate failure is accepted only with independently observed absence.
  terminate_exit=0
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" > "$RUN_OUT/${plugin}-terminate.txt" 2>&1 || terminate_exit=$?
  printf '%s\n' "$terminate_exit" > "$RUN_OUT/${plugin}-terminate-exit.txt"
  deadline=$((SECONDS+10))
  until prove_absent; do
    (( SECONDS < deadline )) || { echo BLOCKED_TRANSPORT_RUNNING_BEFORE_COLD; exit 1; }
    sleep 1
  done
  cp "$RUN_OUT/lifecycle-current.txt" "$RUN_OUT/${plugin}-cold-absence.txt"
  # Validate real path anew; no symlink escape, fixture, or log fallback.
  RECEIPTS="$(node "$CHECKER" container "$CONTAINER" "$UDID")"
  BOUNDARY="$RUN_OUT/${plugin}-boundary.json"
  node "$CHECKER" boundary "$RECEIPTS" "$BOUNDARY"
  cold_nonce="$(node "$CHECKER" nonce)"
  warm_nonce="$(node "$CHECKER" nonce)"
  # This OS openURL is the first launch in this case: no manual launch/attach.
  open_qa_url "${plugin}-cold" "planflow://day/2026-10-14?qaNonce=${cold_nonce}${marker}"
  wait_receipt "$RECEIPTS" "$BOUNDARY" "$plugin" "$cold_nonce" cold "$RUN_OUT/${plugin}-cold.json" ""
  open_qa_url "${plugin}-warm" "planflow://voice-launcher?qaNonce=${warm_nonce}${marker}"
  wait_receipt "$RECEIPTS" "$BOUNDARY" "$plugin" "$warm_nonce" warm "$RUN_OUT/${plugin}-warm.json" "$RUN_OUT/${plugin}-cold.json"
  node "$CHECKER" snapshot "$RECEIPTS" "$RUN_OUT/${plugin}-safe-receipts.json"
  xcrun simctl io "$UDID" screenshot "$RUN_OUT/${plugin}-warm.png" >/dev/null
  upper="$(printf '%s' "$plugin" | tr '[:lower:]' '[:upper:]')"
  echo "WIDGET_TRANSPORT_${upper}_COLD_WARM_PASS external_openurl=true widget_tap=false routing_claim=false"
done
