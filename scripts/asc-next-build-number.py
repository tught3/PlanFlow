#!/usr/bin/env python3
"""Resolve the next iOS CFBundleVersion from App Store Connect's authoritative build history.

This mirrors the ES256 JWT signing and urllib HTTP helper pattern used by
scripts/verify-app-store-build.py in the same directory. It never trusts a
CI run number as the build number: it asks App Store Connect for the global
maximum CFBundleVersion across every build of the target app (not scoped to
a single version train, since Apple only requires uniqueness within a train
and a global max+1 is therefore unique across every train too) and returns
max+1.

Secrets (private key material, issuer id, key id, bearer tokens, JWTs) are
never printed to stdout/stderr, including inside error paths.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API_ROOT = "https://api.appstoreconnect.apple.com/v1"

EXIT_OK = 0
EXIT_CREDENTIALS = 2
EXIT_APP_NOT_FOUND = 3
EXIT_NO_BUILDS = 4
EXIT_API_ERROR = 5

MAX_BUILD_PAGES = 50

_JWT_PATTERN = re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")
_PEM_BLOCK_PATTERN = re.compile(r"-----BEGIN[^-]*-----.*?-----END[^-]*-----", re.DOTALL)
_AUTH_HEADER_PATTERN = re.compile(r"(Authorization\s*[:=]\s*Bearer\s+)\S+", re.IGNORECASE)


class BlockedError(Exception):
    """Carries an exit code and a stderr-safe, already-redacted message."""

    def __init__(self, exit_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.code = code
        self.message = message


def redact(text: str) -> str:
    """Strip anything that looks like a secret before it ever reaches output."""
    if not text:
        return text
    text = _PEM_BLOCK_PATTERN.sub("[REDACTED]", text)
    text = _JWT_PATTERN.sub("[REDACTED]", text)
    text = _AUTH_HEADER_PATTERN.sub(r"\1[REDACTED]", text)
    return text


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


def make_token(private_key_pem: bytes, key_id: str, issuer_id: str) -> str:
    """Sign an ES256 App Store Connect API JWT, mirroring verify-app-store-build.py."""
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode("ascii")
    key_path = None
    input_path = None
    try:
        with tempfile.NamedTemporaryFile(prefix="asc-key-", suffix=".p8", delete=False) as key_file:
            key_file.write(private_key_pem)
            key_path = key_file.name
        with tempfile.NamedTemporaryFile(prefix="asc-jwt-", delete=False) as input_file:
            input_file.write(signing_input)
            input_path = input_file.name
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, "-binary", input_path],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as error:
        # Never surface stderr from openssl verbatim: it can echo key material
        # (e.g. "unable to load key" dumps combined with -sign argv in some
        # OpenSSL builds' verbose modes) so keep this generic.
        raise BlockedError(EXIT_CREDENTIALS, "BLOCKED_ASC_CREDENTIALS", "failed to sign JWT with the provided private key") from error
    finally:
        for path in (key_path, input_path):
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass
    return f"{header}.{payload}.{b64url(der_to_raw_ecdsa(result.stdout))}"


def fetch_json(url: str, token: str, transport=None) -> dict:
    """Fetch a JSON document. `transport(url, token)` is injectable for tests."""
    if transport is not None:
        return transport(url, token)
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
            return json.loads(body)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        try:
            decoded = json.loads(body)
        except json.JSONDecodeError:
            decoded = {"errors": [{"status": str(error.code), "detail": "non-json response"}]}
        return {"__http_status": error.code, **decoded}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        reason = getattr(error, "reason", error)
        detail = " ".join(str(reason).split())[:240]
        return {"errors": [{"code": "ASC_REQUEST_FAILED", "detail": detail or "request failed"}]}


def error_summary(document: dict) -> str:
    errors = document.get("errors") or []
    parts = []
    for error in errors[:3]:
        detail = error.get("detail") or error.get("title") or "request failed"
        detail = " ".join(str(detail).split())[:240]
        parts.append(f"code={error.get('code', 'unknown')} status={error.get('status', 'unknown')} detail={detail}")
    return redact("; ".join(parts) or "unknown App Store Connect API error")


def relationship_id(resource: dict, name: str) -> str | None:
    data = (resource.get("relationships") or {}).get(name, {}).get("data")
    return data.get("id") if isinstance(data, dict) else None


def compute_next_build_number(builds: list) -> dict:
    """Pure function: given ASC `builds` resource dicts, compute the next build number.

    Uses the global maximum CFBundleVersion across all supplied builds
    (not scoped per version train) plus one. Raises ValueError if no
    build in the list has a numeric `attributes.version`.
    """
    max_version = None
    scanned = 0
    skipped_non_numeric = 0
    for build in builds:
        scanned += 1
        attributes = (build.get("attributes") if isinstance(build, dict) else None) or {}
        raw_version = attributes.get("version")
        try:
            version = int(str(raw_version).strip())
        except (TypeError, ValueError):
            skipped_non_numeric += 1
            continue
        if max_version is None or version > max_version:
            max_version = version
    if max_version is None:
        raise ValueError(
            f"BLOCKED_ASC_NO_BUILDS: no build with a numeric version found among {scanned} scanned build(s) "
            f"({skipped_non_numeric} skipped as non-numeric)"
        )
    return {
        "nextBuildNumber": max_version + 1,
        "latestBuildNumber": max_version,
        "scannedBuilds": scanned,
        "skippedNonNumeric": skipped_non_numeric,
    }


def resolve_app_id(token: str, bundle_id: str, transport=None) -> str:
    url = API_ROOT + f"/apps?filter[bundleId]={urllib.parse.quote(bundle_id, safe='')}&fields[apps]=name,bundleId&limit=10"
    document = fetch_json(url, token, transport)
    if document.get("__http_status") or document.get("errors"):
        raise BlockedError(EXIT_API_ERROR, "BLOCKED_ASC_API_ERROR", f"App Store Connect app lookup failed: {error_summary(document)}")
    matches = document.get("data") or []
    if not matches:
        raise BlockedError(EXIT_APP_NOT_FOUND, "BLOCKED_ASC_APP_NOT_FOUND", f"no App Store Connect app found for bundle ID {bundle_id}")
    return matches[0].get("id")


def collect_all_builds(token: str, app_id: str, transport=None, max_pages: int = MAX_BUILD_PAGES) -> tuple[list, dict]:
    """Page through every build for the app. Returns (builds, included_by_id)."""
    builds: list = []
    included_by_id: dict = {}
    url = (
        API_ROOT
        + f"/builds?filter[app]={urllib.parse.quote(app_id, safe='')}&limit=200&sort=-version"
        + "&fields[builds]=version,preReleaseVersion&include=preReleaseVersion"
        + "&fields[preReleaseVersions]=version"
    )
    pages = 0
    while url and pages < max_pages:
        document = fetch_json(url, token, transport)
        if document.get("__http_status") or document.get("errors"):
            raise BlockedError(EXIT_API_ERROR, "BLOCKED_ASC_API_ERROR", f"App Store Connect build lookup failed: {error_summary(document)}")
        builds.extend(document.get("data") or [])
        for resource in document.get("included") or []:
            resource_id = resource.get("id")
            if resource_id:
                included_by_id[resource_id] = resource
        pages += 1
        url = (document.get("links") or {}).get("next")
    if pages >= max_pages and url:
        print(
            f"asc-next-build-number: WARNING page limit ({max_pages}) reached while paging builds; "
            "some builds may not have been scanned",
            file=sys.stderr,
        )
    return builds, included_by_id


def resolve_latest_train(builds: list, included_by_id: dict, latest_build_number: int) -> str | None:
    """Best-effort lookup of the preReleaseVersion (version train) for the latest build."""
    try:
        for build in builds:
            attributes = (build.get("attributes") or {})
            try:
                if int(str(attributes.get("version")).strip()) != latest_build_number:
                    continue
            except (TypeError, ValueError):
                continue
            pre_release_id = relationship_id(build, "preReleaseVersion")
            if not pre_release_id:
                return None
            pre_release = included_by_id.get(pre_release_id) or {}
            return (pre_release.get("attributes") or {}).get("version")
    except Exception:
        return None
    return None


def resolve_credentials(args: argparse.Namespace) -> tuple[str, str, bytes]:
    key_id = args.key_id or os.environ.get("APP_STORE_CONNECT_KEY_ID")
    issuer_id = args.issuer_id or os.environ.get("APP_STORE_CONNECT_ISSUER_ID")

    private_key_pem: bytes | None = None
    if args.private_key_path:
        try:
            with open(args.private_key_path, "rb") as handle:
                private_key_pem = handle.read()
        except OSError as error:
            raise BlockedError(EXIT_CREDENTIALS, "BLOCKED_ASC_CREDENTIALS", f"failed to read private key file: {error.strerror or 'read error'}") from error
    elif args.private_key_base64:
        try:
            private_key_pem = base64.b64decode(args.private_key_base64, validate=True)
        except (ValueError, base64.binascii.Error) as error:
            raise BlockedError(EXIT_CREDENTIALS, "BLOCKED_ASC_CREDENTIALS", "failed to base64-decode private key") from error
    else:
        env_key = os.environ.get("APP_STORE_CONNECT_API_KEY_P8")
        if env_key:
            stripped = env_key.strip()
            if stripped.startswith("-----BEGIN"):
                private_key_pem = env_key.encode("utf-8")
            else:
                try:
                    private_key_pem = base64.b64decode(stripped, validate=True)
                except (ValueError, base64.binascii.Error):
                    private_key_pem = env_key.encode("utf-8")

    if not key_id or not issuer_id or not private_key_pem:
        missing = []
        if not key_id:
            missing.append("key-id")
        if not issuer_id:
            missing.append("issuer-id")
        if not private_key_pem:
            missing.append("private-key")
        raise BlockedError(EXIT_CREDENTIALS, "BLOCKED_ASC_CREDENTIALS", f"missing App Store Connect credentials: {', '.join(missing)}")

    return key_id, issuer_id, private_key_pem


def emit_github_env(build_number: int) -> None:
    github_env_path = os.environ.get("GITHUB_ENV")
    if not github_env_path:
        print(f"IOS_BUILD_NUMBER={build_number}", file=sys.stderr)
        return
    with open(github_env_path, "a", encoding="utf-8") as handle:
        handle.write(f"IOS_BUILD_NUMBER={build_number}\n")


def run(args: argparse.Namespace, transport=None) -> dict:
    key_id, issuer_id, private_key_pem = resolve_credentials(args)
    token = make_token(private_key_pem, key_id, issuer_id)
    app_id = resolve_app_id(token, args.bundle_id, transport)
    builds, included_by_id = collect_all_builds(token, app_id, transport)
    try:
        result = compute_next_build_number(builds)
    except ValueError as error:
        raise BlockedError(EXIT_NO_BUILDS, "BLOCKED_ASC_NO_BUILDS", redact(str(error))) from error
    if result["skippedNonNumeric"]:
        print(
            f"asc-next-build-number: skipped {result['skippedNonNumeric']} build(s) with a non-numeric version "
            f"out of {result['scannedBuilds']} scanned",
            file=sys.stderr,
        )
    result["latestTrain"] = resolve_latest_train(builds, included_by_id, result["latestBuildNumber"])
    return result


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Resolve the next iOS CFBundleVersion from App Store Connect's authoritative build history."
    )
    parser.add_argument("--bundle-id", required=True, help="App Store Connect bundle identifier, e.g. com.fluxstudio.planflow")
    parser.add_argument("--key-id", help="App Store Connect API key ID (or APP_STORE_CONNECT_KEY_ID env var)")
    parser.add_argument("--issuer-id", help="App Store Connect API issuer ID (or APP_STORE_CONNECT_ISSUER_ID env var)")
    parser.add_argument("--private-key-path", help="Path to the .p8 private key file")
    parser.add_argument("--private-key-base64", help="Base64-encoded .p8 private key contents")
    parser.add_argument("--emit-github-env", action="store_true", help="Append IOS_BUILD_NUMBER=<n> to $GITHUB_ENV (or stdout if unset)")
    parser.add_argument("--json", action="store_true", help="Print the result as JSON to stdout")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    try:
        result = run(args)
    except BlockedError as error:
        print(f"{error.code}: {redact(error.message)}", file=sys.stderr)
        return error.exit_code
    except Exception as error:  # noqa: BLE001 - top-level fail-closed boundary
        # Never let a raw traceback escape: it could echo argv, env values,
        # or partially-constructed secrets held in local variables.
        print(f"BLOCKED_ASC_API_ERROR: unexpected failure resolving next build number: {redact(str(error))[:240]}", file=sys.stderr)
        return EXIT_API_ERROR

    if args.emit_github_env:
        emit_github_env(result["nextBuildNumber"])

    if args.json:
        print(json.dumps(result))
    else:
        print(f"nextBuildNumber={result['nextBuildNumber']}")
        print(f"latestBuildNumber={result['latestBuildNumber']}")
        print(f"scannedBuilds={result['scannedBuilds']}")
        print(f"skippedNonNumeric={result['skippedNonNumeric']}")
        print(f"latestTrain={result['latestTrain']}")

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
