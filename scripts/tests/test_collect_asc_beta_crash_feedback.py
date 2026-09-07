import json
import io
import pathlib
import re
import sys
import unittest
import urllib.error
from email.message import Message
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import collect_asc_beta_crash_feedback as collector


class FakeTransport:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, method, path):
        self.calls.append((method, path))
        for prefix, response in sorted(enumerate(self.responses), key=lambda pair: (len(pair[1][0]), pair[0]), reverse=True):
            prefix, response = response
            if path == prefix or path.startswith(prefix):
                return response, "request-safe-1"
        return {}, "request-safe-1"


def resource(kind, ident, attrs=None, relationships=None):
    return {"type": kind, "id": ident, "attributes": attrs or {}, "relationships": relationships or {}}


def relation(kind, ident):
    return {"data": {"type": kind, "id": ident}}


def official_diagnostic_log(event="hang", architecture="arm64", symbol="main"):
    return {"productData": [{"diagnosticLogs": [{"diagnosticMetaData": {"event": event, "platformArchitecture": architecture}, "callStackTree": [{"callStacks": [{"callStackRootFrames": [{"symbolName": symbol, "binaryName": "Runner", "subFrames": []}]}]}]}]}]}


def submissions_document(items, links=None):
    document = {"data": items, "included": []}
    if items:
        document["included"] = [
            resource(
                "builds",
                "build-17",
                {"version": "17"},
                {
                    "app": relation("apps", "app-1"),
                    "preReleaseVersion": relation("preReleaseVersions", "pre-1"),
                },
            )
        ]
    if links is not None:
        document["links"] = links
    return document


class FakeResponse:
    def __init__(self, body):
        self.body = body
        self.headers = Message()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, limit=-1):
        return self.body if limit < 0 else self.body[:limit]


