"""Unit + contract tests for scripts/store-readback-asc.py.

The module under test has a hyphenated filename, so it is loaded via
importlib.util.spec_from_file_location (mirroring
test_asc_next_build_number.py in this same directory). No test performs a
real network call: urllib.request.urlopen is patched module-wide to raise if
anything ever falls through to it, and every App Store Connect HTTP boundary
is exercised through a FakeTransport that receives the {"method", "url",
"headers"} request dict store_readback.ReadbackClient builds.
"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import pathlib
import re
import sys
import tempfile
import unittest
from unittest import mock

try:
    import yaml

    HAVE_YAML = True
except ImportError:  # pragma: no cover - environment without PyYAML
    HAVE_YAML = False

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS_DIR = ROOT / "scripts"
MODULE_PATH = SCRIPTS_DIR / "store-readback-asc.py"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "store-readback.yml"

sys.path.insert(0, str(SCRIPTS_DIR))
_SPEC = importlib.util.spec_from_file_location("store_readback_asc", MODULE_PATH)
store_readback = importlib.util.module_from_spec(_SPEC)
sys.modules["store_readback_asc"] = store_readback
_SPEC.loader.exec_module(store_readback)


def generate_test_p8_key() -> bytes:
    """Generates a synthetic ES256 private key in PEM/PKCS8 form, purely for
    test signing. Never derived from, or related to, any real credential."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def _fake_demo_password() -> str:
    """Build a demo password from fragments."""
    return "super-secret-demo-" + "pw"


def _fake_openai_style_value() -> str:
    """Build an OpenAI-style secret key from fragments."""
    return "s" + "k-" + "should-never-appear-" + "in-output"


class FakeTransport:
    """Stand-in for the request(dict) -> dict transport callable.

    Responses are registered as (substring, response_dict) pairs matched in
    registration order against the request's URL. Raises AssertionError on
    an unmatched URL so wiring mistakes are loud, and raises
    NonGetForbidden if it is ever asked to send a non-GET request (mirrors
    the real transport's defense-in-depth check).
    """

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, request):
        if request.get("method") != "GET":
            raise store_readback.NonGetForbidden(f"refusing non-GET request: {request.get('method')!r}")
        url = request["url"]
        self.calls.append(url)
        for needle, response in self.responses:
            if needle in url:
                return dict(response)
        raise AssertionError(f"FakeTransport received an unexpected URL: {url}")


class NoNetworkGuardMixin:
    def setUp(self):
        patcher = mock.patch(
            "urllib.request.urlopen",
            side_effect=AssertionError("test attempted a real network call via urllib.request.urlopen"),
        )
        patcher.start()
        self.addCleanup(patcher.stop)


def no_sleep(_seconds):
    return None


class AllowlistTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_allowed_paths_pass(self):
        allowed = [
            "/v1/apps",
            "/v1/apps/app-1",
            "/v1/apps/app-1/appInfos",
            "/v1/appInfos/info-1",
            "/v1/appInfos/info-1/appInfoLocalizations",
            "/v1/appInfos/info-1/primaryCategory",
            "/v1/appInfos/info-1/secondaryCategory",
            "/v1/appInfos/info-1/ageRatingDeclaration",
            "/v1/apps/app-1/appStoreVersions",
            "/v1/appStoreVersions/v-1",
            "/v1/appStoreVersions/v-1/appStoreVersionLocalizations",
            "/v1/appStoreVersions/v-1/build",
            "/v1/appStoreVersions/v-1/appStoreReviewDetail",
            "/v1/appStoreVersionLocalizations/loc-1/appScreenshotSets",
            "/v1/appScreenshotSets/set-1/appScreenshots",
            "/v1/apps/app-1/reviewSubmissions",
            "/v1/reviewSubmissions/submission-1/items",
            "/v1/apps/app-1/appPriceSchedule",
            "/v1/apps/app-1/availabilityV2",
        ]
        for path in allowed:
            with self.subTest(path=path):
                self.assertTrue(store_readback.is_path_allowed(path))

    def test_disallowed_paths_are_rejected(self):
        disallowed = [
            "/v1/builds",
            "/v1/apps/app-1/preReleaseVersions",
            "/v2/apps",
            "/v1/appStoreVersions/v-1/appStoreVersionSubmission",
            "/v1/users",
            "/v1/apps/app-1/appStoreVersions/v-1",  # not a real ASC shape
        ]
        for path in disallowed:
            with self.subTest(path=path):
                self.assertFalse(store_readback.is_path_allowed(path))

    def test_get_raises_readback_path_not_allowed_for_disallowed_path(self):
        client = store_readback.ReadbackClient("fake-token", transport=FakeTransport([]))
        with self.assertRaises(store_readback.ReadbackPathNotAllowed):
            client.get("/v1/builds")

    def test_pagination_link_outside_allowlist_is_rejected(self):
        client = store_readback.ReadbackClient("fake-token", transport=FakeTransport([]))
        with self.assertRaises(store_readback.ReadbackPathNotAllowed):
            client.get_url("https://api.appstoreconnect.apple.com/v1/builds?cursor=x")


class NonGetForbiddenTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_real_transport_rejects_forged_non_get_request(self):
        forged_request = {
            "method": "POST",
            "url": "https://api.appstoreconnect.apple.com/v1/apps",
            "headers": {},
        }
        with self.assertRaises(store_readback.NonGetForbidden):
            store_readback._real_transport(forged_request)

    def test_client_get_always_builds_a_get_request(self):
        captured = {}

        def capturing_transport(request):
            captured.update(request)
            return {"data": []}

        client = store_readback.ReadbackClient("fake-token", transport=capturing_transport)
        client.get("/v1/apps")
        self.assertEqual(captured["method"], "GET")

    def test_fake_transport_itself_raises_non_get_forbidden(self):
        transport = FakeTransport([("/v1/apps", {"data": []})])
        with self.assertRaises(store_readback.NonGetForbidden):
            transport({"method": "DELETE", "url": "https://api.appstoreconnect.apple.com/v1/apps", "headers": {}})


class PiiRedactionTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_demo_password_value_never_recorded(self):
        demo_pw = _fake_demo_password()
        sanitized = store_readback.sanitize_review_detail(
            {"demoAccountPassword": demo_pw, "contactEmail": "reviewer@example.com"}
        )
        self.assertNotIn(demo_pw, json.dumps(sanitized))
        self.assertEqual(sanitized["demoPasswordSet"], True)
        self.assertNotIn("demoAccountPassword", sanitized)

    def test_demo_password_false_when_absent(self):
        sanitized = store_readback.sanitize_review_detail({"demoAccountPassword": ""})
        self.assertEqual(sanitized["demoPasswordSet"], False)

    def test_contact_fields_are_hashed_not_raw(self):
        attrs = {
            "demoAccountName": "reviewer-demo-account",
            "contactEmail": "reviewer@example.com",
            "contactPhone": "+1-555-0100",
            "contactFirstName": "Jane",
            "contactLastName": "Doe",
        }
        sanitized = store_readback.sanitize_review_detail(attrs)
        dumped = json.dumps(sanitized)
        for raw_value in attrs.values():
            self.assertNotIn(raw_value, dumped)
        for field in store_readback.PII_HASH_FIELDS:
            self.assertEqual(sanitized[field], {"present": True})
            self.assertNotIn("sha256_12", sanitized[field])

    def test_notes_are_length_only_with_no_digest(self):
        note_text = "Reviewer, please use the demo account above to sign in."
        sanitized = store_readback.sanitize_review_detail({"notes": note_text})
        self.assertNotIn(note_text, json.dumps(sanitized))
        self.assertEqual(sanitized["notes"]["length"], len(note_text))
        self.assertEqual(set(sanitized["notes"]), {"length"})
        self.assertNotIn(hashlib.sha256(note_text.encode("utf-8")).hexdigest(), json.dumps(sanitized))

    def test_absent_pii_field_reports_present_false(self):
        sanitized = store_readback.sanitize_review_detail({"contactEmail": ""})
        self.assertEqual(sanitized["contactEmail"], {"present": False})

    def test_known_passthrough_field_kept(self):
        sanitized = store_readback.sanitize_review_detail({"demoAccountRequired": True})
        self.assertEqual(sanitized["demoAccountRequired"], True)

    def test_unknown_attribute_key_dropped_not_passed_through(self):
        """Allowlist regression: an attribute App Store Connect returns that
        isn't PII/notes/demoAccountPassword/a known passthrough field must be
        dropped entirely, not silently forwarded verbatim into the
        snapshot."""
        secret_value = _fake_openai_style_value()
        sanitized = store_readback.sanitize_review_detail(
            {"someBrandNewSecretLookingField": secret_value}
        )
        self.assertNotIn("someBrandNewSecretLookingField", sanitized)
        self.assertNotIn(secret_value, json.dumps(sanitized))


class RetryAndAuthTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_401_raises_blocked_error_with_exit_code_6_and_no_retries(self):
        transport = FakeTransport([("/v1/apps", {"__http_status": 401, "errors": [{"status": "401", "detail": "unauthorized"}]})])
        client = store_readback.ReadbackClient("fake-token", transport=transport)
        with self.assertRaises(store_readback.BlockedError) as ctx:
            client.request_with_retry("/v1/apps", sleep_fn=no_sleep)
        self.assertEqual(ctx.exception.exit_code, store_readback.EXIT_AUTH_FAILURE)
        self.assertEqual(len(transport.calls), 1, "401 must not be retried")

    def test_403_raises_blocked_error_with_exit_code_6(self):
        transport = FakeTransport([("/v1/apps", {"__http_status": 403, "errors": [{"status": "403", "detail": "forbidden"}]})])
        client = store_readback.ReadbackClient("fake-token", transport=transport)
        with self.assertRaises(store_readback.BlockedError) as ctx:
            client.request_with_retry("/v1/apps", sleep_fn=no_sleep)
        self.assertEqual(ctx.exception.exit_code, store_readback.EXIT_AUTH_FAILURE)

    def test_429_backs_off_then_succeeds(self):
        call_count = {"n": 0}

        def flaky(request):
            call_count["n"] += 1
            if call_count["n"] < 3:
                return {"__http_status": 429, "errors": [{"status": "429", "detail": "rate limited"}]}
            return {"__http_status": 200, "data": [{"id": "app-1", "type": "apps", "attributes": {}}]}

        client = store_readback.ReadbackClient("fake-token", transport=flaky)
        sleeps = []
        document = client.request_with_retry("/v1/apps", sleep_fn=sleeps.append)
        self.assertEqual(call_count["n"], 3)
        self.assertEqual(len(sleeps), 2)
        self.assertEqual(document["__http_status"], 200)

    def test_429_exceeding_retry_budget_raises_internal_error(self):
        transport = FakeTransport([("/v1/apps", {"__http_status": 429, "errors": [{"status": "429", "detail": "rate limited"}]})])
        client = store_readback.ReadbackClient("fake-token", transport=transport)
        with self.assertRaises(store_readback.BlockedError) as ctx:
            client.request_with_retry("/v1/apps", sleep_fn=no_sleep)
        self.assertEqual(ctx.exception.exit_code, store_readback.EXIT_INTERNAL)
        self.assertGreaterEqual(len(transport.calls), store_readback.MAX_RETRIES + 1)


class AgeRatingUnavailableTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_404_age_rating_declaration_marked_unavailable_and_run_exits_zero(self):
        responses = _full_snapshot_responses(age_rating_status=404)
        transport = FakeTransport(responses)
        with tempfile.TemporaryDirectory() as tmp_dir:
            args = _build_args(out_dir=tmp_dir)
            key_pem = generate_test_p8_key()
            with mock.patch.dict(
                "os.environ",
                {
                    "APP_STORE_CONNECT_KEY_ID": "TESTKEYID123",
                    "APP_STORE_CONNECT_ISSUER_ID": "11111111-2222-3333-4444-555555555555",
                    "APP_STORE_CONNECT_API_KEY_P8": key_pem.decode("utf-8"),
                },
            ):
                result = store_readback.run(args, transport=transport, sleep_fn=no_sleep, captured_at="2026-09-11T00:00:00Z")
            self.assertIn("ageRatingDeclaration:info-1", result["unavailableSections"])
            self.assertEqual(result["mutationCount"], 0)
            snapshot = json.loads(pathlib.Path(result["outPath"]).read_text(encoding="utf-8"))
            self.assertEqual(snapshot["fields"]["appInfos"][0]["ageRating"], "UNAVAILABLE")


