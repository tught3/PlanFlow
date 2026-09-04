#!/usr/bin/env bash
# Stage-progress markers for the iOS Simulator E2E workflow's `flutter test`
# child process (see scripts/ios/e2e_watchdog.sh and
# scripts/ios/e2e_summarize.sh).
#
# Motivation: Run#4's actual failure was 4 of 5 legs (mainstream/small/ipad/
# flow05) hanging forever at "Waiting for VM Service port to be available..."
# — i.e. the app built and installed, but the Flutter tool never attached to
# it. Diagnosing that required reading raw watchdog heartbeat logs by hand for
# hours. This script does not add any new instrumentation: it re-reads the
# SAME redirected verbose log (E2E_WATCHDOG_LOG_FILE) and the SAME watchdog
# exit code that scripts/ios/e2e_summarize.sh already consumes, and promotes
# that existing signal into seven independent PASS/FAIL/UNKNOWN stage markers
# so the next regression is visible at a glance instead of requiring log
# archaeology.
#
# Every phrase matched below is taken verbatim from either:
#   (a) the real Run#4 console excerpts recorded in
#       docs/ios/E2E_RUN3_DECISION_TREE.md-style hang investigation notes
#       (mainstream leg: "Xcode build done" -> "executing: rsync ... Runner.app"
#       -> "Waiting for VM Service port to be available..." then silence;
#       flow05 leg: "running test package with arguments" -> "executing: ...
#       xcrun simctl install <UDID> ... Runner.app" -> "Waiting for VM Service
#       port to be available..." then silence), or
#   (b) an anchor scripts/ios/e2e_summarize.sh's dump_tail_and_milestones()
#       (in e2e_watchdog.sh) / build_completion_status() already treats as
#       meaningful ("Xcode build done", "Installing", "Launching",
#       "VM Service", "listening on", "[CHECKPOINT] ").
# A marker that cannot find any of its anchors reports UNKNOWN rather than
# guessing PASS or FAIL — this is a fail-closed design: an unrecognized log
# shape must never be silently reported as healthy.
#
# Usage: e2e_stage_markers.sh <log_file> <simulator_udid> <watchdog_exit_code>
#   log_file:           path to the redirected verbose `flutter test` log
#                        (same file passed as E2E_WATCHDOG_LOG_FILE to
#                        scripts/ios/e2e_watchdog.sh). May be missing/empty;
#                        every marker downstream of it degrades to UNKNOWN
#                        rather than erroring.
#   simulator_udid:      the UDID this leg booted (from `xcrun simctl create`
#                        as wired in .github/workflows/ios-simulator-e2e.yml's
#                        `boot` step). May be empty.
#   watchdog_exit_code:  the exit code scripts/ios/e2e_watchdog.sh returned
#                        for this leg's `flutter test` invocation (124 means
#                        the watchdog killed it on a timeout). May be empty.
#
# All three arguments are optional in practice: this script never validates
# argument count and never fails on a missing/unreadable log file — see the
# "always exits 0" contract below.
#
# Output: one line per marker on stdout,
#   E2E_STAGE marker=<NAME> status=PASS|FAIL|UNKNOWN evidence=<masked, <=200 chars>
# followed by exactly one summary line,
#   E2E_STAGE_SUMMARY first_failed=<marker name>|NONE
#
# Markers are always printed in this fixed order:
#   SIMULATOR_BOOT, APP_BUILD, APP_INSTALL, APP_LAUNCH, FLUTTER_ATTACH,
#   TEST_DISCOVERY, FLOW_EXECUTION
#
# Contract (deliberately mirrors scripts/ios/e2e_summarize.sh and
# scripts/ios/e2e_watchdog.sh's own diagnostic-dump helper):
#   - This script ALWAYS exits 0. It must never change a workflow job's
#     pass/fail result — that is decided solely by the job's own test-run
#     step exit code. A missing log file, an empty log file, a missing
#     argument, or an internal parsing hiccup here degrades individual
#     markers to UNKNOWN; it never aborts this script or propagates a
#     non-zero exit.
#   - Evidence text is only ever taken from lines that already exist in the
#     caller-supplied log file (or the caller-supplied udid/exit-code
#     arguments themselves) — this script fabricates nothing.
#   - Evidence text is masked via scripts/ios/e2e_mask_secrets.sh's
#     mask_secrets() before being printed, following the same fail-closed
#     convention as e2e_watchdog.sh: if that helper cannot be sourced, no raw
#     evidence is ever printed — a placeholder is printed instead.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# --- Fail-closed secret masking (identical loading pattern to
#     scripts/ios/e2e_watchdog.sh) ------------------------------------------
mask_available=0
mask_secrets_source="$script_dir/e2e_mask_secrets.sh"
if [ -f "$mask_secrets_source" ]; then
  # shellcheck source=./e2e_mask_secrets.sh
  if source "$mask_secrets_source" 2>/dev/null; then
    mask_available=1
  fi
