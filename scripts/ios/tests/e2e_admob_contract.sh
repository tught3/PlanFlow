#!/usr/bin/env bash
# Static, macOS-independent contract checks for production and E2E AdMob configuration.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null 2>&1 && pwd)"
runner="$repo_root/scripts/ios/e2e_xctest_flow.sh"
plist="$repo_root/ios/Runner/Info.plist"
summarizer="$repo_root/scripts/ios/e2e_summarize.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

runner_text="$(cat "$runner")"
plist_text="$(cat "$plist")"
summarizer_text="$(cat "$summarizer")"
plist_flat="$(printf '%s' "$plist_text" | tr '\n' ' ')"
production_app_id="$(printf '%s' "$plist_flat" | sed -nE 's/.*<key>GADApplicationIdentifier<\/key>[[:space:]]*<string>(ca-app-pub-[0-9]+~[0-9]+)<\/string>.*/\1/p')"

printf '%s' "$plist_flat" | grep -qE -- '<key>GADApplicationIdentifier</key>[[:space:]]*<string>ca-app-pub-[0-9]+~[0-9]+</string>' || \
  fail 'production Runner Info.plist is missing a strict AdMob application ID'
if printf '%s' "$plist_text" | grep -qE -- 'ca-app-pub-3940256099942544~(1458002511|3347511713)'; then
  fail 'production Runner Info.plist contains a public Google test application ID'
fi
printf '%s' "$plist_text" | grep -qF -- 'GADApplicationIdentifier' || \
  fail 'production Runner Info.plist App ID key is missing'
if [ -z "$production_app_id" ] || printf '%s' "$runner_text" | grep -qF -- "$production_app_id"; then
  fail 'E2E runner contains a committed production App ID instead of temporary injection'
fi
printf '%s' "$runner_text" | grep -qF -- 'ca-app-pub-3940256099942544~1458002511' || \
  fail 'official iOS Google sample app ID is missing from the E2E runner'
printf '%s' "$runner_text" | grep -qF -- 'ca-app-pub-3940256099942544~3347511713' && \
  fail 'Android Google sample app ID appears in the E2E runner'
printf '%s' "$runner_text" | grep -qF -- 'cp -p -- "$runner_plist" "$runner_plist_backup"' || \
  fail 'Runner plist backup is missing'
printf '%s' "$runner_text" | grep -qF -- 'cp -p -- "$runner_plist_backup" "$runner_plist"' || \
  fail 'Runner plist restoration is missing'
printf '%s' "$runner_text" | grep -qF -- 'cleanup_started=0' || \
  fail 'cleanup re-entry guard is missing'
printf '%s' "$runner_text" | grep -qF -- 'trap - EXIT INT TERM HUP' || \
  fail 'cleanup does not detach all signal traps'
printf '%s' "$runner_text" | grep -qF -- "trap 'on_signal 143' TERM" || \
  fail 'TERM signal restoration trap is missing'
printf '%s' "$runner_text" | grep -qF -- "trap 'on_signal 130' INT" || \
  fail 'INT signal restoration trap is missing'
printf '%s' "$runner_text" | grep -qF -- "trap 'on_signal 129' HUP" || \
  fail 'HUP signal restoration trap is missing'
if printf '%s' "$runner_text" | grep -qE -- '(echo|printf)[^\n]*E2E_ADMOB_TEST_APP_ID'; then
  fail 'E2E AdMob app ID is printed directly'
fi
pass 'E2E-only injection, restoration, signal safety, and secret-free output contract'

printf '%s' "$summarizer_text" | grep -qF -- 'Testing failed:' || \
  fail 'summarizer does not recognize terminal XCTest failure'
printf '%s' "$summarizer_text" | grep -qF -- 'XCTEST_NATIVE_FAILURE' || \
  fail 'summarizer native XCTest classification is missing'
pass 'native XCTest crash classification contract'

echo 'e2e_admob_contract.sh: all checks passed'
