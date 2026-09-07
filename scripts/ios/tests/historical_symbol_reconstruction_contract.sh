#!/usr/bin/env bash
# Static, macOS-independent safety contract for historical symbol reconstruction.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null 2>&1 && pwd)"
workflow="$root/.github/workflows/ios-historical-symbol-reconstruction.yml"
script="$root/scripts/ios/reconstruct_historical_runner_symbols.sh"
failures=0
contains() { grep -qF -- "$2" "$1"; }
not_contains() { ! grep -qE -- "$2" "$1"; }
check() { description="$3"; if "$@"; then echo "PASS: $description"; else echo "FAIL: $description"; failures=$((failures + 1)); fi; }

check contains "$workflow" "workflow_dispatch" "workflow is manual-only"
check contains "$workflow" "contents: read" "permissions are read-only"
check contains "$workflow" "fail-fast: false" "matrix fail-fast is disabled"
check contains "$workflow" "503bba99ec5efe37195b2a516c0f923c9fd8b4c6" "fixed Build 16 source"
check contains "$workflow" "f5cd355e0aa78eeb575326cee2822e6bbb528805" "fixed Build 17 source"
check contains "$workflow" "96EB03A3-C4E7-3C3E-9C58-9E3F6DE896BC" "fixed Build 16 UUID"
check contains "$workflow" "D9B552C8-3F13-3217-B8B9-6886EE0926D0" "fixed Build 17 UUID"
check contains "$workflow" "7717012" "fixed Build 16 offsets"
check contains "$workflow" "7717068" "fixed Build 17 offsets"
check contains "$workflow" "actions/checkout@11d5960a326750d5838078e36cf38b85af677262" "checkout SHA pinned"
check contains "$workflow" "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02" "artifact action SHA pinned"
check contains "$workflow" "subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2" "Flutter action SHA pinned"
check contains "$workflow" "persist-credentials: false" "credentials are not persisted"
check contains "$workflow" "flutter-version: 3.47.2" "Flutter is fixed"
check contains "$workflow" "cache: false" "Flutter cache is disabled"
check contains "$workflow" "runs-on: macos-latest" "historical release runner label is reused"
check contains "$workflow" 'ref: ${{ github.sha }}' "tooling checkout is fixed to dispatch SHA"
check contains "$workflow" 'test "${GITHUB_REF}" = refs/heads/main' "dispatch is restricted to main"
check not_contains "$workflow" '^[[:space:]]*(push|pull_request):' "no push or pull triggers"
check not_contains "$workflow" 'xcodebuild[[:space:]]+-exportArchive|altool|Transporter|\.ipa|Build18|BUILD18|signing|provision' "no production signing/export/upload path"
check contains "$workflow" 'FIREBASE_PLIST_BASE64: ${{ secrets.PLANFLOW_IOS_GOOGLE_SERVICE_INFO_PLIST_BASE64 }}' "canonical Firebase secret is scoped"
check contains "$workflow" "Prepare canonical protected Firebase input" "Firebase secret has a dedicated preparation step"
check contains "$workflow" '"$HISTORICAL_FIREBASE_PLIST"' "reconstruction receives only a protected file path"
check contains "$workflow" "Delete protected reconstruction input" "protected Firebase input has an always cleanup step"
check contains "$workflow" 'rm -f -- "${HISTORICAL_FIREBASE_PLIST:-$RUNNER_TEMP/planflow-historical-firebase.plist}"' "protected Firebase input cleanup is explicit"
firebase_secret_count="$(grep -cF 'secrets.PLANFLOW_IOS_GOOGLE_SERVICE_INFO_PLIST_BASE64' "$workflow")"
if [ "$firebase_secret_count" = 1 ]; then
  echo "PASS: canonical Firebase secret is referenced exactly once"
else
  echo "FAIL: canonical Firebase secret must be referenced exactly once"
  failures=$((failures + 1))
fi
delete_input_line="$(grep -nF -- '- name: Delete protected reconstruction input' "$workflow" | cut -d: -f1)"
annotation_line="$(grep -nF -- '- name: Emit one bounded public annotation' "$workflow" | cut -d: -f1)"
if [ -n "$delete_input_line" ] && [ -n "$annotation_line" ] && [ "$delete_input_line" -lt "$annotation_line" ]; then
  echo "PASS: protected Firebase input is deleted before public output steps"
else
  echo "FAIL: protected Firebase input must be deleted before public output steps"
  failures=$((failures + 1))
fi
check contains "$workflow" "HISTORICAL_SYMBOLICATION_PASS_BUILD_" "success annotation"
check contains "$workflow" "HISTORICAL_SYMBOLICATION_NO_RESULT_BUILD_" "no-result annotation"
check contains "$workflow" "Fail matrix result on no-result" "no-result fails the matrix job"

