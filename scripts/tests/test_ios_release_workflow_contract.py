"""Contract tests for .github/workflows/ios-release.yml.

This workflow passed a long real-world qualification (signing/provisioning,
WidgetKit/App Group, Apple 90683 privacy surface, exact dSYM UUID matching,
IPA export, Apple transport, TestFlight, on-device verification). A later
change generalized the Build 22 hardcoding into workflow_dispatch inputs.

These tests read the workflow YAML from disk (no network calls, no workflow
dispatch) and assert that the generalization did not silently drop any of the
previously-qualified steps or safety gates. Do not loosen these assertions to
make a failing test pass -- a failure here means the workflow regressed.
"""

import pathlib
import re
import sys
import unittest

try:
    import yaml

    HAVE_YAML = True
except ImportError:  # pragma: no cover - environment without PyYAML
    HAVE_YAML = False

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "ios-release.yml"


def _load_workflow_text():
    return WORKFLOW_PATH.read_text(encoding="utf-8")


class WorkflowTextTests(unittest.TestCase):
    """Assertions against the raw YAML text (style matches
    test_collect_asc_beta_crash_feedback.py's workflow-text assertions)."""

    @classmethod
    def setUpClass(cls):
        cls.workflow = _load_workflow_text()

    # -- B. Build 22 remnants must be fully removed -----------------------

    def test_no_build_22_references_anywhere(self):
        matches = re.findall(r"(?i)build\s?22", self.workflow)
        self.assertEqual(matches, [], f"Found Build 22 remnants: {matches!r}")

    def test_no_hardcoded_ios_build_number_22(self):
        self.assertNotRegex(self.workflow, r"IOS_BUILD_NUMBER:\s*22\b")

    def test_no_old_build_number_equality_gate(self):
        self.assertNotIn('!= "22"', self.workflow)

    def test_legacy_error_code_is_reused_not_removed(self):
        self.assertIn("BLOCKED_IOS_BUILD_NUMBER_CONFIG", self.workflow)

    # -- C. Symbols staging directory literal consistency ------------------

    def test_symbols_directory_literal_is_consistent_everywhere(self):
        # Broad capture: anything of the shape planflow-ios-build<...>symbols
        # (stops right after "symbols" so trailing artifact-name suffixes
        # like "-${{ github.run_number }}" are excluded from the match).
        occurrences = re.findall(
            r"planflow-ios-build[\w${}.:\-]*symbols", self.workflow
        )
        self.assertGreaterEqual(
            len(occurrences),
            2,
            "Expected the symbols staging directory literal to be collected "
            "from at least 2 locations (staging create, artifact upload "
            "name/path, cleanup rm).",
        )

        def normalize(token):
            # Bash interpolation forms: ${IOS_BUILD_NUMBER} or
            # ${IOS_BUILD_NUMBER:-}
            token = re.sub(
                r"\$\{IOS_BUILD_NUMBER(:-)?\}", "<NUM>", token, flags=re.IGNORECASE
            )
            # GitHub Actions expression form: ${{ env.IOS_BUILD_NUMBER }}
            token = re.sub(
                r"\$\{\{\s*env\.IOS_BUILD_NUMBER\s*\}\}",
                "<NUM>",
                token,
                flags=re.IGNORECASE,
            )
            return token

        normalized = {normalize(token) for token in occurrences}
        self.assertEqual(
            normalized,
            {"planflow-ios-build<NUM>-symbols"},
            "The symbols staging directory literal is not identical across "
            "every reference to it (staging create / artifact upload name / "
            "artifact upload path / cleanup rm). A drifted or hardcoded "
            "literal here causes the artifact upload to fail silently "
            "because of if-no-files-found: error. Raw occurrences found: "
            f"{occurrences!r}",
        )

    # -- D. Preservation list: previously-qualified components must remain -

    PRESERVED_MARKERS = [
        "actions/checkout@v4",
        "refs/heads/main",
        "ITSAppUsesNonExemptEncryption",
        "group.com.fluxstudio.planflow",
        "--require-binary-scan",
        "retention-days: 90",
        "if-no-files-found: error",
        "altool",
        "3.47.2",
        "verify-ios-firebase-config.sh",
        "verify-app-store-build.py",
        "verify-ios-privacy-surface.py",
        "signing_identity_count",
        ".appex",
        "export-options.plist",
        "com.fluxstudio.planflow",
    ]

    def test_all_preserved_markers_present(self):
        for marker in self.PRESERVED_MARKERS:
            with self.subTest(marker=marker):
                self.assertIn(
                    marker,
                    self.workflow,
                    f"Previously-qualified marker disappeared: {marker!r}",
                )

    def test_export_compliance_checked_at_all_three_layers(self):
        count = self.workflow.count("ITSAppUsesNonExemptEncryption")
        self.assertGreaterEqual(
            count,
            3,
            "Expected ITSAppUsesNonExemptEncryption to be checked at the "
            "source, archive, and exported-IPA layers (>=3 occurrences).",
        )

    def test_binary_scan_flag_used_at_least_twice(self):
        count = self.workflow.count("--require-binary-scan")
        self.assertGreaterEqual(
            count,
            2,
            "Expected --require-binary-scan to be used for both the "
            "archive and exported-IPA privacy preflight checks.",
        )

    def test_widget_app_group_checked_at_least_twice(self):
        count = self.workflow.count("group.com.fluxstudio.planflow")
        self.assertGreaterEqual(
            count,
            2,
            "Expected the canonical widget app group literal to appear at "
            "least twice (declared + verified).",
        )

    # -- E. Step ordering ----------------------------------------------------

    def test_step_order_checkout_through_cleanup(self):
        # Stable content keywords rather than full step names, so cosmetic
        # renames of step "name:" fields don't spuriously break this test.
        keywords_in_order = [
            "actions/checkout@v4",  # checkout
            "refs/heads/main",  # ref/build gate
            "flutter build ios",  # Flutter build
            "security import",  # signing
            "xcodebuild archive",  # archive
            "dwarfdump --uuid",  # dSYM/symbols verification
            "-exportArchive",  # IPA export
            "altool",  # Apple transport
            "Secret cleanup gate executed",  # cleanup
        ]
        indices = []
        for keyword in keywords_in_order:
            idx = self.workflow.find(keyword)
            self.assertNotEqual(idx, -1, f"Expected keyword not found: {keyword!r}")
            indices.append(idx)
        self.assertEqual(
            indices,
            sorted(indices),
            f"Steps are out of the expected qualified order: {list(zip(keywords_in_order, indices))}",
        )

    def test_apple_transport_step_names_exist_for_retry_verdict(self):
        # The orchestrator's retry-verdict logic distinguishes "before
        # Apple transport" from "after Apple transport" failures using
        # these step name keywords. If they disappear, retry classification
        # degrades to UNKNOWN.
        self.assertIn("Export signed IPA", self.workflow)
        self.assertIn("Upload IPA to TestFlight", self.workflow)

    # -- F. dry_run gating -----------------------------------------------

    def test_altool_step_is_gated_on_dry_run(self):
        match = re.search(
            r'name:\s*Upload IPA to TestFlight[^\n]*\n\s*if:\s*\$\{\{\s*inputs\.dry_run\s*!=\s*true\s*\}\}',
            self.workflow,
        )
        self.assertIsNotNone(
            match,
            "Expected the Apple transport (altool) step to be immediately "
            "gated by an 'if: inputs.dry_run != true' condition.",
        )

    def test_ingestion_verification_step_is_gated_on_dry_run(self):
        # verify-app-store-build.py must run inside the same non-dry-run
        # gated step as altool (it is not a separate step in this workflow).
        altool_step_start = self.workflow.index("Upload IPA to TestFlight")
        dry_run_stop_start = self.workflow.index("Dry run stop before Apple transport")
        self.assertLess(altool_step_start, dry_run_stop_start)
        gated_block = self.workflow[altool_step_start:dry_run_stop_start]
        self.assertIn("verify-app-store-build.py", gated_block)
        self.assertIn("inputs.dry_run != true", gated_block)

    def test_dry_run_stop_marker_exists(self):
        self.assertIn("DRY_RUN_STOP_BEFORE_TRANSPORT", self.workflow)

    def test_cleanup_step_still_always_runs(self):
        cleanup_idx = self.workflow.index("Cleanup protected artifacts")
        # The "if: ${{ always() }}" condition must be the one immediately
        # associated with the Cleanup protected artifacts step, not some
        # unrelated step earlier in the file.
        following = self.workflow[cleanup_idx : cleanup_idx + 200]
        self.assertIn(
            "always()",
            following,
            "Cleanup protected artifacts must keep an always() condition so "
            "secret material is removed even when dry_run stops the run "
            "early or an earlier step fails.",
        )

    # -- G. ASC call contract --------------------------------------------

    def test_asc_next_build_number_script_invoked_with_required_flags(self):
        self.assertIn("scripts/asc-next-build-number.py", self.workflow)
        self.assertIn("--emit-github-env", self.workflow)
        self.assertIn("--json", self.workflow)

    def test_asc_credential_secrets_still_referenced(self):
        for secret_name in (
            "APP_STORE_CONNECT_KEY_ID",
            "APP_STORE_CONNECT_ISSUER_ID",
            "APP_STORE_CONNECT_API_KEY_P8",
        ):
            with self.subTest(secret_name=secret_name):
                self.assertIn(secret_name, self.workflow)

    # -- H. Secret safety --------------------------------------------------

    def test_no_hardcoded_credential_values(self):
        forbidden_patterns = [
            r"ghp_[A-Za-z0-9]",
            r"github_pat_[A-Za-z0-9]",
            r"-----BEGIN",
            re.escape(r"E:\FluxStudio\secrets"),
        ]
        for pattern in forbidden_patterns:
            with self.subTest(pattern=pattern):
                self.assertNotRegex(self.workflow, pattern)

    def test_secrets_are_only_referenced_via_expression_syntax(self):
        # Every use of the word "secrets." in the workflow must be inside a
        # ${{ secrets.NAME }} expression, never a bare literal value.
        for match in re.finditer(r"secrets\.[A-Za-z0-9_]+", self.workflow):
            start = match.start()
            preceding = self.workflow[max(0, start - 4) : start]
            self.assertIn(
                "${{",
                self.workflow[max(0, start - 20) : start],
                f"Found a 'secrets.' reference not wrapped in ${{{{ }}}}: "
                f"...{self.workflow[max(0, start - 20):start + 30]!r}",
            )


