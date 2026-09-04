#!/usr/bin/env bash
# Shared secret-masking helper for iOS E2E diagnostic scripts.
#
# Extracted verbatim from scripts/ios/e2e_diagnose_hang.sh so it can be
# sourced by any script that needs to redact credential-shaped text before
# writing captured output to disk. Do not change the matching behavior here
# without re-verifying every caller.
#
# This file is meant to be `source`d, not executed directly.

# Redact credential-shaped text from stdin.
#
# Case variants are spelled out explicitly instead of using sed's `I` flag,
# which is not portable across the GNU/BSD sed split (this runs on macOS).
mask_secrets() {
  sed -E \
    -e 's/(--dart-define=)([A-Za-z0-9_.-]+)=[^[:space:]]*/\1\2=<MASKED>/g' \
    -e 's/(--dart-define[[:space:]]+)([A-Za-z0-9_.-]+)=[^[:space:]]*/\1\2=<MASKED>/g' \
    -e 's/eyJ[A-Za-z0-9._-]{10,}/<MASKED_JWT>/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._-]+/\1<MASKED>/g' \
    -e 's/([A-Za-z0-9_.-]*([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa][Nn][Oo][Nn]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll])[A-Za-z0-9_.-]*=)[^[:space:]]*/\1<MASKED>/g'
}