fi

log_file="${1:-}"
udid="${2:-}"
watchdog_rc="${3:-}"

# mask_or_placeholder <text>
#
# Runs <text> through mask_secrets() when available; otherwise returns a
# fixed placeholder rather than ever printing raw text that might contain a
# credential. Mirrors e2e_watchdog.sh's heartbeat `last=` field and on-failure
# tail dump, which apply the identical fail-closed rule.
mask_or_placeholder() {
  local text="$1"
  if [ "$mask_available" = "1" ]; then
    printf '%s' "$text" | mask_secrets
  else
    echo "<mask_secrets unavailable - raw evidence suppressed>"
  fi
}

# cap200 <text>
#
# Length-caps already-masked text so one pathologically long matched line
# cannot blow up a single marker's output line (same 200-char cap
# e2e_watchdog.sh's heartbeat uses for its `last=` field).
cap200() {
  local text="$1"
  printf '%s' "${text:0:200}"
}

# find_first_match <pattern> <log_file>
#
# Prints the first line of <log_file> containing the fixed string <pattern>
# (grep -F, no regex interpretation). Prints nothing and returns non-zero
# when <log_file> does not exist, is empty, or contains no match — every
# caller below treats "nothing printed" as "anchor not found", never as an
# error.
find_first_match() {
  local pattern="$1"
  local logf="$2"
  if [ ! -f "$logf" ] || [ ! -s "$logf" ]; then
    return 1
  fi
  grep -F -m 1 -- "$pattern" "$logf" 2>/dev/null
}

# last_nonblank_line <log_file>
#
# Prints the last non-empty line of <log_file>, or nothing if the file is
# missing/empty. Same extraction e2e_watchdog.sh's heartbeat uses for its
# `last=` field.
last_nonblank_line() {
  local logf="$1"
  if [ ! -f "$logf" ] || [ ! -s "$logf" ]; then
    return 1
  fi
  grep -v '^[[:space:]]*$' -- "$logf" 2>/dev/null | tail -n 1
}

# --- Marker emission ---------------------------------------------------
first_failed="NONE"

# emit_marker <name> <status> <evidence>
emit_marker() {
  local name="$1"
  local status="$2"
  local evidence
  evidence="$(cap200 "$3")"
  echo "E2E_STAGE marker=${name} status=${status} evidence=${evidence}"
  if [ "$status" = "FAIL" ] && [ "$first_failed" = "NONE" ]; then
    first_failed="$name"
  fi
}

# --- 1. SIMULATOR_BOOT ------------------------------------------------------
# Existence check only: by the time this script is invoked (after the
# workflow's own `boot` step has already run `xcrun simctl boot` +
# `bootstatus -b`), a non-empty udid argument means that step already
# succeeded. This marker exists so a caller reading only this script's output
# can still see that stage was reached, without re-deriving it from workflow
# step outcomes.
if [ -n "$udid" ]; then
  emit_marker "SIMULATOR_BOOT" "PASS" "$(mask_or_placeholder "simulator udid provided: $udid")"
