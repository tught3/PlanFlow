#!/usr/bin/env bash
set -euo pipefail

# Validate the Firebase iOS artifact without echoing API keys or other config.
# Exit 12 is reserved for the actionable account/configuration blocker.
plist_path="${FIREBASE_PLIST_PATH:-ios/Runner/GoogleService-Info.plist}"
expected_project="planflow-27fd8"
expected_bundle="com.fluxstudio.planflow"

blocked() {
  echo "::error::BLOCKED_FIREBASE_CONFIG: $1" >&2
  exit 12
}

[[ -f "$plist_path" ]] || blocked "missing $plist_path"
command -v plutil >/dev/null 2>&1 || blocked "plutil is required on macOS"

if ! plutil -lint "$plist_path" >/dev/null 2>&1; then
  blocked "invalid plist format"
fi

read_plist() {
  local key="$1"
  plutil -extract "$key" raw -o - "$plist_path" 2>/dev/null || true
}

project_id="$(read_plist PROJECT_ID)"
bundle_id="$(read_plist BUNDLE_ID)"
app_id="$(read_plist GOOGLE_APP_ID)"

[[ "$project_id" == "$expected_project" ]] || blocked "PROJECT_ID does not match PlanFlow Firebase project"
[[ "$bundle_id" == "$expected_bundle" ]] || blocked "BUNDLE_ID does not match canonical iOS bundle ID"
[[ "$app_id" =~ ^1:[0-9]+:ios:[A-Za-z0-9_-]+$ ]] || blocked "GOOGLE_APP_ID is not a valid iOS Firebase app ID"

echo "Firebase iOS config valid: project=$project_id bundle=$bundle_id"
