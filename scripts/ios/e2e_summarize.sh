#!/usr/bin/env bash
# Best-effort failure summarizer for a captured `flutter test` log from the
# iOS Simulator E2E workflow's `simulator-e2e` job (device-category legs:
# small/mainstream/large/ipad). Never used for the separate
# `flow05-auth-backend` job — that job forwards a real (non-production)
# Supabase credential as a dart-define, and a captured-log summary artifact
# is not covered by GitHub Actions' secret-masking, so this script is
# intentionally not wired into that job to avoid leaking a credential into
# an uploaded artifact.
#
# Reads a captured stdout+stderr log for one device-category leg and writes
# a small markdown summary describing:
#   - the device category and which flow files it attempted
#   - any failed flow test file(s), each with its first observed error line
#   - a coarse failure-category classification, derived by matching known
#     phrases against that error line (best-effort string match, not a real
#     parser — an unmatched phrase is reported as UNKNOWN together with the
#     original line rather than silently mis-classified)
#   - a "hang signals" section for the E2E run-2 hang investigation: the last
#     `[CHECKPOINT] <marker>` line reached (emitted by
#     integration_test/_harness/checkpoint_logger.dart), whether the watchdog
#     (scripts/ios/e2e_watchdog.sh) killed the run, and whether the log went
#     silent right after "Xcode build done"
#
# This script is invoked from an `if: always()` workflow step and is
# intentionally best-effort: a parsing problem here must never be confused
# with (or mask) the actual test outcome, which is already captured verbatim
# in the log file this script reads. Pure text processing only (bash, grep,
# sed) — no macOS-only commands — so it can also be exercised locally
# against a fixture log on any platform.
#
# Usage: e2e_summarize.sh <category> <log_file> <summary_file> [flow_files]
#   category:     device category label (small|mainstream|large|ipad), used
#                 only for the summary header — not validated against the
#                 workflow's category list, since a future category should
#                 not make this script itself fail.
#   log_file:     path to the captured `flutter test` stdout+stderr log
#   summary_file: path to write the generated markdown summary to
#   flow_files:   optional space-separated list of the
#                 `integration_test/flowNN_..._test.dart` paths this leg
#                 attempted (passed in by the workflow step rather than
#                 re-derived here, so the category->files mapping has a
#                 single source of truth: the workflow file itself)

set -uo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <category> <log_file> <summary_file> [flow_files]" >&2
  exit 1
fi

category="$1"
log_file="$2"
summary_file="$3"
flow_files_arg="${4:-}"

if [ ! -f "$log_file" ]; then
  echo "e2e_summarize.sh: log file not found: $log_file" >&2
  exit 1
fi

# Best-effort classification of a single error line into a coarse category.
# Anything that does not match a known phrase is reported as UNKNOWN
# alongside the original line, rather than guessed at — the goal is to make
# an unrecognized failure shape obvious, not to hide it inside a wrong
# bucket.
classify_error() {
  local line="$1"
  case "$line" in
    *"Unable to install"*|*"simctl install"*)
      echo "APP_INSTALL"
      ;;
    *"xcodebuild"*[Ff]ail*|*"Xcode build"*[Ff]ail*|*"** BUILD FAILED **"*)
      echo "XCODE_BUILD"
      ;;
    *)
      echo "UNKNOWN"
      ;;
  esac
}

# --- Hang signals (E2E run-2 hang investigation) -----------------------
#
# These three probes look at the log as a whole rather than at one flow
# file's failure line, because the hang under investigation produces no
# per-test failure marker at all: the run goes silent and is later killed.
# Each probe is a pure text match and is allowed to find nothing — "not
# observed" is reported as such rather than guessed at.

# The marker of the last `[CHECKPOINT] <marker>` line in the log, or empty
# when the log contains none.
#
# Empty is an expected outcome, not a bug: `flutter test -d <UDID>` does not
# forward the app process's stdout to the CI log at all (see the long
# investigation comment at the top of checkpoint_logger.dart), so on the
# current workflow wiring these lines may legitimately never appear. The
# summary says "no checkpoint lines" in that case instead of inventing a
# position.
last_checkpoint_marker() {
  local line
  line="$(grep -F -- '[CHECKPOINT] ' "$log_file" 2>/dev/null | tail -n 1 || true)"
  if [ -z "$line" ]; then
    return 0
  fi
  # Strip everything up to and including the first "[CHECKPOINT] " so the
  # marker survives any timestamp/prefix the CI or the tool may have added
  # in front of it.
  printf '%s' "${line#*'[CHECKPOINT] '}"
}

