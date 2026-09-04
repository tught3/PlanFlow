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
#        convention), e.g. a missing or non-numeric timeout argument
#   *    otherwise, the command's own exit code, forwarded unchanged
#
# Implementation note: macOS runners are BSD-based and do NOT ship GNU
# coreutils `timeout` by default, so this script cannot rely on it being
# present. It probes for a GNU `timeout`/`gtimeout` and, when neither is
# available, falls back to a pure-bash supervisor loop. That bash fallback is
# the load-bearing path here, not an afterthought.

set -uo pipefail

# Whole seconds to wait between SIGTERM and SIGKILL.
readonly GRACE_SECONDS=5

readonly EXIT_TIMEOUT=124
readonly EXIT_USAGE=125

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

  "$@" &
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
    echo "[STEP] watchdog: command exceeded ${timeout_seconds}s, sending SIGTERM" >&2
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

rc=0
if [ -n "$gnu_timeout" ]; then
  "$gnu_timeout" -k "$GRACE_SECONDS" "$timeout_seconds" "$@" || rc=$?
else
  run_with_bash_fallback "$@" || rc=$?
fi

if [ "$rc" -eq "$EXIT_TIMEOUT" ]; then
  echo "::error title=E2E_WATCHDOG_TIMEOUT::Command exceeded the ${timeout_seconds}s watchdog bound and was terminated" >&2
else
  echo "[STEP] watchdog: command completed with exit code ${rc}"
fi

exit "$rc"
