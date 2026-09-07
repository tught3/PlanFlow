#!/usr/bin/env bash
# Audit-only reconstruction of exactly two historical Runner frames.
set -uo pipefail
[ "$#" -eq 8 ] || { echo "usage: $0 SOURCE REPORT BUILD VERSION UUID OFFSET_A OFFSET_B FIREBASE_PLIST_SOURCE" >&2; exit 64; }
source_dir="$1"; report_path="$2"; build_number="$3"; build_name="$4"
expected_uuid="$(printf '%s' "$5" | tr '[:lower:]' '[:upper:]')"; offset_a="$6"; offset_b="$7"
firebase_plist_source="$8"
case "$build_number:$build_name:$expected_uuid:$offset_a:$offset_b" in
  16:1.0.0:96EB03A3-C4E7-3C3E-9C58-9E3F6DE896BC:7717012:7717392|17:1.0.0:D9B552C8-3F13-3217-B8B9-6886EE0926D0:7717068:7717448) ;;
  *) echo "NO_RESULT: fixed historical mapping rejected" >&2; exit 2;;
esac
mkdir -p "$(dirname "$report_path")"
tmp_root=""; plist_path=""; selected_variant=""
actual_executable_uuid=""; actual_dsym_uuid=""; status="NO_RESULT"; reason="NOT_STARTED"
TOOLCHAIN_JSON='{}'; VARIANTS_JSON='{}'; FRAMES_JSON='[]'

cleanup() {
  [ -z "$plist_path" ] || rm -f -- "$plist_path"
  [ -z "$tmp_root" ] || rm -rf -- "$tmp_root"
}
trap cleanup EXIT HUP INT TERM

write_report() {
  python3 - "$report_path" "$build_number" "$build_name" "$expected_uuid" \
    "$actual_executable_uuid" "$actual_dsym_uuid" "$selected_variant" \
    "$status" "$reason" "$TOOLCHAIN_JSON" "$VARIANTS_JSON" "$FRAMES_JSON" <<'PY'
import json, sys
p, build, version, expected, exe, dsym, selected, status, reason, tools, variants, frames = sys.argv[1:]
try: tools = json.loads(tools)
except Exception: tools = {}
try: variants = json.loads(variants)
except Exception: variants = {}
try: frames = json.loads(frames)
except Exception: frames = []
data = {"schema":"planflow.historical-symbol-reconstruction.v1", "build":int(build),
        "version":version, "expected_runner_uuid":expected,
        "actual_executable_uuid":exe, "actual_dsym_uuid":dsym,
        "selected_variant":selected or None,
        "uuid_verdict":"MATCH" if exe and exe == expected and dsym == expected else "NO_MATCH",
        "variants":variants, "toolchain":tools, "frames":frames,
        "status":status, "reason":reason}
with open(p, "w", encoding="utf-8") as f:
  json.dump(data, f, sort_keys=True, separators=(",", ":")); f.write("\n")
PY
}

TOOLCHAIN_JSON="$(python3 - <<'PY'
import json, subprocess
def first(c):
  try:
    x=subprocess.run(c, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.splitlines()
    return x[0].strip() if x else "unavailable"
  except Exception: return "unavailable"
print(json.dumps({"xcode":first(["xcodebuild","-version"]),"swift":first(["swift","--version"]),"flutter":first(["flutter","--version"]),"cocoapods":first(["pod","--version"])}, separators=(",", ":")))
PY
)"
fail() {
  reason="$1"
  write_report
  echo "NO_RESULT build=$build_number reason=$reason executable_uuid=$actual_executable_uuid dsym_uuid=$actual_dsym_uuid" >&2
  exit 2
}

[ -d "$source_dir" ] || fail SOURCE_CHECKOUT_MISSING
[ -f "$firebase_plist_source" ] || fail FIREBASE_CONFIG_MISSING
for tool in flutter xcodebuild dwarfdump atos otool pod python3 ditto; do
  command -v "$tool" >/dev/null 2>&1 || {
    tool_label="$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')"
    fail "${tool_label}_UNAVAILABLE"
  }