# The first watchdog-timeout line in the log, or empty when the run was not
# killed by the watchdog.
#
# Both matched phrases are written by scripts/ios/e2e_watchdog.sh's own
# `watchdog_status` helper. As of Wave3/P5, the workflow no longer routes the
# watchdog invocation through `2>&1 | tee` at all — the child's stdout+stderr
# go straight to E2E_WATCHDOG_LOG_FILE (this is the `$log_file` this script
# reads) via the watchdog's own redirection, and the watchdog's own status
# lines print to its stderr as before. On timeout, `watchdog_status`
# appends status lines into E2E_WATCHDOG_LOG_FILE (see e2e_watchdog.sh's
# header comment, "Timeout-detection exception"), which is what makes them
# visible to this grep — without that append, a real timeout would be
# indistinguishable from "no timeout" here, since nothing else about the
# timeout ever reaches this file (review fix, H1; this comment previously
# described a stale `tee`-based mechanism that Wave3 had already removed, so
# this detection had been silently dead in production).
#
# (Review round-2 correction, LOW: this used to claim both status lines are
# always appended. Only the second one — "::error title=E2E_WATCHDOG_TIMEOUT::"
# — actually is: e2e_watchdog.sh's bash-fallback path appends it AFTER
# `wait`-ing for the child to exit, so the child is confirmed dead and there
# is no writer left to race against. The first — "watchdog: command exceeded
# ...s, sending SIGTERM" — is appended WHILE the child may still be alive and
# still writing to the same file (SIGTERM has just been sent, not yet
# honored), so it is best-effort and can be lost to that write race; a real
# reproduction with a continuously-writing 37MB child (documented in the
# round-2 review of this change) found the first line missing from the log
# entirely while the second line was present, matching the mechanism above.
# `-m 1` above and the `-e`/`-e` alternation mean this function only ever
# needs ONE of the two to match, so the guaranteed second line alone is
# sufficient for this detector — the first line's best-effort nature does
# not weaken it.) (The workflow step's own post-run
# "WATCHDOG_TIMEOUT: ..." echo is a separate, later `echo` in the workflow
# step itself and is not what this grep relies on — it is not guaranteed to
# land in this log file either.) Matching on the substring WATCHDOG_TIMEOUT
# covers the annotation form `::error title=E2E_WATCHDOG_TIMEOUT::...` as
# well.
watchdog_timeout_line() {
  grep -F -m 1 -e "WATCHDOG_TIMEOUT" -e "watchdog: command exceeded" "$log_file" 2>/dev/null || true
}

# Non-empty, non-watchdog-noise lines that appear after the last
# "Xcode build done" line. Prints the count (0 when the log went silent right
# after the build finished, or when there is no build-done line at all).
#
# Watchdog output is excluded on purpose: those lines are emitted by the
# supervisor *because* nothing else was happening, so counting them as
# activity would mask exactly the signature being detected.
lines_after_build_done() {
  local total build_done_line_no
  total="$(grep -c '' "$log_file" 2>/dev/null || echo 0)"
  build_done_line_no="$(grep -nF -- 'Xcode build done' "$log_file" 2>/dev/null | tail -n 1 | cut -d: -f1 || true)"
  if [ -z "$build_done_line_no" ]; then
    echo 0
    return 0
  fi
  if [ "$build_done_line_no" -ge "$total" ] 2>/dev/null; then
    echo 0
    return 0
  fi
  sed -n "$((build_done_line_no + 1)),\$p" "$log_file" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | grep -v -F -e '[STEP] watchdog:' -e 'WATCHDOG_TIMEOUT' \
    | grep -c '' || true
}

