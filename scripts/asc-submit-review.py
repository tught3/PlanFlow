#!/usr/bin/env python3
"""Submit one exact iOS App Store version/build for review.

The planning path is read-only. Mutations are limited to the selected version,
its build relationship, its release option, version-matched localized release
notes when missing, and a review submission containing that version alone.
Review contact information and existing non-empty notes are never overwritten.

Opt-in replacement (--replace-existing-build OLD): before any mutation the
script proves, against freshly fetched App Store Connect state, that this exact
version is under review with that old build via exactly one active review
submission containing only this version. With the explicit confirmation phrase
it cancels that submission (PATCH canceled=true), waits a bounded time for an
editable version state, and only then submits the new build through the normal
path. Without the confirmation phrase the replacement is verification-only and
performs zero mutations.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
MAX_PAGES = 30
MAX_POLLS = 8
ACCEPTED_SUBMISSION_STATES = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
    "PENDING_APPLE_RELEASE",
    "READY_FOR_SALE",
}
REVIEW_SUBMISSION_STATES = {
    "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES",
    "CANCELING", "COMPLETING", "COMPLETE",
}
ACTIVE_VERSION_STATES = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
    "PENDING_APPLE_RELEASE",
}
EDITABLE_VERSION_STATES = {
    "READY_FOR_REVIEW",
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
}
REPLACE_CONFIRMATION_PHRASE = "REPLACE_PLANFLOW_IOS_REVIEW"
CANCELABLE_SUBMISSION_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW"}
REPLACE_POLL_INTERVAL_SECONDS = 5.0
REPLACE_MAX_POLLS = 60  # bounded wait of roughly five minutes for Apple to finish canceling


class SubmissionError(Exception):
    pass


def _load_helpers():
    path = os.path.join(os.path.dirname(__file__), "asc-next-build-number.py")
    spec = importlib.util.spec_from_file_location("asc_release_helpers", path)
    if spec is None or spec.loader is None:
        raise SubmissionError("BLOCKED_ASC_HELPERS: release authentication helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AscClient:
    def __init__(self, token: str, transport: Callable | None = None):
        self.token = token
        self.transport = transport
        self.writes = 0

    def request(self, method: str, path: str, body: dict | None = None) -> dict:
        if self.transport is not None:
            result = self.transport(method, path, body)
            if method != "GET":
                self.writes += 1
            return result
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(API_ROOT + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                raw = response.read()
                result = json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            # Do not echo server bodies: they can contain account or credential data.
            raise SubmissionError(f"BLOCKED_ASC_API: {method} request failed with HTTP {error.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
            raise SubmissionError(f"BLOCKED_ASC_API: {method} request failed") from None
        if method != "GET":
            self.writes += 1
        return result

    def pages(self, path: str) -> list[dict]:
        collected: list[dict] = []
        next_path: str | None = path
        for _ in range(MAX_PAGES):
            if not next_path:
                return collected
            doc = self.request("GET", next_path)
            if (not isinstance(doc, dict) or doc.get("errors")
                    or (doc.get("__http_status") is not None and doc.get("__http_status") != 200)):
                raise SubmissionError("BLOCKED_ASC_RESPONSE: collection request failed or returned malformed data")
            data = doc.get("data")
            if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
                raise SubmissionError("BLOCKED_ASC_RESPONSE: collection data is missing or malformed")
            collected.extend(data)
            links = doc.get("links") or {}
            if not isinstance(links, dict):
                raise SubmissionError("BLOCKED_ASC_PAGINATION: malformed pagination links")
            next_url = links.get("next")
            if "next" in links and next_url == "":
                raise SubmissionError("BLOCKED_ASC_PAGINATION: malformed next-page link")
            if next_url:
                if not isinstance(next_url, str):
                    raise SubmissionError("BLOCKED_ASC_PAGINATION: malformed next-page link")
                parsed = urllib.parse.urlsplit(next_url)
                expected = urllib.parse.urlsplit(API_ROOT)
                if parsed.scheme and (parsed.scheme, parsed.netloc) != (expected.scheme, expected.netloc):
                    raise SubmissionError("BLOCKED_ASC_PAGINATION: unexpected next-page link")
                next_path = parsed.path + ("?" + parsed.query if parsed.query else "") if parsed.scheme else next_url
                if next_path.startswith("/v1/"):
                    next_path = next_path[3:]
                if not next_path.startswith("/"):
                    raise SubmissionError("BLOCKED_ASC_PAGINATION: malformed next-page path")
            else:
                next_path = None
        if next_path:
            raise SubmissionError(f"BLOCKED_ASC_PAGINATION: exceeded {MAX_PAGES} pages")
        return collected


def _query(params: dict[str, str]) -> str:
    return "?" + urllib.parse.urlencode(params)


def _attrs(resource: dict) -> dict:
    return resource.get("attributes") or {}


def _relationship_id(resource: dict, name: str) -> str | None:
    data = (((resource.get("relationships") or {}).get(name) or {}).get("data") or {})
    return data.get("id")


def _version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise SubmissionError("BLOCKED_INPUT: version must be X.Y.Z without leading zeroes")
    return tuple(int(part) for part in value.split("."))


def _live_version_tuple(value: str) -> tuple[int, int, int] | None:
    if not re.fullmatch(r"\d+(?:\.\d+){1,2}", value):
        return None
    parts = tuple(int(part) for part in value.split("."))
    return (parts + (0, 0, 0))[:3]


def _one(items: list[dict], label: str) -> dict:
    if len(items) != 1:
        raise SubmissionError(f"BLOCKED_{label}: expected exactly one match, found {len(items)}")
    return items[0]


def _find_version(client: AscClient, app_id: str, version: str) -> dict | None:
    params = {
        "filter[platform]": "IOS",
        "filter[versionString]": version,
        "fields[appStoreVersions]": "versionString,appStoreState,platform",
        "limit": "200",
    }
    versions = client.pages(f"/apps/{app_id}/appStoreVersions" + _query(params))
    matches = [v for v in versions if _attrs(v).get("versionString") == version]
    if len(matches) > 1:
        raise SubmissionError("BLOCKED_VERSION: App Store Connect returned duplicate target versions")
    return matches[0] if matches else None


def _find_build(client: AscClient, app_id: str, version: str, build_number: str) -> dict:
    params = {
        "filter[app]": app_id,
        "filter[version]": build_number,
        "fields[builds]": "version,processingState,preReleaseVersion,expirationDate",
        "fields[preReleaseVersions]": "version",
        "include": "preReleaseVersion",
        "limit": "200",
    }
    collected: list[dict] = []
    included_items: list[dict] = []
    next_path: str | None = "/builds" + _query(params)
    for _ in range(MAX_PAGES):
        if not next_path:
            break
        doc = client.request("GET", next_path)
        collected.extend(doc.get("data") or [])
        included_items.extend(doc.get("included") or [])
        next_url = (doc.get("links") or {}).get("next")
        if not next_url:
            next_path = None
            break
        parsed = urllib.parse.urlsplit(next_url)
        expected = urllib.parse.urlsplit(API_ROOT)
        if parsed.scheme and (parsed.scheme, parsed.netloc) != (expected.scheme, expected.netloc):
            raise SubmissionError("BLOCKED_ASC_PAGINATION: unexpected next-page link")
        next_path = parsed.path + ("?" + parsed.query if parsed.query else "") if parsed.scheme else next_url
        if next_path.startswith("/v1/"):
            next_path = next_path[3:]
        if not next_path.startswith("/"):
            raise SubmissionError("BLOCKED_ASC_PAGINATION: malformed next-page path")
    if next_path:
        raise SubmissionError(f"BLOCKED_ASC_PAGINATION: exceeded {MAX_PAGES} pages")
    included = {
        item.get("id"): item for item in included_items
        if item.get("type") == "preReleaseVersions"
    }
    matches = []
    for build in collected:
        if str(_attrs(build).get("version")) != build_number:
            continue
        train_id = _relationship_id(build, "preReleaseVersion")
        if _attrs(included.get(train_id) or {}).get("version") == version:
            matches.append(build)
    return _one(matches, "BUILD")


def _get_build(client: AscClient, app_id: str, version: str, build_number: str) -> dict:
    build = _find_build(client, app_id, version, build_number)
    if _attrs(build).get("processingState") != "VALID":
        raise SubmissionError(f"BLOCKED_BUILD_STATE: selected build {version} ({build_number}) is not VALID")
    expiration = _attrs(build).get("expirationDate")
    if not expiration:
        raise SubmissionError("BLOCKED_BUILD_EXPIRATION: selected build has no verifiable expiration date")
    try:
        expires_at = datetime.fromisoformat(expiration.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        raise SubmissionError("BLOCKED_BUILD_EXPIRATION: selected build expiration date is invalid") from None
    if expires_at <= datetime.now(timezone.utc):
        raise SubmissionError("BLOCKED_BUILD_EXPIRATION: selected build has expired")
    return build


def _current_released_version(client: AscClient, app_id: str) -> tuple[int, ...] | None:
    params = {
        "filter[platform]": "IOS",
        "filter[appStoreState]": "READY_FOR_SALE",
        "fields[appStoreVersions]": "versionString,appStoreState",
        "limit": "200",
    }
    releases = client.pages(f"/apps/{app_id}/appStoreVersions" + _query(params))
    versions: list[tuple[int, ...]] = []
    for item in releases:
        version = _attrs(item).get("versionString")
        normalized = _live_version_tuple(version) if isinstance(version, str) else None
        if normalized is not None:
            versions.append(normalized)
    return max(versions) if versions else None


def _review_submission_items(client: AscClient, submission_id: str) -> list[dict]:
    if not isinstance(submission_id, str) or not submission_id.strip():
        raise SubmissionError("BLOCKED_REVIEW_SUBMISSION: existing submission id is missing")
    items = client.pages(
        f"/reviewSubmissions/{submission_id}/items"
        + _query({"include": "appStoreVersion", "fields[reviewSubmissionItems]": "appStoreVersion", "limit": "200"})
    )
    for item in items:
        if (item.get("type") != "reviewSubmissionItems"
                or not isinstance(item.get("id"), str) or not item["id"].strip()
                or not isinstance(_relationship_id(item, "appStoreVersion"), str)
                or not _relationship_id(item, "appStoreVersion").strip()):
            raise SubmissionError("BLOCKED_REVIEW_SUBMISSION: item relationship data is missing or malformed")
    return items


def _review_submission(client: AscClient, app_id: str, version_id: str, *, dry_run: bool) -> str | None:
    submissions = client.pages(f"/apps/{app_id}/reviewSubmissions" + _query({"limit": "200"}))
    for submission in submissions:
        state = _attrs(submission).get("state")
        if state not in REVIEW_SUBMISSION_STATES:
            raise SubmissionError(f"BLOCKED_REVIEW_SUBMISSION_STATE: unknown ReviewSubmission state {state or 'missing'}")
        if state == "COMPLETE":
            continue
        if state != "READY_FOR_REVIEW":
            raise SubmissionError(f"BLOCKED_REVIEW_SUBMISSION_STATE: existing submission state {state} requires manual resolution")
        sid = submission.get("id")
        items = _review_submission_items(client, sid)
        version_items = [i for i in items if _relationship_id(i, "appStoreVersion") == version_id]
        foreign_items = [i for i in items if _relationship_id(i, "appStoreVersion") != version_id]
        if foreign_items:
            raise SubmissionError("BLOCKED_REVIEW_SUBMISSION: an editable submission contains unrelated items")
        if not items:
            # Preserve an empty pre-existing draft. Never adopt or mutate it.
            continue
        if len(version_items) != 1:
            raise SubmissionError("BLOCKED_REVIEW_SUBMISSION: only an existing READY_FOR_REVIEW submission containing exactly the target may be reused")
        return sid
    if dry_run:
        return None
    created = client.request("POST", "/reviewSubmissions", {
        "data": {
            "type": "reviewSubmissions",
            "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    })
    sid = (created.get("data") or {}).get("id")
    if not sid:
        raise SubmissionError("BLOCKED_REVIEW_SUBMISSION: create response omitted its id")
    return sid


def _assert_no_foreign_active_submissions(client: AscClient, app_id: str, target_version_id: str | None) -> None:
    active_states = {"WAITING_FOR_REVIEW", "IN_REVIEW"}
    submissions = client.pages(f"/apps/{app_id}/reviewSubmissions?limit=200")
    for submission in submissions:
        state = _attrs(submission).get("state")
        if state not in REVIEW_SUBMISSION_STATES:
            raise SubmissionError(f"BLOCKED_REVIEW_SUBMISSION_STATE: unknown ReviewSubmission state {state or 'missing'}")
        if state == "COMPLETE":
            continue
        sid = submission.get("id")
        items = _review_submission_items(client, sid)
        if state == "READY_FOR_REVIEW" and not items:
            # Leave a blank editable draft untouched; a new version gets its own submission.
            continue
        if target_version_id is None:
            if state in active_states:
                raise SubmissionError("BLOCKED_ACTIVE_SUBMISSION: another review is already in progress")
            raise SubmissionError(f"BLOCKED_REVIEW_SUBMISSION_STATE: existing {state} submission cannot be adopted for a new version")
        if state in {"CANCELING", "COMPLETING", "UNRESOLVED_ISSUES"}:
            raise SubmissionError(f"BLOCKED_REVIEW_SUBMISSION_STATE: existing {state} submission requires manual resolution")
        if (target_version_id and len(items) == 1
                and _relationship_id(items[0], "appStoreVersion") == target_version_id):
            if state in active_states:
                continue
            if state == "READY_FOR_REVIEW":
                continue
        code = "BLOCKED_ACTIVE_SUBMISSION" if state in active_states else "BLOCKED_REVIEW_SUBMISSION"
        raise SubmissionError(f"{code}: existing submission is unrelated or cannot be reused")


def _assert_marketing_url_readback(client: AscClient, version_id: str, expected_url: str) -> None:
    localizations = client.pages(
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations"
        + _query({"fields[appStoreVersionLocalizations]": "locale,marketingUrl", "limit": "200"})
    )
    if not localizations:
        raise SubmissionError("BLOCKED_MARKETING_URL_READBACK: no version localizations returned")
    for localization in localizations:
        attrs = _attrs(localization)
        locale = attrs.get("locale")
        if not isinstance(locale, str) or str(attrs.get("marketingUrl") or "").strip() != expected_url:
            raise SubmissionError(
                f"BLOCKED_MARKETING_URL_READBACK: expected marketing URL is missing or mismatched for {locale or 'unknown locale'}"
            )


def _plan_replacement(client: AscClient, app_id: str, version: dict | None, version_string: str,
                      new_build: dict, old_build_number: str) -> dict:
    """Read-only proof that the old active submission can be canceled and replaced.

    Every precondition is checked against freshly fetched App Store Connect
    state. There is no generic force flag: any mismatch fails closed before
    the cancellation mutation happens.
    """
    new_build_number = str(_attrs(new_build).get("version"))
    if new_build_number == old_build_number or int(new_build_number) <= int(old_build_number):
        raise SubmissionError(
            f"BLOCKED_REPLACE_BUILD: replacement build {new_build_number} must be greater than old build {old_build_number}")
    if version is None or not version.get("id"):
        raise SubmissionError("BLOCKED_REPLACE_TARGET: the App Store version for the old submission does not exist")
    version_id = version.get("id")
    version_state = _attrs(version).get("appStoreState")
    if version_state == "READY_FOR_SALE":
        raise SubmissionError("BLOCKED_VERSION_LIVE: this version is already released; create a new marketing version")
    if version_state not in ACTIVE_VERSION_STATES:
        raise SubmissionError(
            f"BLOCKED_REPLACE_TARGET: version state {version_state or 'unknown'} is not in an active review; "
            "replacement does not apply")
    try:
        old_build = _find_build(client, app_id, version_string, old_build_number)
    except SubmissionError as error:
        raise SubmissionError(f"BLOCKED_REPLACE_OLD_BUILD: {error}") from None
    linked = client.request("GET", f"/appStoreVersions/{version_id}/relationships/build")
    linked_build_id = (linked.get("data") or {}).get("id")
    if linked_build_id != old_build.get("id"):
        raise SubmissionError(
            f"BLOCKED_REPLACE_VERSION_BUILD: version {version_string} is linked to build id {linked_build_id or 'unknown'}, "
            f"not old build {old_build_number}")
    submissions = client.pages(f"/apps/{app_id}/reviewSubmissions" + _query({"limit": "200"}))
    active: list[tuple[dict, str]] = []
    for submission in submissions:
        state = _attrs(submission).get("state")
        if state not in REVIEW_SUBMISSION_STATES:
            raise SubmissionError(f"BLOCKED_REVIEW_SUBMISSION_STATE: unknown ReviewSubmission state {state or 'missing'}")
        if state == "COMPLETE":
            continue
        active.append((submission, state))
    if not active:
        raise SubmissionError(
            "BLOCKED_REPLACE_NO_ACTIVE: no active review submission to replace; if this version was already approved, "
            "create a new marketing version")
    if len(active) > 1:
        raise SubmissionError(
            f"BLOCKED_REPLACE_MULTIPLE: expected exactly one active review submission, found {len(active)}")
    submission, submission_state = active[0]
    if submission_state not in CANCELABLE_SUBMISSION_STATES:
        raise SubmissionError(
            f"BLOCKED_REPLACE_STATE: existing submission state {submission_state} is not cancelable; resolve it manually")
    submission_id = submission.get("id")
    items = _review_submission_items(client, submission_id)
    if not items:
        raise SubmissionError(
            "BLOCKED_REPLACE_ITEMS: the active submission has no version items; it cannot be proven to be this version's submission")
    foreign = [i for i in items if _relationship_id(i, "appStoreVersion") != version_id]
    if foreign:
        raise SubmissionError("BLOCKED_REPLACE_ITEMS: the active submission contains items unrelated to the target version")
    return {
        "old_build": old_build_number,
        "old_build_id": old_build.get("id"),
        "new_build": new_build_number,
        "version": version_string,
        "version_id": version_id,
        "version_state": version_state,
        "submission_id": submission_id,
        "submission_state": submission_state,
    }


def _cancel_and_wait(client: AscClient, plan: dict, *, sleep: Callable[[float], None] = time.sleep,
                     max_polls: int = REPLACE_MAX_POLLS,
                     poll_interval: float = REPLACE_POLL_INTERVAL_SECONDS) -> dict:
    submission_id = plan["submission_id"]
    client.request("PATCH", f"/reviewSubmissions/{submission_id}", {
        "data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"canceled": True}}
    })
    version_state = None
    submission_state = None
    for attempt in range(max_polls):
        if attempt:
            sleep(poll_interval)
        version_doc = client.request(
            "GET", f"/appStoreVersions/{plan['version_id']}?fields[appStoreVersions]=versionString,appStoreState")
        version_state = _attrs(version_doc.get("data") or {}).get("appStoreState")
        submission_doc = client.request(
            "GET", f"/reviewSubmissions/{submission_id}?fields[reviewSubmissions]=state")
        submission_state = _attrs(submission_doc.get("data") or {}).get("state")
        if submission_state not in REVIEW_SUBMISSION_STATES:
            raise SubmissionError(
                f"BLOCKED_REPLACE_POLL: unknown ReviewSubmission state {submission_state or 'missing'} while waiting for the cancellation")
        if submission_state == "COMPLETE" and version_state in EDITABLE_VERSION_STATES:
            return {**plan, "canceled": True, "submission_state": submission_state, "version_state": version_state}
    raise SubmissionError(
        "REPLACE_CANCEL_UNCONFIRMED: Apple did not confirm the cancellation within the bounded wait "
        f"(submission={submission_state or 'unknown'}, version={version_state or 'unknown'}); "
        "the new build was not attached and no resubmission happened")


def _replacement_report(marker: str, plan: dict, writes: int, **extra: Any) -> str:
    payload = {
        "marker": marker,
        "version": plan.get("version"),
        "old_build": plan.get("old_build"),
        "new_build": plan.get("new_build"),
        "submission_id": plan.get("submission_id"),
        "submission_state": plan.get("submission_state"),
        "version_state": plan.get("version_state"),
        "writes": writes,
    }
    payload.update(extra)
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


def submit(client: AscClient, bundle_id: str, version_string: str, build_number: str, *, whats_new: dict[str, str] | None = None, marketing_url: str | None = None, dry_run: bool = False,
           replace_existing_build: str | None = None, replace_confirm: str | None = None,
           sleep: Callable[[float], None] = time.sleep, max_polls: int = MAX_POLLS,
           replace_max_polls: int = REPLACE_MAX_POLLS,
           replace_poll_interval: float = REPLACE_POLL_INTERVAL_SECONDS) -> dict:
    target_version = _version_tuple(version_string)
    if not re.fullmatch(r"[1-9][0-9]{0,9}", build_number):
        raise SubmissionError("BLOCKED_INPUT: build number must be 1 to 10 digits without leading zeroes")
    if replace_existing_build is not None and not re.fullmatch(r"[1-9][0-9]{0,9}", replace_existing_build):
        raise SubmissionError("BLOCKED_INPUT: replace-existing-build must be 1 to 10 digits without leading zeroes")
    apps = client.pages("/apps" + _query({"filter[bundleId]": bundle_id, "limit": "200"}))
    app = _one([a for a in apps if _attrs(a).get("bundleId") == bundle_id], "APP")
    app_id = app.get("id")
    builds = _get_build(client, app_id, version_string, build_number)
    version = _find_version(client, app_id, version_string)
    replace_plan: dict | None = None
    if replace_existing_build is not None:
        replace_plan = _plan_replacement(client, app_id, version, version_string, builds, replace_existing_build)
        if dry_run or replace_confirm != REPLACE_CONFIRMATION_PHRASE:
            confirmed = replace_confirm == REPLACE_CONFIRMATION_PHRASE and not dry_run
            print(_replacement_report("REPLACE_VERIFIED", replace_plan, client.writes, confirmed=confirmed))
            return {"marker": "REPLACE_VERIFIED", "replace": replace_plan, "confirmed": confirmed, "writes": client.writes}
        replace_plan = _cancel_and_wait(client, replace_plan, sleep=sleep, max_polls=replace_max_polls,
                                        poll_interval=replace_poll_interval)
        print(_replacement_report("REPLACE_CANCELED", replace_plan, client.writes))
        version = _find_version(client, app_id, version_string)
        if version is None:
            raise SubmissionError("BLOCKED_REPLACE_TARGET: target App Store version disappeared after cancellation")
    _assert_no_foreign_active_submissions(client, app_id, version.get("id") if version else None)
    current_live = _current_released_version(client, app_id)

    if version is None:
        if current_live is not None and target_version <= current_live:
            raise SubmissionError("BLOCKED_VERSION_LIVE: target is not newer than the released App Store version; create a new marketing version")
        if dry_run:
            version_id = None
            version_state = "WOULD_CREATE"
        else:
            created = client.request("POST", "/appStoreVersions", {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {"platform": "IOS", "versionString": version_string},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            })
            version = created.get("data") or {}
            version_id = version.get("id")
            version_state = _attrs(version).get("appStoreState")
            if not version_id:
                raise SubmissionError("BLOCKED_VERSION_CREATE: create response omitted its id")
    else:
        version_id = version.get("id")
        version_state = _attrs(version).get("appStoreState")
        if version_state == "READY_FOR_SALE":
            raise SubmissionError("BLOCKED_VERSION_LIVE: this version is already released; create a new marketing version")
        if version_state in ACTIVE_VERSION_STATES:
            relationship = client.request("GET", f"/appStoreVersions/{version_id}/relationships/build")
            active_build = (relationship.get("data") or {}).get("id")
            current_doc = client.request("GET", f"/appStoreVersions/{version_id}?fields[appStoreVersions]=versionString,appStoreState,releaseType")
            current_attrs = _attrs(current_doc.get("data") or {})
            state = version_state
            if (active_build != builds.get("id")
                    or current_attrs.get("versionString") != version_string
                    or current_attrs.get("releaseType") != "AFTER_APPROVAL"):
                raise SubmissionError(f"BLOCKED_ACTIVE_SUBMISSION: version is {state} with a different build or release option")
            if marketing_url is not None:
                _assert_marketing_url_readback(client, version_id, marketing_url)
            print_state = state
            print(f"APP_STORE_SUBMITTED: PASS version={version_string} build={build_number} state={print_state}")
            return {"marker": "APP_STORE_SUBMITTED", "state": print_state, "version": version_string, "build": build_number, "idempotent": True}
        if version_state not in EDITABLE_VERSION_STATES:
            raise SubmissionError(f"BLOCKED_VERSION_STATE: version state {version_state or 'unknown'} is not editable")

    if version_id is None:
        print(f"DRY_RUN_PLAN: create version {version_string}, bind build {build_number}, release after approval, submit for review; METADATA=DEFERRED_UNTIL_VERSION_EXISTS")
        return {"marker": "DRY_RUN_PLAN_ONLY", "version": version_string, "build": build_number, "writes": client.writes}

    # Read state and metadata before mutation. Never invent or overwrite review notes.
    detail = client.request("GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail?fields[appStoreReviewDetails]=demoAccountRequired,demoAccountName,demoAccountPassword,contactFirstName,contactLastName,contactPhone,contactEmail,notes")
    detail_data = detail.get("data") or {}
    detail_id = detail_data.get("id")
    attrs = _attrs(detail_data)
    if not detail_id:
        raise SubmissionError("BLOCKED_REVIEW_METADATA: review details are missing; complete App Store Connect review information")
    required = ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")
    missing = [name for name in required if not str(attrs.get(name) or "").strip()]
    if attrs.get("demoAccountRequired") is True:
        for credential in ("demoAccountName", "demoAccountPassword"):
            if not str(attrs.get(credential) or "").strip():
                missing.append(credential)
    if missing:
        raise SubmissionError("BLOCKED_REVIEW_METADATA: fill required App Store Connect review fields: " + ", ".join(missing))

    localization_params = {
        "fields[appStoreVersionLocalizations]": "locale,description,keywords,supportUrl,whatsNew,marketingUrl",
        "limit": "200",
    }
    localizations = client.pages(
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations" + _query(localization_params)
    )
    if not localizations:
        raise SubmissionError("BLOCKED_STORE_METADATA: no App Store version localization exists; complete the App Store product page")
    if not isinstance(whats_new, dict) or whats_new.get("version") != version_string or not isinstance(whats_new.get("localizations"), dict):
        raise SubmissionError("BLOCKED_RELEASE_NOTES: provide version-matched localized release notes")
    notes_by_locale = whats_new["localizations"]
    if marketing_url is not None and (not isinstance(marketing_url, str)
            or not re.fullmatch(r"https://[^\s]+", marketing_url)):
        raise SubmissionError("BLOCKED_STORE_METADATA: marketing URL must be an HTTPS URL")
    missing_localizations = []
    note_updates: list[tuple[str, str]] = []
    metadata_updates: list[tuple[str, dict[str, str]]] = []
    observed_locales: set[str] = set()
    for localization in localizations:
        localization_attrs = _attrs(localization)
        locale = localization_attrs.get("locale")
        if not isinstance(locale, str):
            raise SubmissionError("BLOCKED_STORE_METADATA: localization has no locale")
        observed_locales.add(locale)
        absent = [field for field in ("description", "keywords", "supportUrl")
                  if not str(localization_attrs.get(field) or "").strip()]
        if absent:
            missing_localizations.append(f"{locale}: {', '.join(absent)}")
        note = notes_by_locale.get(locale)
        if not isinstance(note, str) or not note.strip():
            raise SubmissionError(f"BLOCKED_RELEASE_NOTES: provide non-empty release notes for locale {locale}")
        existing_note = str(localization_attrs.get("whatsNew") or "").strip()
        if existing_note and existing_note != note.strip():
            raise SubmissionError(f"BLOCKED_RELEASE_NOTES_MISMATCH: {locale} already has different release notes; refusing to overwrite")
        if not existing_note:
            note_updates.append((localization.get("id"), note.strip()))
        if marketing_url is not None:
            existing_marketing_url = str(localization_attrs.get("marketingUrl") or "").strip()
            if existing_marketing_url and existing_marketing_url != marketing_url:
                raise SubmissionError(f"BLOCKED_MARKETING_URL_MISMATCH: {locale} already has a different marketing URL; refusing to overwrite")
            if not existing_marketing_url:
                metadata_updates.append((localization.get("id"), {"marketingUrl": marketing_url}))
    if set(notes_by_locale) != observed_locales:
        raise SubmissionError("BLOCKED_RELEASE_NOTES: release-notes locales must exactly match App Store localizations")
    if missing_localizations:
        raise SubmissionError("BLOCKED_STORE_METADATA: complete required localized fields: " + "; ".join(missing_localizations))

    # Inspect editable submission contents before binding or changing release options.
    _review_submission(client, app_id, version_id, dry_run=True)

    # Detect already-live exact target and active submissions before attempting writes.
    current = client.request("GET", f"/appStoreVersions/{version_id}/relationships/build")
    current_build_id = ((current.get("data") or {}).get("id"))
    if dry_run:
        print(f"DRY_RUN_PLAN: version={version_string} state={version_state} currentBuild={'same' if current_build_id == builds.get('id') else 'different'} targetBuild={build_number} releaseOption=AFTER_APPROVAL metadataUpdates={len(note_updates) + len(metadata_updates)}")
        return {"marker": "DRY_RUN_PASS", "version": version_string, "build": build_number, "writes": client.writes}

    for localization_id, note in note_updates:
        if not localization_id:
            raise SubmissionError("BLOCKED_RELEASE_NOTES: localization id is missing")
        client.request("PATCH", f"/appStoreVersionLocalizations/{localization_id}", {
            "data": {"type": "appStoreVersionLocalizations", "id": localization_id,
                     "attributes": {"whatsNew": note}}
        })
    for localization_id, attributes in metadata_updates:
        if not localization_id:
            raise SubmissionError("BLOCKED_STORE_METADATA: localization id is missing")
        client.request("PATCH", f"/appStoreVersionLocalizations/{localization_id}", {
            "data": {"type": "appStoreVersionLocalizations", "id": localization_id,
                     "attributes": attributes}
        })

    if current_build_id != builds.get("id"):
        client.request("PATCH", f"/appStoreVersions/{version_id}/relationships/build", {
            "data": {"type": "builds", "id": builds.get("id")}
        })
    client.request("PATCH", f"/appStoreVersions/{version_id}", {
        "data": {"type": "appStoreVersions", "id": version_id,
                 "attributes": {"releaseType": "AFTER_APPROVAL"}}
    })

    submission_id = _review_submission(client, app_id, version_id, dry_run=False)
    assert submission_id
    items = _review_submission_items(client, submission_id)
    exact = [i for i in items if _relationship_id(i, "appStoreVersion") == version_id]
    foreign = [i for i in items if _relationship_id(i, "appStoreVersion") != version_id]
    if foreign:
        raise SubmissionError("BLOCKED_REVIEW_SUBMISSION: submission contains unrelated items")
    if not exact:
        client.request("POST", "/reviewSubmissionItems", {
            "data": {"type": "reviewSubmissionItems", "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
            }}
        })
    # The same editable submission may be retried safely. Only submit once it has the exact target item.
    client.request("PATCH", f"/reviewSubmissions/{submission_id}", {
        "data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}
    })

    observed = None
    for attempt in range(max_polls):
        if attempt:
            sleep(2)
        doc = client.request("GET", f"/appStoreVersions/{version_id}?fields[appStoreVersions]=versionString,appStoreState,releaseType")
        data = doc.get("data") or {}
        observed = _attrs(data).get("appStoreState")
        exact_version = _attrs(data).get("versionString") == version_string
        relationship = client.request("GET", f"/appStoreVersions/{version_id}/relationships/build")
        exact_build = ((relationship.get("data") or {}).get("id")) == builds.get("id")
        if (exact_version and exact_build and observed in ACCEPTED_SUBMISSION_STATES
                and _attrs(data).get("releaseType") == "AFTER_APPROVAL"):
            print(f"APP_STORE_SUBMITTED: PASS version={version_string} build={build_number} state={observed}")
            result = {"marker": "APP_STORE_SUBMITTED", "state": observed, "version": version_string, "build": build_number, "idempotent": False}
            if replace_plan:
                result["replace"] = {key: replace_plan.get(key) for key in ("old_build", "new_build", "submission_id", "version_state")}
            return result
    raise SubmissionError(f"SUBMIT_UNCONFIRMED: Apple did not confirm exact version/build in an accepted state (observed={observed or 'unknown'})")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True, help="Exact App Store marketing version, X.Y.Z")
    parser.add_argument("--build", required=True, help="Exact valid App Store Connect build number")
    parser.add_argument("--whats-new-file", required=True, help="Version-bound JSON release notes by locale")
    parser.add_argument("--marketing-url", help="HTTPS marketing URL to set on each App Store localization")
    parser.add_argument("--dry-run", action="store_true", help="Read-only validation and plan")
    parser.add_argument("--replace-existing-build",
                        help="Opt-in: old build number currently attached to the active review of this exact "
                             "version; its submission is verified, then canceled so the new build can be submitted")
    parser.add_argument("--confirm-replace", default=None,
                        help=f"Real cancellation requires exactly {REPLACE_CONFIRMATION_PHRASE}; any other value "
                             "keeps the run verification-only with zero mutations")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        helpers = _load_helpers()
        credentials = argparse.Namespace(key_id=None, issuer_id=None, private_key_path=None, private_key_base64=None)
        key_id, issuer_id, private_key = helpers.resolve_credentials(credentials)
        token = helpers.make_token(private_key, key_id, issuer_id)
        try:
            with open(args.whats_new_file, "r", encoding="utf-8") as handle:
                notes_doc = json.load(handle)
        except (OSError, json.JSONDecodeError):
            raise SubmissionError("BLOCKED_RELEASE_NOTES: version-bound release-notes JSON could not be read") from None
        notes = {"version": notes_doc.get("version"), "localizations": notes_doc.get("whatsNew")}
        result = submit(AscClient(token), args.bundle_id, args.version, args.build, whats_new=notes,
                        marketing_url=args.marketing_url, dry_run=args.dry_run,
                        replace_existing_build=args.replace_existing_build, replace_confirm=args.confirm_replace)
        if args.dry_run:
            suffix = " METADATA=DEFERRED" if result.get("marker") == "DRY_RUN_PLAN_ONLY" else ""
            print(f"DRY_RUN=PASS{suffix}")
        return 0 if result.get("marker") in {"APP_STORE_SUBMITTED", "DRY_RUN_PASS", "DRY_RUN_PLAN_ONLY", "REPLACE_VERIFIED"} else 1
    except SubmissionError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception as error:  # fail closed and never reveal request/token details
        sanitized = _load_helpers().redact(str(error))[:180]
        print(f"BLOCKED_ASC_SUBMISSION: request could not be completed ({sanitized})", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
