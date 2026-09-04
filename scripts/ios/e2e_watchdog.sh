#!/usr/bin/env bash
# Bounded watchdog for a single long-running command.
#
# Runs an arbitrary command under an explicit whole-second upper bound. If the
# command finishes inside the bound, its real exit code is forwarded verbatim.
# If the bound is exceeded, the command (and its child process tree) is sent
# SIGTERM, given a short whole-second grace period, then SIGKILL, and this
# script exits with a dedicated timeout exit code so the caller can tell
# "timed out" apart from "the command itself failed".
#
# Motivation: the iOS Simulator E2E job has been observed going completely
# silent right after the Xcode build finishes and then sitting there until the
# GitHub job-level hard timeout fires. By that point the runner is torn down
# and there is nothing left to inspect. Killing the command ourselves, well
# before the job-level limit, is what makes an on-timeout diagnostic dump
# (scripts/ios/e2e_diagnose_hang.sh) possible at all.
#
# Usage: e2e_watchdog.sh <timeout_seconds> <command> [args...]
#   timeout_seconds: positive whole number of seconds
#   command/args:    the command to run, passed through unchanged
#
# Exit codes:
#   124  the command exceeded <timeout_seconds> and was killed by this script
#        (this value is deliberately the same one GNU coreutils `timeout`
#        uses for a timeout, so callers that already special-case 124 keep
#        working regardless of which implementation ran underneath)
#   125  this script's own usage/internal error (also GNU `timeout`'s
#        convention), e.g. a missing or non-numeric timeout argument, or an
#        invalid opt-in env var (see below)
#   *    otherwise, the command's own exit code, forwarded unchanged
#
# Implementation note: macOS runners are BSD-based and do NOT ship GNU
# coreutils `timeout` by default, so this script cannot rely on it being
# present. It probes for a GNU `timeout`/`gtimeout` and, when neither is
# available, falls back to a pure-bash supervisor loop. That bash fallback is
# the load-bearing path here, not an afterthought.
#
# --- Opt-in diagnostics (verbose-overhead investigation, all OFF by default) ---
#
# These exist to answer one question: does `flutter test --verbose`'s own
# console-streaming overhead get in the way of diagnosing a hang, independent
# of whatever caused the hang itself? None of them change behavior unless
# explicitly enabled via environment variable, and this script's own status
# lines (the ones already documented above, e.g. "watchdog: command exceeded
# ...") ALWAYS go to the console — only the *child command's* stdout/stderr is
# ever redirected.
#
#   Timeout-detection exception (review fix, H1): the two status lines that
#   mark an actual timeout — "[STEP] watchdog: command exceeded ...s, sending
#   SIGTERM" (bash-fallback path) and "::error title=E2E_WATCHDOG_TIMEOUT::..."
#   (both paths) — are, in addition to going to the console as always, ALSO
#   appended to E2E_WATCHDOG_LOG_FILE when one is set (see the `watchdog_status`
#   helper below). This is a tee, not a redirect: nothing is removed from the
#   console stream. The reason is that E2E_WATCHDOG_LOG_FILE otherwise only
#   ever captures the *child's* output, so a caller that reads that file after
#   the fact (e.g. scripts/ios/e2e_summarize.sh's `watchdog_timeout_line()`)
#   would have no way to tell "the child failed on its own" apart from "the
#   watchdog killed it" — the timeout signal itself lived only on this
#   script's own stderr, which the workflow no longer pipes through
#   `2>&1 | tee` as of Wave3.
#
#   (Review round-2 correction, LOW: only the SECOND line's append is
#   guaranteed. It happens after `wait "$pid"` in run_with_bash_fallback has
#   returned, i.e. the child is already confirmed dead and nothing else is
#   writing to the log file. The FIRST line's append happens right after
#   sending SIGTERM, while the child may still be alive and still writing to
#   that same file — it is a best-effort append that can lose the race and
#   be dropped entirely; a real reproduction with a continuously-writing
#   child confirmed exactly this (first line missing, second line present).
#   scripts/ios/e2e_summarize.sh's `watchdog_timeout_line()` only ever needs
#   one of the two to match, so this asymmetry does not weaken detection —
#   it is documented here so neither line's append is assumed reliable on
#   its own.
#
#   E2E_WATCHDOG_LOG_FILE=<path>
#       When set, the child command's stdout+stderr are redirected to this
#       file instead of being streamed to the console live. The file is
#       created (and truncated if it already exists) before the child starts;
#       if it cannot be created, this is a usage error (exit 125), not a
#       silent no-op, so a caller that asked for redirection never gets
#       silently downgraded to the old streaming behavior. When this is
#       unset, output streams to the console exactly as before this option
#       existed (zero behavior change).
#
#   E2E_WATCHDOG_HEARTBEAT_INTERVAL=<seconds>
#       When set to a positive whole number AND E2E_WATCHDOG_LOG_FILE is also
#       set, a background heartbeat prints one line to the console every
#       <seconds> while the child runs:
#         [STEP] watchdog: elapsed=<N>s lines=<N> delta=+<N> last=<masked line>
#       `lines` is the current line count of the redirected log file, `delta`
#       is the increase since the previous heartbeat (a heartbeat that stays
#       at delta=+0 across several ticks means the child has stopped
#       producing output), and `last` is the last non-empty line of the log,
#       run through the same secret-masking helper
#       (scripts/ios/e2e_mask_secrets.sh) used elsewhere in this hang
#       investigation and then length-capped. If E2E_WATCHDOG_LOG_FILE is NOT
#       set, heartbeat is a no-op with a one-line warning (there is no
#       redirected log to count lines in) — it never fabricates progress
#       data from the console stream, which this script deliberately does not
#       capture. The heartbeat process is always reaped on every exit path
#       (success, timeout, or error) via an EXIT trap; it never leaks as an
#       orphan — including its own `sleep <interval>` grandchild, which is
#       signalled together with the heartbeat subshell via a shared process
#       group (review fix, L4; see stop_heartbeat/start_heartbeat below).
#
#   E2E_WATCHDOG_TAIL_FILE=<path>
#       Optional. Only consulted when E2E_WATCHDOG_LOG_FILE is set AND the
#       run ends in a timeout or a non-zero exit code. When set, the masked
#       tail dump described below is ALSO written to this path (in addition
#       to printing to the console), so a caller (e.g. a GitHub Actions
#       workflow step) can attach it as a build artifact.
#
# On timeout or command failure (rc != 0), if E2E_WATCHDOG_LOG_FILE was set,
# this script additionally prints (and, if E2E_WATCHDOG_TAIL_FILE is set,
# saves) the last 2000 lines of the redirected log, masked, plus a milestone
# scan (grep for a small set of known-meaningful phrases with line numbers).
# 2000 lines was picked from the run-2 hang investigation's own observed
# density (~143,388 lines over a ~780s mainstream leg, i.e. ~184 lines/sec):
# at that density 2000 lines is only the last ~11 seconds, but a HANG by
# definition is a period where output density collapses toward zero, so in
# the failure case this window instead reaches back several minutes before
# the point output stopped — which is exactly the region worth inspecting.
# This diagnostic dump is best-effort: a missing or empty log file (e.g. the
# child never ran a bash-fallback signal path yet) is reported and skipped,
# and never changes this script's own exit code contract.

