"""Offline state-machine tests for exact App Store review submission."""

import importlib.util
import pathlib
import unittest
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("asc_submit_review", ROOT / "scripts" / "asc-submit-review.py")
asc = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(asc)


class FakeAsc:
    def __init__(self, *, target_state=None, target_build="b1", live_version="1.1.2", submission=None, items=None):
        self.app = {"type": "apps", "id": "app1", "attributes": {"bundleId": "com.example.app"}}
        self.live_version = live_version
        self.version = None
        if target_state:
            self.version = {"type": "appStoreVersions", "id": "v1", "attributes": {
                "versionString": "1.1.3", "appStoreState": target_state, "releaseType": "AFTER_APPROVAL"
            }}
        self.build = {"type": "builds", "id": target_build, "attributes": {"version": "55", "processingState": "VALID", "expirationDate": (datetime.now(timezone.utc) + timedelta(days=30)).isoformat()},
                      "relationships": {"preReleaseVersion": {"data": {"id": "pr1"}}}}
        self.included = [{"type": "preReleaseVersions", "id": "pr1", "attributes": {"version": "1.1.3"}}]
        self.submissions = [submission] if submission else []
        self.items = list(items or [])
        self.localization = {"type": "appStoreVersionLocalizations", "id": "l1", "attributes": {
            "locale": "ko", "description": "desc", "keywords": "kw", "supportUrl": "https://example.com", "whatsNew": None}}
        self.writes = []
        self.item_queries = []

    def __call__(self, method, path, body):
        parsed = urlsplit(path)
        route, query = parsed.path, parse_qs(parsed.query)
        if method == "GET" and route == "/apps":
            return {"data": [self.app]}
        if method == "GET" and route == "/builds":
            return {"data": [self.build], "included": self.included}
        if method == "GET" and route == "/apps/app1/appStoreVersions":
            if query.get("filter[appStoreState]") == ["READY_FOR_SALE"]:
                return {"data": [{"attributes": {"versionString": self.live_version, "appStoreState": "READY_FOR_SALE"}}] if self.live_version else []}
            requested = query.get("filter[versionString]")
            return {"data": [self.version] if self.version and requested == [self.version["attributes"]["versionString"]] else []}
        if method == "POST" and route == "/appStoreVersions":
            self.writes.append((method, route))
            self.version = {"type": "appStoreVersions", "id": "v1", "attributes": body["data"]["attributes"] | {"appStoreState": "PREPARE_FOR_SUBMISSION"}, "relationships": {}}
            return {"data": self.version}
        if method == "GET" and route == "/appStoreVersions/v1/appStoreReviewDetail":
            return {"data": {"type": "appStoreReviewDetails", "id": "detail1", "attributes": {
                "demoAccountRequired": False, "contactFirstName": "A", "contactLastName": "B",
                "contactPhone": "01000000000", "contactEmail": "support@example.com", "notes": "Keep existing"}}}
        if method == "GET" and route == "/appStoreVersions/v1/appStoreVersionLocalizations":
            return {"data": [self.localization]}
        if method == "PATCH" and route == "/appStoreVersionLocalizations/l1":
            self.writes.append((method, route))
            self.localization["attributes"].update(body["data"]["attributes"])
            return {"data": self.localization}
        if method == "GET" and route == "/appStoreVersions/v1/relationships/build":
            return {"data": {"type": "builds", "id": self.version.get("build", "") if self.version else ""}}
        if method == "PATCH" and route == "/appStoreVersions/v1/relationships/build":
            self.writes.append((method, route))
            self.version["build"] = body["data"]["id"]
            return {"data": body["data"]}
        if method == "PATCH" and route == "/appStoreVersions/v1":
            self.writes.append((method, route))
            self.version["attributes"].update(body["data"]["attributes"])
            return {"data": self.version}
        if method == "GET" and route == "/apps/app1/reviewSubmissions":
            return {"data": self.submissions}
        if method == "POST" and route == "/reviewSubmissions":
            self.writes.append((method, route))
            submission_id = f"s{len(self.submissions) + 1}"
            submission = {"type": "reviewSubmissions", "id": submission_id, "attributes": {"state": "READY_FOR_REVIEW"}}
            self.submissions.append(submission)
            return {"data": submission}
        if method == "GET" and route.startswith("/reviewSubmissions/") and route.endswith("/items"):
            self.item_queries.append(query)
            return {"data": self.items}
        if method == "POST" and route == "/reviewSubmissionItems":
            self.writes.append((method, route))
            item = {"type": "reviewSubmissionItems", "id": "i1", "relationships": body["data"]["relationships"]}
            self.items.append(item)
            return {"data": item}
        if method == "PATCH" and route.startswith("/reviewSubmissions/"):
            self.writes.append((method, route))
            submission = next(item for item in self.submissions if item["id"] == route.split("/")[2])
            submission["attributes"]["state"] = "WAITING_FOR_REVIEW"
            self.version["attributes"]["appStoreState"] = "WAITING_FOR_REVIEW"
            return {"data": submission}
        if method == "GET" and route == "/appStoreVersions/v1":
            return {"data": self.version}
        raise AssertionError(f"unexpected fake ASC request {method} {path}")