# Coarse 3-way classification of how the log ended relative to the Xcode
# build step. Prints exactly one of:
#   NEVER_COMPLETED — no "Xcode build done" line at all: the build itself
#                      never finished within the captured log (this is NOT
#                      the same as a silent-after-success hang, and must not
#                      be reported as "normal" — a run that never reaches the
#                      build-done line has made even less progress than one
#                      that hangs right after it).
#   SILENT           — "Xcode build done" is present and nothing meaningful
#                       follows it — the exact shape of the observed run-2
#                       hang.
#   ACTIVE           — "Xcode build done" is present and further output
#                       follows it (the normal/healthy shape).
#
# Previously a single boolean (`build_succeeded_then_silent`) conflated the
# first two cases: it returned false both when the build never completed and
# when it completed with real output after it, and the caller reported both
# as "정상" (normal). A build that never even reaches "Xcode build done" is
# never normal — it means the captured log stops mid-build (e.g. because the
# whole leg was killed before the build finished), which is a distinct and
# more severe failure shape than "build succeeded, then silence". Collapsing
# it into "normal" is a fail-open misclassification.
build_completion_status() {
  # xcodebuild can report a native XCTest host crash as "Testing failed:",
  # even when the captured Flutter log never reaches "Xcode build done".
  # Check this terminal XCTest signal first so that a post-build native crash
  # is not mislabeled as BUILD_NEVER_COMPLETED.
  if grep -qF -- 'Testing failed:' "$log_file" 2>/dev/null; then
    echo "XCTEST_NATIVE_FAILURE"
    return 0
  fi
  if ! grep -qF -- 'Xcode build done' "$log_file" 2>/dev/null; then
    echo "NEVER_COMPLETED"
    return 0
  fi
  local remaining
  remaining="$(lines_after_build_done)"
  if [ "${remaining:-0}" -eq 0 ] 2>/dev/null; then
    echo "SILENT"
  else
    echo "ACTIVE"
  fi
}

# First non-empty line found after `anchor_line`'s first occurrence in
# `log_file`, scanning up to a small fixed window of following lines. Falls
# back to the anchor line itself if nothing usable follows (or if `grep -A`
# is unavailable/behaves unexpectedly on some platform's grep — this
# function must never abort the caller).
first_detail_after() {
  local anchor_line="$1"
  local detail
  detail="$(grep -F -A 5 -- "$anchor_line" "$log_file" 2>/dev/null \
    | sed -n '2,6p' \
    | grep -v '^[[:space:]]*$' \
    | head -n 1 || true)"
  if [ -z "$detail" ]; then
    detail="$anchor_line"
  fi
  echo "$detail"
}

