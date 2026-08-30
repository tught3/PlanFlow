#!/usr/bin/env bash
set -euo pipefail

# The production validator depends on Apple's plutil. Keep executable fixture
# coverage on macOS, and skip clearly on Windows/Linux where that tool is absent.
if [[ "$(uname -s)" != "Darwin" ]] || ! command -v plutil >/dev/null 2>&1; then
  echo "SKIP: Firebase plist fixture tests require macOS plutil"
  exit 0
fi

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

write_plist() {
  local path="$1" project="$2" bundle="$3" app_id="$4"
  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PROJECT_ID</key><string>$project</string>
<key>BUNDLE_ID</key><string>$bundle</string>
<key>GOOGLE_APP_ID</key><string>$app_id</string>
</dict></plist>
EOF
}

expect_exit() {
  local expected="$1" path="$2"
  set +e
  FIREBASE_PLIST_PATH="$path" bash "$root_dir/scripts/verify-ios-firebase-config.sh" >/dev/null 2>&1
  local actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || {
    echo "fixture failed: path=$path expected=$expected actual=$actual" >&2
    exit 1
  }
}

expect_exit 12 "$tmp_dir/missing.plist"
printf '%s\n' 'not a plist' > "$tmp_dir/malformed.plist"
expect_exit 12 "$tmp_dir/malformed.plist"
write_plist "$tmp_dir/project.plist" wrong-project com.planflow.app 1:375219078541:ios:abc123
expect_exit 12 "$tmp_dir/project.plist"
write_plist "$tmp_dir/bundle.plist" planflow-27fd8 com.other.app 1:375219078541:ios:abc123
expect_exit 12 "$tmp_dir/bundle.plist"
write_plist "$tmp_dir/app-id.plist" planflow-27fd8 com.planflow.app 1:375219078541:android:abc123
expect_exit 12 "$tmp_dir/app-id.plist"
write_plist "$tmp_dir/valid.plist" planflow-27fd8 com.planflow.app 1:375219078541:ios:abc123
expect_exit 0 "$tmp_dir/valid.plist"

echo "Firebase plist fixture tests passed"