def target_item(version_id="v1"):
    return {"type": "reviewSubmissionItems", "id": "i1", "relationships": {
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
    }}


class SubmissionTests(unittest.TestCase):
    def run_submit(self, fake, version="1.1.3", build="55", dry_run=False):
        client = asc.AscClient("fixture-token", fake)
        notes = {"version": version, "localizations": {"ko": "fixture release notes"}}
        result = asc.submit(client, "com.example.app", version, build, whats_new=notes, dry_run=dry_run, sleep=lambda _: None, max_polls=1)
        return client, result

    def test_rejects_invalid_version_and_build(self):
        fake = FakeAsc()
        with self.assertRaisesRegex(asc.SubmissionError, "version must be X.Y.Z"):
            self.run_submit(fake, "latest", "55")
        with self.assertRaisesRegex(asc.SubmissionError, "build number"):
            self.run_submit(fake, "1.1.3", "055")
        self.assertEqual(fake.writes, [])

    def test_missing_exact_build_fails(self):
        fake = FakeAsc()
        fake.build["attributes"]["version"] = "54"
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_BUILD"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_expired_build_is_rejected_before_any_write(self):
        fake = FakeAsc()
        fake.build["attributes"]["expirationDate"] = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_BUILD_EXPIRATION"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_dry_run_is_read_only_even_when_version_would_be_created(self):
        fake = FakeAsc()
        client, result = self.run_submit(fake, dry_run=True)
        self.assertEqual(result["marker"], "DRY_RUN_PLAN_ONLY")
        self.assertEqual(result["writes"], 0)
        self.assertEqual(client.writes, 0)
        self.assertEqual(fake.writes, [])

    def test_refuses_live_version_train(self):
        fake = FakeAsc(live_version="1.1.3")
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_VERSION_LIVE"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_new_version_is_created_and_exact_build_submitted(self):
        fake = FakeAsc()
        client, result = self.run_submit(fake)
        self.assertEqual(result["marker"], "APP_STORE_SUBMITTED")
        self.assertEqual(result["state"], "WAITING_FOR_REVIEW")
        self.assertIn(("POST", "/appStoreVersions"), fake.writes)
        self.assertIn(("POST", "/reviewSubmissionItems"), fake.writes)
        self.assertEqual(fake.version["build"], "b1")
        self.assertEqual(fake.version["attributes"]["releaseType"], "AFTER_APPROVAL")
        self.assertEqual(fake.localization["attributes"]["whatsNew"], "fixture release notes")

    def test_partial_submission_retry_reuses_existing_exact_item(self):
        submission = {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "READY_FOR_REVIEW"}}
        fake = FakeAsc(target_state="PREPARE_FOR_SUBMISSION", submission=submission, items=[target_item()])
        client, result = self.run_submit(fake)
        self.assertEqual(result["marker"], "APP_STORE_SUBMITTED")
        self.assertFalse(any(route == "/reviewSubmissionItems" and method == "POST" for method, route in fake.writes))
        self.assertEqual(sum(1 for method, route in fake.writes if method == "POST" and route == "/reviewSubmissions"), 0)

    def test_ready_for_review_version_reuses_only_its_exact_existing_submission(self):
        submission = {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "READY_FOR_REVIEW"}}
        fake = FakeAsc(target_state="READY_FOR_REVIEW", submission=submission, items=[target_item()])
        client, result = self.run_submit(fake)
        self.assertEqual(result["marker"], "APP_STORE_SUBMITTED")
        self.assertEqual(result["state"], "WAITING_FOR_REVIEW")
        self.assertFalse(any(method == "POST" and route in {"/reviewSubmissions", "/reviewSubmissionItems"}
                             for method, route in fake.writes))
        self.assertIn(("PATCH", "/reviewSubmissions/s1"), fake.writes)
        self.assertTrue(fake.item_queries)
        self.assertTrue(all(query.get("include") == ["appStoreVersion"] for query in fake.item_queries))
        self.assertEqual(client.writes, len(fake.writes))

    def test_rejects_foreign_item_in_editable_submission(self):
        submission = {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "READY_FOR_REVIEW"}}
        fake = FakeAsc(target_state="PREPARE_FOR_SUBMISSION", submission=submission, items=[target_item("foreign")])
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REVIEW_SUBMISSION"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_foreign_active_submission_blocks_before_mutation(self):
        submission = {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "IN_REVIEW"}}
        fake = FakeAsc(submission=submission, items=[target_item("other-version")])
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_ACTIVE_SUBMISSION"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_empty_ready_for_review_submission_is_preserved_and_new_submission_created(self):
        submission = {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "READY_FOR_REVIEW"}}
        fake = FakeAsc(submission=submission)
        client, result = self.run_submit(fake)
        self.assertEqual(result["marker"], "APP_STORE_SUBMITTED")
        self.assertEqual(fake.submissions[0]["attributes"]["state"], "READY_FOR_REVIEW")
        self.assertEqual(fake.submissions[1]["attributes"]["state"], "WAITING_FOR_REVIEW")
        self.assertIn(("POST", "/reviewSubmissions"), fake.writes)
        self.assertEqual(client.writes, len(fake.writes))

    def test_malformed_review_submission_collection_fails_closed(self):
        class MalformedAsc(FakeAsc):
            def __call__(self, method, path, body):
                if method == "GET" and urlsplit(path).path == "/apps/app1/reviewSubmissions":
                    return {"errors": [{"status": "500"}], "data": []}
                return super().__call__(method, path, body)

        fake = MalformedAsc()
        with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_ASC_RESPONSE"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_review_submission_items_without_target_relationship_fail_closed(self):
        submission = {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": "READY_FOR_REVIEW"}}
        fake = FakeAsc(target_state="PREPARE_FOR_SUBMISSION", submission=submission,
                       items=[{"type": "reviewSubmissionItems", "id": "i1", "relationships": {}}])
        with self.assertRaisesRegex(asc.SubmissionError, "relationship data is missing"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_transitional_or_unresolved_submission_states_block_before_mutation(self):
        for state in ("CANCELING", "COMPLETING", "UNRESOLVED_ISSUES", "FUTURE_UNKNOWN"):
            with self.subTest(state=state):
                submission = {"type": "reviewSubmissions", "id": "s1", "attributes": {"state": state}}
                fake = FakeAsc(submission=submission)
                with self.assertRaisesRegex(asc.SubmissionError, "BLOCKED_REVIEW_SUBMISSION_STATE"):
                    self.run_submit(fake)
                self.assertEqual(fake.writes, [])

    def test_exact_active_build_with_wrong_release_mode_is_not_confirmed(self):
        fake = FakeAsc(target_state="WAITING_FOR_REVIEW", target_build="b1")
        fake.version["build"] = "b1"
        fake.version["attributes"]["releaseType"] = "MANUAL"
        with self.assertRaisesRegex(asc.SubmissionError, "release option"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])

    def test_exact_active_submission_is_read_only_idempotent(self):
        fake = FakeAsc(target_state="WAITING_FOR_REVIEW", target_build="b1")
        fake.version["build"] = "b1"
        client, result = self.run_submit(fake)
        self.assertTrue(result["idempotent"])
        self.assertEqual(result["marker"], "APP_STORE_SUBMITTED")
        self.assertEqual(client.writes, 0)

    def test_active_submission_with_different_build_is_blocked(self):
        fake = FakeAsc(target_state="IN_REVIEW", target_build="b1")
        fake.version["build"] = "other"
        with self.assertRaisesRegex(asc.SubmissionError, "different build"):
            self.run_submit(fake)
        self.assertEqual(fake.writes, [])


if __name__ == "__main__":
    unittest.main()