@unittest.skipUnless(HAVE_YAML, "PyYAML is not installed in this environment")
class WorkflowYamlTests(unittest.TestCase):
    """Assertions against the parsed YAML structure."""

    @classmethod
    def setUpClass(cls):
        cls.doc = yaml.safe_load(_load_workflow_text())
        # "on:" parses to the boolean key True under PyYAML's default
        # resolver.
        cls.inputs = cls.doc[True]["workflow_dispatch"]["inputs"]

    def test_exactly_four_workflow_dispatch_inputs(self):
        self.assertEqual(
            set(self.inputs.keys()),
            {
                "build_number",
                "build_name",
                "allow_version_train_change",
                "dry_run",
            },
        )

    def test_string_inputs_are_optional_with_empty_default(self):
        for name in ("build_number", "build_name"):
            with self.subTest(name=name):
                spec = self.inputs[name]
                self.assertEqual(spec.get("type"), "string")
                self.assertFalse(spec.get("required", False))
                self.assertEqual(spec.get("default"), "")

    def test_boolean_inputs_default_false(self):
        for name in ("allow_version_train_change", "dry_run"):
            with self.subTest(name=name):
                spec = self.inputs[name]
                self.assertEqual(spec.get("type"), "boolean")
                self.assertFalse(spec.get("required", False))
                self.assertIs(spec.get("default"), False)

    def test_allow_version_train_change_defaults_false_not_true(self):
        # Explicit, isolated guard-rail assertion: this input controls
        # whether the App Store version train can silently change. If its
        # default flips to true, that guard-rail is defeated by default.
        spec = self.inputs["allow_version_train_change"]
        self.assertIs(
            spec.get("default"),
            False,
            "allow_version_train_change must default to false; a true "
            "default would let the App Store version train change "
            "silently on an un-parameterized dispatch.",
        )


if __name__ == "__main__":
    unittest.main()