set -uo pipefail

# Whole seconds to wait between SIGTERM and SIGKILL.
readonly GRACE_SECONDS=5

readonly EXIT_TIMEOUT=124
readonly EXIT_USAGE=125

# Number of trailing lines dumped from the redirected log on timeout/failure.
# See the "2000 was picked from..." note in the header comment above.
readonly TAIL_LINES=2000

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Best-effort load of the shared secret-masking helper. Diagnostics below
# that would otherwise print raw child output (heartbeat's `last=`, and the
# on-failure tail/milestone dump) check `mask_available` and refuse to print
# anything unmasked if this failed to load — fail-closed, consistent with
# this repo's other hang-investigation diagnostic scripts.
mask_available=0
mask_secrets_source="$script_dir/e2e_mask_secrets.sh"
if [ -f "$mask_secrets_source" ]; then
  # shellcheck source=./e2e_mask_secrets.sh
  if source "$mask_secrets_source" 2>/dev/null; then
    mask_available=1
  fi
fi

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <timeout_seconds> <command> [args...]" >&2
  exit "$EXIT_USAGE"
fi

timeout_seconds="$1"
shift

case "$timeout_seconds" in
  ''|*[!0-9]*)
    echo "::error title=BLOCKED_INVALID_TIMEOUT::Timeout must be a positive whole number of seconds (got '${timeout_seconds}')" >&2
    exit "$EXIT_USAGE"
    ;;
esac

if [ "$timeout_seconds" -le 0 ]; then
  echo "::error title=BLOCKED_INVALID_TIMEOUT::Timeout must be greater than zero seconds (got '${timeout_seconds}')" >&2
  exit "$EXIT_USAGE"
fi