else
  emit_marker "SIMULATOR_BOOT" "UNKNOWN" "no simulator UDID was passed to this script"
fi

# --- 2. APP_BUILD ------------------------------------------------------
# Anchor: "Xcode build done" — reused verbatim from
# scripts/ios/e2e_summarize.sh's build_completion_status()/
# dump_tail_and_milestones() milestone scan (scripts/ios/e2e_watchdog.sh),
# and confirmed present in both the Run#4 mainstream and flow05 excerpts
# before the hang.
build_line="$(find_first_match "Xcode build done" "$log_file")"
if [ -n "$build_line" ]; then
  emit_marker "APP_BUILD" "PASS" "$(mask_or_placeholder "$build_line")"
else
  emit_marker "APP_BUILD" "UNKNOWN" "no 'Xcode build done' line found (anchor reused from e2e_summarize.sh build_completion_status())"
fi

# --- 3. APP_INSTALL ------------------------------------------------------
# Primary anchor: "simctl install" — verbatim from the Run#4 flow05 excerpt's
# "executing: /usr/bin/arch -arm64e xcrun simctl install <UDID> .../Runner.app"
# line. Secondary anchor: "Installing" — reused from e2e_watchdog.sh's own
# dump_tail_and_milestones() milestone pattern list.
install_line="$(find_first_match "simctl install" "$log_file")"
if [ -z "$install_line" ]; then
  install_line="$(find_first_match "Installing" "$log_file")"
fi
if [ -n "$install_line" ]; then
  emit_marker "APP_INSTALL" "PASS" "$(mask_or_placeholder "$install_line")"
else
  emit_marker "APP_INSTALL" "UNKNOWN" "neither 'simctl install' (Run#4 flow05 excerpt) nor 'Installing' (e2e_watchdog.sh milestone anchor) found"
fi

# --- 4. APP_LAUNCH ------------------------------------------------------
# Primary anchor: "Launching" — reused from e2e_watchdog.sh's own
# dump_tail_and_milestones() milestone pattern list. Secondary/fallback
# anchor: an "rsync" line that also mentions "Runner.app" — verbatim from the
# Run#4 mainstream excerpt's
# "executing: rsync -8 -av --delete .../Runner.app
#  /Users/runner/work/PlanFlow/PlanFlow/build/ios/iphonesimulator" line,
# which is the last step observed before that leg's hang. Neither anchor
# found -> UNKNOWN rather than guessing.
launch_line="$(find_first_match "Launching" "$log_file")"
if [ -z "$launch_line" ]; then
  rsync_candidate="$(find_first_match "rsync" "$log_file")"
  if [ -n "$rsync_candidate" ] && printf '%s' "$rsync_candidate" | grep -qF -- "Runner.app"; then
    launch_line="$rsync_candidate"
  fi
fi
if [ -n "$launch_line" ]; then
  emit_marker "APP_LAUNCH" "PASS" "$(mask_or_placeholder "$launch_line")"
else
  emit_marker "APP_LAUNCH" "UNKNOWN" "neither 'Launching' (e2e_watchdog.sh milestone anchor) nor an 'rsync ... Runner.app' line (Run#4 mainstream excerpt) found"
fi

