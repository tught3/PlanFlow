#!/usr/bin/env python3
"""Fail-closed App Store Connect upload and build ingestion check.

The buildUploads resource is the authoritative post-transport signal. A
transport receipt alone is never promoted to a TestFlight build gate. Only
non-secret metadata and provider request IDs are printed.
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
UPLOAD_STATES = {"AWAITING_UPLOAD", "PROCESSING", "FAILED", "COMPLETE"}
BUILD_STATES = {"PROCESSING", "VALID"}


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def der_to_raw_ecdsa(signature: bytes) -> bytes:
    if len(signature) < 8 or signature[0] != 0x30:
        raise ValueError("unexpected ECDSA signature encoding")
    pos = 2
    if signature[1] & 0x80:
        pos = 2 + (signature[1] & 0x7F)
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
        detail = error.get("detail") or error.get("title") or "request failed"
        detail = " ".join(str(detail).split())[:240]
        parts.append(f"code={error.get('code', 'unknown')} status={error.get('status', 'unknown')} detail={detail}")
    return "; ".join(parts) or "unknown App Store Connect API error"


def relationship_id(resource: dict, name: str) -> str | None:
    data = resource.get("relationships", {}).get(name, {}).get("data")
    return data.get("id") if isinstance(data, dict) else None


def print_state_details(attributes: dict) -> None:
    """Print bounded provider diagnostics without dumping response JSON."""
    for key in ("stateDetails", "stateDetail", "errors", "warnings", "info"):
        value = attributes.get(key)
        if not value:
            continue
        values = value if isinstance(value, list) else [value]
        for item in values[:5]:
            if isinstance(item, dict):
                code = item.get("code", "unknown")
                description = item.get("description") or item.get("detail") or item.get("title") or ""
            else:
                code = "unknown"
                description = str(item)
            description = " ".join(str(description).split())[:240]
            print(f"Build upload {key}: code={code} description={description}")


def pending_result(args: argparse.Namespace, marker: str, message: str) -> int:
    print(f"::warning title={marker}::{message}")
    print(marker + ": PENDING")
    return 0 if args.pending_exit_zero else 2


def build_from_upload(upload: dict, document: dict) -> dict | None:
    """Return an included build only when the upload explicitly relates to it."""
    linked_id = relationship_id(upload, "build")
    if not linked_id:
        return None
    for resource in document.get("included", []):
        if resource.get("type") == "builds" and resource.get("id") == linked_id:
            return resource
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--poll-interval-seconds", type=int, default=30)
    parser.add_argument("--pending-exit-zero", action="store_true")
    parser.add_argument("--delivery-uuid")
    args = parser.parse_args()

    if not os.path.isfile(args.key_path):
        print("::error title=BLOCKED_ASC_API_KEY::App Store Connect API key file is missing.")
        return 1
    token = make_token(args.key_path, args.key_id, args.issuer_id)
    bundle_filter = urllib.parse.quote(args.bundle_id, safe="")
    apps_path = f"/apps?filter[bundleId]={bundle_filter}&fields[apps]=name,bundleId&limit=10"
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
    if args.delivery_uuid:
        print(f"Transport delivery UUID correlation hint: {args.delivery_uuid}")

    version_filter = urllib.parse.quote(args.version, safe="")
    build_filter = urllib.parse.quote(str(args.build), safe="")
    upload_path = (
        f"/apps/{urllib.parse.quote(app_id, safe='')}/buildUploads"
        f"?filter[cfBundleShortVersionString]={version_filter}"
        f"&filter[cfBundleVersion]={build_filter}&filter[platform]=IOS"
        f"&include=build&fields[buildUploads]=cfBundleShortVersionString,cfBundleVersion,createdDate,state,platform,uploadedDate,build"
        f"&fields[builds]=version,uploadedDate,expirationDate,expired,processingState,usesNonExemptEncryption,preReleaseVersion,app,buildUpload,buildBetaDetail,appStoreVersion"
        f"&limit=20&sort=-uploadedDate"
    )
    builds_path = (
        f"/builds?filter[app]={urllib.parse.quote(app_id, safe='')}"
        f"&filter[version]={build_filter}&include=preReleaseVersion,app,buildUpload"
        f"&fields[builds]=version,processingState,uploadedDate,usesNonExemptEncryption,preReleaseVersion,app,buildUpload,buildBetaDetail,appStoreVersion"
        f"&fields[preReleaseVersions]=version,platform&fields[apps]=name,bundleId&sort=-uploadedDate&limit=10"
    )
    deadline = time.monotonic() + max(0, args.timeout_seconds)
    attempt = 0
    upload_state = "NOT_FOUND"
    upload_included_build = None
    while True:
        attempt += 1
        uploads, request_id = request_json(token, upload_path)
        if request_id:
            print(f"Build upload lookup request ID (attempt {attempt}): {request_id}")
        if uploads.get("__http_status") or uploads.get("errors"):
            print(f"::error title=BLOCKED_ASC_BUILD_UPLOAD_LOOKUP::{error_summary(uploads)}")
            return 1
        upload_resources = uploads.get("data") or []
        if upload_resources:
            upload = upload_resources[0]
            upload_id = upload.get("id", "unknown")
            upload_attributes = upload.get("attributes", {})
            upload_included_build = build_from_upload(upload, uploads)
            raw_upload_state = upload_attributes.get("state", "UNKNOWN")
            if isinstance(raw_upload_state, dict):
                print_state_details(raw_upload_state)
                upload_state = raw_upload_state.get("state") or raw_upload_state.get("value") or "UNKNOWN"
            else:
                upload_state = raw_upload_state
            print(
                "App Store Connect build upload observed: "
                f"id={upload_id} version={upload_attributes.get('cfBundleShortVersionString', args.version)} "
                f"build={upload_attributes.get('cfBundleVersion', args.build)} platform={upload_attributes.get('platform', 'IOS')} state={upload_state}"
            )
            if upload_state not in UPLOAD_STATES:
                print(f"::error title=BLOCKED_ASC_BUILD_UPLOAD_STATE::Unexpected build upload state={upload_state}.")
                return 1
            if str(upload_attributes.get("cfBundleVersion")) != str(args.build) or upload_attributes.get("cfBundleShortVersionString") != args.version or upload_attributes.get("platform") != "IOS":
                print("::error title=BLOCKED_ASC_BUILD_UPLOAD_METADATA::Build upload metadata does not match requested PlanFlow build.")
                return 1
            if upload_state in {"PROCESSING", "COMPLETE"}:
                print("BUILD_UPLOAD_ACCEPTED_OR_PROCESSING: PASS")
            if upload_state == "FAILED":
                print_state_details(upload_attributes)
                detail_path = (
                    f"/buildUploads/{urllib.parse.quote(upload_id, safe='')}"
                    "?include=build&fields[buildUploads]=cfBundleShortVersionString,cfBundleVersion,createdDate,state,platform,uploadedDate,build"
                )
                detail_document, detail_request_id = request_json(token, detail_path)
                if detail_request_id:
                    print(f"Build upload detail request ID: {detail_request_id}")
                if not detail_document.get("__http_status") and not detail_document.get("errors"):
                    detail_resource = (detail_document.get("data") or {})
                    print_state_details(detail_resource.get("attributes", {}))
                print("::error title=BLOCKED_APP_STORE_UPLOAD_FAILED::App Store Connect build upload state=FAILED.")
                return 1
            if upload_state == "AWAITING_UPLOAD":
                if time.monotonic() >= deadline:
                    return pending_result(args, "BLOCKED_APP_STORE_INGESTION_TIMEOUT", "Build upload remains AWAITING_UPLOAD after the inspection window.")
                print(f"Build upload remains AWAITING_UPLOAD; retrying in {args.poll_interval_seconds}s (attempt {attempt}).")
                time.sleep(max(1, args.poll_interval_seconds))
                continue

        builds, request_id = request_json(token, builds_path)
        if request_id:
            print(f"Build lookup request ID (attempt {attempt}): {request_id}")
        if builds.get("__http_status") or builds.get("errors"):
            print(f"::error title=BLOCKED_ASC_BUILD_LOOKUP::{error_summary(builds)}")
            return 1
        resources = builds.get("data") or []
        if not resources and upload_included_build is not None:
            resources = [upload_included_build]
        if resources:
            build = resources[0]
            attributes = build.get("attributes", {})
            state = attributes.get("processingState", "UNKNOWN")
            included = {item.get("id"): item for item in builds.get("included", [])}
            pre_release = included.get(relationship_id(build, "preReleaseVersion"), {})
            pre_attributes = pre_release.get("attributes", {})
            app_resource = included.get(relationship_id(build, "app"), {})
            app_attributes = app_resource.get("attributes", {})
            if pre_attributes.get("version") != args.version or pre_attributes.get("platform") != "IOS":
                print(f"::error title=BLOCKED_APP_STORE_VERSION::Pre-release version relationship does not match version={args.version} platform=IOS.")
                return 1
            if app_attributes.get("bundleId") not in (None, args.bundle_id):
                print("::error title=BLOCKED_ASC_APP_TARGET::Build relationship is not the canonical PlanFlow app.")
                return 1
            if str(attributes.get("version")) != str(args.build):
                print(f"::error title=BLOCKED_APP_STORE_BUILD_NUMBER::App Store build version does not match expected build number {args.build}.")
                return 1
            print(
                "App Store Connect build resource found: "
                f"app={app_name} bundleId={args.bundle_id} version={pre_attributes.get('version', args.version)} "
                f"build={attributes.get('version', args.build)} processingState={state}"
            )
            if state in {"FAILED", "INVALID", "REJECTED"}:
                print_state_details(attributes)
                print(f"::error title=BLOCKED_APP_STORE_PROCESSING::App Store build processingState={state}.")
                return 1
            if state not in BUILD_STATES:
                print(f"::error title=BLOCKED_APP_STORE_PROCESSING::Unexpected App Store build processingState={state}.")
                return 1
            print("APP_STORE_BUILD_INGESTED: PASS")
            print("TESTFLIGHT_BUILD_VISIBLE_OR_PROCESSING: PASS")
            if state == "VALID":
                print("TESTFLIGHT_BUILD_AVAILABLE: PASS")
            else:
                print("TESTFLIGHT_BUILD_AVAILABLE: NOT_YET_AVAILABLE")
            return 0

        if time.monotonic() >= deadline:
            if upload_state == "PROCESSING":
                return pending_result(args, "PENDING_APPLE_PROCESSING", "Build upload remains PROCESSING; build resource is not authoritative yet.")
            if upload_state == "COMPLETE":
                return pending_result(args, "BLOCKED_BUILD_ASSOCIATION_PENDING", "Build upload is COMPLETE but no associated builds resource is visible yet.")
            return pending_result(args, "BLOCKED_APP_STORE_INGESTION_TIMEOUT", f"No matching build resource after {args.timeout_seconds}s.")
        print(f"App Store Connect build not visible yet; uploadState={upload_state}; retrying in {args.poll_interval_seconds}s (attempt {attempt}).")
        time.sleep(max(1, args.poll_interval_seconds))


if __name__ == "__main__":
    sys.exit(main())