class CategoryRelationshipTests(NoNetworkGuardMixin, unittest.TestCase):
    def _collect(self, info_response, category_responses=()):
        responses = _full_snapshot_responses()
        responses[1] = ("/v1/apps/app-1/appInfos", info_response)
        responses[3:3] = list(category_responses)
        transport = FakeTransport(responses)
        client = store_readback.ReadbackClient("test-token", transport=transport)
        fields, unavailable = store_readback.collect_snapshot(client, "com.fluxstudio.planflow", sleep_fn=no_sleep)
        result = {"unavailableSections": unavailable, "mutationCount": client.mutation_count}
        snapshot = {"fields": fields}
        return result, snapshot, transport

    def test_embedded_relationship_is_configured_without_extra_category_gets(self):
        info = {"__http_status": 200, "data": [{"id": "info-1", "type": "appInfos", "attributes": {}, "relationships": {
            "primaryCategory": {"data": {"id": "cat-primary", "type": "appCategories"}},
            "secondaryCategory": {"data": {"id": "cat-secondary", "type": "appCategories"}},
        }}]}
        result, snapshot, transport = self._collect(info)
        item = snapshot["fields"]["appInfos"][0]
        self.assertEqual(item["primaryCategoryState"], "CONFIGURED")
        self.assertEqual(item["secondaryCategoryState"], "CONFIGURED")
        self.assertFalse(any("primaryCategory" in url for url in transport.calls))
        self.assertEqual(result["mutationCount"], 0)

    def test_malformed_embedded_relationship_is_unavailable_without_fallback(self):
        info = {"__http_status": 200, "data": [{"id": "info-1", "type": "appInfos", "attributes": {}, "relationships": {
            "primaryCategory": {"data": []},
            "secondaryCategory": {"data": {"id": 17, "type": "appCategories"}},
        }}]}
        result, snapshot, transport = self._collect(info)
        item = snapshot["fields"]["appInfos"][0]
        self.assertEqual(item["primaryCategoryState"], "UNAVAILABLE")
        self.assertEqual(item["secondaryCategoryState"], "UNAVAILABLE")
        self.assertIn("primaryCategory:info-1", result["unavailableSections"])
        self.assertIn("secondaryCategory:info-1", result["unavailableSections"])
        self.assertFalse(any("primaryCategory" in url for url in transport.calls))
        self.assertFalse(any("secondaryCategory" in url for url in transport.calls))
        self.assertEqual(result["mutationCount"], 0)

    def test_empty_and_404_relationships_are_unset(self):
        responses = [
            ("/v1/appInfos/info-1/primaryCategory", {"__http_status": 200, "data": None}),
            ("/v1/appInfos/info-1/secondaryCategory", {"__http_status": 404, "errors": [{"status": "404"}]}),
        ]
        info = {"__http_status": 200, "data": [{"id": "info-1", "type": "appInfos", "attributes": {}, "relationships": {}}]}
        result, snapshot, _ = self._collect(info, responses)
        item = snapshot["fields"]["appInfos"][0]
        self.assertEqual(item["primaryCategoryState"], "UNSET")
        self.assertEqual(item["secondaryCategoryState"], "UNSET")
        self.assertEqual(result["unavailableSections"], [])
        self.assertEqual(result["mutationCount"], 0)

    def test_relationship_request_failure_is_unavailable(self):
        responses = [
            ("/v1/appInfos/info-1/primaryCategory", {"__http_status": None, "errors": [{"code": "ASC_REQUEST_FAILED"}]}),
            ("/v1/appInfos/info-1/secondaryCategory", {"__http_status": 200, "data": None}),
        ]
        info = {"__http_status": 200, "data": [{"id": "info-1", "type": "appInfos", "attributes": {}, "relationships": {}}]}
        result, snapshot, _ = self._collect(info, responses)
        item = snapshot["fields"]["appInfos"][0]
        self.assertEqual(item["primaryCategoryState"], "UNAVAILABLE")
        self.assertEqual(item["secondaryCategoryState"], "UNSET")
        self.assertIn("primaryCategory:info-1", result["unavailableSections"])
        self.assertEqual(result["mutationCount"], 0)

    def test_relationship_missing_http_status_is_unavailable(self):
        responses = [
            ("/v1/appInfos/info-1/primaryCategory", {"data": None}),
            ("/v1/appInfos/info-1/secondaryCategory", {"__http_status": 200, "data": None}),
        ]
        info = {"__http_status": 200, "data": [{"id": "info-1", "type": "appInfos", "attributes": {}, "relationships": {}}]}
        result, snapshot, _ = self._collect(info, responses)
        item = snapshot["fields"]["appInfos"][0]
        self.assertEqual(item["primaryCategoryState"], "UNAVAILABLE")
        self.assertEqual(item["secondaryCategoryState"], "UNSET")
        self.assertIn("primaryCategory:info-1", result["unavailableSections"])

    def test_relationship_200_error_or_malformed_data_is_unavailable(self):
        responses = [
            ("/v1/appInfos/info-1/primaryCategory", {"__http_status": 200, "errors": [{"code": "BAD_RESPONSE"}], "data": None}),
            ("/v1/appInfos/info-1/secondaryCategory", {"__http_status": 200, "data": {}}),
        ]
        info = {"__http_status": 200, "data": [{"id": "info-1", "type": "appInfos", "attributes": {}, "relationships": {}}]}
        result, snapshot, _ = self._collect(info, responses)
        item = snapshot["fields"]["appInfos"][0]
        self.assertEqual(item["primaryCategoryState"], "UNAVAILABLE")
        self.assertEqual(item["secondaryCategoryState"], "UNAVAILABLE")
        self.assertIn("primaryCategory:info-1", result["unavailableSections"])
        self.assertIn("secondaryCategory:info-1", result["unavailableSections"])
        self.assertEqual(result["mutationCount"], 0)