check contains "$script" "dwarfdump --verify" "dSYM verification"
check contains "$script" "xcodebuild archive" "final release archive action is reconstructed"
check contains "$script" 'CODE_SIGNING_ALLOWED=NO' "reconstruction archive cannot be signed"
check contains "$script" 'CODE_SIGNING_REQUIRED=NO' "reconstruction archive requires no signing material"
check contains "$script" 'archive_runner="$archive_path/Products/Applications/Runner.app/Runner"' "archive Runner path is explicit"
check contains "$script" 'archive_dwarf="$archive_path/dSYMs/Runner.app.dSYM/Contents/Resources/DWARF/Runner"' "archive dSYM path is explicit"
check contains "$script" 'build_runner="$build_source/build/ios/iphoneos/Runner.app/Runner"' "Flutter-build Runner path is explicit"
check contains "$script" 'build_dwarf="$build_source/build/ios/iphoneos/Runner.app.dSYM/Contents/Resources/DWARF/Runner"' "Flutter-build dSYM path is explicit"
check contains "$script" "actual_executable_uuid" "executable UUID capture"
check contains "$script" "actual_dsym_uuid" "dSYM UUID capture"
check contains "$script" '"$exe_uuid" != "$expected_uuid"' "each executable UUID is gated against crash UUID"
check contains "$script" '"$dsym_uuid" != "$expected_uuid"' "each dSYM UUID is gated against crash UUID"
check contains "$script" '"$archive_state" = MATCH' "archive variant requires exact UUID match"
check contains "$script" '"$build_state" = MATCH' "Flutter-build fallback requires exact UUID match"
check contains "$script" "AMBIGUOUS_VARIANTS_NO_RESULT" "conflicting matched variants fail closed"
check contains "$script" "classify_no_match_reason" "no-match classification is centralized"
check contains "$script" "UUID_MISMATCH_NO_SYMBOLICATION" "UUID mismatch remains a distinct no-match reason"
check contains "$script" "RECONSTRUCTION_OR_VERIFICATION_FAILED_NO_SYMBOLICATION" "non-UUID reconstruction failures are distinguished"
check contains "$script" "CREATION_FAILED" "archive creation failure is classified separately from UUID mismatch"
check contains "$script" "MISSING_OUTPUT" "missing output is classified separately from UUID mismatch"
check contains "$script" "EXECUTABLE_ARM64_UUID_INVALID" "invalid executable UUID is classified separately from UUID mismatch"
check contains "$script" "DSYM_ARM64_UUID_INVALID" "invalid dSYM UUID is classified separately from UUID mismatch"
check contains "$script" "DSYM_VERIFY_FAILED" "dSYM verification failure is classified separately from UUID mismatch"
check contains "$script" "otool" "actual Mach-O load information"
check contains "$script" 'any(x < 0 or x >= size for x in offsets)' "__TEXT range gate"
check contains "$script" "vm+offsets[0]" "synthetic address calculation"
check contains "$script" 'atos -o "$dwarf_path" -arch arm64 -l' "atos uses the selected dSYM DWARF, exact arch, and load address"
check not_contains "$script" 'atos -o "\$runner_path"' "atos never uses a stripped Runner executable as symbol source"
check contains "$script" "ARCHIVE_SYMBOLICATION_FAILED" "archive-frame failure is fail-closed"
check contains "$script" "FLUTTER_BUILD_SYMBOLICATION_FAILED" "fallback-frame failure is fail-closed"
check contains "$script" "unnamed_symbol" "unnamed atos output is rejected"
check contains "$script" 'Runner\s*\+\s*' "raw Runner-plus-offset output is rejected"
check contains "$script" "RUNNER_FRAMES_SYMBOLICATED_FROM_UUID_MATCHED_RECONSTRUCTION" "bounded success status"
check contains "$script" 'rm -f -- "$plist_path"' "plist cleanup trap"
check contains "$script" 'rm -rf -- "$tmp_root"' "binary and build cleanup trap"
check not_contains "$script" 'xcodebuild[[:space:]]+-exportArchive|altool|Transporter|\.ipa|Build18|BUILD18|security[[:space:]]|(^|[^-])codesign([[:space:]]|$)' "no signing/export/upload path"
check contains "$script" 'CODE_SIGN_IDENTITY=""' "archive identity is explicitly empty"
check not_contains "$script" 'CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PROVISIONING_PROFILE|DISTRIBUTION_CERTIFICATE|ASC_' "no signing style, team, profile, certificate, or ASC input"
check not_contains "$script" 'FIREBASE_PLIST_BASE64' "protected Firebase value is not inherited by build subprocesses"
check not_contains "$script" 'GADApplicationIdentifier|ca-app-pub-[0-9]+~[0-9]+' "no placeholder AdMob ID"
check not_contains "$workflow" '\.(ips|dSYM|app|ipa|xcarchive)([^[:alnum:]_]|$)' "workflow never names a raw crash or binary artifact"
check not_contains "$workflow" 'android/|Android|adb|gradle' "workflow does not mutate Android/native targets"
check not_contains "$script" 'android/|Android|adb|gradle' "script does not mutate Android/native targets"

cleanup_line="$(grep -nF 'rm -f -- "$plist_path" || fail FIREBASE_CONFIG_CLEANUP_FAILED' "$script" | cut -d: -f1)"
archive_line="$(grep -nF 'if (cd "$build_source" && xcodebuild archive' "$script" | cut -d: -f1)"
if [ -n "$cleanup_line" ] && [ -n "$archive_line" ] && [ "$cleanup_line" -lt "$archive_line" ]; then
  echo "PASS: protected Firebase source is removed before archive like production"
else
  echo "FAIL: protected Firebase source must be removed before archive"
  failures=$((failures + 1))
fi

if bash -n "$script"; then echo "PASS: reconstruction syntax"; else echo "FAIL: reconstruction syntax"; failures=$((failures + 1)); fi
echo "Results: $failures failure(s)"
[ "$failures" -eq 0 ]