done

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/planflow-historical.XXXXXX")" || fail TEMP_DIRECTORY_FAILED
build_source="$tmp_root/source"; mkdir -p "$build_source"
ditto "$source_dir" "$build_source" >/dev/null 2>&1 || fail SOURCE_COPY_FAILED
[ -f "$build_source/ios/Podfile.lock" ] && historical_lock=present || historical_lock=absent
(cd "$build_source" && flutter pub get >"$tmp_root/pub-get.log" 2>&1) || fail FLUTTER_PUB_GET_FAILED
(cd "$build_source" && pod install --project-directory=ios >"$tmp_root/pod-install.log" 2>&1) || fail POD_INSTALL_FAILED
[ -f "$build_source/ios/Podfile.lock" ] && selected_lock=generated-by-pod-install || selected_lock=not-generated
TOOLCHAIN_JSON="$(python3 - "$TOOLCHAIN_JSON" "$historical_lock" "$selected_lock" <<'PY'
import json, sys
x=json.loads(sys.argv[1]); x["historical_podfile_lock"]=sys.argv[2]; x["selected_pod_lock_state"]=sys.argv[3]
print(json.dumps(x, separators=(",", ":")))
PY
)"

plist_path="$build_source/ios/Runner/GoogleService-Info.plist"
umask 077
cp "$firebase_plist_source" "$plist_path" || fail FIREBASE_CONFIG_COPY_FAILED
(cd "$build_source" && FIREBASE_PLIST_PATH="ios/Runner/GoogleService-Info.plist" bash scripts/verify-ios-firebase-config.sh >"$tmp_root/firebase-verify.log" 2>&1) || fail FIREBASE_CONFIG_INVALID
(cd "$build_source" && flutter build ios --release --no-codesign --build-name "$build_name" --build-number "$build_number" >"$tmp_root/flutter-build.log" 2>&1) || fail RELEASE_BUILD_FAILED

build_runner="$build_source/build/ios/iphoneos/Runner.app/Runner"
build_dwarf="$build_source/build/ios/iphoneos/Runner.app.dSYM/Contents/Resources/DWARF/Runner"

# The production workflow removes the protected source plist after the Flutter
# preparation build and before xcodebuild archive. Reproduce that exact order.
rm -f -- "$plist_path" || fail FIREBASE_CONFIG_CLEANUP_FAILED
plist_path=""

archive_path="$tmp_root/PlanFlow.xcarchive"
archive_state=CREATION_FAILED
if (cd "$build_source" && xcodebuild archive \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath "$archive_path" \
  -destination 'generic/platform=iOS' \
  FLUTTER_BUILD_NAME="$build_name" \
  FLUTTER_BUILD_NUMBER="$build_number" \
  MARKETING_VERSION="$build_name" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  >"$tmp_root/xcodebuild-archive.log" 2>&1); then
  archive_state=CREATED
fi
archive_runner="$archive_path/Products/Applications/Runner.app/Runner"
archive_dwarf="$archive_path/dSYMs/Runner.app.dSYM/Contents/Resources/DWARF/Runner"

arm64_uuid() {
  local value count
  value="$(dwarfdump --uuid "$1" 2>/dev/null | awk '/\(arm64\)/ {print toupper($2)}')"
  count="$(printf '%s\n' "$value" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" = 1 ] || return 1
  printf '%s' "$value"
}