# --- 5. FLUTTER_ATTACH ------------------------------------------------------
# This is the decisive check for the Run#4 shape: the run's last non-empty
# log line was, verbatim in both the mainstream and flow05 excerpts,
# "Waiting for VM Service port to be available..." followed by nothing else
# until the watchdog (scripts/ios/e2e_watchdog.sh) killed the child with
# SIGTERM/SIGKILL and returned exit code 124. When that exact shape recurs,
# this marker reports FAIL with evidence=VM_SERVICE_WAIT_HANG rather than
# falling through to a generic UNKNOWN, so the next occurrence of this exact
# regression is named on sight.
#
# Otherwise, a successful attach is recognized via "listening on" — reused
# verbatim from e2e_watchdog.sh's own milestone pattern list (the shape of a
# real "VM Service listening on http://127.0.0.1:<port>/..." line). No match
# for either shape -> UNKNOWN (this script never guesses PASS from absence of
# evidence).
last_line="$(last_nonblank_line "$log_file")"
if [ -n "$last_line" ] \
  && printf '%s' "$last_line" | grep -qF -- "Waiting for VM Service port to be available" \
  && [ "$watchdog_rc" = "124" ]; then
  emit_marker "FLUTTER_ATTACH" "FAIL" "VM_SERVICE_WAIT_HANG: $(mask_or_placeholder "$last_line")"
else
  attach_line="$(find_first_match "listening on" "$log_file")"
  if [ -n "$attach_line" ]; then
    emit_marker "FLUTTER_ATTACH" "PASS" "$(mask_or_placeholder "$attach_line")"
  else
    emit_marker "FLUTTER_ATTACH" "UNKNOWN" "no VM Service connect signal ('listening on', e2e_watchdog.sh milestone anchor) found, and the Run#4 hang shape (last line = 'Waiting for VM Service port to be available...' + watchdog exit 124) was not observed either"
  fi
fi

# --- 6. TEST_DISCOVERY ------------------------------------------------------
# Anchor: "running test package with arguments" — verbatim from the Run#4
# flow05 excerpt's
# "running test package with arguments: [--no-color, --concurrency=1, ...]"
# line, which is the Flutter tool's own log line for starting a test binary.
discovery_line="$(find_first_match "running test package with arguments" "$log_file")"
if [ -n "$discovery_line" ]; then
  emit_marker "TEST_DISCOVERY" "PASS" "$(mask_or_placeholder "$discovery_line")"
else
  emit_marker "TEST_DISCOVERY" "UNKNOWN" "no 'running test package with arguments' line found (anchor: Run#4 flow05 excerpt)"
fi

# --- 7. FLOW_EXECUTION ------------------------------------------------------
# Primary anchor: "[CHECKPOINT] " — reused verbatim from
# scripts/ios/e2e_summarize.sh's last_checkpoint_marker(), which already
# treats this as the signal that a flow test body actually started
# executing. Secondary anchor: "All tests passed" — the literal final line
# Flutter's default test reporter prints on a fully green run, and already an
# established fixture value in scripts/ios/tests/e2e_script_contract.sh's own
# fixture_c_log/fixture_no_checkpoint_log ("+12 -0: All tests passed!" /
# "+5 -0: All tests passed!"). If FLUTTER_ATTACH above never got past
# attaching, this marker legitimately reports UNKNOWN — it must not report
# PASS just because the earlier stages did.
exec_line="$(find_first_match "[CHECKPOINT] " "$log_file")"
if [ -z "$exec_line" ]; then
  exec_line="$(find_first_match "All tests passed" "$log_file")"
fi
if [ -n "$exec_line" ]; then
  emit_marker "FLOW_EXECUTION" "PASS" "$(mask_or_placeholder "$exec_line")"
else
  emit_marker "FLOW_EXECUTION" "UNKNOWN" "neither '[CHECKPOINT] ' (e2e_summarize.sh anchor) nor 'All tests passed' (flutter test reporter's final line, per e2e_script_contract.sh's own fixtures) found"
fi

echo "E2E_STAGE_SUMMARY first_failed=${first_failed}"

# Contract: this script always exits 0 regardless of what it found above —
# see the header comment. Its findings are entirely conveyed through the
# E2E_STAGE/E2E_STAGE_SUMMARY lines already printed; a non-zero exit here
# must never be able to change a workflow job's pass/fail result.
exit 0