# --- Opt-in child output redirection (P2) -----------------------------------
#
# Unset (the default): behavior is byte-for-byte identical to before this
# option existed — the child's stdout/stderr are never touched here.
log_file="${E2E_WATCHDOG_LOG_FILE:-}"
if [ -n "$log_file" ]; then
  log_file_dir="$(dirname -- "$log_file")"
  if ! mkdir -p -- "$log_file_dir" 2>/dev/null; then
    echo "::error title=BLOCKED_INVALID_LOG_FILE::Could not create directory for E2E_WATCHDOG_LOG_FILE ('${log_file_dir}')" >&2
    exit "$EXIT_USAGE"
  fi
  if ! : > "$log_file" 2>/dev/null; then
    echo "::error title=BLOCKED_INVALID_LOG_FILE::Could not create/truncate E2E_WATCHDOG_LOG_FILE ('${log_file}')" >&2
    exit "$EXIT_USAGE"
  fi
fi

# watchdog_status <message>
#
# Prints a watchdog status line to this script's own stderr (unchanged —
# always reaches the console, exactly as a plain `echo ... >&2` would) and,
# ONLY when E2E_WATCHDOG_LOG_FILE is set, additionally appends the identical
# line to that file (which has already been created/truncated above by this
# point). This exists solely so a timeout status line survives into the
# redirected log for a downstream reader (see the header comment's
# "Timeout-detection exception" note) — it is a tee, never a substitute for
# the console print, and the append is best-effort (a failure to write here
# must never change this script's own exit code contract).
watchdog_status() {
  local message="$1"
  echo "$message" >&2
  if [ -n "$log_file" ]; then
    printf '%s\n' "$message" >>"$log_file" 2>/dev/null || true
  fi
}

# --- Opt-in heartbeat (P3) ---------------------------------------------------
#
# Only meaningful when log_file redirection (above) is also enabled, since
# heartbeat's progress signal is "how many lines has the redirected log
# grown by". Disabled by default (interval 0).
heartbeat_interval="${E2E_WATCHDOG_HEARTBEAT_INTERVAL:-0}"
case "$heartbeat_interval" in
  ''|*[!0-9]*)
    echo "::error title=BLOCKED_INVALID_HEARTBEAT::E2E_WATCHDOG_HEARTBEAT_INTERVAL must be a whole number of seconds (got '${heartbeat_interval}')" >&2
    exit "$EXIT_USAGE"
    ;;
esac

heartbeat_enabled=0
if [ "$heartbeat_interval" -gt 0 ]; then
  if [ -z "$log_file" ]; then
    echo "[STEP] watchdog: E2E_WATCHDOG_HEARTBEAT_INTERVAL is set but E2E_WATCHDOG_LOG_FILE is not; heartbeat disabled (nothing to count lines in)" >&2
  else
    heartbeat_enabled=1
  fi
fi

heartbeat_pid=""

# Reaped on every exit path (normal return, `exit` from a timeout/error
# branch below, or an unexpected early exit) so the heartbeat background
# process never leaks as an orphan. Idempotent: safe to call more than once.
#
# Uses signal_tree (defined further below, but already loaded by the time
# this is ever actually invoked via the EXIT trap) to signal the heartbeat
# subshell's whole process group, not just the subshell itself: start_heartbeat
# backgrounds it with job control enabled so it gets its own group (mirroring
# run_with_bash_fallback's existing pattern for the main child below), and its
# `sleep <interval>` grandchild inherits that same group. A plain `kill
# $heartbeat_pid` only ever terminated the subshell; the `sleep` it was
# blocked in kept running as an orphan for up to <interval> seconds (30s in
# production) after every exit path, which is the bug signal_tree fixes here.
stop_heartbeat() {
  if [ -n "$heartbeat_pid" ]; then
    signal_tree TERM "$heartbeat_pid"
    wait "$heartbeat_pid" 2>/dev/null || true
    heartbeat_pid=""
  fi
}
trap stop_heartbeat EXIT