def _build_args(out_dir):
    parser = store_readback.build_arg_parser()
    return parser.parse_args(["--bundle-id", "com.fluxstudio.planflow", "--out", out_dir, "--project-id", "planflow"])


def _full_snapshot_responses(age_rating_status=200, review_submissions=None, review_items=None):
    age_rating_response = (
        {"__http_status": 404, "errors": [{"status": "404", "detail": "not found"}]}
        if age_rating_status == 404
        else {"__http_status": 200, "data": {"id": "age-1", "type": "ageRatingDeclarations", "attributes": {"ageRatingOverride": "NONE"}}}
    )
    return [
        ("/v1/apps?", {"__http_status": 200, "data": [{"id": "app-1", "type": "apps", "attributes": {"bundleId": "com.fluxstudio.planflow", "name": "PlanFlow", "primaryLocale": "en-US"}}]}),
        ("/v1/apps/app-1/appInfos", {"__http_status": 200, "data": [{"id": "info-1", "type": "appInfos", "attributes": {"appStoreState": "READY_FOR_SALE"}, "relationships": {}}]}),
        ("/v1/appInfos/info-1/appInfoLocalizations", {"__http_status": 200, "data": [{"id": "loc-info-1", "type": "appInfoLocalizations", "attributes": {"locale": "en-US", "name": "PlanFlow"}}]}),
        ("/v1/appInfos/info-1/primaryCategory", {"__http_status": 200, "data": None}),
        ("/v1/appInfos/info-1/secondaryCategory", {"__http_status": 200, "data": None}),
        ("/v1/appInfos/info-1/ageRatingDeclaration", age_rating_response),
        ("/v1/apps/app-1/appStoreVersions", {"__http_status": 200, "data": [{"id": "v-1", "type": "appStoreVersions", "attributes": {"versionString": "1.1.1", "appStoreState": "READY_FOR_SALE"}}]}),
        ("/v1/appStoreVersions/v-1/build", {"__http_status": 200, "data": {"id": "build-1", "type": "builds", "attributes": {"version": "159", "usesNonExemptEncryption": False}}}),
        ("/v1/appStoreVersions/v-1/appStoreReviewDetail", {"__http_status": 200, "data": {"id": "review-1", "type": "appStoreReviewDetails", "attributes": {"demoAccountPassword": "hunter2", "contactEmail": "reviewer@example.com"}}}),
        ("/v1/appStoreVersions/v-1/appStoreVersionLocalizations", {"__http_status": 200, "data": [{"id": "vloc-1", "type": "appStoreVersionLocalizations", "attributes": {"locale": "en-US", "description": "PlanFlow"}}]}),
        ("/v1/appStoreVersionLocalizations/vloc-1/appScreenshotSets", {"__http_status": 200, "data": []}),
        ("/v1/apps/app-1/reviewSubmissions", {"__http_status": 200, "data": review_submissions or []}),
        ("/v1/reviewSubmissions/submission-1/items", {"__http_status": 200, "data": review_items or []}),
        ("/v1/apps/app-1/appPriceSchedule", {"__http_status": 200, "data": {"id": "price-1", "type": "appPriceSchedules"}}),
        ("/v1/apps/app-1/availabilityV2", {"__http_status": 200, "data": {"id": "avail-1", "type": "appAvailabilities", "attributes": {}}}),
    ]


