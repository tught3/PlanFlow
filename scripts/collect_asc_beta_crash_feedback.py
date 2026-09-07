#!/usr/bin/env python3
"""GET-only, PII-safe Build 17 TestFlight crash evidence collector.

The provider documents are never written to disk or serialized.  Only the
small allowlist assembled by ``build_report`` is emitted.
"""

from __future__ import annotations

import argparse
import base64
import ipaddress
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
from typing import Any, Callable

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_CRASH_EVIDENCE = 25
MAX_DIAGNOSTIC_AGGREGATES = 25
MAX_TOP_SYMBOLS = 5
BUNDLE_ID = "com.fluxstudio.planflow"
MARKETING_VERSION = "1.0.0"
BUILD_NUMBER = "17"
UNKNOWN = "UNKNOWN"

SENSITIVE_RE = re.compile(
    r"(?ix)(?:"
    r"[\w.+-]+@[\w.-]+|"
    r"eyJ[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){0,2}|"
    r"(?:sk|pk|rk)_[A-Za-z0-9][A-Za-z0-9_-]{3,}|"
    r"(?:gh[a-z]|github_pat)_[A-Za-z0-9_]+|"
    r"xox[a-z]-[A-Za-z0-9-]+|AIza[A-Za-z0-9_-]+|AKIA[A-Z0-9]{8,}|"
    r"0x[0-9a-f]+|\b[0-9a-f]{16,}\b|"
    r"(?:^|\s)(?:[A-Za-z]:[\\/]|/)[^\s]*|"
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|"
    r"\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b|"
    r"\b(?:\d{1,3}\.){3}\d{1,3}\b|"
    r"\b[a-z]{2}[-_][A-Z]{2}\b|\b[A-Z][a-z]+/[A-Z][A-Za-z_]+\b|"
    r"\b(?:UTC|GMT)\s*[+-]\d{1,2}(?::\d{2})?\b"
    r")"
)

CREDENTIAL_PREFIX_RE = re.compile(
    r"(?i)^(?:(?:sk|pk|rk)(?:_|$)|gh[a-z](?:_|$)|github_pat(?:_|$)|xox[a-z](?:-|$)|AIza|AKIA)"
)

SAFE_BARE_SYMBOLS = frozenset({"main", "start", "run", "abort", "UIApplicationMain"})
SAFE_C_RUNTIME_SYMBOLS = frozenset(
    {
        "calloc",
        "free",
        "kill",
        "malloc",
        "memcpy",
        "memmove",
        "memset",
        "pthread_kill",
        "raise",
        "realloc",
        "strcmp",
        "strlen",
    }
)
SAFE_SYMBOL_NAMESPACES = (
    "Runner",
    "App",
    "Flutter",
    "FIR",
    "Firebase",
    "GAD",
    "UMP",
    "Google",
    "UIKit",
    "UI",
    "NS",
    "CF",
    "Dart",
    "dyld",
)
SAFE_RUNTIME_PREFIXES = ("dispatch_", "objc_", "swift_", "pthread_", "mach_", "os_")
SAFE_BINARY_NAMESPACES = (
    "Flutter",
    "FIR",
    "Firebase",
    "GAD",
    "UMP",
    "Google",
    "UIKit",
    "UI",
    "NS",
    "CF",
    "Dart",
    "dyld",
)
SAFE_SYSTEM_BINARY_NAMESPACES = (
    "CoreFoundation",
    "CoreGraphics",
    "Foundation",
    "JavaScriptCore",
    "Metal",
    "QuartzCore",
    "Security",
    "SwiftUI",
    "SystemConfiguration",
    "WebKit",
    "libdispatch",
    "libobjc",
    "libswift",
    "libsystem",
)


class SchemaError(ValueError):
    pass


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _der_signature_to_raw(value: bytes) -> bytes:
    if len(value) < 8 or value[0] != 0x30:
        raise ValueError("invalid signature")
    pos = 2 + (value[1] & 0x7F if value[1] & 0x80 else 0)
    if pos >= len(value) or value[pos] != 0x02:
        raise ValueError("invalid r")
    r_len = value[pos + 1]
    r = value[pos + 2 : pos + 2 + r_len]
    pos += 2 + r_len
    if pos >= len(value) or value[pos] != 0x02:
        raise ValueError("invalid s")
    s_len = value[pos + 1]
    s = value[pos + 2 : pos + 2 + s_len]
    return r.lstrip(b"\0").rjust(32, b"\0") + s.lstrip(b"\0").rjust(32, b"\0")


def make_token(key_path: str, key_id: str, issuer_id: str) -> str:
    now = int(time.time())
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = _b64(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode("ascii")
    fd, path = tempfile.mkstemp(prefix="asc-signing-input-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(signing_input)
        result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, "-binary", path], check=True, capture_output=True)
        return f"{header}.{payload}.{_b64(_der_signature_to_raw(result.stdout))}"
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _request_scope_error_marker(path: str) -> str | None:
    parsed = urllib.parse.urlparse(str(path))
    safe_path = parsed.path or str(path)
    if safe_path.startswith("/v1/"):
        safe_path = safe_path[3:]
    if safe_path.startswith("/apps/") and safe_path.endswith("/betaFeedbackCrashSubmissions"):
        return "ASC_SUBMISSION_LIST_REQUEST_FAILED"
    if safe_path.startswith("/betaFeedbackCrashSubmissions/") and safe_path.endswith("/crashLog"):
        return "ASC_CRASH_LOG_REQUEST_FAILED"
    if safe_path.startswith("/diagnosticSignatures/") and safe_path.endswith("/logs"):
        return "ASC_DIAGNOSTIC_LOG_REQUEST_FAILED"
    if safe_path.startswith("/builds/") and safe_path.endswith("/diagnosticSignatures"):
        return "ASC_DIAGNOSTIC_SIGNATURES_REQUEST_FAILED"
    if safe_path.startswith("/builds"):
        return "ASC_BUILD_LIST_REQUEST_FAILED"
    if safe_path.startswith("/apps"):
        return "ASC_APP_LIST_REQUEST_FAILED"
    return None


