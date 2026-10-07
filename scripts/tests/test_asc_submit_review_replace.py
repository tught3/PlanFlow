"""Opt-in review-submission replacement tests for exact App Store submission.

Covers the --replace-existing-build flow: fresh-state verification with zero
mutations until the explicit confirmation phrase, the bounded cancel wait, and
the normal attach + submit path afterwards.
"""

import importlib.util
import json
import pathlib
import unittest
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "asc_submit_review_replace_target", ROOT / "scripts" / "asc-submit-review.py")
asc = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(asc)

APP_ID = "app1"
VERSION_ID = "v1"
VERSION = "1.1.7"
OLD_BUILD = "193"
NEW_BUILD = "195"
OLD_BUILD_ID = "b193"
NEW_BUILD_ID = "b195"
SUBMISSION_ID = "s1"
DRAFT_ID = "s-blank"
CONFIRM = "REPLACE_PLANFLOW_IOS_REVIEW"


def build_resource(build_id: str, number: str, processing_state: str = "VALID") -> dict:
    return {"type": "builds", "id": build_id, "attributes": {
        "version": number, "processingState": processing_state,
        "expirationDate": (datetime.now(timezone.utc) + timedelta(days=30)).isoformat()},
        "relationships": {"preReleaseVersion": {"data": {"id": "pr1"}}}}


