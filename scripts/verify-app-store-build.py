#!/usr/bin/env python3
"""Fail-closed App Store Connect ingestion check for the signed iOS release.

Only non-secret build metadata is printed. The API key is read from a protected
file and is never included in logs or exception text.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


API_ROOT = "https://api.appstoreconnect.apple.com/v1"


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def der_to_raw_ecdsa(signature: bytes) -> bytes:
    """Convert OpenSSL's DER ECDSA signature to JWT's 64-byte format."""
    if len(signature) < 8 or signature[0] != 0x30:
        raise ValueError("unexpected ECDSA signature encoding")
    pos = 2
    if signature[1] & 0x80:
        length_bytes = signature[1] & 0x7F
        pos = 2 + length_bytes
    if signature[pos] != 0x02:
        raise ValueError("missing ECDSA r")
    r_len = signature[pos + 1]
    r = signature[pos + 2 : pos + 2 + r_len]
    pos += 2 + r_len
    if signature[pos] != 0x02:
        raise ValueError("missing ECDSA s")
    s_len = signature[pos + 1]
    s = signature[pos + 2 : pos + 2 + s_len]
    r = r.lstrip(b"\0").rjust(32, b"\0")
    s = s.lstrip(b"\0").rjust(32, b"\0")
    if len(r) != 32 or len(s) != 32:
        raise ValueError("invalid ECDSA component length")
    return r + s


def make_token(key_path: str, key_id: str, issuer_id: str) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode("ascii")
    with tempfile.NamedTemporaryFile(prefix="asc-jwt-", delete=False) as input_file:
        input_file.write(signing_input)
        input_path = input_file.name
    try:
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, "-binary", input_path],
            check=True,
            capture_output=True,
        )
    finally:
        try:
            os.unlink(input_path)
        except OSError:
            pass
    return f"{header}.{payload}.{b64url(der_to_raw_ecdsa(result.stdout))}"


def request_json(token: str, path: str) -> tuple[dict, str | None]:
    request = urllib.request.Request(
        API_ROOT + path,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
            request_id = response.headers.get("x-request-id") or response.headers.get("x-apple-request-uuid")
            return json.loads(body), request_id
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        try:
            decoded = json.loads(body)
        except json.JSONDecodeError:
            decoded = {"errors": [{"status": str(error.code), "detail": "non-json response"}]}
        request_id = error.headers.get("x-request-id") or error.headers.get("x-apple-request-uuid")
        return {"__http_status": error.code, **decoded}, request_id


def error_summary(document: dict) -> str:
    errors = document.get("errors") or []
    parts = []
    for error in errors[:3]:
        parts.append(f"domain={error.get('code', 'unknown')} status={error.get('status', 'unknown')} detail={error.get('title', 'request failed')}")
    return "; ".join(parts) or "unknown App Store Connect API error"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=300)
    parser.add_argument("--poll-interval-seconds", type=int, default=30)
    args = parser.parse_args()

    if not os.path.isfile(args.key_path):
        print("::error title=BLOCKED_ASC_API_KEY::App Store Connect API key file is missing.")
        return 1
    token = make_token(args.key_path, args.key_id, args.issuer_id)
    app_filter = urllib.parse.quote(args.bundle_id, safe="")
    apps_path = f"/apps?filter[bundleId]={app_filter}&fields[apps]=name,bundleId&limit=10"
    apps, request_id = request_json(token, apps_path)
    if request_id:
        print(f"App Store Connect app lookup request ID: {request_id}")
    if apps.get("__http_status") or apps.get("errors"):
        print(f"::error title=BLOCKED_ASC_APP_LOOKUP::{error_summary(apps)}")
        return 1
    matches = apps.get("data") or []
    if len(matches) != 1 or matches[0].get("attributes", {}).get("bundleId") != args.bundle_id:
        print(f"::error title=BLOCKED_ASC_APP_TARGET::Expected exactly one app with bundle ID {args.bundle_id}; found {len(matches)}.")
        return 1
    app_id = matches[0].get("id")
    app_name = matches[0].get("attributes", {}).get("name", "unknown")
    print(f"App Store Connect target verified: name={app_name} bundleId={args.bundle_id}")

    build_filter = urllib.parse.quote(args.build, safe="")
    builds_path = (
        f"/builds?filter[app]={urllib.parse.quote(app_id, safe='')}"
        f"&filter[version]={build_filter}"
        f"&include=preReleaseVersion,app&fields[builds]=version,processingState,uploadedDate,usesNonExemptEncryption"
        f"&fields[preReleaseVersions]=version,platform&fields[apps]=name,bundleId&sort=-uploadedDate&limit=10"
    )
    deadline = time.monotonic() + max(0, args.timeout_seconds)
    attempt = 0
    while True:
        attempt += 1
        builds, request_id = request_json(token, builds_path)
        if request_id:
            print(f"Build lookup request ID (attempt {attempt}): {request_id}")
        if builds.get("__http_status") or builds.get("errors"):
            print(f"::error title=BLOCKED_ASC_BUILD_LOOKUP::{error_summary(builds)}")
            return 1
        resources = builds.get("data") or []
        if resources:
            build = resources[0]
            attributes = build.get("attributes", {})
            state = attributes.get("processingState", "UNKNOWN")
            included = {item.get("id"): item for item in builds.get("included", [])}
            pre_release = included.get((build.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id"), {})
            pre_attributes = pre_release.get("attributes", {})
            app_resource = included.get((build.get("relationships", {}).get("app", {}).get("data") or {}).get("id"), {})
            app_attributes = app_resource.get("attributes", {})
            if pre_attributes.get("version") != args.version or pre_attributes.get("platform") != "IOS":
                print(
                    "::error title=BLOCKED_APP_STORE_VERSION::Pre-release version relationship does not match "
                    f"version={args.version} platform=IOS."
                )
                return 1
            if app_attributes.get("bundleId") not in (None, args.bundle_id):
                print("::error title=BLOCKED_ASC_APP_TARGET::Build relationship is not the canonical PlanFlow app.")
                return 1
            if str(attributes.get("version")) != str(args.build):
                print(
                    "::error title=BLOCKED_APP_STORE_BUILD_NUMBER::App Store build version does not match "
                    f"expected build number {args.build}."
                )
                return 1
            print(
                "App Store Connect build resource found: "
                f"app={app_name} bundleId={args.bundle_id} version={pre_attributes.get('version', args.version)} "
                f"build={attributes.get('version', args.build)} processingState={state}"
            )
            if state in {"FAILED", "INVALID", "REJECTED"}:
                print(f"::error title=BLOCKED_APP_STORE_PROCESSING::App Store build processingState={state}.")
                return 1
            if state not in {"PROCESSING", "VALID", "READY_FOR_BETA_TESTING"}:
                print(f"::error title=BLOCKED_APP_STORE_PROCESSING::Unexpected App Store build processingState={state}.")
                return 1
            print("APP_STORE_BUILD_INGESTED: PASS")
            print("TESTFLIGHT_BUILD_VISIBLE_OR_PROCESSING: PASS")
            if state == "VALID" or state == "READY_FOR_BETA_TESTING":
                print("TESTFLIGHT_BUILD_AVAILABLE: PASS")
            else:
                print("TESTFLIGHT_BUILD_AVAILABLE: NOT_YET_AVAILABLE")
            return 0
        if time.monotonic() >= deadline:
            print(
                "::error title=BLOCKED_ASC_INGESTION::No matching App Store Connect build resource "
                f"after {args.timeout_seconds}s for bundleId={args.bundle_id} version={args.version} build={args.build}."
            )
            print("APP_STORE_BUILD_INGESTED: NOT_VERIFIED")
            print("TESTFLIGHT_BUILD_VISIBLE_OR_PROCESSING: NOT_VERIFIED")
            return 1
        print(f"App Store Connect build not visible yet; retrying in {args.poll_interval_seconds}s (attempt {attempt}).")
        time.sleep(max(1, args.poll_interval_seconds))


if __name__ == "__main__":
    sys.exit(main())