evaluate_variant() {
  local runner_path="$1" dwarf_path="$2" verify_log="$3" variant_state exe_uuid dsym_uuid
  variant_state=MISSING_OUTPUT; exe_uuid=""; dsym_uuid=""
  if [ -f "$runner_path" ] && [ -f "$dwarf_path" ]; then
    if ! exe_uuid="$(arm64_uuid "$runner_path")"; then
      variant_state=EXECUTABLE_ARM64_UUID_INVALID
    elif ! dsym_uuid="$(arm64_uuid "$dwarf_path")"; then
      variant_state=DSYM_ARM64_UUID_INVALID
    elif [ "$exe_uuid" != "$expected_uuid" ]; then
      variant_state=EXECUTABLE_UUID_MISMATCH
    elif [ "$dsym_uuid" != "$expected_uuid" ]; then
      variant_state=DSYM_UUID_MISMATCH
    elif ! dwarfdump --verify "$dwarf_path" >"$verify_log" 2>&1; then
      variant_state=DSYM_VERIFY_FAILED
    else
      variant_state=MATCH
    fi
  fi
  printf '%s|%s|%s' "$variant_state" "$exe_uuid" "$dsym_uuid"
}

classify_no_match_reason() {
  case "$archive_state:$build_state" in
    *CREATION_FAILED*|*MISSING_OUTPUT*|*EXECUTABLE_ARM64_UUID_INVALID*|*DSYM_ARM64_UUID_INVALID*|*DSYM_VERIFY_FAILED*)
      printf '%s' RECONSTRUCTION_OR_VERIFICATION_FAILED_NO_SYMBOLICATION
      ;;
    *EXECUTABLE_UUID_MISMATCH*|*DSYM_UUID_MISMATCH*)
      printf '%s' UUID_MISMATCH_NO_SYMBOLICATION
      ;;
    *)
      printf '%s' RECONSTRUCTION_OR_VERIFICATION_FAILED_NO_SYMBOLICATION
      ;;
  esac
}

IFS='|' read -r build_state build_executable_uuid build_dsym_uuid <<EOF
$(evaluate_variant "$build_runner" "$build_dwarf" "$tmp_root/dwarfdump-build-verify.log")
EOF
if [ "$archive_state" = CREATED ]; then
  IFS='|' read -r archive_state archive_executable_uuid archive_dsym_uuid <<EOF
$(evaluate_variant "$archive_runner" "$archive_dwarf" "$tmp_root/dwarfdump-archive-verify.log")
EOF
else
  archive_executable_uuid=""; archive_dsym_uuid=""
fi

VARIANTS_JSON="$(python3 - "$build_state" "$build_executable_uuid" "$build_dsym_uuid" \
  "$archive_state" "$archive_executable_uuid" "$archive_dsym_uuid" <<'PY'
import json, sys
a_state, a_exe, a_dsym, b_state, b_exe, b_dsym = sys.argv[1:]
print(json.dumps({
  "flutter_build":{"status":a_state,"executable_uuid":a_exe,"dsym_uuid":a_dsym},
  "unsigned_archive":{"status":b_state,"executable_uuid":b_exe,"dsym_uuid":b_dsym},
}, separators=(",", ":")))
PY
)"

