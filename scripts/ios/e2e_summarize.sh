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
    else
      echo "No failure markers detected in the captured log for this category."
      echo ""
    fi
  fi

  echo "---"
  echo ""
  echo "_Generated by scripts/ios/e2e_summarize.sh (best-effort; a parsing_"
  echo "_gap here does not change the actual test outcome, which is in_"
  echo "_flow-test-output.log)._"
} > "$summary_file"

echo "e2e_summarize.sh: wrote $summary_file"
