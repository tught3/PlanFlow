"""Unit tests for scripts/asc-next-build-number.py.

The module under test has a hyphenated filename (asc-next-build-number.py),
so it cannot be imported with a plain `import` statement. We load it via
importlib.util.spec_from_file_location, after inserting the scripts/
directory onto sys.path (mirroring the sys.path.insert pattern used by
test_collect_asc_beta_crash_feedback.py in this same directory, adapted with
importlib for the hyphenated filename).

No test in this file performs a real network call. Every ASC HTTP boundary
(fetch_json's `transport` parameter) is exercised through FakeTransport.
A module-wide guard patches urllib.request.urlopen to raise if anything
ever falls through to the real network path, so a missing transport
injection fails loudly instead of silently hitting the internet.
"""

import contextlib
import importlib.util
import io
import pathlib
import sys
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS_DIR = ROOT / "scripts"
MODULE_PATH = SCRIPTS_DIR / "asc-next-build-number.py"

sys.path.insert(0, str(SCRIPTS_DIR))
_SPEC = importlib.util.spec_from_file_location("asc_next_build_number", MODULE_PATH)
asc = importlib.util.module_from_spec(_SPEC)
sys.modules["asc_next_build_number"] = asc
_SPEC.loader.exec_module(asc)


def build_resource(version, pre_release_id=None):
    relationships = {}
    if pre_release_id is not None:
        relationships["preReleaseVersion"] = {"data": {"type": "preReleaseVersions", "id": pre_release_id}}
    return {"type": "builds", "id": f"build-{version}", "attributes": {"version": version}, "relationships": relationships}


def pre_release_resource(ident, version):
    return {"type": "preReleaseVersions", "id": ident, "attributes": {"version": version}}


class FakeTransport:
    """Stand-in for the `transport(url, token)` callable fetch_json() accepts.

    Responses are registered as (substring, response_dict) pairs and matched
    in registration order by substring containment against the requested
    URL. Any URL that matches nothing raises AssertionError so a wiring
    mistake in a test is loud rather than silently returning {}.
    """

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, url, token):
        self.calls.append(url)
        for needle, response in self.responses:
            if needle in url:
                return response
        raise AssertionError(f"FakeTransport received an unexpected URL: {url}")


class NoNetworkGuardMixin:
    """Fails any test that falls through to a real urllib.request.urlopen call."""

    def setUp(self):
        patcher = mock.patch(
            "urllib.request.urlopen",
            side_effect=AssertionError("test attempted a real network call via urllib.request.urlopen"),
        )
        patcher.start()
        self.addCleanup(patcher.stop)


class ComputeNextBuildNumberTests(NoNetworkGuardMixin, unittest.TestCase):
    """Direct tests of the pure function compute_next_build_number()."""

    def test_normal_sequence_returns_max_plus_one(self):
        builds = [build_resource(v) for v in ("20", "22", "21")]
        result = asc.compute_next_build_number(builds)
        self.assertEqual(result["nextBuildNumber"], 23)
        self.assertEqual(result["latestBuildNumber"], 22)
        self.assertEqual(result["scannedBuilds"], 3)
        self.assertEqual(result["skippedNonNumeric"], 0)

    def test_nonconsecutive_sequence_uses_max_not_count(self):
        builds = [build_resource(v) for v in ("5", "100")]
        result = asc.compute_next_build_number(builds)
        self.assertEqual(result["nextBuildNumber"], 101)
        self.assertEqual(result["latestBuildNumber"], 100)

    def test_mixed_version_trains_use_global_max_not_per_train_max(self):
        """The whole reason this test module exists.

        Build 22 belongs to the 1.0.0 train; build 9 belongs to a newer
        1.1.1 train. A per-train computation would wrongly return 10
        (9 + 1) for the 1.1.1 train. Apple requires CFBundleVersion
        uniqueness only within a train, but re-using a number from another
        train is still a real-world upload hazard this script exists to
        avoid, so the correct answer is always the GLOBAL max + 1 = 23,
        regardless of which train the max came from.
        """
        builds = [
            build_resource("22", pre_release_id="train-1.0.0"),
            build_resource("9", pre_release_id="train-1.1.1"),
            build_resource("15", pre_release_id="train-1.0.0"),
        ]
        result = asc.compute_next_build_number(builds)
        self.assertEqual(result["nextBuildNumber"], 23)
        self.assertEqual(result["latestBuildNumber"], 22)
        self.assertNotEqual(result["nextBuildNumber"], 10, "must not fall back to a per-train maximum")

    def test_non_numeric_versions_are_skipped_and_counted(self):
        builds = [build_resource(v) for v in ("22", "1.0.0", "abc")]
        result = asc.compute_next_build_number(builds)
        self.assertEqual(result["nextBuildNumber"], 23)
        self.assertEqual(result["latestBuildNumber"], 22)
        self.assertEqual(result["scannedBuilds"], 3)
        self.assertEqual(result["skippedNonNumeric"], 2)

    def test_all_non_numeric_versions_raise_no_builds_value_error(self):
        builds = [build_resource(v) for v in ("1.0.0", "abc")]
        with self.assertRaises(ValueError) as ctx:
            asc.compute_next_build_number(builds)
        self.assertIn("BLOCKED_ASC_NO_BUILDS", str(ctx.exception))

    def test_empty_build_list_raises_no_builds_value_error(self):
        with self.assertRaises(ValueError) as ctx:
            asc.compute_next_build_number([])
        self.assertIn("BLOCKED_ASC_NO_BUILDS", str(ctx.exception))

    def test_single_build(self):
        result = asc.compute_next_build_number([build_resource("1")])
        self.assertEqual(result["nextBuildNumber"], 2)
        self.assertEqual(result["latestBuildNumber"], 1)

    def test_large_value_string_to_int_conversion(self):
        result = asc.compute_next_build_number([build_resource("999999")])
        self.assertEqual(result["nextBuildNumber"], 1000000)
        self.assertEqual(result["latestBuildNumber"], 999999)


