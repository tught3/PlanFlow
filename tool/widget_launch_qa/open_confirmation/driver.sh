#!/usr/bin/env bash
# Sourced host helper: own case directory, PID, and xcodebuild group only.
OPEN_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper.mjs"
OPEN_PID=''
OPEN_WAIT_PID=''
OPEN_DIAG_FIRST_FAILURE=NONE
OPEN_DIAG_STARTED=0
OPEN_DIAG_PHASE_STARTED=0
OPEN_DIAG_READY_MS=-1
OPEN_DIAG_PHASE=UNKNOWN
OPEN_DIAG_OWNER_PRESENT=unknown
OPEN_DIAG_PROXY_VALID=unknown
OPEN_DIAG_HELPER_LIVE=unknown
OPEN_DIAG_TERMINAL_PRESENT=unknown
OPEN_DIAG_FD_REGULAR=unknown
OPEN_DIAG_FD_IDENTITY=unknown
OPEN_DIAG_ERROR_CLASS=NONE
open_driver_diag_emit() {
  local source reason phase elapsed phaseElapsed first owner proxy live terminal fdRegular fdIdentity
  case "$1" in driver) source=driver;; transport) source=transport;; *) source=driver;; esac
  case "$2" in NONE|START_PRECONDITION|START_DIRECTORY|START_OWNER_PUBLISH|START_TERMINAL|START_PROXY_READ|START_PROXY_LIVE|START_READY_TIMEOUT|START_READY_LOG_GUARD|POST_READY_PID_EMPTY|POST_READY_LIVE_GUARD|POST_READY_LOG_GUARD|COLD_ACK_PREDICATE|MARKER_PREDICATE|LOG_GUARD_BLOCKED|STARTUP_DEADLINE|READY_ACCEPTED|READY_REJECTED|TARGET_START_ERROR|TARGET_EXIT_NONZERO|CONTROL_DISCONNECT|CONTROL_SIGNAL|CONTROL_STOP|LEASE_EXPIRED|CLEANUP_REQUEST|CONTAINMENT_UNVERIFIED|OS_REQUEST_FAILED|OS_REQUEST_ACCEPTED|PRE_URL_GUARD_PASSED|FINISH_TIMEOUT|FINISH_EXIT|FINISH_OWNERSHIP|FINISH_STATUS|COLD_FINISH_BLOCKED|WARM_FINISH_BLOCKED|COLD_FINISH|WARM_FINISH|FORMAT_BOUNDED) reason=$2;; *) reason=FORMAT_BOUNDED;; esac
  case "${OPEN_DIAG_PHASE:-UNKNOWN}" in STARTUP|READY|COLD|WARM|CONTAINMENT|TERMINAL) phase=$OPEN_DIAG_PHASE;; *) phase=UNKNOWN;; esac
  case "${OPEN_DIAG_FIRST_FAILURE:-NONE}" in NONE|START_PRECONDITION|START_DIRECTORY|START_OWNER_PUBLISH|START_TERMINAL|START_PROXY_READ|START_PROXY_LIVE|START_READY_TIMEOUT|START_READY_LOG_GUARD|POST_READY_PID_EMPTY|POST_READY_LIVE_GUARD|POST_READY_LOG_GUARD|COLD_ACK_PREDICATE|MARKER_PREDICATE|LOG_GUARD_BLOCKED|STARTUP_DEADLINE|READY_REJECTED|TARGET_START_ERROR|TARGET_EXIT_NONZERO|CONTROL_DISCONNECT|CONTROL_SIGNAL|OS_REQUEST_FAILED|LEASE_EXPIRED|CLEANUP_REQUEST|CONTAINMENT_UNVERIFIED|FINISH_TIMEOUT|FINISH_EXIT|FINISH_OWNERSHIP|FINISH_STATUS|COLD_FINISH_BLOCKED|WARM_FINISH_BLOCKED) first=$OPEN_DIAG_FIRST_FAILURE;; *) first=NONE;; esac
  elapsed=0; phaseElapsed=0
  if [[ "${OPEN_DIAG_STARTED:-}" =~ ^[0-9]+$ ]] && (( SECONDS >= OPEN_DIAG_STARTED )); then elapsed=$(( (SECONDS-OPEN_DIAG_STARTED)*1000 )); fi
  if [[ "${OPEN_DIAG_PHASE_STARTED:-}" =~ ^[0-9]+$ ]] && (( SECONDS >= OPEN_DIAG_PHASE_STARTED )); then phaseElapsed=$(( (SECONDS-OPEN_DIAG_PHASE_STARTED)*1000 )); fi
  (( elapsed <= 60000 )) || elapsed=60000; (( phaseElapsed <= 60000 )) || phaseElapsed=60000
  [[ "${OPEN_DIAG_READY_MS:-}" =~ ^-?[0-9]+$ ]] || OPEN_DIAG_READY_MS=-1
  case "${OPEN_DIAG_ERROR_CLASS:-NONE}" in NONE|BLOCKED|EIO|ENOENT|EACCES|OTHER) ;; *) OPEN_DIAG_ERROR_CLASS=OTHER;; esac
  case "${OPEN_DIAG_OWNER_PRESENT:-unknown}" in 0) owner=false;; 1) owner=true;; *) owner=null;; esac
  case "${OPEN_DIAG_PROXY_VALID:-unknown}" in 0) proxy=false;; 1) proxy=true;; *) proxy=null;; esac
  case "${OPEN_DIAG_HELPER_LIVE:-unknown}" in 0) live=false;; 1) live=true;; *) live=null;; esac
  case "${OPEN_DIAG_TERMINAL_PRESENT:-unknown}" in 0) terminal=false;; 1) terminal=true;; *) terminal=null;; esac
  case "${OPEN_DIAG_FD_REGULAR:-unknown}" in 0) fdRegular=false;; 1) fdRegular=true;; *) fdRegular=null;; esac
  case "${OPEN_DIAG_FD_IDENTITY:-unknown}" in 0) fdIdentity=false;; 1) fdIdentity=true;; *) fdIdentity=null;; esac
  printf '{"kind":"WIDGET_QA_DIAG_V1","source":"%s","reason":"%s","firstFailure":"%s","phase":"%s","elapsedMs":%s,"readyElapsedMs":%s,"phaseElapsedMs":%s,"ownerPresent":%s,"proxyValid":%s,"helperLive":%s,"terminalPresent":%s,"fdRegular":%s,"fdIdentityValid":%s,"errorClass":"%s"}\n' "$source" "$reason" "$first" "$phase" "$elapsed" "$OPEN_DIAG_READY_MS" "$phaseElapsed" "$owner" "$proxy" "$live" "$terminal" "$fdRegular" "$fdIdentity" "$OPEN_DIAG_ERROR_CLASS" >&2 || true
}
open_driver_diag_fail() {
  local reason="$1"
  case "$reason" in START_PRECONDITION|START_DIRECTORY|START_OWNER_PUBLISH|START_TERMINAL|START_PROXY_READ|START_PROXY_LIVE|START_READY_TIMEOUT|START_READY_LOG_GUARD|POST_READY_PID_EMPTY|POST_READY_LIVE_GUARD|POST_READY_LOG_GUARD|FINISH_TIMEOUT|FINISH_EXIT|FINISH_OWNERSHIP|FINISH_STATUS|COLD_FINISH_BLOCKED|WARM_FINISH_BLOCKED|CLEANUP_REQUEST|CONTAINMENT_UNVERIFIED) ;; *) reason=FORMAT_BOUNDED;; esac
  if [[ "$OPEN_DIAG_FIRST_FAILURE" == NONE ]]; then OPEN_DIAG_FIRST_FAILURE="$reason"; fi
  open_driver_diag_emit driver "$OPEN_DIAG_FIRST_FAILURE"
}
open_driver_diag_transport() { if [[ "$1" == OS_REQUEST_FAILED && "$OPEN_DIAG_FIRST_FAILURE" == NONE ]]; then OPEN_DIAG_FIRST_FAILURE=OS_REQUEST_FAILED; fi; open_driver_diag_emit transport "$1"; }
open_driver_guard() {
  if [[ -z "$OPEN_PID" ]]; then open_driver_diag_fail POST_READY_PID_EMPTY; return 1; fi
  if ! node "$OPEN_HELPER" alive "$OPEN_PID" "$OPEN_DIR" >/dev/null; then OPEN_DIAG_HELPER_LIVE=0; open_driver_diag_fail POST_READY_LIVE_GUARD; return 1; fi
  OPEN_DIAG_HELPER_LIVE=1
  if ! node "$OPEN_HELPER" check "$OPEN_DIR/driver.log" ready guard >/dev/null; then open_driver_diag_fail POST_READY_LOG_GUARD; return 1; fi
  OPEN_DIAG_FD_REGULAR=1; OPEN_DIAG_FD_IDENTITY=1
}
open_driver_start() {
  OPEN_DIAG_STARTED=$SECONDS; OPEN_DIAG_PHASE_STARTED=$SECONDS; OPEN_DIAG_READY_MS=-1; OPEN_DIAG_PHASE=STARTUP; OPEN_DIAG_FIRST_FAILURE=NONE; OPEN_DIAG_OWNER_PRESENT=0; OPEN_DIAG_PROXY_VALID=0; OPEN_DIAG_HELPER_LIVE=unknown; OPEN_DIAG_TERMINAL_PRESENT=0; OPEN_DIAG_FD_REGULAR=unknown; OPEN_DIAG_FD_IDENTITY=unknown; OPEN_DIAG_ERROR_CLASS=NONE
  if [[ "${GITHUB_ACTIONS:-}" != true ]]; then open_driver_diag_fail START_PRECONDITION; return 1; fi
  : "${QA_OPEN_XCTESTRUN:?}" "${QA_OPEN_PRODUCTS:?}"
  OPEN_DIR="$RUN_OUT/$ACTIVE_CASE-ui"
  if ! mkdir "$OPEN_DIR"; then open_driver_diag_fail START_DIRECTORY; return 1; fi
  node "$OPEN_HELPER" run "$UDID" "$QA_OPEN_XCTESTRUN" "$OPEN_DIR" &
  OPEN_WAIT_PID=$!
  OPEN_PID="$OPEN_WAIT_PID"
  local deadline=$((SECONDS+20))
  until node "$OPEN_HELPER" check "$OPEN_DIR/driver.log" ready wait >/dev/null 2>&1; do
    if [[ -f "$OPEN_DIR/exit" ]]; then OPEN_DIAG_TERMINAL_PRESENT=1; open_driver_diag_fail START_TERMINAL; return 1; fi
    if [[ -f "$OPEN_DIR/ownership.json" ]]; then
      OPEN_DIAG_OWNER_PRESENT=1
      if ! OPEN_PID="$(node "$OPEN_HELPER" proxy "$OPEN_DIR")"; then OPEN_DIAG_ERROR_CLASS=BLOCKED; open_driver_diag_fail START_PROXY_READ; return 1; fi
      OPEN_DIAG_PROXY_VALID=1
      if ! node "$OPEN_HELPER" alive "$OPEN_PID" "$OPEN_DIR" >/dev/null 2>&1; then OPEN_DIAG_HELPER_LIVE=0; open_driver_diag_fail START_PROXY_LIVE; return 1; fi
      OPEN_DIAG_HELPER_LIVE=1
    fi
    if (( SECONDS >= deadline )); then open_driver_diag_fail START_READY_TIMEOUT; return 1; fi
    sleep 0.1
  done
  OPEN_DIAG_READY_MS=$(( (SECONDS-OPEN_DIAG_STARTED)*1000 )); OPEN_DIAG_PHASE=READY; OPEN_DIAG_PHASE_STARTED=$SECONDS; OPEN_DIAG_FD_REGULAR=1; OPEN_DIAG_FD_IDENTITY=1
  if ! OPEN_PID="$(node "$OPEN_HELPER" proxy "$OPEN_DIR")"; then OPEN_DIAG_ERROR_CLASS=BLOCKED; open_driver_diag_fail START_PROXY_READ; return 1; fi
  OPEN_DIAG_PROXY_VALID=1; OPEN_DIAG_OWNER_PRESENT=1
  # Post-READY liveness+terminal-exit guard. READY alone does not authorize a dead driver.
  open_driver_guard || return 1
  open_driver_diag_emit driver READY_ACCEPTED
}
open_driver_guard_pre_url() {
  # Immediately before each open_qa_url call. Re-checks live and terminal exit absent.
  if ! open_driver_guard; then echo BLOCKED_OPEN_CONFIRMATION_NOT_LIVE; return 1; fi
  open_driver_diag_emit driver PRE_URL_GUARD_PASSED
}
open_driver_finish() {
  # READY opens a bounded warm-observation plus terminal allowance; total remains capped at 60s.
  OPEN_DIAG_PHASE="$1"; OPEN_DIAG_PHASE_STARTED=$SECONDS
  local deadline=$((SECONDS+40))
  until [[ -f "$OPEN_DIR/exit" ]]; do
    if (( SECONDS >= deadline )); then open_driver_diag_fail FINISH_TIMEOUT; return 1; fi
    sleep 0.1
  done
  OPEN_DIAG_TERMINAL_PRESENT=1
  local status=0
  wait "${OPEN_WAIT_PID:-$OPEN_PID}" || status=1
  [[ $(cat "$OPEN_DIR/exit") == 0 ]] || status=1
  if [[ -e "$OPEN_DIR/ownership.json" || -e "$OPEN_DIR/emergency.json" ]]; then if [[ -e "$OPEN_DIR/ownership.json" ]]; then OPEN_DIAG_OWNER_PRESENT=1; else OPEN_DIAG_OWNER_PRESENT=0; fi; open_driver_diag_fail FINISH_OWNERSHIP; return 1; fi
  OPEN_DIAG_OWNER_PRESENT=0
  OPEN_PID=''
  OPEN_WAIT_PID=''
  if [[ "$status" != 0 ]]; then open_driver_diag_fail FINISH_EXIT; return 1; fi
  if ! node "$OPEN_HELPER" check "$OPEN_DIR/driver.log" "$1"; then OPEN_DIAG_ERROR_CLASS=BLOCKED; if [[ "$1" == cold ]]; then open_driver_diag_fail COLD_FINISH_BLOCKED; else open_driver_diag_fail WARM_FINISH_BLOCKED; fi; return 1; fi
  if [[ "$1" == cold ]]; then open_driver_diag_emit driver COLD_FINISH; else open_driver_diag_emit driver WARM_FINISH; fi
}
open_driver_cleanup() {
  if [[ -n "$OPEN_PID" && -d "$OPEN_DIR" ]]; then
    # No external PID/PGID signals: request cleanup from the still-owned supervisor only.
    if [[ -e "$OPEN_DIR/ownership.json" ]]; then
      # Only request the still-live controller. Persisted PID/PGID is diagnostic, never signal authority.
      if ! node "$OPEN_HELPER" cleanup "$OPEN_DIR" >/dev/null; then OPEN_DIAG_OWNER_PRESENT=1; open_driver_diag_fail CLEANUP_REQUEST; return 1; fi
    fi
    if [[ ! -f "$OPEN_DIR/exit" || -e "$OPEN_DIR/ownership.json" || -e "$OPEN_DIR/emergency.json" ]]; then OPEN_DIAG_TERMINAL_PRESENT=0; if [[ -e "$OPEN_DIR/ownership.json" ]]; then OPEN_DIAG_OWNER_PRESENT=1; else OPEN_DIAG_OWNER_PRESENT=0; fi; open_driver_diag_fail CONTAINMENT_UNVERIFIED; return 1; fi
    wait "${OPEN_WAIT_PID:-$OPEN_PID}" 2>/dev/null || true
    OPEN_PID=''
    OPEN_WAIT_PID=''
  fi
}