# start_heartbeat <interval_seconds> <log_file>
#
# Backgrounds a loop that, every <interval_seconds>, prints one progress line
# to THIS script's own stdout (never redirected, so it always reaches the
# console even when the child's output is going to <log_file>).
#
# Job control (`set -m`) is enabled only for the instant this subshell is
# backgrounded, so it becomes its own process group leader (pgid == its own
# pid) instead of sharing this script's group — the same technique
# run_with_bash_fallback uses for the main child, applied here so
# stop_heartbeat's signal_tree call above can actually reach the `sleep`
# grandchild too, not just the subshell.
start_heartbeat() {
  local interval="$1"
  local logf="$2"

  set -m
  (
    local last_count=0
    local start_ts
    start_ts="$(date +%s)"
    while true; do
      sleep "$interval"

      local now elapsed count delta last_line masked_line
      now="$(date +%s)"
      elapsed=$((now - start_ts))

      if [ -f "$logf" ]; then
        count="$(wc -l < "$logf" 2>/dev/null | tr -d '[:space:]')"
        count="${count:-0}"
      else
        count=0
      fi
      delta=$((count - last_count))
      last_count="$count"

      if [ -f "$logf" ]; then
        last_line="$(grep -v '^[[:space:]]*$' -- "$logf" 2>/dev/null | tail -n 1)"
      else
        last_line=""
      fi

      if [ "$mask_available" = "1" ]; then
        masked_line="$(printf '%s' "$last_line" | mask_secrets)"
      else
        masked_line="<mask_secrets unavailable - raw output suppressed>"
      fi
      # Length-cap after masking so a pathologically long single line cannot
      # blow up the heartbeat line itself.
      masked_line="${masked_line:0:200}"

      echo "[STEP] watchdog: elapsed=${elapsed}s lines=${count} delta=+${delta} last=${masked_line}"
    done
  ) &
  heartbeat_pid=$!
  set +m
}

# --- Opt-in on-failure tail + milestone dump (P4) ---------------------------
#
# dump_tail_and_milestones <log_file>
#
# Best-effort: a missing/empty log file is reported and skipped, and any
# failure inside this function must never propagate to (or change) this
# script's own exit code — the diagnostic dump is strictly additive.
dump_tail_and_milestones() {
  local logf="$1"
  local out_file="${E2E_WATCHDOG_TAIL_FILE:-}"

  if [ ! -f "$logf" ]; then
    echo "[STEP] watchdog: redirected log file not found, skipping timeout/failure tail dump: ${logf}" >&2
    return 0
  fi
  if [ ! -s "$logf" ]; then
    echo "[STEP] watchdog: redirected log file is empty, skipping timeout/failure tail dump: ${logf}" >&2
    return 0
  fi

  local tail_content
  tail_content="$(tail -n "$TAIL_LINES" -- "$logf" 2>/dev/null || true)"

  local masked_tail
  if [ "$mask_available" = "1" ]; then
    masked_tail="$(printf '%s\n' "$tail_content" | mask_secrets)"
  else
    masked_tail="<mask_secrets unavailable - raw tail suppressed to avoid leaking secrets>"
  fi

  echo "::group::watchdog tail (last ${TAIL_LINES} lines of redirected child output)"
  printf '%s\n' "$masked_tail"
  echo "::endgroup::"

  if [ -n "$out_file" ]; then
    if ! printf '%s\n' "$masked_tail" > "$out_file" 2>/dev/null; then
      echo "[STEP] watchdog: failed to write tail dump to E2E_WATCHDOG_TAIL_FILE ('${out_file}')" >&2
    fi
  fi

  echo "::group::watchdog milestone scan"
  local patterns=("Xcode build done" "Installing" "Launching" "VM Service" "listening on" "error:" "xcodebuild:")
  local pattern matches any_match
  any_match=0
  for pattern in "${patterns[@]}"; do
    matches="$(grep -nF -- "$pattern" "$logf" 2>/dev/null || true)"
    if [ -n "$matches" ]; then
      any_match=1
      echo "-- pattern: ${pattern} --"
      if [ "$mask_available" = "1" ]; then
        printf '%s\n' "$matches" | mask_secrets
      else
        echo "<mask_secrets unavailable - raw matches suppressed>"
      fi
    fi
  done
  if [ "$any_match" -eq 0 ]; then
    echo "마일스톤 매치 없음"
  fi
  echo "::endgroup::"

  return 0
}