class ResolveAppIdTests(NoNetworkGuardMixin, unittest.TestCase):
    """Integration-path tests for resolve_app_id() through FakeTransport."""

    def test_app_not_found_raises_blocked_error_with_exit_code_3(self):
        transport = FakeTransport([("/apps?", {"data": []})])
        with self.assertRaises(asc.BlockedError) as ctx:
            asc.resolve_app_id("fake-token", "com.fluxstudio.planflow", transport)
        self.assertEqual(ctx.exception.exit_code, asc.EXIT_APP_NOT_FOUND)
        self.assertEqual(ctx.exception.code, "BLOCKED_ASC_APP_NOT_FOUND")

    def test_app_lookup_http_error_raises_blocked_error_with_exit_code_5(self):
        transport = FakeTransport([("/apps?", {"__http_status": 500, "errors": [{"status": "500", "detail": "server exploded"}]})])
        with self.assertRaises(asc.BlockedError) as ctx:
            asc.resolve_app_id("fake-token", "com.fluxstudio.planflow", transport)
        self.assertEqual(ctx.exception.exit_code, asc.EXIT_API_ERROR)
        self.assertEqual(ctx.exception.code, "BLOCKED_ASC_API_ERROR")

    def test_app_found_returns_id(self):
        transport = FakeTransport([("/apps?", {"data": [{"type": "apps", "id": "app-42", "attributes": {"bundleId": "com.fluxstudio.planflow"}}]})])
        app_id = asc.resolve_app_id("fake-token", "com.fluxstudio.planflow", transport)
        self.assertEqual(app_id, "app-42")


class CollectAllBuildsTests(NoNetworkGuardMixin, unittest.TestCase):
    """Integration-path tests for collect_all_builds() through FakeTransport, including paging."""

    def test_pagination_collects_every_page_before_computing_max(self):
        page_one = {
            "data": [build_resource("50"), build_resource("40")],
            "links": {"next": "https://api.appstoreconnect.apple.com/v1/builds?cursor=page2"},
        }
        page_two = {"data": [build_resource("80"), build_resource("60")]}
        transport = FakeTransport(
            [
                ("cursor=page2", page_two),
                ("/builds?", page_one),
            ]
        )
        builds, included_by_id = asc.collect_all_builds("fake-token", "app-42", transport)
        self.assertEqual(len(builds), 4)
        self.assertEqual(included_by_id, {})
        result = asc.compute_next_build_number(builds)
        self.assertEqual(result["latestBuildNumber"], 80, "must scan the second page, not stop after the first")
        self.assertEqual(result["nextBuildNumber"], 81)

    def test_build_lookup_http_error_raises_blocked_error_with_exit_code_5(self):
        transport = FakeTransport([("/builds?", {"errors": [{"status": "503", "detail": "unavailable"}]})])
        with self.assertRaises(asc.BlockedError) as ctx:
            asc.collect_all_builds("fake-token", "app-42", transport)
        self.assertEqual(ctx.exception.exit_code, asc.EXIT_API_ERROR)
        self.assertEqual(ctx.exception.code, "BLOCKED_ASC_API_ERROR")

    def test_included_resources_are_indexed_by_id(self):
        page = {
            "data": [build_resource("10", pre_release_id="pre-1")],
            "included": [pre_release_resource("pre-1", "1.0.0")],
        }
        transport = FakeTransport([("/builds?", page)])
        builds, included_by_id = asc.collect_all_builds("fake-token", "app-42", transport)
        self.assertEqual(len(builds), 1)
        self.assertIn("pre-1", included_by_id)
        self.assertEqual(included_by_id["pre-1"]["attributes"]["version"], "1.0.0")


