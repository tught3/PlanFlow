#!/usr/bin/env python3
"""READ-ONLY App Store Connect snapshot collector for Store Intelligence bootstrap.

The current PlanFlow iOS submission is READ_ONLY_PROTECTED: while Apple review
is pending, nothing may write to App Store Connect. This script exists to
build a secret-free snapshot of the *current* App Store Connect configuration
using GET requests only, so Store Intelligence can bootstrap from real data
without ever risking a write.

Design constraints (see the task brief this file was written against):

  * The only way to talk to ASC is `get(path, token, params, transport)`.
    There is no `post`/`patch`/`delete` helper anywhere in this module, and
    `get()` itself refuses (`ReadbackPathNotAllowed`) any path that is not on
    the explicit `ALLOWLIST_PATTERNS` list below.
  * As defense in depth *below* the allowlist, every request is built as a
    plain dict describing an HTTP method + URL + headers (never an
    already-constructed urllib.request.Request with an implicit verb), and
    the transport boundary (`_real_transport`, and any injected test
    transport) is expected to raise `NonGetForbidden` if it is ever asked to
    perform anything other than "GET". This means even a future bug that
    accidentally builds a non-GET request dict cannot silently reach the
    network.
  * `make_token`, `redact`, `b64url`, and `der_to_raw_ecdsa` are re-used from
    scripts/asc-next-build-number.py (loaded via importlib because that
    filename is not a valid Python module name) rather than re-implemented,
    per this task's brief. That script is not modified.
  * PII (demo account credentials, contact details, reviewer notes) is never
    written to the output snapshot in cleartext. See `hash_pii` and
    `sanitize_review_detail`.

Exit codes: 0 success, 3 missing configuration, 6 auth failure, 1 internal
error. stdout on success is a single JSON summary line (file path, section
counts, UNAVAILABLE sections, mutationCount). mutationCount is always 0: the
transport layer is structurally incapable of performing a mutation.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------------------
# Re-use JWT signing + redaction from the sibling ASC script instead of
# duplicating them. That script's filename has a hyphen, so it is loaded via
# importlib.util rather than a normal import statement.
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent
_ASC_MODULE_PATH = _SCRIPTS_DIR / "asc-next-build-number.py"
_ASC_SPEC = importlib.util.spec_from_file_location("_asc_next_build_number_readback", _ASC_MODULE_PATH)
_asc = importlib.util.module_from_spec(_ASC_SPEC)
_ASC_SPEC.loader.exec_module(_asc)

make_token = _asc.make_token
redact = _asc.redact
BlockedError = _asc.BlockedError


API_ROOT = "https://api.appstoreconnect.apple.com"

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_CONFIG_MISSING = 3
EXIT_AUTH_FAILURE = 6

MAX_RETRIES = 5
MAX_BACKOFF_SECONDS = 30
MAX_PAGES = 50

SCHEMA_VERSION = 1

PII_HASH_FIELDS = (
    "demoAccountName",
    "contactEmail",
    "contactPhone",
    "contactFirstName",
    "contactLastName",
)

CANONICAL_PLANFLOW_BUNDLE_ID = "com.fluxstudio.planflow"

# appStoreReviewDetail attribute keys that are neither the demo password nor
# PII/notes and are safe to pass through verbatim (allowlist -- see
# sanitize_review_detail). Any attribute App Store Connect returns that is
# NOT one of PII_HASH_FIELDS, "demoAccountPassword", "notes", or this set is
# dropped rather than passed through by default.
REVIEW_DETAIL_PASSTHROUGH_FIELDS = frozenset({"demoAccountRequired"})


class ReadbackPathNotAllowed(Exception):
    """Raised when a caller asks for a path not on the GET allowlist."""


class NonGetForbidden(Exception):
    """Defense-in-depth: raised if a non-GET request object ever reaches transport."""


# ---------------------------------------------------------------------------
# GET-only path allowlist (App Store Connect OpenAPI 4.4.1, confirmed paths).
# Every entry is an anchored regex matched against the URL *path only*
# (never the query string), for both the initial request and any
# `links.next` pagination URL.
# ---------------------------------------------------------------------------
ALLOWLIST_PATTERNS = [
    re.compile(pattern)
    for pattern in (
        r"^/v1/apps$",
        r"^/v1/apps/[^/]+$",
        r"^/v1/apps/[^/]+/appInfos$",
        r"^/v1/appInfos/[^/]+$",
        r"^/v1/appInfos/[^/]+/appInfoLocalizations$",
        r"^/v1/appInfos/[^/]+/primaryCategory$",
        r"^/v1/appInfos/[^/]+/secondaryCategory$",
        r"^/v1/appInfos/[^/]+/ageRatingDeclaration$",
        r"^/v1/apps/[^/]+/appStoreVersions$",
        r"^/v1/appStoreVersions/[^/]+$",
        r"^/v1/appStoreVersions/[^/]+/appStoreVersionLocalizations$",
        r"^/v1/appStoreVersions/[^/]+/build$",
        r"^/v1/appStoreVersions/[^/]+/appStoreReviewDetail$",
        r"^/v1/appStoreVersionLocalizations/[^/]+/appScreenshotSets$",
        r"^/v1/appScreenshotSets/[^/]+/appScreenshots$",
        r"^/v1/apps/[^/]+/reviewSubmissions$",
        r"^/v1/reviewSubmissions/[^/]+/items$",
        r"^/v1/apps/[^/]+/appPriceSchedule$",
        r"^/v1/apps/[^/]+/availabilityV2$",
    )
]


def is_path_allowed(path: str) -> bool:
    return any(pattern.match(path) for pattern in ALLOWLIST_PATTERNS)


def _real_transport(request: dict) -> dict:
    """Default transport: performs the actual HTTP GET via urllib.

    `request` is a plain dict describing the call (never a
    urllib.request.Request already carrying an implicit verb), so this is
    the single place a verb decision is made against live traffic. Anything
    other than "GET" is refused before urllib is ever touched.
    """
    if request.get("method") != "GET":
        raise NonGetForbidden(f"refusing to send non-GET request: {request.get('method')!r}")
    try:
        http_request = urllib.request.Request(request["url"], headers=request["headers"], method="GET")
        with urllib.request.urlopen(http_request, timeout=30) as response:
            body = response.read()
            return {"__http_status": response.status, **json.loads(body or b"{}")}
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
        return {"__http_status": None, "errors": [{"code": "ASC_REQUEST_FAILED", "detail": detail or "request failed"}]}


class ReadbackClient:
    """Bundles the GET-only transport with a request counter that proves
    mutationCount is structurally always 0 (no method other than GET is ever
    constructed by this client)."""

    def __init__(self, token: str, transport=None):
        self.token = token
        self.transport = transport or _real_transport
        self.request_count = 0
        self.mutation_count = 0

    def get(self, path: str, params: dict | None = None) -> dict:
        if not is_path_allowed(path):
            raise ReadbackPathNotAllowed(f"path not in GET allowlist: {path}")
        url = API_ROOT + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        request = {
            "method": "GET",
            "url": url,
            "headers": {"Authorization": f"Bearer {self.token}", "Accept": "application/json"},
        }
        self.request_count += 1
        return self.transport(request)

    def get_url(self, url: str) -> dict:
        """Follow a `links.next` pagination URL. The URL's path is
        re-validated against the same allowlist before any request is made."""
        parsed = urllib.parse.urlsplit(url)
        if not is_path_allowed(parsed.path):
            raise ReadbackPathNotAllowed(f"pagination link path not in GET allowlist: {parsed.path}")
        params = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
        return self.get(parsed.path, params)

    def request_with_retry(self, path: str, params: dict | None = None, sleep_fn=time.sleep) -> dict:
        attempt = 0
        backoff = 1
        while True:
            document = self.get(path, params)
            status = document.get("__http_status")
            if status in (401, 403):
                raise BlockedError(EXIT_AUTH_FAILURE, "AUTH_FAILURE", f"App Store Connect rejected credentials with status {status}")
            if status == 429:
                attempt += 1
                if attempt > MAX_RETRIES:
                    raise BlockedError(EXIT_INTERNAL, "RATE_LIMIT_EXCEEDED", "exceeded 429 retry budget while reading App Store Connect")
                sleep_fn(min(backoff, MAX_BACKOFF_SECONDS))
                backoff *= 2
                continue
            return document

    def request_url_with_retry(self, url: str, sleep_fn=time.sleep) -> dict:
        attempt = 0
        backoff = 1
        while True:
            document = self.get_url(url)
            status = document.get("__http_status")
            if status in (401, 403):
                raise BlockedError(EXIT_AUTH_FAILURE, "AUTH_FAILURE", f"App Store Connect rejected credentials with status {status}")
            if status == 429:
                attempt += 1
                if attempt > MAX_RETRIES:
                    raise BlockedError(EXIT_INTERNAL, "RATE_LIMIT_EXCEEDED", "exceeded 429 retry budget while reading App Store Connect")
                sleep_fn(min(backoff, MAX_BACKOFF_SECONDS))
                backoff *= 2
                continue
            return document

    def collect_pages(self, path: str, params: dict | None = None, sleep_fn=time.sleep) -> list:
        items: list = []
        document = self.request_with_retry(path, params=params, sleep_fn=sleep_fn)
        if not isinstance(document, dict):
            raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection response is malformed")
        if document.get("__http_status") != 200 or document.get("errors"):
            raise BlockedError(EXIT_INTERNAL, "ASC_REQUEST_FAILED", redact(error_summary(document)))
        page_items = document.get("data")
        if not isinstance(page_items, list) or any(not isinstance(item, dict) for item in page_items):
            raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection response data is missing or malformed")
        items.extend(page_items)
        links = document.get("links") or {}
        if not isinstance(links, dict):
            raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection pagination links are malformed")
        next_link = links.get("next")
        if next_link is not None and (not isinstance(next_link, str) or not next_link):
            raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection next-page link is malformed")
        pages = 1
        while next_link and pages < MAX_PAGES:
            document = self.request_url_with_retry(next_link, sleep_fn=sleep_fn)
            if not isinstance(document, dict):
                raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection response is malformed")
            if document.get("__http_status") != 200 or document.get("errors"):
                raise BlockedError(EXIT_INTERNAL, "ASC_REQUEST_FAILED", redact(error_summary(document)))
            page_items = document.get("data")
            if not isinstance(page_items, list) or any(not isinstance(item, dict) for item in page_items):
                raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection response data is missing or malformed")
            items.extend(page_items)
            links = document.get("links") or {}
            if not isinstance(links, dict):
                raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection pagination links are malformed")
            next_link = links.get("next")
            if next_link is not None and (not isinstance(next_link, str) or not next_link):
                raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "collection next-page link is malformed")
            pages += 1
        if next_link:
            raise BlockedError(EXIT_INTERNAL, "ASC_PAGINATION_INCOMPLETE", "collection pagination exceeded the page limit")
        return items


def error_summary(document: dict) -> str:
    errors = document.get("errors") or []
    parts = []
    for error in errors[:3]:
        detail = error.get("detail") or error.get("title") or "request failed"
        detail = " ".join(str(detail).split())[:240]
        parts.append(f"code={error.get('code', 'unknown')} status={error.get('status', 'unknown')} detail={detail}")
    return "; ".join(parts) or "unknown App Store Connect API error"


def _attrs(resource: dict | None) -> dict:
    return (resource or {}).get("attributes") or {}


def _relationship_id(resource: dict, name: str) -> str | None:
    data = (resource.get("relationships") or {}).get(name, {}).get("data")
    return data.get("id") if isinstance(data, dict) else None


def _category_relationship(
    client: ReadbackClient,
    info: dict,
    info_id: str,
    name: str,
    sleep_fn=time.sleep,
) -> tuple[str | None, str]:
    """Read a category relationship without turning missing data into a guess.

    ASC sometimes omits relationship members from an ``appInfos`` response.
    In that case the relationship endpoint is read separately.  A 404 or a
    successful response with no data means the category is explicitly unset;
    transport/API failure is kept distinct as UNAVAILABLE.
    """
    relationships = info.get("relationships") or {}
    if name in relationships and "data" in (relationships.get(name) or {}):
        data = (relationships.get(name) or {}).get("data")
        if data is None:
            return None, "UNSET"
        if not isinstance(data, dict):
            return None, "UNAVAILABLE"
        relationship_id = data.get("id")
        if not isinstance(relationship_id, str) or not relationship_id:
            return None, "UNAVAILABLE"
        return relationship_id, "CONFIGURED"

    document = client.request_with_retry(f"/v1/appInfos/{info_id}/{name}", sleep_fn=sleep_fn)
    status = document.get("__http_status")
    if status == 404:
        return None, "UNSET"
    if status != 200 or document.get("errors"):
        return None, "UNAVAILABLE"
    data = document.get("data")
    if data is None:
        return None, "UNSET"
    if not isinstance(data, dict):
        return None, "UNAVAILABLE"
    relationship_id = data.get("id")
    if not isinstance(relationship_id, str) or not relationship_id:
        return None, "UNAVAILABLE"
    return relationship_id, "CONFIGURED"


# ---------------------------------------------------------------------------
# PII handling
# ---------------------------------------------------------------------------

def hash_pii(value) -> dict:
    """Presence-only PII marker (spec SEC-M6): a salt-less sha256-12 digest
    of a short PII value (an email, phone number, or name) is feasibly
    reversible by brute force, so no digest is stored -- only whether the
    field was present."""
    if value is None or value == "":
        return {"present": False}
    return {"present": True}


def hash_notes(value) -> dict | None:
    """Return only a non-identifying marker; never digest free-text notes."""
    if value is None or value == "":
        return None
    text = str(value)
    return {"length": len(text)}


def sanitize_review_detail(attributes: dict) -> dict:
    """Never emits demoAccountPassword's value, never emits raw contact PII.

    Allowlist-based (SEC-M6 + LOW hardening): any attribute key App Store
    Connect returns that is not on the known allowlist below is dropped
    entirely, not passed through verbatim -- an API change on Apple's side
    could add a new field that happens to carry PII or a secret, and
    passing unknown keys through by default would leak it into a committed
    snapshot silently. Dropped key names (never their values) are reported
    to stderr so a human notices and can extend the allowlist deliberately.
    """
    sanitized: dict = {}
    for key, value in attributes.items():
        if key == "demoAccountPassword":
            sanitized["demoPasswordSet"] = bool(value)
        elif key in PII_HASH_FIELDS:
            sanitized[key] = hash_pii(value)
        elif key == "notes":
            sanitized["notes"] = hash_notes(value)
        elif key in REVIEW_DETAIL_PASSTHROUGH_FIELDS:
            sanitized[key] = value
        else:
            print(
                f"WARNING: dropping unknown appStoreReviewDetail attribute {key!r} "
                "(not on the sanitize allowlist)",
                file=sys.stderr,
            )
    return sanitized


# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------

def read_bundle_id_from_xcconfig(xcconfig_path: pathlib.Path) -> str | None:
    try:
        text = xcconfig_path.read_text(encoding="utf-8")
    except OSError:
        return None
    match = re.search(r"^\s*PLANFLOW_IOS_BUNDLE_ID\s*=\s*(\S+)\s*$", text, re.MULTILINE)
    return match.group(1) if match else None


def validate_bundle_id(bundle_id: str) -> None:
    """Refuse any ASC collection outside the PlanFlow canonical app."""
    if bundle_id != CANONICAL_PLANFLOW_BUNDLE_ID:
        raise BlockedError(
            EXIT_CONFIG_MISSING,
            "BUNDLE_ID_NOT_ALLOWED",
            "refusing App Store Connect readback for non-PlanFlow bundle ID",
        )


def resolve_app(client: ReadbackClient, bundle_id: str) -> dict:
    validate_bundle_id(bundle_id)
    document = client.request_with_retry("/v1/apps", params={"filter[bundleId]": bundle_id, "limit": "10"})
    if document.get("__http_status") not in (None, 200):
        raise BlockedError(EXIT_INTERNAL, "ASC_REQUEST_FAILED", redact(error_summary(document)))
    matches = document.get("data") or []
    if not matches:
        raise BlockedError(EXIT_INTERNAL, "APP_NOT_FOUND", f"no App Store Connect app found for bundle ID {bundle_id}")
    return matches[0]


def collect_snapshot(client: ReadbackClient, bundle_id: str, sleep_fn=time.sleep) -> tuple[dict, list]:
    """Returns (fields, unavailable_sections)."""
    unavailable: list = []
    fields: dict = {}

    app_resource = resolve_app(client, bundle_id)
    app_attrs = _attrs(app_resource)
    app_id = app_resource.get("id")
    fields["app"] = {
        "id": app_id,
        "bundleId": app_attrs.get("bundleId"),
        "name": app_attrs.get("name"),
        "primaryLocale": app_attrs.get("primaryLocale"),
        "contentRightsDeclaration": app_attrs.get("contentRightsDeclaration"),
    }

    # -- appInfos -----------------------------------------------------
    app_infos_raw = client.collect_pages(f"/v1/apps/{app_id}/appInfos", sleep_fn=sleep_fn)
    app_infos = []
    for info in app_infos_raw:
        info_id = info.get("id")
        info_attrs = _attrs(info)
        localizations_raw = client.collect_pages(f"/v1/appInfos/{info_id}/appInfoLocalizations", sleep_fn=sleep_fn)
        localizations = [
            {
                "locale": _attrs(loc).get("locale"),
                "name": _attrs(loc).get("name"),
                "subtitle": _attrs(loc).get("subtitle"),
                "privacyPolicyUrl": _attrs(loc).get("privacyPolicyUrl"),
                "privacyChoicesUrl": _attrs(loc).get("privacyChoicesUrl"),
            }
            for loc in localizations_raw
        ]

        primary_category_id, primary_category_state = _category_relationship(
            client, info, info_id, "primaryCategory", sleep_fn=sleep_fn
        )
        secondary_category_id, secondary_category_state = _category_relationship(
            client, info, info_id, "secondaryCategory", sleep_fn=sleep_fn
        )
        if primary_category_state == "UNAVAILABLE":
            unavailable.append(f"primaryCategory:{info_id}")
        if secondary_category_state == "UNAVAILABLE":
            unavailable.append(f"secondaryCategory:{info_id}")

        age_rating_document = client.request_with_retry(f"/v1/appInfos/{info_id}/ageRatingDeclaration", sleep_fn=sleep_fn)
        if age_rating_document.get("__http_status") == 404:
            age_rating = "UNAVAILABLE"
            unavailable.append(f"ageRatingDeclaration:{info_id}")
        elif age_rating_document.get("__http_status") not in (None, 200):
            age_rating = "UNAVAILABLE"
            unavailable.append(f"ageRatingDeclaration:{info_id}")
        else:
            age_rating = _attrs(age_rating_document.get("data"))

        app_infos.append(
            {
                "id": info_id,
                "state": info_attrs.get("appStoreState"),
                "primaryCategoryId": primary_category_id,
                "primaryCategoryState": primary_category_state,
                "secondaryCategoryId": secondary_category_id,
                "secondaryCategoryState": secondary_category_state,
                "localizations": localizations,
                "ageRating": age_rating,
            }
        )
    fields["appInfos"] = app_infos

    # -- appStoreVersions ----------------------------------------------
    versions_raw = client.collect_pages(f"/v1/apps/{app_id}/appStoreVersions", sleep_fn=sleep_fn)
    versions = []
    for version in versions_raw:
        version_id = version.get("id")
        version_attrs = _attrs(version)

        build_document = client.request_with_retry(f"/v1/appStoreVersions/{version_id}/build", sleep_fn=sleep_fn)
        build_attrs = _attrs(build_document.get("data")) if build_document.get("__http_status") in (None, 200) else {}

        review_detail_document = client.request_with_retry(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail", sleep_fn=sleep_fn)
        if review_detail_document.get("__http_status") not in (None, 200):
            review_detail = "UNAVAILABLE"
            unavailable.append(f"appStoreReviewDetail:{version_id}")
        else:
            review_detail = sanitize_review_detail(_attrs(review_detail_document.get("data")))

        localizations_raw = client.collect_pages(
            f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", sleep_fn=sleep_fn
        )
        localizations = []
        for loc in localizations_raw:
            loc_id = loc.get("id")
            loc_attrs = _attrs(loc)
            screenshot_sets_raw = client.collect_pages(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets", sleep_fn=sleep_fn)
            screenshot_sets = []
            for screenshot_set in screenshot_sets_raw:
                set_id = screenshot_set.get("id")
                set_attrs = _attrs(screenshot_set)
                screenshots_raw = client.collect_pages(f"/v1/appScreenshotSets/{set_id}/appScreenshots", sleep_fn=sleep_fn)
                screenshots = [
                    {
                        "fileName": _attrs(shot).get("fileName"),
                        "fileSize": _attrs(shot).get("fileSize"),
                        "sourceFileChecksum": _attrs(shot).get("sourceFileChecksum"),
                        "assetDeliveryState": (_attrs(shot).get("assetDeliveryState") or {}).get("state"),
                    }
                    for shot in screenshots_raw
                ]
                screenshot_sets.append(
                    {
                        "id": set_id,
                        "screenshotDisplayType": set_attrs.get("screenshotDisplayType"),
                        "screenshots": screenshots,
                    }
                )
            localizations.append(
                {
                    "locale": loc_attrs.get("locale"),
                    "description": loc_attrs.get("description"),
                    "keywords": loc_attrs.get("keywords"),
                    "whatsNew": loc_attrs.get("whatsNew"),
                    "promotionalText": loc_attrs.get("promotionalText"),
                    "supportUrl": loc_attrs.get("supportUrl"),
                    "marketingUrl": loc_attrs.get("marketingUrl"),
                    "screenshotSets": screenshot_sets,
                }
            )

        versions.append(
            {
                "id": version_id,
                "versionString": version_attrs.get("versionString"),
                "appStoreState": version_attrs.get("appStoreState"),
                "releaseType": version_attrs.get("releaseType"),
                "earliestReleaseDate": version_attrs.get("earliestReleaseDate"),
                "build": {
                    "version": build_attrs.get("version"),
                    "usesNonExemptEncryption": build_attrs.get("usesNonExemptEncryption"),
                },
                "reviewDetail": review_detail,
                "localizations": localizations,
            }
        )
    fields["appStoreVersions"] = versions

    # -- reviewSubmissions ----------------------------------------------
    review_submissions_raw = client.collect_pages(f"/v1/apps/{app_id}/reviewSubmissions", sleep_fn=sleep_fn)
    review_submissions = []
    for submission in review_submissions_raw:
        submission_id = submission.get("id")
        attrs = _attrs(submission)
        state = attrs.get("state")
        if (not isinstance(submission_id, str) or not submission_id.strip()
                or not isinstance(state, str) or not state.strip()):
            raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "review submission identity or state is missing")
        items_raw = client.collect_pages(
            f"/v1/reviewSubmissions/{submission_id}/items",
            params={"include": "appStoreVersion", "fields[reviewSubmissionItems]": "appStoreVersion", "limit": "200"},
            sleep_fn=sleep_fn,
        )
        safe_items = []
        for item in items_raw:
            item_id = item.get("id")
            version_id = _relationship_id(item, "appStoreVersion")
            if (item.get("type") != "reviewSubmissionItems"
                    or not isinstance(item_id, str) or not item_id.strip()
                    or not isinstance(version_id, str) or not version_id.strip()):
                raise BlockedError(EXIT_INTERNAL, "ASC_RESPONSE_MALFORMED", "review submission item relationship is missing")
            safe_items.append({"id": item_id, "appStoreVersionId": version_id})
        review_submissions.append({
            "id": submission_id,
            "state": state,
            "submittedDate": attrs.get("submittedDate"),
            "platform": attrs.get("platform"),
            "itemsReadState": "COMPLETE",
            "itemCount": len(safe_items),
            "items": safe_items,
        })
    fields["reviewSubmissions"] = review_submissions

    # -- pricing ----------------------------------------------------------
    pricing_document = client.request_with_retry(f"/v1/apps/{app_id}/appPriceSchedule", sleep_fn=sleep_fn)
    if pricing_document.get("__http_status") not in (None, 200):
        fields["pricing"] = "UNAVAILABLE"
        unavailable.append("appPriceSchedule")
    else:
        pricing_data = pricing_document.get("data")
        fields["pricing"] = {"id": pricing_data.get("id")} if isinstance(pricing_data, dict) else "UNAVAILABLE"
        if fields["pricing"] == "UNAVAILABLE":
            unavailable.append("appPriceSchedule")

    # -- availability -------------------------------------------------------
    availability_document = client.request_with_retry(f"/v1/apps/{app_id}/availabilityV2", sleep_fn=sleep_fn)
    if availability_document.get("__http_status") == 404 or availability_document.get("__http_status") not in (None, 200):
        fields["availability"] = "UNAVAILABLE"
        unavailable.append("availabilityV2")
    else:
        availability_data = availability_document.get("data")
        fields["availability"] = _attrs(availability_data)

    return fields, unavailable


def compute_content_hash(fields: dict) -> str:
    canonical = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def build_snapshot(project_id: str, fields: dict, captured_at: str) -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "projectId": project_id,
        "platform": "ios",
        "capturedAt": captured_at,
        "source": {"kind": "STORE_READBACK", "api": "app-store-connect", "apiVersion": "v1"},
        "contentHash": compute_content_hash(fields),
        "fields": fields,
        "redaction": {
            "piiPresenceOnly": list(PII_HASH_FIELDS),
            "omitted": ["demoAccountPassword"],
        },
    }


def resolve_credentials() -> tuple[str, str, bytes]:
    key_id = os.environ.get("APP_STORE_CONNECT_KEY_ID")
    issuer_id = os.environ.get("APP_STORE_CONNECT_ISSUER_ID")
    raw_key = os.environ.get("APP_STORE_CONNECT_API_KEY_P8")

    private_key_pem: bytes | None = None
    if raw_key:
        stripped = raw_key.strip()
        if stripped.startswith("-----BEGIN"):
            private_key_pem = raw_key.encode("utf-8")
        else:
            import base64

            try:
                private_key_pem = base64.b64decode(stripped, validate=True)
            except (ValueError, Exception):  # noqa: BLE001 - fall back to raw bytes
                private_key_pem = raw_key.encode("utf-8")

    if not key_id or not issuer_id or not private_key_pem:
        missing = []
        if not key_id:
            missing.append("APP_STORE_CONNECT_KEY_ID")
        if not issuer_id:
            missing.append("APP_STORE_CONNECT_ISSUER_ID")
        if not private_key_pem:
            missing.append("APP_STORE_CONNECT_API_KEY_P8")
        raise BlockedError(EXIT_CONFIG_MISSING, "AUTH_CONFIG_MISSING", f"missing App Store Connect credentials: {', '.join(missing)}")

    return key_id, issuer_id, private_key_pem


def run(args: argparse.Namespace, transport=None, sleep_fn=time.sleep, captured_at: str | None = None) -> dict:
    key_id, issuer_id, private_key_pem = resolve_credentials()
    token = make_token(private_key_pem, key_id, issuer_id)

    bundle_id = args.bundle_id
    if args.bundle_id_from_xcconfig:
        xcconfig_bundle_id = read_bundle_id_from_xcconfig(pathlib.Path(args.bundle_id_from_xcconfig))
        if not xcconfig_bundle_id:
            # Fail closed: the caller explicitly asked to resolve the bundle
            # id from this xcconfig file, so a failed/empty read must not
            # silently fall back to --bundle-id's default -- that could read
            # back (and later diff/write against) an entirely different
            # app's App Store Connect record.
            raise BlockedError(
                EXIT_CONFIG_MISSING,
                "BUNDLE_ID_XCCONFIG_UNREADABLE",
                f"could not resolve PLANFLOW_IOS_BUNDLE_ID from {args.bundle_id_from_xcconfig}",
            )
        bundle_id = xcconfig_bundle_id

    validate_bundle_id(bundle_id)

    client = ReadbackClient(token, transport=transport)
    fields, unavailable = collect_snapshot(client, bundle_id, sleep_fn=sleep_fn)

    captured_at = captured_at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    snapshot = build_snapshot(args.project_id, fields, captured_at)

    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    date_str = time.strftime("%Y-%m-%d", time.gmtime())
    out_path = out_dir / f"ios-readback-{date_str}.json"
    out_path.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    return {
        "outPath": str(out_path),
        "sectionsCollected": len(fields),
        "unavailableSections": unavailable,
        "mutationCount": client.mutation_count,
    }


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="READ-ONLY App Store Connect snapshot collector (GET requests only)."
    )
    parser.add_argument("--bundle-id", default="com.fluxstudio.planflow", help="App Store Connect bundle identifier")
    parser.add_argument(
        "--bundle-id-from-xcconfig",
        help="Path to an .xcconfig file containing PLANFLOW_IOS_BUNDLE_ID; overrides --bundle-id when present",
    )
    parser.add_argument("--out", required=True, help="Output directory for the snapshot JSON")
    parser.add_argument("--project-id", default="planflow", help="projectId to stamp into the snapshot")
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
        print(f"INTERNAL_ERROR: unexpected failure during store readback: {redact(str(error))[:240]}", file=sys.stderr)
        return EXIT_INTERNAL

    print(json.dumps(result))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