def version_item(item_id: str = "i1", version_id: str = VERSION_ID) -> dict:
    return {"type": "reviewSubmissionItems", "id": item_id, "relationships": {
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}


class ReplacementAsc:
    """Fake ASC covering an active WAITING_FOR_REVIEW review of 1.1.7 (193)."""

    def __init__(self, *, version_state="WAITING_FOR_REVIEW", linked_build=OLD_BUILD_ID,
                 submission_state="WAITING_FOR_REVIEW", items=None, new_build_state="VALID",
                 submissions=None, cancel_completes_after=2, live_version="1.1.2",
                 items_by_submission=None, items_error=None, items_malformed=False):
        self.app = {"type": "apps", "id": APP_ID, "attributes": {"bundleId": "com.example.app"}}
        self.live_version = live_version
        self.version = {"type": "appStoreVersions", "id": VERSION_ID, "attributes": {
            "versionString": VERSION, "appStoreState": version_state, "releaseType": "AFTER_APPROVAL"}}
        self.linked_build = linked_build
        self.builds = {OLD_BUILD_ID: build_resource(OLD_BUILD_ID, OLD_BUILD),
                       NEW_BUILD_ID: build_resource(NEW_BUILD_ID, NEW_BUILD, new_build_state)}
        self.included = [{"type": "preReleaseVersions", "id": "pr1", "attributes": {"version": VERSION}}]
        if submissions is None:
            self.submissions = [{"type": "reviewSubmissions", "id": SUBMISSION_ID,
                                 "attributes": {"state": submission_state}}]
        else:
            self.submissions = submissions
        self.items = list(items) if items is not None else [version_item()]
        self.items_by_submission = dict(items_by_submission) if items_by_submission is not None else None
        self.items_error = items_error
        self.items_malformed = items_malformed
        self.localization = {"type": "appStoreVersionLocalizations", "id": "l1", "attributes": {
            "locale": "ko", "description": "desc", "keywords": "kw", "supportUrl": "https://example.com",
            "whatsNew": None, "marketingUrl": None}}
        self.cancel_completes_after = cancel_completes_after
        self.cancel_polls = 0
        self.writes = []        # (method, route)
        self.write_bodies = []  # (method, route, body)

    def writes_on(self, route: str) -> list[dict]:
        return [body for method, item_route, body in self.write_bodies if item_route == route]

    def _write(self, method: str, route: str, body) -> None:
        self.writes.append((method, route))
        self.write_bodies.append((method, route, body))

    def __call__(self, method: str, path: str, body) -> dict:
        parsed = urlsplit(path)
        route, query = parsed.path, parse_qs(parsed.query)
        if method == "GET" and route == "/apps":
            return {"data": [self.app]}
        if method == "GET" and route == "/builds":
            wanted = (query.get("filter[version]") or [None])[0]
            matched = [b for b in self.builds.values()
                       if b["attributes"]["version"] == wanted] if wanted else list(self.builds.values())
            return {"data": matched, "included": self.included}
        if method == "GET" and route == f"/apps/{APP_ID}/appStoreVersions":
            if query.get("filter[appStoreState]") == ["READY_FOR_SALE"]:
                return {"data": [{"attributes": {"versionString": self.live_version,
                                                 "appStoreState": "READY_FOR_SALE"}}] if self.live_version else []}
            wanted = (query.get("filter[versionString]") or [None])[0]
            return {"data": [self.version]
                    if self.version and wanted == self.version["attributes"]["versionString"] else []}
        if method == "GET" and route == f"/appStoreVersions/{VERSION_ID}/relationships/build":
            return {"data": {"type": "builds", "id": self.linked_build}}
        if method == "PATCH" and route == f"/appStoreVersions/{VERSION_ID}/relationships/build":
            self._write(method, route, body)
            self.linked_build = body["data"]["id"]
            return {"data": body["data"]}
        if method == "PATCH" and route == f"/appStoreVersions/{VERSION_ID}":
            self._write(method, route, body)
            self.version["attributes"].update(body["data"]["attributes"])
            return {"data": self.version}
        if method == "GET" and route == f"/appStoreVersions/{VERSION_ID}":
            return {"data": self.version}
        if method == "GET" and route == f"/apps/{APP_ID}/reviewSubmissions":
            return {"data": self.submissions}
        if method == "POST" and route == "/reviewSubmissions":
            self._write(method, route, body)
            submission = {"type": "reviewSubmissions", "id": f"s{len(self.submissions) + 1}",
                          "attributes": {"state": "READY_FOR_REVIEW"}}
            self.submissions.append(submission)
            return {"data": submission}
        if method == "GET" and route.startswith("/reviewSubmissions/") and route.endswith("/items"):
            if self.items_error is not None:
                raise self.items_error
            if self.items_malformed:
                return {"errors": [{"status": "500", "title": "fixture items read failure"}]}
            sid = route.split("/")[2]
            if self.items_by_submission is not None:
                return {"data": list(self.items_by_submission.get(sid, []))}
            return {"data": self.items}
        if method == "GET" and route.startswith("/reviewSubmissions/"):
            submission = next(s for s in self.submissions if s["id"] == route.split("/")[2])
            if (submission["attributes"]["state"] == "CANCELING"
                    and self.cancel_completes_after is not None):
                self.cancel_polls += 1
                if self.cancel_polls >= self.cancel_completes_after:
                    submission["attributes"]["state"] = "COMPLETE"
                    self.version["attributes"]["appStoreState"] = "DEVELOPER_REJECTED"
            return {"data": submission}
        if method == "PATCH" and route.startswith("/reviewSubmissions/"):
            self._write(method, route, body)
            submission = next(s for s in self.submissions if s["id"] == route.split("/")[2])
            attributes = (body.get("data") or {}).get("attributes") or {}
            if attributes.get("canceled") is True:
                submission["attributes"]["state"] = "CANCELING"
                self.cancel_polls = 0
            elif attributes.get("submitted") is True:
                submission["attributes"]["state"] = "WAITING_FOR_REVIEW"
                self.version["attributes"]["appStoreState"] = "WAITING_FOR_REVIEW"
            return {"data": submission}
        if method == "POST" and route == "/reviewSubmissionItems":
            self._write(method, route, body)
            item = {"type": "reviewSubmissionItems", "id": f"i{len(self.items) + 1}",
                    "relationships": body["data"]["relationships"]}
            self.items.append(item)
            if self.items_by_submission is not None:
                relationships = ((body.get("data") or {}).get("relationships") or {})
                submitted_sid = ((relationships.get("reviewSubmission") or {}).get("data") or {}).get("id")
                self.items_by_submission.setdefault(submitted_sid, []).append(item)
            return {"data": item}
        if method == "GET" and route == f"/appStoreVersions/{VERSION_ID}/appStoreReviewDetail":
            return {"data": {"type": "appStoreReviewDetails", "id": "detail1", "attributes": {
                "demoAccountRequired": False, "contactFirstName": "A", "contactLastName": "B",
                "contactPhone": "01000000000", "contactEmail": "support@example.com", "notes": "Keep existing"}}}
        if method == "GET" and route == f"/appStoreVersions/{VERSION_ID}/appStoreVersionLocalizations":
            return {"data": [self.localization]}
        if method == "PATCH" and route == "/appStoreVersionLocalizations/l1":
            self._write(method, route, body)
            self.localization["attributes"].update(body["data"]["attributes"])
            return {"data": self.localization}
        raise AssertionError(f"unexpected fake ASC request {method} {path}")


class ReplacementTestBase(unittest.TestCase):
    def run_submit(self, fake, *, version=VERSION, build=NEW_BUILD, dry_run=False,
                   replace=None, confirm=None, **kwargs):
        client = asc.AscClient("fixture-token", fake)
        notes = {"version": version, "localizations": {"ko": "fixture release notes"}}
        result = asc.submit(client, "com.example.app", version, build, whats_new=notes,
                            marketing_url="https://fluxstudio.co.kr", dry_run=dry_run,
                            replace_existing_build=replace, replace_confirm=confirm,
                            sleep=lambda _: None, max_polls=1, **kwargs)
        return client, result


class ReplaceVerificationTests(ReplacementTestBase):
    def test_dry_run_replacement_performs_zero_mutations(self):
        fake = ReplacementAsc()
        client, result = self.run_submit(fake, dry_run=True, replace=OLD_BUILD, confirm=CONFIRM)
        self.assertEqual(result["marker"], "REPLACE_VERIFIED")
        self.assertFalse(result["confirmed"])
        self.assertEqual(result["writes"], 0)
        self.assertEqual(client.writes, 0)
        self.assertEqual(fake.writes, [])

    def test_unconfirmed_real_run_verifies_only_without_cancel(self):
        fake = ReplacementAsc()
        client, result = self.run_submit(fake, replace=OLD_BUILD, confirm=None)
        self.assertEqual(result["marker"], "REPLACE_VERIFIED")
        self.assertFalse(result["confirmed"])
        self.assertEqual(client.writes, 0)
        self.assertEqual(fake.writes, [])
        self.assertFalse(any(route.startswith("/reviewSubmissions/") for _, route in fake.writes))

    def test_wrong_confirm_phrase_never_cancels(self):
        fake = ReplacementAsc()
        client, result = self.run_submit(fake, replace=OLD_BUILD, confirm="yes-replace")
        self.assertEqual(result["marker"], "REPLACE_VERIFIED")
        self.assertFalse(result["confirmed"])
        self.assertEqual(client.writes, 0)
        self.assertEqual(fake.writes, [])

    def test_old_build_mismatch_fails_without_cancel(self):
        fake = ReplacementAsc(linked_build=NEW_BUILD_ID)
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_VERSION_BUILD"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_unknown_old_build_fails_without_cancel(self):
        fake = ReplacementAsc()
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_OLD_BUILD"):
            self.run_submit(fake, replace="194")
        self.assertEqual(fake.writes, [])

    def test_unrelated_submission_items_fail_without_cancel(self):
        fake = ReplacementAsc(items=[version_item("i1"), version_item("i2", "other-version")])
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_ITEMS"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_unknown_item_relationship_fails_without_cancel(self):
        fake = ReplacementAsc(items=[{"type": "reviewSubmissionItems", "id": "i1", "relationships": {}}])
        with self.assertRaisesRegex(asc.SubmissionError, "relationship data is missing"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_non_valid_new_build_fails_before_any_cancel(self):
        fake = ReplacementAsc(new_build_state="IN_PROCESS")
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_BUILD_STATE"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_multiple_active_submissions_fail_without_cancel(self):
        submissions = [
            {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "WAITING_FOR_REVIEW"}},
            {"type": "reviewSubmissions", "id": "s2", "attributes": {"state": "IN_REVIEW"}},
        ]
        fake = ReplacementAsc(submissions=submissions)
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_MULTIPLE"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_no_active_submission_requires_new_marketing_version(self):
        submissions = [{"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "COMPLETE"}}]
        fake = ReplacementAsc(submissions=submissions, version_state="PENDING_DEVELOPER_RELEASE")
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_NO_ACTIVE"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_published_version_refuses_replacement(self):
        fake = ReplacementAsc(version_state="READY_FOR_SALE")
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_VERSION_LIVE"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_non_cancelable_submission_state_requires_manual_resolution(self):
        fake = ReplacementAsc(submission_state="UNRESOLVED_ISSUES")
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_STATE"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_replacement_build_must_differ_and_be_greater_than_old(self):
        for build, old in ((OLD_BUILD, OLD_BUILD), (OLD_BUILD, NEW_BUILD)):
            with self.subTest(build=build, old=old):
                fake = ReplacementAsc()
                with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_BUILD"):
                    self.run_submit(fake, build=build, replace=old)
                self.assertEqual(fake.writes, [])


class ReplaceExecutionTests(ReplacementTestBase):
    def test_confirmed_replacement_cancels_exact_submission_then_submits_new_build(self):
        fake = ReplacementAsc()
        client, result = self.run_submit(fake, replace=OLD_BUILD, confirm=CONFIRM)
        self.assertEqual(result["marker"], "APP_STORE_SUBMITTED")
        self.assertEqual(result["state"], "WAITING_FOR_REVIEW")
        cancel_bodies = fake.writes_on(f"/reviewSubmissions/{SUBMISSION_ID}")
        self.assertEqual(len(cancel_bodies), 1)
        self.assertEqual(cancel_bodies[0]["data"]["attributes"], {"canceled": True})
        self.assertEqual(fake.linked_build, NEW_BUILD_ID)
        self.assertEqual(fake.version["attributes"]["releaseType"], "AFTER_APPROVAL")
        self.assertEqual(fake.version["attributes"]["appStoreState"], "WAITING_FOR_REVIEW")
        submitted = [body for method, route, body in fake.write_bodies
                     if method == "PATCH" and route.startswith("/reviewSubmissions/")
                     and ((body.get("data") or {}).get("attributes") or {}).get("submitted") is True]
        self.assertEqual(len(submitted), 1)
        self.assertEqual(client.writes, len(fake.writes))
        self.assertEqual(result["replace"]["old_build"], OLD_BUILD)
        self.assertEqual(result["replace"]["new_build"], NEW_BUILD)
        self.assertEqual(result["replace"]["submission_id"], SUBMISSION_ID)

    def test_cancel_timeout_fails_without_attaching_or_resubmitting(self):
        fake = ReplacementAsc(cancel_completes_after=None)
        with self.assertRaisesRegex(asc.SubmissionError, "REPLACE_CANCEL_UNCONFIRMED"):
            self.run_submit(fake, replace=OLD_BUILD, confirm=CONFIRM,
                            replace_max_polls=3, replace_poll_interval=0.0)
        self.assertEqual(fake.writes, [("PATCH", f"/reviewSubmissions/{SUBMISSION_ID}")])
        self.assertEqual(fake.linked_build, OLD_BUILD_ID)
        self.assertEqual(fake.version["attributes"]["appStoreState"], "WAITING_FOR_REVIEW")

    def test_active_canceling_submission_is_never_reused_for_attach(self):
        # While Apple is still canceling, the normal path must refuse to attach.
        fake = ReplacementAsc(submission_state="CANCELING")
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_STATE"):
            self.run_submit(fake, replace=OLD_BUILD, confirm=CONFIRM)
        self.assertEqual(fake.writes, [])


class ReplaceContractTests(unittest.TestCase):
    WORKFLOW = ROOT / ".github" / "workflows" / "ios-app-review-submit.yml"

    def test_replacement_report_is_secret_safe_json(self):
        plan = {"version": VERSION, "old_build": OLD_BUILD, "new_build": NEW_BUILD,
                "submission_id": "s1", "submission_state": "WAITING_FOR_REVIEW",
                "version_state": "WAITING_FOR_REVIEW"}
        parsed = json.loads(asc._replacement_report("REPLACE_VERIFIED", plan, 0, confirmed=False))
        self.assertEqual(parsed["marker"], "REPLACE_VERIFIED")
        self.assertEqual(parsed["old_build"], OLD_BUILD)
        self.assertEqual(parsed["writes"], 0)
        self.assertEqual(set(parsed), {"marker", "version", "old_build", "new_build", "submission_id",
                                       "submission_state", "version_state", "writes", "confirmed"})

    def test_parser_accepts_opt_in_replacement_flags(self):
        args = asc._parser().parse_args([
            "--bundle-id", "com.example.app", "--version", VERSION, "--build", NEW_BUILD,
            "--whats-new-file", "notes.json", "--replace-existing-build", OLD_BUILD,
            "--confirm-replace", CONFIRM])
        self.assertEqual(args.replace_existing_build, OLD_BUILD)
        self.assertEqual(args.confirm_replace, CONFIRM)

    def test_workflow_replacement_inputs_and_gates(self):
        text = self.WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("replace_existing_build:", text)
        self.assertIn("default: ''", text)
        self.assertIn("INPUT_REPLACE_EXISTING_BUILD: ${{ inputs.replace_existing_build }}", text)
        self.assertIn("INPUT_CONFIRM_REPLACE: ${{ inputs.confirm_replace }}", text)
        self.assertIn('args+=(--replace-existing-build "$INPUT_REPLACE_EXISTING_BUILD")', text)
        self.assertIn('--confirm-replace "REPLACE_PLANFLOW_IOS_REVIEW"', text)
        # Existing confirmation and dry-run defaults must remain untouched.
        self.assertIn("SUBMIT_PLANFLOW_IOS_REVIEW", text)
        dry_run_idx = text.index("dry_run:")
        self.assertIn("default: true", text[dry_run_idx:text.index("confirm:", dry_run_idx)])
        self.assertLess(text.index("timeout-minutes: 15"), text.index("env:"))


class ReplaceBlankDraftTests(ReplacementTestBase):
    """A blank READY_FOR_REVIEW draft must not count as the active review.

    Mirrors the live 2026-10-07 state: one empty editable draft plus one
    WAITING_FOR_REVIEW submission of 1.1.7 (193). Only a successful, validated
    empty items read may skip the draft; failed or malformed reads block.
    """

    def draft_plus_target(self, *, draft_items, items_error=None, items_malformed=False):
        submissions = [
            {"type": "reviewSubmissions", "id": DRAFT_ID, "attributes": {"state": "READY_FOR_REVIEW"}},
            {"type": "reviewSubmissions", "id": SUBMISSION_ID, "attributes": {"state": "WAITING_FOR_REVIEW"}},
        ]
        return ReplacementAsc(
            submissions=submissions,
            items_by_submission={DRAFT_ID: list(draft_items), SUBMISSION_ID: [version_item()]},
            items_error=items_error, items_malformed=items_malformed)

    def test_dry_run_skips_proved_blank_draft_and_plans_the_waiting_target(self):
        fake = self.draft_plus_target(draft_items=[])
        client, result = self.run_submit(fake, dry_run=True, replace=OLD_BUILD, confirm=CONFIRM)
        self.assertEqual(result["marker"], "REPLACE_VERIFIED")
        self.assertEqual(result["replace"]["submission_id"], SUBMISSION_ID)
        self.assertEqual(result["replace"]["old_build"], OLD_BUILD)
        self.assertEqual(result["replace"]["new_build"], NEW_BUILD)
        self.assertEqual(client.writes, 0)
        self.assertEqual(fake.writes, [])

    def test_confirmed_replacement_cancels_only_the_target_and_never_the_blank_draft(self):
        fake = self.draft_plus_target(draft_items=[])
        client, result = self.run_submit(fake, replace=OLD_BUILD, confirm=CONFIRM)
        self.assertEqual(result["marker"], "APP_STORE_SUBMITTED")
        self.assertEqual(result["replace"]["old_build"], OLD_BUILD)
        self.assertEqual(result["replace"]["new_build"], NEW_BUILD)
        self.assertEqual(result["replace"]["submission_id"], SUBMISSION_ID)
        cancel_bodies = fake.writes_on(f"/reviewSubmissions/{SUBMISSION_ID}")
        self.assertEqual(cancel_bodies, [{"data": {"type": "reviewSubmissions", "id": SUBMISSION_ID,
                                                   "attributes": {"canceled": True}}}])
        self.assertFalse(any(DRAFT_ID in route for _, route in fake.writes))
        self.assertTrue(any(method == "POST" and route == "/reviewSubmissions"
                            for method, route in fake.writes))
        self.assertEqual(client.writes, len(fake.writes))

    def test_nonblank_ready_draft_still_counts_as_active_and_blocks(self):
        fake = self.draft_plus_target(draft_items=[version_item("i-draft")])
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_MULTIPLE"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_failed_draft_items_read_blocks_instead_of_treating_draft_as_empty(self):
        failed = asc.SubmissionError("BLOCKED_ASC_API: GET request failed with HTTP 500")
        fake = self.draft_plus_target(draft_items=[], items_error=failed)
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_ASC_API"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_malformed_draft_items_response_blocks_instead_of_treating_draft_as_empty(self):
        fake = self.draft_plus_target(draft_items=[], items_malformed=True)
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_ASC_RESPONSE"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_malformed_draft_item_row_blocks(self):
        fake = self.draft_plus_target(
            draft_items=[{"type": "reviewSubmissionItems", "id": "i-x", "relationships": {}}])
        with self.assertRaisesRegex(asc.SubmissionError, "relationship data is missing or malformed"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_draft_without_id_blocks_instead_of_treating_it_as_empty(self):
        submissions = [
            {"type": "reviewSubmissions", "attributes": {"state": "READY_FOR_REVIEW"}},
            {"type": "reviewSubmissions", "id": SUBMISSION_ID, "attributes": {"state": "WAITING_FOR_REVIEW"}},
        ]
        fake = ReplacementAsc(submissions=submissions,
                              items_by_submission={SUBMISSION_ID: [version_item()]})
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REVIEW_SUBMISSION"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])

    def test_duplicate_target_items_fail_replacement(self):
        fake = ReplacementAsc(items=[version_item("i1"), version_item("i2")])
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REPLACE_ITEMS"):
            self.run_submit(fake, replace=OLD_BUILD)
        self.assertEqual(fake.writes, [])


if __name__ == "__main__":
    unittest.main()