class ResolveLatestTrainTests(NoNetworkGuardMixin, unittest.TestCase):
    """resolve_latest_train() is documented as best-effort: failures return None,
    they never propagate and never fail the overall resolution."""

    def test_successful_lookup_returns_train_version(self):
        builds = [
            build_resource("5"),
            build_resource("12", pre_release_id="pre-1"),
        ]
        included_by_id = {"pre-1": pre_release_resource("pre-1", "1.5.0")}
        train = asc.resolve_latest_train(builds, included_by_id, 12)
        self.assertEqual(train, "1.5.0")

    def test_missing_relationship_returns_none_without_raising(self):
        builds = [build_resource("12")]  # no preReleaseVersion relationship
        train = asc.resolve_latest_train(builds, {}, 12)
        self.assertIsNone(train)

    def test_malformed_build_entry_is_swallowed_and_returns_none(self):
        """A non-dict build entry would raise AttributeError inside the loop;
        resolve_latest_train's contract is to swallow it and return None
        rather than let the whole run() pipeline fail on best-effort data."""
        builds = [None, "not-a-build"]
        train = asc.resolve_latest_train(builds, {}, 12)
        self.assertIsNone(train)


class RedactTests(NoNetworkGuardMixin, unittest.TestCase):
    """redact() must strip PEM key blocks, JWTs, and bearer tokens from any
    text before it can reach stdout/stderr."""

    def test_pem_private_key_block_is_redacted(self):
        text = (
            "context before\n"
            "-----BEGIN PRIVATE KEY-----\n"
            "MIIFAKEKEYDATAFAKEKEYDATAFAKEKEYDATA==\n"
            "-----END PRIVATE KEY-----\n"
            "context after"
        )
        redacted = asc.redact(text)
        self.assertNotIn("MIIFAKEKEYDATA", redacted)
        self.assertNotIn("BEGIN PRIVATE KEY", redacted)
        self.assertIn("[REDACTED]", redacted)
        self.assertIn("context before", redacted)
        self.assertIn("context after", redacted)

    def test_jwt_like_token_is_redacted(self):
        fake_jwt = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJmYWtlLWlzc3VlciJ9.ZmFrZS1zaWduYXR1cmU"
        text = f"received token {fake_jwt} during request"
        redacted = asc.redact(text)
        self.assertNotIn(fake_jwt, redacted)
        self.assertIn("[REDACTED]", redacted)

    def test_authorization_bearer_header_value_is_redacted(self):
        text = "Authorization: Bearer super-secret-token-value-123"
        redacted = asc.redact(text)
        self.assertNotIn("super-secret-token-value-123", redacted)
        self.assertIn("Authorization: Bearer [REDACTED]", redacted)

    def test_empty_and_none_like_input_is_returned_unchanged(self):
        self.assertEqual(asc.redact(""), "")


class ErrorPathRedactionTests(NoNetworkGuardMixin, unittest.TestCase):
    """Exercise the real error-formatting code paths (error_summary, main's
    exception handlers) with secret-shaped values and assert the secrets
    never survive into the printed/returned text."""

    def test_error_summary_redacts_jwt_in_asc_error_detail(self):
        fake_jwt = "eyJhbGciOiJIUzI1NiJ9.abc123.def456"
        document = {"errors": [{"code": "AUTH", "status": "401", "detail": f"rejected token {fake_jwt} leaked in detail"}]}
        summary = asc.error_summary(document)
        self.assertNotIn(fake_jwt, summary)
        self.assertIn("[REDACTED]", summary)

    def test_blocked_error_message_is_redacted_before_printing_in_main(self):
        fake_pem = "-----BEGIN PRIVATE KEY-----\nSECRETKEYDATA\n-----END PRIVATE KEY-----"
        leaking_error = asc.BlockedError(asc.EXIT_CREDENTIALS, "BLOCKED_ASC_CREDENTIALS", f"signing failed with key {fake_pem}")
        with mock.patch.object(asc, "run", side_effect=leaking_error):
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                exit_code = asc.main(["--bundle-id", "com.fluxstudio.planflow"])
        self.assertEqual(exit_code, asc.EXIT_CREDENTIALS)
        output = stderr.getvalue()
        self.assertNotIn("SECRETKEYDATA", output)
        self.assertIn("BLOCKED_ASC_CREDENTIALS", output)

    def test_unexpected_exception_message_is_redacted_and_bounded_in_main(self):
        fake_jwt = "eyJhbGciOiJIUzI1NiJ9." + ("a" * 300) + ".sig"
        with mock.patch.object(asc, "run", side_effect=RuntimeError(f"boom with token {fake_jwt}")):
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                exit_code = asc.main(["--bundle-id", "com.fluxstudio.planflow"])
        self.assertEqual(exit_code, asc.EXIT_API_ERROR)
        output = stderr.getvalue()
        self.assertNotIn(fake_jwt, output)
        self.assertIn("BLOCKED_ASC_API_ERROR", output)


if __name__ == "__main__":
    unittest.main()