class ASCClient:
    def __init__(self, token: str, transport: Callable[[str, str], tuple[Any, str | None]] | None = None, timeout: int = 30):
        self.token = token
        self.transport = transport
        self.timeout = timeout
        self.errors: list[str] = []

    def _append_request_scope_error(self, path: str) -> None:
        marker = _request_scope_error_marker(path)
        if marker and marker not in self.errors:
            self.errors.append(marker)

    def get(self, path: str) -> dict[str, Any]:
        original_path = path
        path = self._normalize_link(path)
        if not path:
            self.errors.append("UNTRUSTED_ASC_LINK")
            self._append_request_scope_error(original_path)
            return {}
        if self.transport:
            document, _transport_metadata = self.transport("GET", path)
        else:
            parsed = urllib.parse.urlparse(path)
            if parsed.netloc and parsed.hostname != "api.appstoreconnect.apple.com":
                self.errors.append("UNTRUSTED_ASC_LINK")
                self._append_request_scope_error(path)
                return {}
            safe_path = parsed.path + (("?" + parsed.query) if parsed.query else "")
            if safe_path.startswith("/v1/"):
                safe_path = safe_path[3:]
            request = urllib.request.Request(API_ROOT + safe_path, method="GET", headers={"Authorization": f"Bearer {self.token}", "Accept": "application/json, application/vnd.apple.diagnostic-logs+json"})
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    body = response.read(MAX_RESPONSE_BYTES + 1)
                    if len(body) > MAX_RESPONSE_BYTES:
                        self.errors.append("ASC_RESPONSE_TOO_LARGE")
                        self._append_request_scope_error(path)
                        document = {}
                    else:
                        document = json.loads(body)
            except urllib.error.HTTPError as error:
                self.errors.append(f"HTTP_{error.code}")
                self._append_request_scope_error(path)
                document = {}
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
                self.errors.append("ASC_REQUEST_FAILED")
                self._append_request_scope_error(path)
                document = {}
        if isinstance(document, dict) and document.get("errors"):
            self.errors.append("ASC_API_ERROR")
            self._append_request_scope_error(path)
        return document if isinstance(document, dict) else {}

    def _normalize_link(self, path: str) -> str | None:
        parsed = urllib.parse.urlparse(str(path))
        if parsed.netloc and parsed.hostname != "api.appstoreconnect.apple.com":
            return None
        if parsed.scheme and parsed.scheme != "https":
            return None
        normalized = parsed.path + (("?" + parsed.query) if parsed.query else "")
        if normalized.startswith("/v1/"):
            normalized = normalized[3:]
        if not normalized.startswith("/") or "/../" in normalized or normalized.endswith("/.."):
            return None
        return normalized

    def pages(self, path: str, expected_type: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        next_path: str | None = path
        current_path = path
        for _ in range(100):
            if not next_path:
                break
            current_path = next_path
            document = self.get(current_path)
            data = document.get("data")
            if not isinstance(data, list):
                self.errors.append("JSON_API_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                break
            if not all(_is_resource(item, expected_type) for item in data):
                self.errors.append("JSON_API_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                break
            result.extend(data)
            if "links" in document and not isinstance(document.get("links"), dict):
                self.errors.append("JSON_API_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                break
            links = document.get("links", {})
            candidate = links.get("next")
            if not candidate:
                next_path = None
            elif not isinstance(candidate, str):
                self.errors.append("JSON_API_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                next_path = None
            else:
                next_path = self._normalize_link(str(candidate))
                if not next_path:
                    self.errors.append("UNTRUSTED_ASC_LINK")
                    self._append_request_scope_error(current_path)
        else:
            if next_path:
                self.errors.append("PAGINATION_LIMIT")
                self._append_request_scope_error(current_path)
        return result

    def pages_with_included(self, path: str, expected_type: str, included_types: set[str]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        result: list[dict[str, Any]] = []
        included: list[dict[str, Any]] = []
        included_keys: set[tuple[str, str]] = set()
        next_path: str | None = path
        current_path = path
        for _ in range(100):
            if not next_path:
                break
            current_path = next_path
            document = self.get(current_path)
            data = document.get("data")
            if not isinstance(data, list) or not all(_is_resource(item, expected_type) for item in data):
                self.errors.append("JSON_API_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                break
            result.extend(data)
            if "included" not in document:
                if data:
                    self.errors.append("JSON_API_INCLUDED_SCHEMA_MISMATCH")
                    self._append_request_scope_error(current_path)
                    break
                values: list[dict[str, Any]] = []
            else:
                values = document.get("included")
                if not isinstance(values, list) or not all(_is_resource(item) and item.get("type") in included_types for item in values):
                    self.errors.append("JSON_API_INCLUDED_SCHEMA_MISMATCH")
                    self._append_request_scope_error(current_path)
                    break
            page_keys = [(item["type"], item["id"]) for item in values]
            if len(page_keys) != len(set(page_keys)):
                self.errors.append("JSON_API_INCLUDED_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                break
            for item, key in zip(values, page_keys):
                if key not in included_keys:
                    included.append(item)
                    included_keys.add(key)
            if "links" in document and not isinstance(document.get("links"), dict):
                self.errors.append("JSON_API_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                break
            links = document.get("links", {})
            candidate = links.get("next")
            if not candidate:
                next_path = None
            elif not isinstance(candidate, str):
                self.errors.append("JSON_API_SCHEMA_MISMATCH")
                self._append_request_scope_error(current_path)
                next_path = None
            else:
                next_path = self._normalize_link(str(candidate))
                if not next_path:
                    self.errors.append("UNTRUSTED_ASC_LINK")
                    self._append_request_scope_error(current_path)
        else:
            if next_path:
                self.errors.append("PAGINATION_LIMIT")
                self._append_request_scope_error(current_path)
        return result, included


def _attrs(resource: dict[str, Any]) -> dict[str, Any]:
    value = resource.get("attributes")
    return value if isinstance(value, dict) else {}


EXPECTED_RELATIONSHIP_TYPES = {
    "apps": {"builds": "builds"},
    "builds": {"app": "apps", "preReleaseVersion": "preReleaseVersions"},
    "preReleaseVersions": {"app": "apps", "builds": "builds"},
    "betaFeedbackCrashSubmissions": {"build": "builds", "crashLog": "betaCrashLogs"},
    "diagnosticSignatures": {"build": "builds", "logs": "diagnosticLogs"},
}


def _is_linkage(value: Any, expected_type: str | None = None) -> bool:
    return (
        isinstance(value, dict)
        and set(value).issubset({"type", "id", "meta"})
        and isinstance(value.get("type"), str)
        and isinstance(value.get("id"), str)
        and bool(value.get("id"))
        and (expected_type is None or value.get("type") == expected_type)
        and ("meta" not in value or isinstance(value["meta"], dict))
    )


def _is_link(value: Any) -> bool:
    if isinstance(value, str):
        return bool(value)
    return (
        isinstance(value, dict)
        and set(value).issubset({"href", "meta"})
        and isinstance(value.get("href"), str)
        and bool(value.get("href"))
        and ("meta" not in value or isinstance(value["meta"], dict))
    )


def _is_relationship(value: Any, expected_type: str | None = None) -> bool:
    if not isinstance(value, dict) or not value or not set(value).issubset({"data", "links", "meta"}):
        return False
    if "meta" in value and not isinstance(value["meta"], dict):
        return False
    if "links" in value:
        links = value["links"]
        if not isinstance(links, dict) or not links or not all(isinstance(name, str) and _is_link(link) for name, link in links.items()):
            return False
    if "data" in value:
        data = value["data"]
        if data is None:
            return expected_type is None
        if isinstance(data, list):
            return all(_is_linkage(item, expected_type) for item in data)
        return _is_linkage(data, expected_type)
    return "links" in value or "meta" in value


def _relationships_valid(resource: dict[str, Any]) -> bool:
    relationships = resource.get("relationships", {})
    if not isinstance(relationships, dict):
        return False
    expected = EXPECTED_RELATIONSHIP_TYPES.get(resource.get("type"), {})
    return all(
        isinstance(name, str)
        and bool(name)
        and _is_relationship(relationship, expected.get(name))
        for name, relationship in relationships.items()
    )


def _is_resource(resource: Any, expected_type: str | None = None) -> bool:
    return (
        isinstance(resource, dict)
        and isinstance(resource.get("id"), str)
        and bool(resource.get("id"))
        and isinstance(resource.get("type"), str)
        and (expected_type is None or resource.get("type") == expected_type)
        and isinstance(resource.get("attributes"), dict)
        and _relationships_valid(resource)
    )


def _relationship_id(resource: dict[str, Any], name: str, expected_type: str) -> str | None:
    relationships = resource.get("relationships")
    if not isinstance(relationships, dict):
        return None
    data = relationships.get(name, {}).get("data") if isinstance(relationships.get(name), dict) else None
    if not isinstance(data, dict) or data.get("type") != expected_type or not isinstance(data.get("id"), str) or not data.get("id"):
        return None
    return data["id"]


def _canonical_submission_build(
    included: list[dict[str, Any]],
    build_id: str,
    app_id: str,
    pre_release_version_id: str,
) -> dict[str, Any] | None:
    if len(included) != 1:
        return None
    build = included[0]
    if not _is_resource(build, "builds"):
        return None
    if build.get("id") != build_id or _attrs(build).get("version") != BUILD_NUMBER:
        return None
    if _relationship_id(build, "app", "apps") != app_id:
        return None
    if _relationship_id(build, "preReleaseVersion", "preReleaseVersions") != pre_release_version_id:
        return None
    return build


def _provider_text(value: Any, limit: int, allow_iphone_brand: bool = False) -> str | None:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    compact = re.sub(r"[^a-z]", "", text.lower())
    forbidden_words = (
        "customer",
        "user",
        "account",
        "person",
        "name",
        "email",
        "phone",
        "address",
        "location",
        "key",
        "apikey",
        "secret",
        "credential",
        "password",
        "passcode",
        "auth",
        "oauth",
        "bearer",
        "session",
        "cookie",
        "deviceid",
        "deviceidentifier",
        "deviceuniqueid",
        "incidentid",
        "incidentidentifier",
        "comment",
        "locale",
        "timezone",
        "requestid",
        "requesttoken",
        "request",
        "accesstoken",
        "authtoken",
        "token",
        "identifier",
        "serialnumber",
        "udid",
        "idfa",
        "idfv",
    )
    id_suffix = bool(re.search(r"(?:[_-]id|[a-z0-9]Id|ID)$", text)) or compact in {"id", "identifier"}
    forbidden_hit = any(word in compact for word in forbidden_words if not (allow_iphone_brand and word == "phone" and compact.startswith("iphone")))
    if not text or len(text) > limit or SENSITIVE_RE.search(text) or CREDENTIAL_PREFIX_RE.search(text) or id_suffix or forbidden_hit:
        return None
    for candidate in re.findall(r"[0-9A-Fa-f:.%]{3,}", text):
        candidate = candidate.strip("[](),")
        if ":" not in candidate:
            continue
        try:
            ipaddress.ip_address(candidate.split("%", 1)[0])
            return None
        except ValueError:
            pass
    return text


def _safe_device(value: Any) -> str:
    text = _provider_text(value, 48, allow_iphone_brand=True)
    pattern = r"(?i)(?:iPhone|iPad|iPod|AppleTV|Apple Watch|Watch|Mac|Vision|RealityDevice|Simulator|iOS Device)[A-Za-z0-9 .,_()-]*"
    return text if text and re.fullmatch(pattern, text) else UNKNOWN


def _safe_os(value: Any) -> str:
    text = _provider_text(value, 64, allow_iphone_brand=True)
    pattern = r"(?i)(?:iOS|iPhone OS|iPadOS|macOS|watchOS|tvOS|visionOS)\s+\d+(?:\.\d+){0,3}(?:\s*\([A-Za-z0-9 ._-]{1,24}\))?"
    return text if text and re.fullmatch(pattern, text) else UNKNOWN


def _safe_architecture(value: Any) -> str:
    text = _provider_text(value, 32)
    return text if text and text.lower() in {"arm64", "arm64e", "arm-64", "x86_64", "x86-64", "i386", "armv7", "armv7s"} else UNKNOWN


def _safe_uptime(value: Any) -> str:
    if isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= 315_576_000:
        return str(value)
    text = _provider_text(value, 48)
    pattern = r"(?i)\d+(?:\.\d+)?(?:\s*(?:ms|milliseconds?|s|seconds?|minutes?|hours?|days?))?"
    return text if text and re.fullmatch(pattern, text) else UNKNOWN


def _safe_exception(value: Any) -> str:
    text = _provider_text(value, 80)
    pattern = r"(?:EXC_[A-Z0-9_]+(?:\s*\(SIG[A-Z0-9]+\))?|SIG[A-Z0-9]+)"
    return text if text and re.fullmatch(pattern, text) else UNKNOWN


def _safe_termination(value: Any) -> str:
    text = _provider_text(value, 120)
    pattern = r"(?i)(?:Namespace\s+)?(?:SIGNAL|CODESIGNING|WATCHDOG|DYLD|LIBXPC|FRONTBOARD|RUNNINGBOARD|SPRINGBOARD)(?:,?\s*(?:Code\s+)?\d+)?"
    return text if text and re.fullmatch(pattern, text) else UNKNOWN


def _safe_crashed_thread(value: Any) -> str:
    text = str("" if value is None else value).strip()
    return text if re.fullmatch(r"\d{1,6}", text) else UNKNOWN


def _has_program_namespace(text: str, namespaces: tuple[str, ...]) -> bool:
    for namespace in namespaces:
        if text == namespace:
            return True
        if text.startswith(namespace) and len(text) > len(namespace):
            boundary = text[len(namespace)]
            if boundary.isupper() or boundary.isdigit() or boundary in "._:$(":
                return True
    return False


def _safe_symbol(value: Any) -> str:
    text = _provider_text(value, 180)
    if not text:
        return UNKNOWN
    text = re.sub(r"\s+\+\s+\d+\s*$", "", text)
    if text in SAFE_BARE_SYMBOLS or text in SAFE_C_RUNTIME_SYMBOLS:
        return text
    if re.fullmatch(r"[+-]\[[A-Za-z_][A-Za-z0-9_.$]*(?:\([A-Za-z_][A-Za-z0-9_.$]*\))?\s+[A-Za-z_][A-Za-z0-9_:]*\]", text):
        return text
    if re.fullmatch(r"\$s[A-Za-z0-9_.$]{3,}", text):
        return text
    if re.fullmatch(r"_(?:\$s|T|Z|_+|dispatch_|objc_|swift_|pthread_|mach_|os_|UI|NS|CF|FIR|GAD)[A-Za-z0-9_.$]*", text):
        return text
    if any(text.startswith(prefix) for prefix in SAFE_RUNTIME_PREFIXES) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.$]*", text):
        return text
    if re.fullmatch(r"(?:Runner|App(?:\.framework)?)\s+(?:main|start|run|abort|UIApplicationMain|entry)", text):
        return text
    scoped_shape = re.fullmatch(
        r"[A-Za-z_$][A-Za-z0-9_$]*(?:(?:::|\.)[A-Za-z_~$][A-Za-z0-9_~$<>]*)*(?:\([A-Za-z0-9_~$.:,*&<> \-]{0,80}\))?",
        text,
    )
    if scoped_shape and _has_program_namespace(text, SAFE_SYMBOL_NAMESPACES):
        return text
    strong_shape = re.fullmatch(
        r"[A-Za-z_~$][A-Za-z0-9_~$<>]*(?:(?:::|\.)[A-Za-z_~$][A-Za-z0-9_~$<>]*)+(?:\([A-Za-z0-9_~$.:,*&<> \-]{0,80}\))?",
        text,
    ) or re.fullmatch(r"[A-Za-z_~][A-Za-z0-9_~]*\([A-Za-z0-9_~$.:,*&<> \-]{0,80}\)", text)
    return text if strong_shape else UNKNOWN


def _safe_binary_name(value: Any) -> str:
    text = _provider_text(value, 64)
    if not text or not re.fullmatch(r"[A-Za-z][A-Za-z0-9._+-]*", text):
        return UNKNOWN
    if text in {"Runner", "App.framework", "UIKitCore", "dyld"}:
        return text
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9_+-]*\.framework", text):
        return text
    if re.fullmatch(r"lib[A-Za-z0-9_.+-]+\.dylib", text):
        return text
    if _has_program_namespace(text, SAFE_BINARY_NAMESPACES + SAFE_SYSTEM_BINARY_NAMESPACES):
        return text
    return UNKNOWN


def _safe_signature(value: Any) -> str:
    return _safe_symbol(value)


def _safe_event(value: Any) -> str:
    text = _provider_text(value, 32)
    if not text:
        return UNKNOWN
    normalized = re.sub(r"[^A-Z]", "", text.upper())
    return {"HANG": "HANGS", "HANGS": "HANGS", "LAUNCH": "LAUNCHES", "LAUNCHES": "LAUNCHES", "DISKWRITE": "DISK_WRITES", "DISKWRITES": "DISK_WRITES"}.get(normalized, UNKNOWN)


def _safe_uuid(value: Any) -> str:
    match = re.fullmatch(r"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", str(value or ""))
    return match.group(0).upper() if match else UNKNOWN


def _frames_from_json(document: dict[str, Any]) -> list[str]:
    threads = document.get("threads")
    if not isinstance(threads, list):
        return []
    chosen = next((item for item in threads if isinstance(item, dict) and item.get("triggered")), None)
    chosen = chosen or (threads[0] if threads else {})
    frames = chosen.get("frames", []) if isinstance(chosen, dict) else []
    result = []
    for frame in frames[:10] if isinstance(frames, list) else []:
        if isinstance(frame, dict):
            result.append(_safe_symbol(frame.get("symbol") or frame.get("symbolLocation", {}).get("symbol")))
    return [item for item in result if item != UNKNOWN]


def _json_documents(value: str) -> list[dict[str, Any]]:
    """Decode the concatenated JSON objects used by modern Apple .ips files."""
    decoder = json.JSONDecoder()
    documents: list[dict[str, Any]] = []
    position = 0
    while position < len(value):
        while position < len(value) and value[position].isspace():
            position += 1
        if position >= len(value):
            break
        try:
            decoded, position = decoder.raw_decode(value, position)
        except json.JSONDecodeError:
            return []
        if not isinstance(decoded, dict):
            return []
        documents.append(decoded)
    return documents


def _merged_json_incident(value: str) -> dict[str, Any] | None:
    documents = _json_documents(value)
    incidents = [item for item in documents if "threads" in item or "exception" in item]
    if len(incidents) != 1:
        return None
    incident = incidents[0]
    metadata = next((item for item in documents if item is not incident), {})
    merged = dict(metadata)
    merged.update(incident)
    return merged


def _valid_json_frame(frame: Any) -> bool:
    if not isinstance(frame, dict):
        return False
    if "symbol" in frame and not isinstance(frame["symbol"], str):
        return False
    if "symbolLocation" in frame and (
        not isinstance(frame["symbolLocation"], dict)
        or not isinstance(frame["symbolLocation"].get("symbol"), str)
    ):
        return False
    if "imageIndex" in frame and (not isinstance(frame["imageIndex"], int) or isinstance(frame["imageIndex"], bool)):
        return False
    if "imageOffset" in frame and (not isinstance(frame["imageOffset"], int) or isinstance(frame["imageOffset"], bool)):
        return False
    return (
        bool(frame.get("symbol"))
        or bool(frame.get("symbolLocation", {}).get("symbol"))
        or ("imageIndex" in frame and "imageOffset" in frame)
    )


def _valid_json_incident(document: Any) -> bool:
    if not isinstance(document, dict):
        return False
    exception = document.get("exception")
    if not isinstance(exception, dict):
        return False
    exception_value = exception.get("type") or exception.get("signal")
    if not isinstance(exception_value, str) or not exception_value.strip():
        return False
    threads = document.get("threads")
    if not isinstance(threads, list) or not threads:
        return False
    for thread in threads:
        if not isinstance(thread, dict) or not isinstance(thread.get("frames"), list):
            return False
        if "triggered" in thread and not isinstance(thread["triggered"], bool):
            return False
        if not all(_valid_json_frame(frame) for frame in thread["frames"]):
            return False
    faulting = document.get("faultingThread")
    if faulting is not None and (not isinstance(faulting, int) or isinstance(faulting, bool) or faulting < 0 or faulting >= len(threads)):
        return False
    triggered = [index for index, thread in enumerate(threads) if thread.get("triggered") is True]
    if faulting is None and len(triggered) != 1:
        return False
    target = faulting if faulting is not None else triggered[0]
    if not threads[target]["frames"]:
        return False
    if "termination" in document:
        termination = document["termination"]
        if not isinstance(termination, dict) or not any(isinstance(termination.get(key), str) and termination.get(key) for key in ("reason", "namespace")):
            return False
    if "usedImages" in document:
        images = document["usedImages"]
        if not isinstance(images, list) or not all(
            isinstance(image, dict)
            and isinstance(image.get("name"), str)
            and isinstance(image.get("uuid"), str)
            and ("arch" not in image or isinstance(image["arch"], str))
            for image in images
        ):
            return False
    return True


def _valid_classic_crash(text: str) -> bool:
    required = (
        r"^(?:Hardware Model|Model):\s*\S.+$",
        r"^OS Version:\s*\S.+$",
        r"^Code Type:\s*\S.+$",
        r"^Exception Type:\s*\S.+$",
        r"^Crashed Thread:\s*\d+\s*$",
    )
    if not all(re.search(pattern, text, re.I | re.M) for pattern in required):
        return False
    return bool(re.search(r"^\s*\d+\s+\S+\s+(?:0x[0-9a-fA-F]+|\d+)\s+.+?\s+\+\s+\d+\s*$", text, re.M))


def _supported_crash_log(value: Any) -> bool:
    if not isinstance(value, str) or not value.strip():
        return False
    if value.lstrip().startswith("{"):
        return _valid_json_incident(_merged_json_incident(value))
    return _valid_classic_crash(value)


def parse_crash_log(value: Any) -> dict[str, Any]:
    if isinstance(value, str):
        incident = _merged_json_incident(value)
        if incident:
            return parse_crash_log(incident)
    if isinstance(value, dict):
        system = value.get("system", {}) if isinstance(value.get("system"), dict) else {}
        exception = value.get("exception", {}) if isinstance(value.get("exception"), dict) else {}
        termination = value.get("termination", {}) if isinstance(value.get("termination"), dict) else {}
        frames = _frames_from_json(value)
        binary_uuid = UNKNOWN
        for image in value.get("usedImages", []) if isinstance(value.get("usedImages"), list) else []:
            if isinstance(image, dict) and str(image.get("name", "")).lower() in {"runner", "app.framework"}:
                binary_uuid = _safe_uuid(image.get("uuid"))
                break
        model = value.get("model") or value.get("modelCode") or system.get("model") or system.get("modelCode")
        os_version = value.get("osVersion") or system.get("osVersion")
        if isinstance(os_version, dict):
            os_version = os_version.get("version") or os_version.get("name") or os_version.get("train")
        architecture = value.get("cpuType") or system.get("cpuType")
        if not architecture and isinstance(value.get("usedImages"), list):
            architecture = next((image.get("arch") for image in value["usedImages"] if isinstance(image, dict) and image.get("arch")), None)
        return {"device_model": _safe_device(model), "device_family": _safe_device(value.get("family") or system.get("modelCode")), "os": _safe_os(os_version), "architecture": _safe_architecture(architecture), "uptime": _safe_uptime(value.get("uptime") or system.get("uptime")), "exception": _safe_exception(exception.get("type") or exception.get("signal")), "termination": _safe_termination(termination.get("reason") or termination.get("namespace")), "crashed_thread": _safe_crashed_thread(value.get("faultingThread")), "binary_uuid": binary_uuid, "top_symbols": frames[:MAX_TOP_SYMBOLS] or [UNKNOWN]}
    text = str(value or "")
    def find(pattern: str, sanitizer: Callable[[Any], str]) -> str:
        match = re.search(pattern, text, re.I | re.M)
        return sanitizer(match.group(1)) if match else UNKNOWN
    frames = [_safe_symbol(match.group(1)) for match in re.finditer(r"^\s*\d+\s+\S+\s+(?:0x[0-9a-fA-F]+|\d+)\s+(.+?)\s+\+\s+\d+", text, re.M)]
    return {"device_model": find(r"(?:Hardware Model|Model):\s*(.+)$", _safe_device), "device_family": UNKNOWN, "os": find(r"OS Version:\s*(.+)$", _safe_os), "architecture": find(r"Code Type:\s*(.+)$", _safe_architecture), "uptime": find(r"(?:Time Since Boot|Uptime):\s*(.+)$", _safe_uptime), "exception": find(r"Exception Type:\s*(.+)$", _safe_exception), "termination": find(r"Termination Reason:\s*(.+)$", _safe_termination), "crashed_thread": find(r"Crashed Thread:\s*(.+)$", _safe_crashed_thread), "binary_uuid": UNKNOWN, "top_symbols": frames[:MAX_TOP_SYMBOLS] or [UNKNOWN]}


def _has_decisive_crash_evidence(evidence: dict[str, Any]) -> bool:
    scalar_fields = ("exception", "termination", "crashed_thread", "binary_uuid")
    if any(evidence.get(field) not in (None, "", UNKNOWN) for field in scalar_fields):
        return True
    return any(symbol != UNKNOWN for symbol in evidence.get("top_symbols", []))


def parse_diagnostic_logs(document: dict[str, Any]) -> list[dict[str, Any]]:
    if not isinstance(document, dict) or not isinstance(document.get("productData"), list):
        raise SchemaError("diagnostic log root")
    parsed: list[dict[str, Any]] = []
    for product in document["productData"]:
        if not isinstance(product, dict) or not isinstance(product.get("diagnosticLogs"), list):
            raise SchemaError("diagnostic product")
        for log in product["diagnosticLogs"]:
            if not isinstance(log, dict) or not isinstance(log.get("diagnosticMetaData"), dict) or not isinstance(log.get("callStackTree"), list):
                raise SchemaError("diagnostic log")
            metadata = log["diagnosticMetaData"]
            if not isinstance(metadata.get("event"), str) or not isinstance(metadata.get("platformArchitecture"), str):
                raise SchemaError("diagnostic metadata")
            symbols: list[str] = []
            for tree in log["callStackTree"]:
                if not isinstance(tree, dict) or not isinstance(tree.get("callStacks"), list):
                    raise SchemaError("diagnostic stack tree")
                for stack in tree["callStacks"]:
                    if not isinstance(stack, dict) or not isinstance(stack.get("callStackRootFrames"), list):
                        raise SchemaError("diagnostic call stack")
                    pending = list(reversed(stack["callStackRootFrames"]))
                    inspected = 0
                    while pending and inspected < 200:
                        frame = pending.pop()
                        inspected += 1
                        if not isinstance(frame, dict) or not isinstance(frame.get("subFrames", []), list):
                            raise SchemaError("diagnostic frame")
                        if "symbolName" in frame and not isinstance(frame["symbolName"], str):
                            raise SchemaError("diagnostic symbol")
                        if "binaryName" in frame and not isinstance(frame["binaryName"], str):
                            raise SchemaError("diagnostic binary")
                        binary = _safe_binary_name(frame.get("binaryName"))
                        symbol = _safe_symbol(frame.get("symbolName"))
                        if len(symbols) < MAX_TOP_SYMBOLS and binary != UNKNOWN and symbol != UNKNOWN:
                            symbols.append(binary + "!" + symbol)
                        pending.extend(reversed(frame.get("subFrames", [])))
                    if pending:
                        raise SchemaError("diagnostic frame limit")
            event = _safe_event(metadata["event"])
            architecture = _safe_architecture(metadata["platformArchitecture"])
            if event == UNKNOWN or architecture == UNKNOWN:
                raise SchemaError("unsafe diagnostic metadata")
            parsed.append({"event": event, "architecture": architecture, "top_symbols": symbols or [UNKNOWN]})
    return parsed


def _diagnostic(item: dict[str, Any], logs: list[dict[str, Any]]) -> dict[str, Any]:
    attributes = _attrs(item)
    kind = _safe_event(attributes.get("diagnosticType") or attributes.get("type"))
    signature = _safe_signature(attributes.get("signature") or attributes.get("diagnosticSignature"))
    weight = attributes.get("weight")
    symbols = [_safe_symbol(value) for value in attributes.get("topFrames", [])] if isinstance(attributes.get("topFrames"), list) else []
    symbols = [value for value in symbols if value != UNKNOWN]
    architecture = _safe_architecture(attributes.get("architecture"))
    for log in logs:
        kind = _safe_event(log.get("event") or kind)
        architecture = _safe_architecture(log.get("architecture") or architecture)
        symbols.extend(value for value in log.get("top_symbols", []) if isinstance(value, str) and value != UNKNOWN)
    return {"type": kind, "signature": signature, "weight": weight if isinstance(weight, (int, float)) and not isinstance(weight, bool) else UNKNOWN, "architecture": architecture, "top_symbols": symbols[:MAX_TOP_SYMBOLS] or [UNKNOWN], "log_count": len(logs)}


def collect(client: ASCClient) -> dict[str, Any]:
    report: dict[str, Any] = {
        "target": {"bundle_id": BUNDLE_ID, "marketing_version": MARKETING_VERSION, "build": BUILD_NUMBER},
        "source": {"provider": "App Store Connect", "mode": "GET_ONLY"},
        "status": [],
        "counts": {
            "feedback_submissions": 0,
            "matched_feedback": 0,
            "crash_logs": 0,
            "crash_evidence_emitted": 0,
            "crash_evidence_truncated": 0,
            "diagnostic_signatures": 0,
            "diagnostic_logs": 0,
            "diagnostic_aggregates_emitted": 0,
            "diagnostic_aggregates_truncated": 0,
        },
        "crash_evidence": [],
        "diagnostic_aggregate": [],
    }
    apps = client.pages("/apps?filter[bundleId]=" + urllib.parse.quote(BUNDLE_ID, safe=""), "apps")
    if client.errors:
        return _finish(report, client, False)
    app = next((item for item in apps if _attrs(item).get("bundleId") == BUNDLE_ID), None)
    if len(apps) != 1 or not app or not app.get("id"):
        report["status"].append("CANONICAL_APP_NOT_FOUND")
        return _finish(report, client, False)
    app_id = app["id"]
    builds, included = client.pages_with_included(
        "/builds?filter[app]=" + urllib.parse.quote(app_id, safe="") + "&filter[version]=" + BUILD_NUMBER + "&include=preReleaseVersion,app",
        "builds",
        {"preReleaseVersions", "apps"},
    )
    if client.errors:
        return _finish(report, client, False)
    build = next((item for item in builds if str(_attrs(item).get("version")) == BUILD_NUMBER), None)
    pre = _relationship_id(build, "preReleaseVersion", "preReleaseVersions") if build else None
    related_app = _relationship_id(build, "app", "apps") if build else None
    pre_matches = [item for item in included if item.get("type") == "preReleaseVersions" and item.get("id") == pre]
    app_matches = [item for item in included if item.get("type") == "apps" and item.get("id") == related_app]
    pre_resource = pre_matches[0] if len(pre_matches) == 1 else {}
    app_resource = app_matches[0] if len(app_matches) == 1 else {}
    pre_attrs = _attrs(pre_resource)
    app_attrs = _attrs(app_resource)
    if (
        len(builds) != 1
        or len(included) != 2
        or not build
        or not build.get("id")
        or not pre
        or related_app != app_id
        or len(pre_matches) != 1
        or len(app_matches) != 1
        or pre_attrs.get("version") != MARKETING_VERSION
        or pre_attrs.get("platform") != "IOS"
        or app_attrs.get("bundleId") != BUNDLE_ID
    ):
        client.errors.append("CANONICAL_BUILD_SCHEMA_MISMATCH")
        report["status"].append("CANONICAL_BUILD_NOT_FOUND")
        return _finish(report, client, False)
    report["status"].append("CANONICAL_APP_BUILD_BOUND")
    build_id = build["id"]
    submissions, submission_included = client.pages_with_included(
        "/apps/" + urllib.parse.quote(app_id, safe="") + "/betaFeedbackCrashSubmissions?filter[build]=" + urllib.parse.quote(build_id, safe="") + "&include=build&fields[betaFeedbackCrashSubmissions]=crashLog,build",
        "betaFeedbackCrashSubmissions",
        {"builds"},
    )
    report["counts"]["feedback_submissions"] = len(submissions)
    if client.errors:
        return _finish(report, client, False)
    if submissions and not _canonical_submission_build(submission_included, build_id, app_id, pre):
        client.errors.append("JSON_API_INCLUDED_SCHEMA_MISMATCH")
        return _finish(report, client, False)
    for submission in submissions:
        linked_build = _relationship_id(submission, "build", "builds")
        linked_log = _relationship_id(submission, "crashLog", "betaCrashLogs")
        if not linked_build or not linked_log:
            client.errors.append("JSON_API_RELATIONSHIP_SCHEMA_MISMATCH")
            return _finish(report, client, False)
        if linked_build != build_id:
            continue
        report["counts"]["matched_feedback"] += 1
        sid = submission.get("id")
        if not isinstance(sid, str):
            continue
        log = client.get("/betaFeedbackCrashSubmissions/" + urllib.parse.quote(sid, safe="") + "/crashLog?fields[betaCrashLogs]=logText")
        if client.errors:
            return _finish(report, client, False)
        log_data = log.get("data")
        if not _is_resource(log_data, "betaCrashLogs") or log_data.get("id") != linked_log:
            client.errors.append("BETA_CRASH_LOG_SCHEMA_MISMATCH")
            return _finish(report, client, False)
        raw = _attrs(log_data).get("logText")
        if not isinstance(raw, str) or not raw:
            client.errors.append("BETA_CRASH_LOG_SCHEMA_MISMATCH")
            return _finish(report, client, False)
        report["counts"]["crash_logs"] += 1
        structurally_supported = _supported_crash_log(raw)
        evidence = parse_crash_log(raw)
        if structurally_supported and _has_decisive_crash_evidence(evidence):
            if len(report["crash_evidence"]) < MAX_CRASH_EVIDENCE:
                report["crash_evidence"].append(evidence)
            else:
                report["counts"]["crash_evidence_truncated"] += 1
        else:
            client.errors.append("CRASH_LOG_UNPARSEABLE")
            return _finish(report, client, False)
    report["counts"]["crash_evidence_emitted"] = len(report["crash_evidence"])
    if report["counts"]["crash_evidence_truncated"]:
        report["status"].append("CRASH_EVIDENCE_TRUNCATED")
    diagnostics = client.pages("/builds/" + urllib.parse.quote(build_id, safe="") + "/diagnosticSignatures", "diagnosticSignatures")
    if client.errors:
        return _finish(report, client, False)
    report["counts"]["diagnostic_signatures"] = len(diagnostics)
    aggregates = []
    for item in diagnostics:
        attributes = _attrs(item)
        if (
            attributes.get("diagnosticType") not in {"DISK_WRITES", "HANGS", "LAUNCHES"}
            or not isinstance(attributes.get("signature"), str)
            or not isinstance(attributes.get("weight"), (int, float))
            or ("topFrames" in attributes and (not isinstance(attributes["topFrames"], list) or not all(isinstance(value, str) for value in attributes["topFrames"])))
        ):
            client.errors.append("DIAGNOSTIC_SIGNATURE_SCHEMA_MISMATCH")
            return _finish(report, client, False)
        if "build" in item.get("relationships", {}):
            diagnostic_build = _relationship_id(item, "build", "builds")
            if diagnostic_build != build_id:
                client.errors.append("DIAGNOSTIC_BUILD_MISMATCH")
                return _finish(report, client, False)
        signature_id = item.get("id")
        logs_document = client.get("/diagnosticSignatures/" + urllib.parse.quote(signature_id, safe="") + "/logs?limit=50")
        if client.errors:
            return _finish(report, client, False)
        try:
            logs = parse_diagnostic_logs(logs_document)
        except SchemaError:
            client.errors.append("DIAGNOSTIC_LOG_SCHEMA_MISMATCH")
            return _finish(report, client, False)
        report["counts"]["diagnostic_logs"] += len(logs)
        if not logs:
            client.errors.append("NO_DIAGNOSTIC_LOGS")
            return _finish(report, client, False)
        if len(aggregates) < MAX_DIAGNOSTIC_AGGREGATES:
            aggregates.append(_diagnostic(item, logs))
        else:
            report["counts"]["diagnostic_aggregates_truncated"] += 1
    report["diagnostic_aggregate"] = aggregates
    report["counts"]["diagnostic_aggregates_emitted"] = len(aggregates)
    if report["counts"]["diagnostic_aggregates_truncated"]:
        report["status"].append("DIAGNOSTIC_AGGREGATES_TRUNCATED")
    if report["crash_evidence"]:
        report["status"].append("MATCHED_BETA_CRASH_EVIDENCE")
        ok = True
    elif any(item.get("log_count", 0) > 0 for item in report["diagnostic_aggregate"]):
        report["status"].append("MATCHED_DIAGNOSTIC_EVIDENCE")
        ok = True
    else:
        report["status"].append("NO_MATCHED_CRASH_EVIDENCE")
        ok = False
    return _finish(report, client, ok)


def _finish(report: dict[str, Any], client: ASCClient, ok: bool) -> dict[str, Any]:
    if client.errors:
        distinct_errors: list[str] = []
        seen_errors: set[str] = set()
        for error in client.errors:
            if error in seen_errors:
                continue
            seen_errors.add(error)
            distinct_errors.append(error)
        if "crash_evidence" in report:
            report["crash_evidence"] = []
        if "diagnostic_aggregate" in report:
            report["diagnostic_aggregate"] = []
        counts = report.get("counts")
        if isinstance(counts, dict):
            counts["crash_evidence_emitted"] = 0
            counts["diagnostic_aggregates_emitted"] = 0
        report["status"] = [status for status in report["status"] if not status.startswith("MATCHED_")]
        report["status"].extend(distinct_errors[:5])
        ok = False
    report["status"].append("PASS" if ok else "FAIL_CLOSED")
    return report


def markdown(report: dict[str, Any]) -> str:
    counts = report["counts"]
    lines = ["# Build 17 TestFlight crash evidence", "", "- Source: App Store Connect GET-only", f"- Target: `{report['target']['bundle_id']}` / version `{report['target']['marketing_version']}` / build `{report['target']['build']}`", f"- Status: `{', '.join(report['status'])}`", f"- Counts: submissions={counts['feedback_submissions']}, matched={counts['matched_feedback']}, crash_logs={counts['crash_logs']}, crash_emitted={counts['crash_evidence_emitted']}, crash_truncated={counts['crash_evidence_truncated']}, diagnostic_signatures={counts['diagnostic_signatures']}, diagnostic_logs={counts['diagnostic_logs']}, diagnostic_emitted={counts['diagnostic_aggregates_emitted']}, diagnostic_truncated={counts['diagnostic_aggregates_truncated']}", ""]
    for index, evidence in enumerate(report["crash_evidence"], 1):
        lines.extend([f"## Crash evidence {index}", f"- Device: {evidence['device_model']} ({evidence['device_family']}); OS: {evidence['os']}; architecture: {evidence['architecture']}", f"- Uptime: {evidence['uptime']}; exception: {evidence['exception']}; termination: {evidence['termination']}; crashed thread: {evidence['crashed_thread']}", f"- Runner/App.framework UUID: {evidence['binary_uuid']}", f"- Top symbols: {', '.join(evidence['top_symbols'])}", ""])
    if report["diagnostic_aggregate"]:
        lines.extend(["## Diagnostic signatures", ""])
        for item in report["diagnostic_aggregate"]:
            lines.append(f"- type={item['type']}; signature={item['signature']}; weight={item['weight']}; top_symbols={', '.join(item['top_symbols'])}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--json-output", required=True)
    parser.add_argument("--markdown-output", required=True)
    args = parser.parse_args(argv)
    report: dict[str, Any]
    try:
        token = make_token(args.key_path, args.key_id, args.issuer_id)
        report = collect(ASCClient(token))
    except Exception as error:  # bounded report; never expose provider or credential material
        report = {"target": {"bundle_id": BUNDLE_ID, "marketing_version": MARKETING_VERSION, "build": BUILD_NUMBER}, "source": {"provider": "App Store Connect", "mode": "GET_ONLY"}, "status": ["COLLECTOR_ERROR", type(error).__name__, "FAIL_CLOSED"], "counts": {"feedback_submissions": 0, "matched_feedback": 0, "crash_logs": 0, "crash_evidence_emitted": 0, "crash_evidence_truncated": 0, "diagnostic_signatures": 0, "diagnostic_logs": 0, "diagnostic_aggregates_emitted": 0, "diagnostic_aggregates_truncated": 0}, "crash_evidence": [], "diagnostic_aggregate": []}
    with open(args.json_output, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=True, indent=2, sort_keys=True)
        handle.write("\n")
    with open(args.markdown_output, "w", encoding="utf-8") as handle:
        handle.write(markdown(report))
    return 0 if "PASS" in report["status"] else 1


if __name__ == "__main__":
    sys.exit(main())
