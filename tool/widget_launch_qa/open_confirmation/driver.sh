#!/usr/bin/env bash
# Sourced host helper: own case directory, PID, and xcodebuild group only.
OPEN_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper.mjs"
OPEN_PID=''
OPEN_WAIT_PID=''
open_driver_guard() {
  [[ -n "$OPEN_PID" ]] || return 1
  # After READY, the helper must still be live and must not have a terminal exit file.
  node "$OPEN_HELPER" alive "$OPEN_PID" "$OPEN_DIR" >/dev/null 2>&1 || return 1
  # Re-confirm READY marker via the same pinned-FD dev/ino check the supervisor uses.
  node "$OPEN_HELPER" check "$OPEN_DIR/driver.log" ready >/dev/null 2>&1
}
open_driver_start() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 1
  : "${QA_OPEN_XCTESTRUN:?}" "${QA_OPEN_PRODUCTS:?}"
  OPEN_DIR="$RUN_OUT/$ACTIVE_CASE-ui"
  mkdir "$OPEN_DIR" || return 1
  node "$OPEN_HELPER" run "$UDID" "$QA_OPEN_XCTESTRUN" "$OPEN_DIR" &
  OPEN_WAIT_PID=$!
  OPEN_PID="$OPEN_WAIT_PID"
  local deadline=$((SECONDS+20))
  until node "$OPEN_HELPER" check "$OPEN_DIR/driver.log" ready >/dev/null 2>&1; do
    [[ ! -f "$OPEN_DIR/exit" ]] || return 1
    if [[ -f "$OPEN_DIR/ownership.json" ]]; then
      OPEN_PID="$(node "$OPEN_HELPER" proxy "$OPEN_DIR")" || return 1
      node "$OPEN_HELPER" alive "$OPEN_PID" "$OPEN_DIR" >/dev/null 2>&1 || return 1
    fi
    (( SECONDS < deadline )) || return 1
    sleep 0.1
  done
  OPEN_PID="$(node "$OPEN_HELPER" proxy "$OPEN_DIR")" || return 1
  # Post-READY liveness+terminal-exit guard. READY alone does not authorize a dead driver.
  open_driver_guard || return 1
}
open_driver_guard_pre_url() {
  # Immediately before each open_qa_url call. Re-checks live and terminal exit absent.
  open_driver_guard || { echo BLOCKED_OPEN_CONFIRMATION_NOT_LIVE; return 1; }
}
open_driver_finish() {
  # READY opens a bounded warm-observation plus terminal allowance; total remains capped at 60s.
  local deadline=$((SECONDS+40))
  until [[ -f "$OPEN_DIR/exit" ]]; do
    (( SECONDS < deadline )) || return 1
    sleep 0.1
  done
  local status=0
  wait "${OPEN_WAIT_PID:-$OPEN_PID}" || status=1
  [[ $(cat "$OPEN_DIR/exit") == 0 ]] || status=1
  [[ ! -e "$OPEN_DIR/ownership.json" && ! -e "$OPEN_DIR/emergency.json" ]] || return 1
  OPEN_PID=''
  OPEN_WAIT_PID=''
  [[ "$status" == 0 ]] || return 1
  node "$OPEN_HELPER" check "$OPEN_DIR/driver.log" "$1"
}
open_driver_cleanup() {
  if [[ -n "$OPEN_PID" && -d "$OPEN_DIR" ]]; then
    # No external PID/PGID signals: request cleanup from the still-owned supervisor only.
    if [[ -e "$OPEN_DIR/ownership.json" ]]; then
      # Only request the still-live controller. Persisted PID/PGID is diagnostic, never signal authority.
      node "$OPEN_HELPER" cleanup "$OPEN_DIR" >/dev/null || return 1
    fi
    [[ -f "$OPEN_DIR/exit" && ! -e "$OPEN_DIR/ownership.json" && ! -e "$OPEN_DIR/emergency.json" ]] || return 1
    wait "${OPEN_WAIT_PID:-$OPEN_PID}" 2>/dev/null || true
    OPEN_PID=''
    OPEN_WAIT_PID=''
  fi
}