# Resolve a GNU coreutils `timeout`, if one exists on this machine.
#
# Presence of a binary named `timeout` is NOT enough: a non-GNU implementation
# may not support `-k` (the kill-after grace flag) or may not use 124 for a
# timeout, which would silently change this script's contract. So the probe is
# fail-closed - anything that does not clearly identify itself as GNU
# coreutils is ignored and the bash fallback is used instead.
#
# E2E_WATCHDOG_FORCE_BASH=1 forces the bash fallback even when a GNU
# `timeout` is present. This exists so the fallback - which is the path that
# will actually run on a macOS runner - can be exercised on a machine that
# does have GNU coreutils (e.g. a Linux/git-bash dev box), instead of only
# being reachable on the very platform it is hardest to test on.
resolve_gnu_timeout() {
  if [ "${E2E_WATCHDOG_FORCE_BASH:-0}" = "1" ]; then
    return 1
  fi

  local candidate
  for candidate in gtimeout timeout; do
    if command -v "$candidate" >/dev/null 2>&1; then
      if "$candidate" --version 2>/dev/null | head -n 1 | grep -qi 'coreutils'; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

# Signal a process and, when the platform supports it, its whole process
# group, so that children spawned by the command (xcodebuild, dart, simulator
# helpers) are torn down with it rather than left orphaned.
#
# The group form is attempted first and failures are tolerated: not every
# platform this script may be linted/exercised on supports negative-PID
# signalling, and a best-effort kill must never abort the watchdog itself.
signal_tree() {
  local sig="$1"
  local pid="$2"
  kill -"$sig" -- -"$pid" 2>/dev/null \
    || kill -"$sig" "$pid" 2>/dev/null \
    || true
}

run_with_bash_fallback() {
  # Job control is enabled so the background child is placed in its own
  # process group; without it the negative-PID signal above would target this
  # script's own group and the watchdog would kill itself.
  set -m

  if [ -n "$log_file" ]; then
    "$@" > "$log_file" 2>&1 &
  else
    "$@" &
  fi
  local pid=$!

  set +m

  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    watchdog_status "[STEP] watchdog: command exceeded ${timeout_seconds}s, sending SIGTERM"
    signal_tree TERM "$pid"

    local waited=0
    while [ "$waited" -lt "$GRACE_SECONDS" ]; do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
      echo "[STEP] watchdog: still alive after ${GRACE_SECONDS}s grace, sending SIGKILL" >&2
      signal_tree KILL "$pid"
    fi

    wait "$pid" 2>/dev/null || true
    return "$EXIT_TIMEOUT"
  fi

  local rc=0
  wait "$pid" || rc=$?
  return "$rc"
}

gnu_timeout=""
if gnu_timeout="$(resolve_gnu_timeout)"; then
  echo "[STEP] watchdog: bounding command at ${timeout_seconds}s via GNU ${gnu_timeout}"
else
  gnu_timeout=""
  echo "[STEP] watchdog: no GNU timeout available, bounding command at ${timeout_seconds}s via bash supervisor"
fi

if [ -n "$log_file" ]; then
  echo "[STEP] watchdog: child stdout+stderr redirected to ${log_file} (console streaming disabled for the child only)"
fi

if [ "$heartbeat_enabled" -eq 1 ]; then
  start_heartbeat "$heartbeat_interval" "$log_file"
fi

rc=0
if [ -n "$gnu_timeout" ]; then
  if [ -n "$log_file" ]; then
    "$gnu_timeout" -k "$GRACE_SECONDS" "$timeout_seconds" "$@" > "$log_file" 2>&1 || rc=$?
  else
    "$gnu_timeout" -k "$GRACE_SECONDS" "$timeout_seconds" "$@" || rc=$?
  fi
else
  run_with_bash_fallback "$@" || rc=$?
fi

stop_heartbeat

# Review round-2 fix (LOW): the tail/milestone dump below reads log_file from
# disk, and on a timeout the "::error title=E2E_WATCHDOG_TIMEOUT::..." status
# line is appended into that same log_file by watchdog_status() just below.
# This dump used to run AFTER that append, so on every timeout the freshly
# appended "::error" line was itself inside the last TAIL_LINES of log_file
# and got printed to the console a second time via the tail dump (GitHub
# Actions parses `::error` as a workflow command wherever it appears in the
# log, including inside a `::group::`, so this was a real duplicate
# annotation, not just a cosmetic repeat — three annotations in production
# once the workflow step's own separate `::error` echo is counted too).
# Capturing the tail BEFORE the status-line append avoids this: the dump
# below cannot contain a line that has not been written yet. This does not
# change what ends up in log_file itself (watchdog_status still appends the
# same line right after, so scripts/ios/e2e_summarize.sh's
# `watchdog_timeout_line()` still finds it when reading the file from disk
# after this process exits) — it only changes what shows up twice in this
# process's own console output.
if [ -n "$log_file" ] && [ "$rc" -ne 0 ]; then
  dump_tail_and_milestones "$log_file" || true
fi

if [ "$rc" -eq "$EXIT_TIMEOUT" ]; then
  watchdog_status "::error title=E2E_WATCHDOG_TIMEOUT::Command exceeded the ${timeout_seconds}s watchdog bound and was terminated"
else
  echo "[STEP] watchdog: command completed with exit code ${rc}"
fi

exit "$rc"