frames_for_variant() {
  local runner_path="$1" dwarf_path="$2" text_info text_vmaddr text_vmsize address_a address_b
  local raw_a raw_b count_a count_b
  text_info="$(python3 - "$runner_path" "$offset_a" "$offset_b" <<'PY'
import subprocess, sys
out=subprocess.run(["otool","-l",sys.argv[1]], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
text=False; vm=None; size=None
for line in out.splitlines():
  f=line.split()
  if f[:1] == ["segname"]: text=len(f)>1 and f[1] == "__TEXT"
  elif text and f[:1] == ["vmaddr"]: vm=int(f[1],16)
  elif text and f[:1] == ["vmsize"]: size=int(f[1],16); break
if vm is None or size is None: raise SystemExit(1)
offsets=[int(sys.argv[2]),int(sys.argv[3])]
if any(x < 0 or x >= size for x in offsets): raise SystemExit(2)
print("%x|%x|%x|%x" % (vm,size,vm+offsets[0],vm+offsets[1]))
PY
)" || return 10
  IFS='|' read -r text_vmaddr text_vmsize address_a address_b <<EOF
$text_info
EOF
  raw_a="$(atos -o "$dwarf_path" -arch arm64 -l "0x$text_vmaddr" "0x$address_a" 2>/dev/null)" || return 11
  raw_b="$(atos -o "$dwarf_path" -arch arm64 -l "0x$text_vmaddr" "0x$address_b" 2>/dev/null)" || return 12
  count_a="$(printf '%s\n' "$raw_a" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  count_b="$(printf '%s\n' "$raw_b" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  [ "$count_a" = 1 ] && [ "$count_b" = 1 ] || return 13
  printf '%s\n%s\n' "$raw_a" "$raw_b" | grep -Eiq '(\?\?\?|unknown|ambiguous|atos cannot)' && return 14
  python3 - "$raw_a" "$raw_b" "$offset_a" "$offset_b" <<'PY'
import json, os, re, sys
def one(raw, off):
  raw=re.sub(r'\x1b\[[0-9;]*m','',raw).strip()
  m=re.search(r'([^()\s]+\.(?:swift|m|mm|c|cc|cpp|h)):(\d+)',raw)
  module_match=re.search(r'\(in ([^)]+)\)',raw)
  module=module_match.group(1) if module_match else "Runner"
  fn=raw.split(" (in ",1)[0].strip(); fn=re.sub(r'/(?:[^ )]+/)+','',fn)
  unresolved=(
    not fn or "???" in fn or
    re.fullmatch(r'(?:Runner\s*\+\s*)?(?:0x)?[0-9a-fA-F]+', fn) or
    re.search(r'(?:lldb_)?unnamed_symbol', fn, re.IGNORECASE)
  )
  if unresolved: raise SystemExit(1)
  return {"offset":int(off),"function":fn[:240],"module":module[:120],
          "file":os.path.basename(m.group(1)) if m else None,
          "line":int(m.group(2)) if m else None}
print(json.dumps([one(sys.argv[1],sys.argv[3]),one(sys.argv[2],sys.argv[4])],separators=(",", ":")))
PY
}

if [ "$archive_state" = MATCH ] && [ "$build_state" = MATCH ]; then
  selected_variant=unsigned_archive; actual_executable_uuid="$archive_executable_uuid"; actual_dsym_uuid="$archive_dsym_uuid"
  archive_frames="$(frames_for_variant "$archive_runner" "$archive_dwarf")" || fail ARCHIVE_SYMBOLICATION_FAILED
  build_frames="$(frames_for_variant "$build_runner" "$build_dwarf")" || fail FLUTTER_BUILD_SYMBOLICATION_FAILED
  [ "$archive_frames" = "$build_frames" ] || fail AMBIGUOUS_VARIANTS_NO_RESULT
  FRAMES_JSON="$archive_frames"
elif [ "$archive_state" = MATCH ]; then
  selected_variant=unsigned_archive; actual_executable_uuid="$archive_executable_uuid"; actual_dsym_uuid="$archive_dsym_uuid"
  FRAMES_JSON="$(frames_for_variant "$archive_runner" "$archive_dwarf")" || fail ARCHIVE_SYMBOLICATION_FAILED
elif [ "$build_state" = MATCH ]; then
  selected_variant=flutter_build; actual_executable_uuid="$build_executable_uuid"; actual_dsym_uuid="$build_dsym_uuid"
  FRAMES_JSON="$(frames_for_variant "$build_runner" "$build_dwarf")" || fail FLUTTER_BUILD_SYMBOLICATION_FAILED
else
  actual_executable_uuid="${archive_executable_uuid:-$build_executable_uuid}"
  actual_dsym_uuid="${archive_dsym_uuid:-$build_dsym_uuid}"
  fail "$(classify_no_match_reason)"
fi

status=PASS; reason=RUNNER_FRAMES_SYMBOLICATED_FROM_UUID_MATCHED_RECONSTRUCTION; write_report
echo "PASS build=$build_number uuid=$expected_uuid variant=$selected_variant frames=2"; exit 0