class CollectorTests(unittest.TestCase):
    def client(self, transport):
        return collector.ASCClient("in-memory", transport=transport)

    def base(self, extra=None):
        app = resource("apps", "app-1", {"bundleId": collector.BUNDLE_ID})
        build = resource("builds", "build-17", {"version": "17"}, {"preReleaseVersion": relation("preReleaseVersions", "pre-1"), "app": relation("apps", "app-1")})
        pre = resource("preReleaseVersions", "pre-1", {"version": "1.0.0", "platform": "IOS"})
        app_included = resource("apps", "app-1", {"bundleId": collector.BUNDLE_ID})
        responses = [
            ("/apps?", {"data": [app]}),
            ("/builds?", {"data": [build], "included": [pre, app_included]}),
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([])),
            ("/builds/build-17/diagnosticSignatures", {"data": []}),
        ]
        if extra:
            responses.extend(extra)
        return responses

    def test_canonical_binding_pagination_and_mismatch_exclusion(self):
        matching = resource("betaFeedbackCrashSubmissions", "s-good", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-1")})
        wrong = resource("betaFeedbackCrashSubmissions", "s-wrong", {}, {"build": relation("builds", "build-other"), "crashLog": relation("betaCrashLogs", "log-wrong")})
        transport = FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([wrong], {"next": "/page-2"})),
            ("/page-2", submissions_document([matching])),
            ("/betaFeedbackCrashSubmissions/s-good/crashLog", {"data": resource("betaCrashLogs", "log-1", {"logText": json.dumps({"system": {"model": "iPhone15,2", "osVersion": "iOS 17.6", "cpuType": "ARM-64", "uptime": "20 seconds"}, "exception": {"type": "EXC_BAD_ACCESS"}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": "Runner main"}]}], "usedImages": [{"name": "Runner", "uuid": "AABBCCDD-1234"}]})})}),
        ]))
        report = collector.collect(self.client(transport))
        self.assertIn("MATCHED_BETA_CRASH_EVIDENCE", report["status"])
        self.assertEqual(report["counts"]["matched_feedback"], 1)
        self.assertEqual(report["counts"]["crash_logs"], 1)
        self.assertTrue(all(method == "GET" for method, _ in transport.calls))

    def test_nonempty_submissions_require_one_canonical_included_build_before_crash_log_requests(self):
        submission = resource("betaFeedbackCrashSubmissions", "s-1", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-1")})
        canonical_build = resource(
            "builds",
            "build-17",
            {"version": "17"},
            {"app": relation("apps", "app-1"), "preReleaseVersion": relation("preReleaseVersions", "pre-1")},
        )
        cases = {
            "missing": {"data": [submission]},
            "wrong": {"data": [submission], "included": [resource("builds", "build-other", {"version": "17"}, {"app": relation("apps", "app-1"), "preReleaseVersion": relation("preReleaseVersions", "pre-1")})]},
            "duplicate": {"data": [submission], "included": [canonical_build, canonical_build]},
        }
        for name, document in cases.items():
            transport = FakeTransport(self.base([( "/apps/app-1/betaFeedbackCrashSubmissions", document )]))
            with self.subTest(name=name):
                report = collector.collect(self.client(transport))
                self.assertEqual(report["counts"]["feedback_submissions"], 1)
                self.assertEqual(report["counts"]["matched_feedback"], 0)
                self.assertEqual(report["counts"]["crash_logs"], 0)
                self.assertEqual(report["counts"]["crash_evidence_emitted"], 0)
                self.assertEqual(report["crash_evidence"], [])
                self.assertNotIn("MATCHED_BETA_CRASH_EVIDENCE", report["status"])
                self.assertIn("FAIL_CLOSED", report["status"])
                self.assertNotIn(("GET", "/betaFeedbackCrashSubmissions/s-1/crashLog?fields[betaCrashLogs]=logText"), transport.calls)

    def test_stage_errors_stop_before_downstream_requests_or_positive_evidence(self):
        app = resource("apps", "app-1", {"bundleId": collector.BUNDLE_ID})
        build = resource("builds", "build-17", {"version": "17"}, {"preReleaseVersion": relation("preReleaseVersions", "pre-1"), "app": relation("apps", "app-1")})
        pre = resource("preReleaseVersions", "pre-1", {"version": "1.0.0", "platform": "IOS"})
        app_included = resource("apps", "app-1", {"bundleId": collector.BUNDLE_ID})
        submission = resource("betaFeedbackCrashSubmissions", "s-1", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-1")})
        cases = {
            "app_pagination": (
                [
                    ("/apps?", {"data": [app], "links": {"next": "/broken-app-page"}}),
                    ("/broken-app-page", {}),
                ],
                "/builds?",
            ),
            "build_pagination": (
                [
                    ("/builds?", {"data": [build], "included": [pre, app_included], "links": {"next": "/broken-build-page"}}),
                    ("/broken-build-page", {}),
                ],
                "/apps/app-1/betaFeedbackCrashSubmissions",
            ),
            "submission_pagination": (
                [
                    ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([submission], {"next": "/broken-submission-page"})),
                    ("/broken-submission-page", {}),
                ],
                "/betaFeedbackCrashSubmissions/s-1/crashLog",
            ),
        }
        for name, (overrides, forbidden_prefix) in cases.items():
            transport = FakeTransport(self.base(overrides))
            with self.subTest(name=name):
                report = collector.collect(self.client(transport))
                self.assertIn("FAIL_CLOSED", report["status"])
                self.assertNotIn("MATCHED_BETA_CRASH_EVIDENCE", report["status"])
                self.assertNotIn("MATCHED_DIAGNOSTIC_EVIDENCE", report["status"])
                self.assertEqual(report["crash_evidence"], [])
                self.assertEqual(report["diagnostic_aggregate"], [])
                self.assertFalse(any(path.startswith(forbidden_prefix) for _, path in transport.calls))

    def test_preexisting_request_error_and_late_diagnostic_error_cannot_emit_positive_evidence(self):
        preexisting_transport = FakeTransport(self.base())
        preexisting_client = self.client(preexisting_transport)
        preexisting_client.errors.append("HTTP_401")
        preexisting_report = collector.collect(preexisting_client)
        self.assertEqual(preexisting_report["crash_evidence"], [])
        self.assertNotIn("MATCHED_BETA_CRASH_EVIDENCE", preexisting_report["status"])
        self.assertFalse(any(path.startswith("/builds?") for _, path in preexisting_transport.calls))

        matching = resource("betaFeedbackCrashSubmissions", "s-good", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-1")})
        crash_log = {"data": resource("betaCrashLogs", "log-1", {"logText": json.dumps({"system": {"model": "iPhone15,2", "osVersion": "iOS 17.6", "cpuType": "ARM-64", "uptime": "20 seconds"}, "exception": {"type": "EXC_BAD_ACCESS"}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": "Runner main"}]}], "usedImages": [{"name": "Runner", "uuid": "AABBCCDD-1234"}]})})}
        late_error_transport = FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([matching])),
            ("/betaFeedbackCrashSubmissions/s-good/crashLog", crash_log),
            ("/builds/build-17/diagnosticSignatures", {}),
        ]))
        late_error_report = collector.collect(self.client(late_error_transport))
        self.assertIn("FAIL_CLOSED", late_error_report["status"])
        self.assertNotIn("MATCHED_BETA_CRASH_EVIDENCE", late_error_report["status"])
        self.assertEqual(late_error_report["crash_evidence"], [])
        self.assertEqual(late_error_report["counts"]["crash_evidence_emitted"], 0)

    def test_pagination_helpers_do_not_emit_limit_on_request_or_schema_failure(self):
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.HTTPError("https://api.appstoreconnect.apple.com/v1/apps", 404, "not found", Message(), io.BytesIO(b"{}"))):
            client = collector.ASCClient("secret-token")
            self.assertEqual(client.pages("/apps?filter[bundleId]=com.fluxstudio.planflow", "apps"), [])
            self.assertIn("HTTP_404", client.errors)
            self.assertIn("ASC_APP_LIST_REQUEST_FAILED", client.errors)
            self.assertNotIn("PAGINATION_LIMIT", client.errors)
        with mock.patch("urllib.request.urlopen", return_value=FakeResponse(json.dumps({"data": [resource("builds", "build-17", {"version": "17"})]}).encode("utf-8"))):
            client = collector.ASCClient("secret-token")
            self.assertEqual(client.pages_with_included("/builds?filter[app]=app-1&filter[version]=17&include=preReleaseVersion,app", "builds", {"preReleaseVersions", "apps"}), ([
                resource("builds", "build-17", {"version": "17"})
            ], []))
            self.assertIn("JSON_API_INCLUDED_SCHEMA_MISMATCH", client.errors)
            self.assertIn("ASC_BUILD_LIST_REQUEST_FAILED", client.errors)
            self.assertNotIn("PAGINATION_LIMIT", client.errors)

    def test_exactly_100_pages_only_emit_limit_when_next_is_present(self):
        def paginated_responses(with_extra_next: bool):
            responses = []
            for index in range(100):
                path = "/builds?filter[app]=app-1&filter[version]=17&include=preReleaseVersion,app" if index == 0 else f"/page-{index + 1}"
                next_link = {"next": f"/page-{index + 2}"} if index < 99 or with_extra_next else None
                document = {"data": []}
                if next_link is not None:
                    document["links"] = next_link
                responses.append((path, document))
            if with_extra_next:
                responses.append(("/page-101", {"data": []}))
            return responses

        no_next_client = self.client(FakeTransport(self.base(paginated_responses(False))))
        submissions, included = no_next_client.pages_with_included(
            "/builds?filter[app]=app-1&filter[version]=17&include=preReleaseVersion,app",
            "builds",
            {"preReleaseVersions", "apps"},
        )
        self.assertEqual(submissions, [])
        self.assertEqual(included, [])
        self.assertNotIn("PAGINATION_LIMIT", no_next_client.errors)

        next_client = self.client(FakeTransport(self.base(paginated_responses(True))))
        submissions, included = next_client.pages_with_included(
            "/builds?filter[app]=app-1&filter[version]=17&include=preReleaseVersion,app",
            "builds",
            {"preReleaseVersions", "apps"},
        )
        self.assertEqual(submissions, [])
        self.assertEqual(included, [])
        self.assertIn("PAGINATION_LIMIT", next_client.errors)

    def test_absolute_apple_pagination_link_is_normalized(self):
        transport = FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([], {"next": "https://api.appstoreconnect.apple.com/v1/page-2"})),
            ("/page-2", submissions_document([])),
        ]))
        collector.collect(self.client(transport))
        self.assertIn(("GET", "/page-2"), transport.calls)

    def test_text_parser_and_absent_log(self):
        text = """Hardware Model: iPhone14,5\nOS Version: iOS 16.7\nCode Type: ARM-64\nException Type: EXC_CRASH\nTermination Reason: SIGNAL 6\nCrashed Thread: 0\n    0   Runner 0x0000000100001000 main + 12\n"""
        parsed = collector.parse_crash_log(text)
        self.assertEqual(parsed["exception"], "EXC_CRASH")
        self.assertEqual(parsed["top_symbols"], ["main"])
        self.assertEqual(collector.parse_crash_log({})["exception"], "UNKNOWN")

    def test_json_lines_ips_parser_keeps_safe_binary_uuid(self):
        value = json.dumps({"bug_type": "309", "modelCode": "iPhone15,2", "osVersion": {"train": "iPhone OS 17.6"}, "cpuType": "ARM-64", "uptime": 20}) + "\n" + json.dumps({"exception": {"type": "EXC_CRASH"}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": "Runner main"}]}], "usedImages": [{"name": "Runner", "uuid": "01234567-89AB-CDEF-0123-456789ABCDEF", "arch": "arm64"}]}, indent=2)
        parsed = collector.parse_crash_log(value)
        self.assertEqual(parsed["exception"], "EXC_CRASH")
        self.assertEqual(parsed["device_model"], "iPhone15,2")
        self.assertEqual(parsed["os"], "iPhone OS 17.6")
        self.assertEqual(parsed["architecture"], "ARM-64")
        self.assertEqual(parsed["crashed_thread"], "0")
        self.assertEqual(parsed["binary_uuid"], "01234567-89AB-CDEF-0123-456789ABCDEF")

    def test_unparseable_crash_log_fails_closed(self):
        matching = resource("betaFeedbackCrashSubmissions", "s-bad", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-bad")})
        transport = FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([matching])),
            ("/betaFeedbackCrashSubmissions/s-bad/crashLog", {"data": resource("betaCrashLogs", "log-bad", {"logText": "not a crash report"})}),
        ]))
        report = collector.collect(self.client(transport))
        self.assertEqual(report["counts"]["crash_logs"], 1)
        self.assertEqual(report["crash_evidence"], [])
        self.assertIn("CRASH_LOG_UNPARSEABLE", report["status"])
        self.assertNotIn("MATCHED_BETA_CRASH_EVIDENCE", report["status"])
        self.assertIn("FAIL_CLOSED", report["status"])

    def test_decisive_looking_but_incomplete_crash_logs_fail_closed(self):
        malformed_logs = {
            "json_exception_only": json.dumps({"exception": {"type": "EXC_CRASH"}}),
            "classic_exception_only": "Exception Type: EXC_CRASH\n",
        }
        for name, log_text in malformed_logs.items():
            submission = resource("betaFeedbackCrashSubmissions", f"s-{name}", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", f"log-{name}")})
            transport = FakeTransport(self.base([
                ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([submission])),
                (f"/betaFeedbackCrashSubmissions/s-{name}/crashLog", {"data": resource("betaCrashLogs", f"log-{name}", {"logText": log_text})}),
            ]))
            with self.subTest(name=name):
                report = collector.collect(self.client(transport))
                self.assertEqual(report["counts"]["crash_logs"], 1)
                self.assertEqual(report["crash_evidence"], [])
                self.assertIn("CRASH_LOG_UNPARSEABLE", report["status"])
                self.assertIn("FAIL_CLOSED", report["status"])

    def test_official_diagnostic_log_schema_is_allowlisted(self):
        item = resource("diagnosticSignatures", "d-official", {"diagnosticType": "HANGS", "signature": "safe-signature", "weight": 1})
        official = {"productData": [{"diagnosticLogs": [{"diagnosticMetaData": {"event": "hang", "platformArchitecture": "arm64", "deviceType": "private", "osVersion": "private", "eventDetail": "private"}, "callStackTree": [{"callStacks": [{"callStackRootFrames": [{"symbolName": "main", "binaryName": "Runner", "address": "0xBAD", "rawFrame": "private", "subFrames": [{"symbolName": "run", "binaryName": "App.framework", "fileName": "/Users/private/a"}]}]}]}]}]}]}
        transport = FakeTransport(self.base([("/builds/build-17/diagnosticSignatures", {"data": [item]}), ("/diagnosticSignatures/d-official/logs", official)]))
        report = collector.collect(self.client(transport))
        serialized = json.dumps(report) + collector.markdown(report)
        self.assertEqual(report["counts"]["diagnostic_logs"], 1)
        self.assertEqual(report["diagnostic_aggregate"][0]["top_symbols"], ["Runner!main", "App.framework!run"])
        self.assertNotRegex(serialized, r"private|0xBAD|rawFrame|fileName|deviceType|osVersion|eventDetail")

    def test_auth_and_api_error_fail_closed(self):
        transport = FakeTransport([("/apps?", ({}, "request-safe-1"))])
        client = self.client(transport)
        client.errors.append("HTTP_401")
        report = collector.collect(client)
        self.assertIn("FAIL_CLOSED", report["status"])
        api_error = FakeTransport([("/apps?", {"errors": [{"status": "401", "detail": "secret detail"}]})])
        error_report = collector.collect(self.client(api_error))
        self.assertIn("ASC_API_ERROR", error_report["status"])
        self.assertIn("FAIL_CLOSED", error_report["status"])

    def test_empty_included_is_accepted_only_for_empty_data_and_nonempty_binding_stays_required(self):
        empty_submissions_transport = FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", {"data": []}),
        ]))
        empty_client = self.client(empty_submissions_transport)
        submissions, submission_included = empty_client.pages_with_included(
            "/apps/app-1/betaFeedbackCrashSubmissions?filter[build]=build-17&include=build&fields[betaFeedbackCrashSubmissions]=crashLog,build",
            "betaFeedbackCrashSubmissions",
            {"builds"},
        )
        self.assertEqual(submissions, [])
        self.assertEqual(submission_included, [])
        self.assertNotIn("JSON_API_INCLUDED_SCHEMA_MISMATCH", empty_client.errors)
        self.assertNotIn("PAGINATION_LIMIT", empty_client.errors)

        build_client = self.client(FakeTransport(self.base()))
        builds, included = build_client.pages_with_included(
            "/builds?filter[app]=app-1&filter[version]=17&include=preReleaseVersion,app",
            "builds",
            {"preReleaseVersions", "apps"},
        )
        self.assertEqual(len(builds), 1)
        self.assertEqual(len(included), 2)
        self.assertEqual(build_client.errors, [])

    def test_finish_dedupes_errors_in_insertion_order_before_applying_five_item_cap(self):
        client = self.client(FakeTransport(self.base()))
        client.errors = ["ONE", "ONE", "TWO", "THREE", "TWO", "FOUR", "FIVE", "SIX"]
        report = collector._finish({"status": []}, client, True)
        self.assertEqual(report["status"], ["ONE", "TWO", "THREE", "FOUR", "FIVE", "FAIL_CLOSED"])

    def test_request_scope_markers_are_fixed_and_non_sensitive(self):
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.HTTPError("https://api.appstoreconnect.apple.com/v1/betaFeedbackCrashSubmissions/s-1/crashLog?fields[betaCrashLogs]=logText", 404, "not found", Message(), io.BytesIO(b"{}"))):
            client = collector.ASCClient("secret-token")
            self.assertEqual(client.get("/betaFeedbackCrashSubmissions/s-1/crashLog?fields[betaCrashLogs]=logText"), {})
            self.assertIn("HTTP_404", client.errors)
            self.assertIn("ASC_CRASH_LOG_REQUEST_FAILED", client.errors)
            serialized = json.dumps(client.errors)
            self.assertNotRegex(serialized, r"/betaFeedbackCrashSubmissions|s-1|request-safe-1|https://|v1/")

    def test_real_urllib_failures_and_body_bound_are_safe(self):
        headers = Message()
        headers["x-request-id"] = "safe-http-request"
        cases = [
            (urllib.error.HTTPError("https://api.appstoreconnect.apple.com/v1/apps", 401, "denied", headers, io.BytesIO(b"{}")), "HTTP_401"),
            (urllib.error.URLError("offline"), "ASC_REQUEST_FAILED"),
        ]
        for raised, marker in cases:
            with self.subTest(marker=marker), mock.patch("urllib.request.urlopen", side_effect=raised):
                client = collector.ASCClient("secret-token")
                self.assertEqual(client.get("/apps"), {})
                self.assertIn(marker, client.errors)
        with mock.patch("urllib.request.urlopen", return_value=FakeResponse(b"not-json")):
            client = collector.ASCClient("secret-token")
            self.assertEqual(client.get("/apps"), {})
            self.assertIn("ASC_REQUEST_FAILED", client.errors)
        oversized = b"{" + b" " * collector.MAX_RESPONSE_BYTES + b"}"
        with mock.patch("urllib.request.urlopen", return_value=FakeResponse(oversized)):
            client = collector.ASCClient("secret-token")
            self.assertEqual(client.get("/apps"), {})
            self.assertIn("ASC_RESPONSE_TOO_LARGE", client.errors)

    def test_malformed_resource_relationship_and_log_schemas_fail_closed(self):
        valid_submission = resource("betaFeedbackCrashSubmissions", "s", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log")})
        valid_signature = resource("diagnosticSignatures", "d", {"diagnosticType": "HANGS", "signature": "safe", "weight": 1})
        malformed_cases = {
            "app_type": FakeTransport([("/apps?", {"data": [resource("builds", "app-1", {"bundleId": collector.BUNDLE_ID})]})]),
            "app_relationship": FakeTransport([("/apps?", {"data": [resource("apps", "app-1", {"bundleId": collector.BUNDLE_ID}, {"builds": relation("apps", "wrong")})]})]),
            "build_relation": FakeTransport(self.base([("/builds?", {"data": [resource("builds", "build-17", {"version": "17"}, {"preReleaseVersion": relation("builds", "pre-1"), "app": relation("apps", "app-1")})], "included": [resource("preReleaseVersions", "pre-1", {"version": "1.0.0", "platform": "IOS"}), resource("apps", "app-1", {"bundleId": collector.BUNDLE_ID})]})])),
            "submission_relation": FakeTransport(self.base([("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([resource("betaFeedbackCrashSubmissions", "s", {}, {"build": relation("apps", "build-17"), "crashLog": relation("betaCrashLogs", "log")})]))])),
            "crash_log_type": FakeTransport(self.base([("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([valid_submission])), ("/betaFeedbackCrashSubmissions/s/crashLog", {"data": resource("apps", "log", {"logText": "Exception Type: EXC_CRASH"})})])),
            "crash_log_relationship": FakeTransport(self.base([("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([valid_submission])), ("/betaFeedbackCrashSubmissions/s/crashLog", {"data": resource("betaCrashLogs", "log", {"logText": "Exception Type: EXC_CRASH"}, {"broken": {"data": {"type": "apps"}}})})])),
            "signature_type": FakeTransport(self.base([("/builds/build-17/diagnosticSignatures", {"data": [resource("builds", "d", {"diagnosticType": "HANGS", "signature": "safe", "weight": 1})]})])),
            "signature_relationship": FakeTransport(self.base([("/builds/build-17/diagnosticSignatures", {"data": [resource("diagnosticSignatures", "d", {"diagnosticType": "HANGS", "signature": "safe", "weight": 1}, {"build": relation("apps", "wrong")})]})])),
            "diagnostic_log": FakeTransport(self.base([("/builds/build-17/diagnosticSignatures", {"data": [valid_signature]}), ("/diagnosticSignatures/d/logs", {"productData": [{"diagnosticLogs": "malformed"}]})])),
        }
        for name, transport in malformed_cases.items():
            with self.subTest(name=name):
                report = collector.collect(self.client(transport))
                self.assertIn("FAIL_CLOSED", report["status"])
                self.assertNotIn("PASS", report["status"])

    def test_large_synthetic_input_is_bounded_and_reports_truncation(self):
        submissions = []
        signatures = []
        extra = []
        crash_text = json.dumps({"exception": {"type": "EXC_CRASH"}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": "main"}]}]})
        for index in range(collector.MAX_CRASH_EVIDENCE + 5):
            submission_id = f"s-{index}"
            log_id = f"log-{index}"
            submissions.append(resource("betaFeedbackCrashSubmissions", submission_id, {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", log_id)}))
            extra.append((f"/betaFeedbackCrashSubmissions/{submission_id}/crashLog", {"data": resource("betaCrashLogs", log_id, {"logText": crash_text})}))
        for index in range(collector.MAX_DIAGNOSTIC_AGGREGATES + 5):
            signature_id = f"d-{index}"
            signatures.append(resource("diagnosticSignatures", signature_id, {"diagnosticType": "HANGS", "signature": "safe", "weight": 1}))
            extra.append((f"/diagnosticSignatures/{signature_id}/logs", official_diagnostic_log()))
        extra.extend([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document(submissions)),
            ("/builds/build-17/diagnosticSignatures", {"data": signatures}),
        ])
        report = collector.collect(self.client(FakeTransport(self.base(extra))))
        serialized = json.dumps(report) + collector.markdown(report)
        self.assertEqual(len(report["crash_evidence"]), collector.MAX_CRASH_EVIDENCE)
        self.assertEqual(len(report["diagnostic_aggregate"]), collector.MAX_DIAGNOSTIC_AGGREGATES)
        self.assertEqual(report["counts"]["crash_evidence_truncated"], 5)
        self.assertEqual(report["counts"]["diagnostic_aggregates_truncated"], 5)
        self.assertIn("CRASH_EVIDENCE_TRUNCATED", report["status"])
        self.assertIn("DIAGNOSTIC_AGGREGATES_TRUNCATED", report["status"])
        self.assertLess(len(serialized), 100_000)

    def test_diagnostic_signature_parsing(self):
        item = resource("diagnosticSignatures", "d1", {"diagnosticType": "HANGS", "signature": "Runner::main", "weight": 4, "topFrames": ["main", "App.framework entry"]})
        official = {"productData": [{"diagnosticLogs": [{"diagnosticMetaData": {"event": "hang", "platformArchitecture": "arm64"}, "callStackTree": [{"callStacks": [{"callStackRootFrames": [{"symbolName": "main", "binaryName": "Runner"}]}]}]}]}]}
        transport = FakeTransport(self.base([("/builds/build-17/diagnosticSignatures", {"data": [item]}), ("/diagnosticSignatures/d1/logs", official)]))
        report = collector.collect(self.client(transport))
        self.assertEqual(report["diagnostic_aggregate"][0]["type"], "HANGS")
        self.assertEqual(report["diagnostic_aggregate"][0]["weight"], 4)
        self.assertEqual(report["counts"]["diagnostic_logs"], 1)
        self.assertIn("MATCHED_DIAGNOSTIC_EVIDENCE", report["status"])
        self.assertIn(("GET", "/diagnosticSignatures/d1/logs?limit=50"), transport.calls)
        serialized = json.dumps(report) + collector.markdown(report)
        self.assertNotRegex(serialized, r"DEADBEEF|private/a.ips|BAD|signatureId|insights")

    def test_diagnostic_build_relationship_must_match_canonical_build(self):
        for name, build_id, expected_pass in (("matching", "build-17", True), ("mismatch", "build-other", False)):
            item = resource("diagnosticSignatures", f"d-{name}", {"diagnosticType": "HANGS", "signature": "Runner::main", "weight": 1}, {"build": relation("builds", build_id)})
            transport = FakeTransport(self.base([
                ("/builds/build-17/diagnosticSignatures", {"data": [item]}),
                (f"/diagnosticSignatures/d-{name}/logs", official_diagnostic_log()),
            ]))
            with self.subTest(name=name):
                report = collector.collect(self.client(transport))
                if expected_pass:
                    self.assertIn("MATCHED_DIAGNOSTIC_EVIDENCE", report["status"])
                    self.assertIn("PASS", report["status"])
                else:
                    self.assertIn("DIAGNOSTIC_BUILD_MISMATCH", report["status"])
                    self.assertEqual(report["diagnostic_aggregate"], [])
                    self.assertIn("FAIL_CLOSED", report["status"])

    def test_empty_diagnostic_payloads_are_not_evidence(self):
        empty_documents = (
            {"productData": []},
            {"productData": [{"diagnosticLogs": []}]},
        )
        for index, document in enumerate(empty_documents):
            item = resource("diagnosticSignatures", f"d-empty-{index}", {"diagnosticType": "HANGS", "signature": "Runner::main", "weight": 1})
            transport = FakeTransport(self.base([
                ("/builds/build-17/diagnosticSignatures", {"data": [item]}),
                (f"/diagnosticSignatures/d-empty-{index}/logs", document),
            ]))
            with self.subTest(index=index):
                report = collector.collect(self.client(transport))
                self.assertEqual(report["counts"]["diagnostic_logs"], 0)
                self.assertEqual(report["diagnostic_aggregate"], [])
                self.assertNotIn("MATCHED_DIAGNOSTIC_EVIDENCE", report["status"])
                self.assertNotIn("PASS", report["status"])
                self.assertIn("NO_DIAGNOSTIC_LOGS", report["status"])
                self.assertIn("FAIL_CLOSED", report["status"])

    def test_field_specific_allowlists_drop_all_sensitive_sentinel_classes(self):
        safe_submission = resource("betaFeedbackCrashSubmissions", "s-safe", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-safe")})
        unsafe_submission = resource("betaFeedbackCrashSubmissions", "s-unsafe", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-unsafe")})
        safe_crash = json.dumps({"modelCode": "iPhone15,2", "family": "iPhone", "osVersion": "iOS 17.6", "cpuType": "arm64", "uptime": "20 seconds", "exception": {"type": "EXC_CRASH"}, "termination": {"reason": "SIGNAL 6"}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": "main"}]}]})
        adversarial = ("customerId", "customer_id", "customer-id", "addressValue", "sk_live_ABC123", "apiKey", "secretValue")
        sentinels = " ".join(adversarial) + " deviceUniqueIdentifier-1 incident_id-2 COMMENT_TEXT localeValue timezoneValue requestToken-3 identifierValue 192.0.2.10 2001:db8::1 aa:bb:cc:dd:ee:ff tester@example.test eyJhbGciOiJIUzI1NiJ9.aaa.bbb /Users/private/a 0xABCDEF"
        unsafe_crash = json.dumps({"modelCode": sentinels, "family": sentinels, "osVersion": sentinels, "cpuType": sentinels, "uptime": sentinels, "exception": {"type": "EXC_CRASH"}, "termination": {"reason": sentinels}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": sentinels}]}], "usedImages": [{"name": "Runner", "uuid": "01234567-89AB-CDEF-0123-456789ABCDEF"}]})
        signature = resource("diagnosticSignatures", "d-safe", {"diagnosticType": "HANGS", "signature": sentinels, "weight": 1})
        diagnostic = {"productData": [{"diagnosticLogs": [{"diagnosticMetaData": {"event": "hang", "platformArchitecture": "arm64"}, "callStackTree": [{"callStacks": [{"callStackRootFrames": [{"symbolName": "main", "binaryName": "Runner", "subFrames": [{"symbolName": "FirebaseApp.configure", "binaryName": "App.framework", "subFrames": [{"symbolName": sentinels, "binaryName": sentinels, "subFrames": []}]}]}]}]}]}]}]}
        transport = FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([safe_submission, unsafe_submission])),
            ("/betaFeedbackCrashSubmissions/s-safe/crashLog", {"data": resource("betaCrashLogs", "log-safe", {"logText": safe_crash})}),
            ("/betaFeedbackCrashSubmissions/s-unsafe/crashLog", {"data": resource("betaCrashLogs", "log-unsafe", {"logText": unsafe_crash})}),
            ("/builds/build-17/diagnosticSignatures", {"data": [signature]}),
            ("/diagnosticSignatures/d-safe/logs", diagnostic),
        ]))
        report = collector.collect(self.client(transport))
        serialized = json.dumps(report) + collector.markdown(report)
        for forbidden in adversarial + ("deviceUniqueIdentifier", "incident_id", "COMMENT_TEXT", "localeValue", "timezoneValue", "requestToken", "identifierValue", "192.0.2.10", "2001:db8::1", "aa:bb:cc:dd:ee:ff", "tester@example.test", "eyJhbGci", "/Users/private", "0xABCDEF"):
            self.assertNotIn(forbidden, serialized)
        for value in adversarial:
            self.assertEqual(collector._safe_symbol(value), "UNKNOWN")
            self.assertEqual(collector._safe_binary_name(value), "UNKNOWN")
            self.assertEqual(collector._safe_signature(value), "UNKNOWN")
        self.assertIn("iPhone15,2", serialized)
        self.assertIn("iOS 17.6", serialized)
        self.assertIn("arm64", serialized)
        self.assertIn("Runner!main", serialized)
        self.assertIn("App.framework!FirebaseApp.configure", serialized)
        self.assertIn("01234567-89AB-CDEF-0123-456789ABCDEF", serialized)

    def test_concatenated_ips_rejects_any_non_object_json_document(self):
        metadata = {"bug_type": "309", "modelCode": "iPhone15,2", "osVersion": "iOS 17.6", "cpuType": "arm64"}
        incident = {"exception": {"type": "EXC_CRASH"}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": "main"}]}]}
        for extra in ([], 123, None, "unexpected"):
            for position in ("before", "after"):
                parts = (extra, metadata, incident) if position == "before" else (metadata, incident, extra)
                payload = "\n".join(json.dumps(part, indent=2) for part in parts)
                submission = resource("betaFeedbackCrashSubmissions", "s-invalid-json", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-invalid-json")})
                transport = FakeTransport(self.base([
                    ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([submission])),
                    ("/betaFeedbackCrashSubmissions/s-invalid-json/crashLog", {"data": resource("betaCrashLogs", "log-invalid-json", {"logText": payload})}),
                ]))
                with self.subTest(extra=repr(extra), position=position):
                    self.assertEqual(collector._json_documents(payload), [])
                    report = collector.collect(self.client(transport))
                    self.assertEqual(report["counts"]["crash_logs"], 1)
                    self.assertEqual(report["crash_evidence"], [])
                    self.assertIn("CRASH_LOG_UNPARSEABLE", report["status"])
                    self.assertIn("FAIL_CLOSED", report["status"])

    def test_program_shape_allowlists_accept_only_code_like_values(self):
        safe_symbols = (
            "main",
            "start",
            "run",
            "abort",
            "UIApplicationMain",
            "Runner main",
            "Runner::main",
            "App.framework entry",
            "FirebaseApp.configure",
            "UIKitCore",
            "dispatch_async",
            "objc_msgSend",
            "swift_retain",
            "free",
            "$s8PlanFlow4mainyyF",
            "-[UIApplicationDelegate application:didFinishLaunchingWithOptions:]",
        )
        unsafe_values = (
            "rk",
            "sk_dev",
            "ghp_",
            "github_pat",
            "xoxb-",
            "AIza",
            "AKIA",
            "johnDoe",
            "randomValue",
            "arbitrary_value",
            "arbitrary-value",
        )
        for symbol in safe_symbols:
            with self.subTest(symbol=symbol):
                self.assertEqual(collector._safe_symbol(symbol), symbol)
                self.assertEqual(collector._safe_signature(symbol), symbol)
        for value in unsafe_values:
            with self.subTest(value=value):
                self.assertEqual(collector._safe_symbol(value), "UNKNOWN")
                self.assertEqual(collector._safe_signature(value), "UNKNOWN")
                self.assertEqual(collector._safe_binary_name(value), "UNKNOWN")
        for binary in ("Runner", "App.framework", "UIKitCore", "libsystem_kernel.dylib", "FirebaseCore.framework", "Flutter", "Foundation", "dyld"):
            with self.subTest(binary=binary):
                self.assertEqual(collector._safe_binary_name(binary), binary)
        deliberate_uuid = "01234567-89AB-CDEF-0123-456789ABCDEF"
        self.assertEqual(collector._safe_uuid(deliberate_uuid), deliberate_uuid)

    def test_program_shape_allowlists_bound_serialized_crash_and_diagnostics(self):
        unsafe_values = ("rk", "sk_dev", "ghp_", "github_pat", "xoxb-", "AIza", "AKIA", "johnDoe", "randomValue")
        deliberate_uuid = "01234567-89AB-CDEF-0123-456789ABCDEF"
        submission = resource("betaFeedbackCrashSubmissions", "s-program-shapes", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-program-shapes")})
        crash_frames = [
            {"symbol": "Runner main"},
            {"symbol": "$s8PlanFlow4mainyyF"},
            {"symbol": "FirebaseApp.configure"},
        ] + [{"symbol": value} for value in unsafe_values]
        crash = json.dumps({"modelCode": "iPhone15,2", "osVersion": "iOS 17.6", "cpuType": "arm64", "exception": {"type": "EXC_CRASH"}, "faultingThread": 0, "threads": [{"triggered": True, "frames": crash_frames}], "usedImages": [{"name": "Runner", "uuid": deliberate_uuid}]})
        signature = resource("diagnosticSignatures", "d-program-shapes", {"diagnosticType": "HANGS", "signature": "johnDoe", "weight": 1, "topFrames": ["Runner main", "randomValue"]})
        diagnostic_frames = [
            {"symbolName": "main", "binaryName": "Runner", "subFrames": []},
            {"symbolName": "FirebaseApp.configure", "binaryName": "App.framework", "subFrames": []},
            {"symbolName": "UIApplicationMain", "binaryName": "UIKitCore", "subFrames": []},
            {"symbolName": "abort", "binaryName": "libsystem_kernel.dylib", "subFrames": []},
        ] + [{"symbolName": value, "binaryName": value, "subFrames": []} for value in unsafe_values]
        diagnostic = {"productData": [{"diagnosticLogs": [{"diagnosticMetaData": {"event": "hang", "platformArchitecture": "arm64"}, "callStackTree": [{"callStacks": [{"callStackRootFrames": diagnostic_frames}]}]}]}]}
        report = collector.collect(self.client(FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([submission])),
            ("/betaFeedbackCrashSubmissions/s-program-shapes/crashLog", {"data": resource("betaCrashLogs", "log-program-shapes", {"logText": crash})}),
            ("/builds/build-17/diagnosticSignatures", {"data": [signature]}),
            ("/diagnosticSignatures/d-program-shapes/logs", diagnostic),
        ]))))
        serialized = json.dumps(report) + collector.markdown(report)
        for value in unsafe_values:
            self.assertNotRegex(serialized, rf"(?<![A-Za-z0-9_]){re.escape(value)}(?![A-Za-z0-9_])")
        for value in ("Runner main", "$s8PlanFlow4mainyyF", "FirebaseApp.configure", "Runner!main", "App.framework!FirebaseApp.configure", "UIKitCore!UIApplicationMain", "libsystem_kernel.dylib!abort", deliberate_uuid):
            self.assertIn(value, serialized)

    def test_provider_credential_prefixes_are_rejected_by_every_sanitizer(self):
        credentials = (
            "sk_live_ABC123",
            "sk_test_ABC123",
            "sk_dev_ABC123",
            "sk_prod_ABC123",
            "sk_sandbox_ABC123",
            "pk_live_ABC123",
            "pk_test_ABC123",
            "rk_test",
            "rk_prod_ABC123",
            "ghp_ABC123",
            "gho_ABC123",
            "ghu_ABC123",
            "ghs_ABC123",
            "github_pat_ABC123",
            "xoxb-ABC123",
            "xoxp-ABC123",
            "xoxa-ABC123",
            "AIzaSyABC123",
            "AKIAIOSFODNN7EXAMPLE",
        )
        sanitizers = (
            collector._safe_device,
            collector._safe_os,
            collector._safe_architecture,
            collector._safe_uptime,
            collector._safe_exception,
            collector._safe_termination,
            collector._safe_symbol,
            collector._safe_binary_name,
            collector._safe_signature,
            collector._safe_event,
        )
        for credential in credentials:
            for sanitizer in sanitizers:
                with self.subTest(credential=credential, sanitizer=sanitizer.__name__):
                    self.assertEqual(sanitizer(credential), "UNKNOWN")

    def test_provider_credential_prefixes_never_reach_serialized_crash_or_diagnostics(self):
        credentials = ("sk_live_ABC123", "sk_test_ABC123", "pk_live_ABC123", "pk_test_ABC123", "rk_dev_ABC123", "rk_sandbox_ABC123", "ghr_ABC123", "xoxs-ABC123", "AIzaSyABC123", "AKIAIOSFODNN7EXAMPLE")
        sentinel = " ".join(credentials)
        submission = resource("betaFeedbackCrashSubmissions", "s-credential", {}, {"build": relation("builds", "build-17"), "crashLog": relation("betaCrashLogs", "log-credential")})
        crash = json.dumps({"modelCode": sentinel, "family": sentinel, "osVersion": sentinel, "cpuType": sentinel, "uptime": sentinel, "exception": {"type": sentinel}, "termination": {"reason": sentinel}, "faultingThread": 0, "threads": [{"triggered": True, "frames": [{"symbol": sentinel}]}], "usedImages": [{"name": "Runner", "uuid": "01234567-89AB-CDEF-0123-456789ABCDEF"}]})
        signature = resource("diagnosticSignatures", "d-credential", {"diagnosticType": "HANGS", "signature": sentinel, "weight": 1})
        diagnostic = {"productData": [{"diagnosticLogs": [{"diagnosticMetaData": {"event": "hang", "platformArchitecture": "arm64"}, "callStackTree": [{"callStacks": [{"callStackRootFrames": [{"symbolName": "main", "binaryName": "Runner", "subFrames": [{"symbolName": "FirebaseApp.configure", "binaryName": "App.framework", "subFrames": [{"symbolName": sentinel, "binaryName": sentinel, "subFrames": []}]}]}]}]}]}]}]}
        report = collector.collect(self.client(FakeTransport(self.base([
            ("/apps/app-1/betaFeedbackCrashSubmissions", submissions_document([submission])),
            ("/betaFeedbackCrashSubmissions/s-credential/crashLog", {"data": resource("betaCrashLogs", "log-credential", {"logText": crash})}),
            ("/builds/build-17/diagnosticSignatures", {"data": [signature]}),
            ("/diagnosticSignatures/d-credential/logs", diagnostic),
        ]))))
        serialized = json.dumps(report) + collector.markdown(report)
        for credential in credentials:
            self.assertNotIn(credential, serialized)
        self.assertIn("Runner!main", serialized)
        self.assertIn("App.framework!FirebaseApp.configure", serialized)
        self.assertIn("01234567-89AB-CDEF-0123-456789ABCDEF", serialized)

    def test_serialized_output_has_no_sentinel_pii_or_raw_values(self):
        sentinel = "tester@example.test COMMENT_SECRET /Users/secret/crash.ips 0xABCDEF deviceUniqueId-999 incident_id-777 en_US America/Seoul eyJhbGciOiJIUzI1NiJ9"
        report = collector.collect(self.client(FakeTransport(self.base([
            ("/builds/build-17/diagnosticSignatures", {"data": [resource("diagnosticSignatures", "d", {"diagnosticType": "HANGS", "signature": sentinel, "weight": 1})]}),
            ("/diagnosticSignatures/d/logs", official_diagnostic_log(event=sentinel, architecture=sentinel, symbol=sentinel)),
        ]))))
        serialized = json.dumps(report) + collector.markdown(report)
        self.assertNotRegex(serialized, re.compile(r"tester@example|COMMENT_SECRET|/Users/secret|0xABCDEF|deviceUniqueId|incident_id|en_US|America/Seoul|eyJhbGci|request-safe-1|request_ids"))

    def test_crash_safe_fields_reject_unique_identifiers_and_keep_runner_uuid(self):
        sentinel = "device-unique-id-999 incidentId-777 tester@example.test COMMENTSECRET /Users/private/a 0xABCDEF eyJhbGciOiJIUzI1NiJ9"
        evidence = collector.parse_crash_log(json.dumps({"modelCode": sentinel, "family": "en_US", "osVersion": "America/Seoul", "cpuType": sentinel, "exception": {"type": sentinel}, "termination": {"reason": sentinel}, "faultingThread": "device_id_1", "threads": [{"triggered": True, "frames": [{"symbol": sentinel}]}], "usedImages": [{"name": "Runner", "uuid": "01234567-89AB-CDEF-0123-456789ABCDEF"}]}))
        serialized = json.dumps(evidence)
        self.assertNotRegex(serialized, r"device-unique|incidentId|tester@example|COMMENTSECRET|/Users|0xABCDEF|eyJhbGci|en_US|America/Seoul")
        self.assertEqual(evidence["binary_uuid"], "01234567-89AB-CDEF-0123-456789ABCDEF")

    def test_source_contract_and_workflow_contract(self):
        source = (ROOT / "scripts/collect_asc_beta_crash_feedback.py").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/ios-testflight-crash-feedback.yml").read_text(encoding="utf-8")
        self.assertNotRegex(source, r"\b(?:POST|PATCH|DELETE|PUT)\b")
        self.assertIn('method="GET"', source)
        self.assertIn("MAX_RESPONSE_BYTES", source)
        self.assertIn("application/vnd.apple.diagnostic-logs+json", source)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("inputs:", workflow)
        self.assertIn("Build17", workflow)
        self.assertIn("build-17", workflow)
        self.assertIn("APP_STORE_CONNECT_KEY_ID", workflow)
        self.assertIn("APP_STORE_CONNECT_ISSUER_ID", workflow)
        self.assertIn("APP_STORE_CONNECT_API_KEY_P8", workflow)
        self.assertIn("if: ${{ always() }}", workflow)
        self.assertIn("retention-days: 7", workflow)
        before_steps = workflow.split("    steps:", 1)[0]
        self.assertNotIn("APP_STORE_CONNECT_KEY_ID", before_steps)
        self.assertIn("if: ${{ github.ref == 'refs/heads/main' }}", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("id: cleanup", workflow)
        self.assertIn('echo "cleanup_ok=$cleanup_ok" >> "$GITHUB_OUTPUT"', workflow)
        self.assertIn('[[ ! -e "$key_path" ]]', workflow)
        self.assertIn("steps.cleanup.outputs.cleanup_ok", workflow)
        gate = lambda result, cleanup_ok: result == "0" and cleanup_ok == "true"
        self.assertTrue(gate("0", "true"))
        self.assertFalse(gate("0", "false"))
        self.assertFalse(gate("1", "true"))
        checkout = workflow.index("Checkout trusted main collector")
        collect = workflow.index("Collect sanitized Build 17 evidence")
        cleanup = workflow.index("Cleanup protected credential material")
        summary = workflow.index("Append sanitized summary")
        upload = workflow.index("Upload sanitized Build 17 evidence")
        final_gate = workflow.index("Fail closed on collection result")
        self.assertLess(checkout, collect)
        self.assertLess(collect, cleanup)
        self.assertLess(cleanup, summary)
        self.assertLess(summary, upload)
        self.assertLess(upload, final_gate)


if __name__ == "__main__":
    unittest.main()