class EndToEndSecretSafetyTests(NoNetworkGuardMixin, unittest.TestCase):
    def _run_full(self, tmp_dir, key_pem, key_id="TESTKEYID123", issuer_id="11111111-2222-3333-4444-555555555555"):
        transport = FakeTransport(_full_snapshot_responses())
        args = _build_args(out_dir=tmp_dir)
        stdout = io.StringIO()
        with mock.patch.dict(
            "os.environ",
            {
                "APP_STORE_CONNECT_KEY_ID": key_id,
                "APP_STORE_CONNECT_ISSUER_ID": issuer_id,
                "APP_STORE_CONNECT_API_KEY_P8": key_pem.decode("utf-8"),
            },
        ):
            original_run = store_readback.run
            with mock.patch.object(
                store_readback,
                "run",
                side_effect=lambda a, **kw: original_run(
                    a, transport=transport, sleep_fn=no_sleep, captured_at="2026-09-11T00:00:00Z"
                ),
            ):
                with contextlib.redirect_stdout(stdout):
                    exit_code = store_readback.main(["--bundle-id", "com.fluxstudio.planflow", "--out", tmp_dir, "--project-id", "planflow"])
        return exit_code, stdout.getvalue()

    def test_no_secret_material_in_output_file_or_stdout(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            key_pem = generate_test_p8_key()
            exit_code, stdout_text = self._run_full(tmp_dir, key_pem)
            self.assertEqual(exit_code, store_readback.EXIT_OK)

            out_files = list(pathlib.Path(tmp_dir).glob("*.json"))
            self.assertEqual(len(out_files), 1)
            snapshot_text = out_files[0].read_text(encoding="utf-8")

            forbidden_patterns = [
                r"-----BEGIN",
                r"TESTKEYID123",
                r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
                r"hunter2",
                r"reviewer@example\.com",
            ]
            for pattern in forbidden_patterns:
                with self.subTest(pattern=pattern, where="snapshot file"):
                    self.assertNotRegex(snapshot_text, pattern)
                with self.subTest(pattern=pattern, where="stdout"):
                    self.assertNotRegex(stdout_text, pattern)

            snapshot = json.loads(snapshot_text)
            self.assertEqual(snapshot["fields"]["appStoreVersions"][0]["reviewDetail"]["demoPasswordSet"], True)
            self.assertTrue(snapshot["fields"]["appStoreVersions"][0]["reviewDetail"]["contactEmail"]["present"])
            self.assertEqual(
                snapshot["redaction"]["piiPresenceOnly"],
                list(store_readback.PII_HASH_FIELDS),
            )
            self.assertNotIn("piiHashed", snapshot["redaction"])
            self.assertEqual(snapshot["schemaVersion"], 1)
            self.assertEqual(snapshot["fields"]["app"]["bundleId"], "com.fluxstudio.planflow")
            self.assertEqual(snapshot["redaction"]["omitted"], ["demoAccountPassword"])

    def test_review_submission_items_are_read_only_sanitized_and_complete(self):
        submission = {"id": "submission-1", "type": "reviewSubmissions", "attributes": {
            "state": "READY_FOR_REVIEW", "platform": "IOS", "submittedDate": None}}
        item = {"id": "item-1", "type": "reviewSubmissionItems", "attributes": {"privateNote": "never export"},
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": "version-1"}}}}
        responses = _full_snapshot_responses(review_submissions=[submission], review_items=[item])
        transport = FakeTransport(responses)
        fields, _unavailable = store_readback.collect_snapshot(
            store_readback.ReadbackClient("fake-token", transport=transport),
            "com.fluxstudio.planflow", sleep_fn=no_sleep,
        )
        saved = fields["reviewSubmissions"][0]
        self.assertEqual(saved["itemsReadState"], "COMPLETE")
        self.assertEqual(saved["itemCount"], 1)
        self.assertEqual(saved["items"], [{"id": "item-1", "appStoreVersionId": "version-1"}])
        self.assertNotIn("privateNote", json.dumps(fields))
        self.assertTrue(any("/v1/reviewSubmissions/submission-1/items?" in url for url in transport.calls))

    def test_review_submission_items_missing_or_failed_page_blocks_readback(self):
        submission = {"id": "submission-1", "type": "reviewSubmissions", "attributes": {"state": "READY_FOR_REVIEW"}}
        for response in (
            {"__http_status": 200},
            {"__http_status": 200, "data": None},
            {"__http_status": 200, "errors": [{"status": "500", "detail": "failure"}], "data": []},
            {"__http_status": 500, "data": []},
            {"__http_status": 200, "data": [], "links": {"next": "https://api.appstoreconnect.apple.com/v1/reviewSubmissions/submission-1/items?cursor=next"}},
        ):
            with self.subTest(response=response), tempfile.TemporaryDirectory() as tmp_dir:
                responses = _full_snapshot_responses(review_submissions=[submission])
                responses = [
                    (needle, response if needle == "/v1/reviewSubmissions/submission-1/items" else body)
                    for needle, body in responses
                ]
                transport = FakeTransport(responses)
                with self.assertRaises(store_readback.BlockedError):
                    store_readback.collect_snapshot(
                        store_readback.ReadbackClient("fake-token", transport=transport),
                        "com.fluxstudio.planflow", sleep_fn=no_sleep,
                    )
                self.assertEqual(transport.calls[-1].split("/items")[0].split("/v1")[-1], "/reviewSubmissions/submission-1")

    def test_review_submission_item_without_version_linkage_blocks(self):
        submission = {"id": "submission-1", "type": "reviewSubmissions", "attributes": {"state": "READY_FOR_REVIEW"}}
        item = {"id": "item-1", "type": "reviewSubmissionItems", "relationships": {}}
        transport = FakeTransport(_full_snapshot_responses(review_submissions=[submission], review_items=[item]))
        with self.assertRaisesRegex(store_readback.BlockedError, "relationship is missing"):
            store_readback.collect_snapshot(store_readback.ReadbackClient("fake-token", transport=transport), "com.fluxstudio.planflow", sleep_fn=no_sleep)


class ContentHashDeterminismTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_same_input_same_hash(self):
        fields_a = {"app": {"id": "app-1"}, "appStoreVersions": [1, 2, 3]}
        fields_b = json.loads(json.dumps(fields_a))  # equal but freshly-parsed dict
        self.assertEqual(
            store_readback.compute_content_hash(fields_a),
            store_readback.compute_content_hash(fields_b),
        )

    def test_different_input_different_hash(self):
        fields_a = {"app": {"id": "app-1"}}
        fields_b = {"app": {"id": "app-2"}}
        self.assertNotEqual(
            store_readback.compute_content_hash(fields_a),
            store_readback.compute_content_hash(fields_b),
        )

    def test_key_order_does_not_affect_hash(self):
        fields_a = {"a": 1, "b": 2}
        fields_b = {"b": 2, "a": 1}
        self.assertEqual(
            store_readback.compute_content_hash(fields_a),
            store_readback.compute_content_hash(fields_b),
        )


class ConfigMissingTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_missing_credentials_exit_3(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            args = _build_args(out_dir=tmp_dir)
            with mock.patch.dict("os.environ", {}, clear=False):
                for key in (
                    "APP_STORE_CONNECT_KEY_ID",
                    "APP_STORE_CONNECT_ISSUER_ID",
                    "APP_STORE_CONNECT_API_KEY_P8",
                ):
                    __import__("os").environ.pop(key, None)
                with self.assertRaises(store_readback.BlockedError) as ctx:
                    store_readback.run(args, transport=FakeTransport([]), sleep_fn=no_sleep)
            self.assertEqual(ctx.exception.exit_code, store_readback.EXIT_CONFIG_MISSING)
            self.assertEqual(ctx.exception.code, "AUTH_CONFIG_MISSING")


class BundleIdFromXcconfigTests(NoNetworkGuardMixin, unittest.TestCase):
    def test_foreign_bundle_id_is_rejected_before_collection(self):
        with self.assertRaises(store_readback.BlockedError) as ctx:
            store_readback.validate_bundle_id("com.foreign.other")
        self.assertEqual(ctx.exception.exit_code, store_readback.EXIT_CONFIG_MISSING)
        self.assertEqual(ctx.exception.code, "BUNDLE_ID_NOT_ALLOWED")

    def test_foreign_xcconfig_bundle_id_is_rejected_without_network(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            xcconfig_path = pathlib.Path(tmp_dir) / "PlanFlow-Identity.xcconfig"
            xcconfig_path.write_text("PLANFLOW_IOS_BUNDLE_ID = com.foreign.other\n", encoding="utf-8")
            parser = store_readback.build_arg_parser()
            args = parser.parse_args([
                "--bundle-id-from-xcconfig", str(xcconfig_path),
                "--out", tmp_dir, "--project-id", "planflow",
            ])
            with mock.patch.dict("os.environ", {
                "APP_STORE_CONNECT_KEY_ID": "TESTKEYID123",
                "APP_STORE_CONNECT_ISSUER_ID": "11111111-2222-3333-4444-555555555555",
                "APP_STORE_CONNECT_API_KEY_P8": generate_test_p8_key().decode("utf-8"),
            }):
                with self.assertRaises(store_readback.BlockedError) as ctx:
                    store_readback.run(args, transport=FakeTransport([]), sleep_fn=no_sleep)
            self.assertEqual(ctx.exception.code, "BUNDLE_ID_NOT_ALLOWED")

    def test_reads_bundle_id_from_xcconfig(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            xcconfig_path = pathlib.Path(tmp_dir) / "PlanFlow-Identity.xcconfig"
            xcconfig_path.write_text("PLANFLOW_IOS_BUNDLE_ID = com.fluxstudio.planflow\n", encoding="utf-8")
            bundle_id = store_readback.read_bundle_id_from_xcconfig(xcconfig_path)
            self.assertEqual(bundle_id, "com.fluxstudio.planflow")

    def test_run_refuses_when_xcconfig_bundle_id_unreadable_no_fallback_to_default(self):
        """Removed-fallback regression (SEC-M6/LOW): a caller that explicitly
        asks --bundle-id-from-xcconfig must not silently fall back to
        --bundle-id's default when the file is missing/unparseable -- that
        could read back an entirely different app's App Store Connect
        record without any signal. run() must raise BlockedError instead."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            parser = store_readback.build_arg_parser()
            args = parser.parse_args(
                [
                    "--bundle-id",
                    "com.fluxstudio.planflow",
                    "--bundle-id-from-xcconfig",
                    str(pathlib.Path(tmp_dir) / "does-not-exist.xcconfig"),
                    "--out",
                    tmp_dir,
                    "--project-id",
                    "planflow",
                ]
            )
            with mock.patch.dict(
                "os.environ",
                {
                    "APP_STORE_CONNECT_KEY_ID": "TESTKEYID123",
                    "APP_STORE_CONNECT_ISSUER_ID": "11111111-2222-3333-4444-555555555555",
                    "APP_STORE_CONNECT_API_KEY_P8": generate_test_p8_key().decode("utf-8"),
                },
            ):
                with self.assertRaises(store_readback.BlockedError) as ctx:
                    store_readback.run(args, transport=FakeTransport([]), sleep_fn=no_sleep)
            self.assertEqual(ctx.exception.exit_code, store_readback.EXIT_CONFIG_MISSING)
            self.assertEqual(ctx.exception.code, "BUNDLE_ID_XCCONFIG_UNREADABLE")


@unittest.skipUnless(WORKFLOW_PATH.exists(), "workflow file not found")
class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_text = WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_workflow_dispatch_is_the_only_trigger(self):
        if HAVE_YAML:
            doc = yaml.safe_load(self.workflow_text)
            triggers = doc[True] if True in doc else doc.get("on")
            self.assertEqual(set(triggers.keys()), {"workflow_dispatch"})
        else:
            self.assertIn("workflow_dispatch:", self.workflow_text)
            for forbidden in ("\non: push", "\n  push:", "\n  schedule:", "\n  pull_request:"):
                self.assertNotIn(forbidden, self.workflow_text)

    def test_permissions_contents_read(self):
        if HAVE_YAML:
            doc = yaml.safe_load(self.workflow_text)
            self.assertEqual(doc["permissions"]["contents"], "read")
        else:
            self.assertRegex(self.workflow_text, r"permissions:\s*\n\s*contents:\s*read")

    def test_no_secret_echo(self):
        for secret_name in (
            "APP_STORE_CONNECT_KEY_ID",
            "APP_STORE_CONNECT_ISSUER_ID",
            "APP_STORE_CONNECT_API_KEY_P8",
        ):
            self.assertNotRegex(
                self.workflow_text,
                r"echo[^\n]*\$" + re.escape(secret_name),
                f"Found an echo of ${secret_name} in the workflow.",
            )
        self.assertNotIn("set -x", self.workflow_text)

    def test_secrets_only_referenced_via_expression_syntax(self):
        for match in re.finditer(r"secrets\.[A-Za-z0-9_]+", self.workflow_text):
            start = match.start()
            preceding = self.workflow_text[max(0, start - 20) : start]
            self.assertIn("${{", preceding)

    def test_guard_step_exists_before_upload(self):
        guard_idx = self.workflow_text.index("Guard against secret material")
        upload_idx = self.workflow_text.index("Upload sanitized App Store Connect snapshot")
        self.assertLess(guard_idx, upload_idx)
        guard_block = self.workflow_text[guard_idx:upload_idx]
        self.assertIn("grep", guard_block)
        self.assertIn("BEGIN", guard_block)

    def test_no_write_verbs_anywhere_in_workflow(self):
        forbidden_patterns = [
            r"gh\s+workflow\s+run",
            r"gh\s+api\s+.*-X\s*POST",
            r"curl\s+.*-X\s*POST",
            r"curl\s+.*-X\s*PATCH",
            r"curl\s+.*-X\s*DELETE",
            r"appstoreconnect\.apple\.com.*-X\s*(POST|PATCH|DELETE|PUT)",
        ]
        for pattern in forbidden_patterns:
            with self.subTest(pattern=pattern):
                self.assertNotRegex(self.workflow_text, pattern)

    def test_uses_ubuntu_runner(self):
        self.assertIn("runs-on: ubuntu-latest", self.workflow_text)

    def test_upload_artifact_v4_used(self):
        self.assertIn("actions/upload-artifact@v4", self.workflow_text)

    def test_short_retention(self):
        match = re.search(r"retention-days:\s*(\d+)", self.workflow_text)
        self.assertIsNotNone(match)
        self.assertLessEqual(int(match.group(1)), 14)


if __name__ == "__main__":
    unittest.main()