{
  echo "# iOS Simulator E2E failure summary"
  echo ""
  echo "- Device category: \`$category\`"
  echo "- Log file: \`$(basename -- "$log_file")\`"
  if [ -n "$flow_files_arg" ]; then
    echo "- Flow files attempted:"
    for flow_file in $flow_files_arg; do
      echo "  - \`$flow_file\`"
    done
  else
    echo "- Flow files attempted: (not provided to this script)"
  fi
  echo ""

  checkpoint_marker="$(last_checkpoint_marker)"
  watchdog_line="$(watchdog_timeout_line)"
  build_status="$(build_completion_status)"

  echo "## Hang signals"
  echo ""
  if [ -n "$checkpoint_marker" ]; then
    echo "- 마지막 도달 체크포인트: \`$checkpoint_marker\`"
  else
    echo "- 마지막 도달 체크포인트: 체크포인트 로그 없음 (\`[CHECKPOINT]\` 라인이 캡처된 로그에 없음 — \`flutter test -d <UDID>\` 경로는 앱 프로세스의 stdout을 CI 로그로 전혀 forwarding하지 않으므로(채널 자체가 부재, 상세는 integration_test/_harness/checkpoint_logger.dart 상단 주석 참고), 이 항목이 비어 있는 것은 현재 워크플로우 배선에서 항상 나타나는 알려진 한계이며 테스트가 해당 체크포인트에 미도달했다는 뜻과 구분할 수 없음)"
  fi
  if [ -n "$watchdog_line" ]; then
    echo "- Watchdog: 타임아웃으로 종료됨 — \`$watchdog_line\`"
  else
    echo "- Watchdog: 타임아웃 신호 없음"
  fi
  case "$build_status" in
    XCTEST_NATIVE_FAILURE)
      echo "- Post-build 출력: \"Testing failed:\" 감지 — native XCTest 실행 실패 또는 호스트 crash"
      ;;
    NEVER_COMPLETED)
      echo "- Post-build 출력: \"Xcode build done\" 라인 자체가 로그에 없음 — 빌드가 캡처된 로그 안에서 완료되지 못함"
      ;;
    SILENT)
      echo "- Post-build 출력: \"Xcode build done\" 이후 유의미한 로그 라인 없음"
      ;;
    ACTIVE)
      echo "- Post-build 출력: 정상 (빌드 완료 라인 이후 출력 있음)"
      ;;
  esac
  echo ""

  any_failure_found="false"

  if [ -n "$flow_files_arg" ]; then
    for flow_file in $flow_files_arg; do
      flow_basename="$(basename -- "$flow_file")"
      if ! grep -qF -- "$flow_basename" "$log_file"; then
        continue
      fi
      # Flutter's default human-readable test reporter marks a failed test
      # with a trailing "[E]" on the same line that names the file and test
      # description, e.g.:
      #   00:12 +34 -1: <path>/flow02_schedule_crud_test.dart: some test [E]
      failure_line="$(grep -F -- "$flow_basename" "$log_file" | grep -F -- '[E]' | head -n 1 || true)"
      if [ -z "$failure_line" ]; then
        continue
      fi
      any_failure_found="true"
      detail_line="$(first_detail_after "$failure_line")"
      category_guess="$(classify_error "$detail_line")"
      if [ "$category_guess" = "UNKNOWN" ]; then
        category_guess="$(classify_error "$failure_line")"
      fi

      echo "## FAILED: \`$flow_basename\`"
      echo ""
      echo "- Category guess: \`$category_guess\`"
      echo "- First failing test line: \`$failure_line\`"
      echo "- First error detail line: \`$detail_line\`"
      echo ""
    done
  fi

  if [ "$any_failure_found" = "false" ]; then
    # No per-file "[E]" markers found (or no flow_files_arg was provided).
    # The run may still have failed for a reason unrelated to a specific
    # flow file — simulator boot failure, app install failure, Xcode
    # toolchain failure, etc. Fall back to scanning the whole log for known
    # install/build failure phrases so this summary is not silently empty on
    # a real failure.
    whole_log_hit="$(grep -F -m 1 -e "Unable to install" -e "simctl install" -e "BUILD FAILED" "$log_file" || true)"
    if [ -n "$whole_log_hit" ]; then
      category_guess="$(classify_error "$whole_log_hit")"
      echo "## FAILED: (no specific flow file identified)"
      echo ""
      echo "- Category guess: \`$category_guess\`"
      echo "- First matching line: \`$whole_log_hit\`"
      echo ""
    elif [ -n "$watchdog_line" ]; then
      # The run was killed by scripts/ios/e2e_watchdog.sh rather than failing
      # on its own, so there is no error line to classify — the timeout IS
      # the finding.
      echo "## FAILED: (watchdog timeout, no specific flow file identified)"
      echo ""
      echo "- Category guess: \`WATCHDOG_TIMEOUT\`"
      echo "- First matching line: \`$watchdog_line\`"
      echo ""
    elif [ "$build_status" = "XCTEST_NATIVE_FAILURE" ]; then
      echo "## FAILED: (native XCTest failure, no specific flow file identified)"
      echo ""
      echo "- Category guess: \`XCTEST_NATIVE_FAILURE\`"
      echo "- First matching line: \`$(grep -F -m 1 -- 'Testing failed:' "$log_file" || true)\`"
      echo ""
    elif [ "$build_status" = "SILENT" ]; then
      # Previously this shape fell through to "no failure markers detected"
      # (or, with an error line present, to UNKNOWN). It has its own name now
      # because it is the signature of the run-2 hang: the Xcode build
      # completed and the Flutter tool then produced nothing at all, which
      # points at the install/launch/attach handshake rather than at any Dart
      # test body.
      echo "## FAILED: (no output after the Xcode build completed)"
      echo ""
      echo "- Category guess: \`BUILD_SUCCEEDED_THEN_SILENT\`"
      echo "- Last log line: \`$(grep -v '^[[:space:]]*$' "$log_file" | tail -n 1 || true)\`"
      echo ""
    elif [ "$build_status" = "NEVER_COMPLETED" ]; then
      # The captured log does not even reach "Xcode build done". This is a
      # distinct and more severe failure shape than BUILD_SUCCEEDED_THEN_SILENT
      # above: the build itself did not finish within the captured window
      # (e.g. the leg was killed, or the whole run timed out, before the
      # Xcode build step completed). Previously this fell through to "no
      # failure markers detected" and was reported by the Hang signals
      # section as "정상" — a fail-open misclassification, since a build that
      # never completes is never normal.
      echo "## FAILED: (Xcode build never completed within the captured log)"
      echo ""
      echo "- Category guess: \`BUILD_NEVER_COMPLETED\`"
      echo "- Last log line: \`$(grep -v '^[[:space:]]*$' "$log_file" | tail -n 1 || true)\`"
      echo ""
    else
      echo "No failure markers detected in the captured log for this category."
      echo ""
    fi
  fi

  echo "---"
  echo ""
  echo "_Generated by scripts/ios/e2e_summarize.sh (best-effort; a parsing_"
  echo "_gap here does not change the actual test outcome, which is in_"
  echo "_the raw captured log this summary was generated from: \`$(basename -- "$log_file")\`)._"
} > "$summary_file"

echo "e2e_summarize.sh: wrote $summary_file"
