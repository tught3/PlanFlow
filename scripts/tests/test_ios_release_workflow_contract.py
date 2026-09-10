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

import json
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
            "--upload-app",  # Apple transport (now its own step)
            "scripts/verify-app-store-build.py",  # ingestion verification (separate step)
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
        self.assertIn("Verify App Store ingestion", self.workflow)

    # -- F. dry_run gating -----------------------------------------------

    # The Apple transport gate must be POSITIVE (fail-closed). A negated
    # gate ("run unless dry_run is exactly the boolean true") is fail-open:
    # every value that is not that native boolean -- a string, an empty
    # value, a mis-cast workflow_dispatch input -- satisfies it and produces
    # an irreversible TestFlight upload that also consumes a build number.
    # The literal expression the workflow must use, and its exact negation
    # for the dry-run-stop step.
    DRY_RUN_FALSE_EXPR = "inputs.dry_run == false || inputs.dry_run == 'false'"
    DRY_RUN_GATE = "${{ " + DRY_RUN_FALSE_EXPR + " }}"
    DRY_RUN_STOP_GATE = "${{ !(" + DRY_RUN_FALSE_EXPR + ") }}"

    def test_altool_step_is_gated_fail_closed_on_dry_run(self):
        match = re.search(
            r"name:\s*Upload IPA to TestFlight[^\n]*\n\s*if:\s*"
            + re.escape(self.DRY_RUN_GATE),
            self.workflow,
        )
        self.assertIsNotNone(
            match,
            "Expected the Apple transport (altool) step to be immediately "
            "gated by the fail-closed condition "
            f"'if: {self.DRY_RUN_GATE}', i.e. the transport runs only when "
            "dry_run is explicitly false. Actual text after the step name: "
            f"{self.workflow[self.workflow.index('Upload IPA to TestFlight'):self.workflow.index('Upload IPA to TestFlight') + 200]!r}",
        )

    def test_no_negated_dry_run_gate_anywhere_in_the_workflow(self):
        # Regression guard for the exact defect this replaced: any surviving
        # 'inputs.dry_run !=' gate is fail-open in the upload direction.
        self.assertNotRegex(
            self.workflow,
            r"inputs\.dry_run\s*!=",
            "Found a negated dry_run gate. A negated gate lets any "
            "non-boolean dry_run value reach the Apple transport, which is "
            "an irreversible upload. Gate on an explicit false instead.",
        )

    def test_transport_step_reasserts_dry_run_in_the_shell(self):
        # Double defense: the if: expression is evaluated by GitHub's
        # expression engine (whose casting rules are what caused the
        # original defect), so the step body re-checks the same value in
        # bash, in the same style as the ALLOW_VERSION_TRAIN_CHANGE guard,
        # and refuses to run altool unless it is literally "false".
        upload_idx = self.workflow.index("- name: Upload IPA to TestFlight")
        ingestion_idx = self.workflow.index("- name: Verify App Store ingestion")
        upload_block = self.workflow[upload_idx:ingestion_idx]
        self.assertIn(
            "DRY_RUN: ${{ inputs.dry_run }}",
            upload_block,
            "The transport step must pass dry_run into the shell via env: so "
            "the value can be re-asserted with a quoted \"$VAR\" test.",
        )
        assert_idx = upload_block.find('if [[ "${DRY_RUN:-}" != "false" ]]; then')
        self.assertNotEqual(
            assert_idx,
            -1,
            "Expected a shell-level fail-closed re-assertion "
            "'if [[ \"${DRY_RUN:-}\" != \"false\" ]]; then' inside the "
            "Apple transport step body.",
        )
        self.assertIn("BLOCKED_DRY_RUN_ASSERT", upload_block)
        exit_idx = upload_block.find("exit 1", assert_idx)
        upload_call_idx = upload_block.index("--upload-app")
        self.assertNotEqual(exit_idx, -1, "The shell re-assertion must exit 1.")
        self.assertLess(
            exit_idx,
            upload_call_idx,
            "The shell re-assertion must exit BEFORE 'xcrun altool "
            "--upload-app' runs; an assertion after the transport cannot "
            "prevent an irreversible upload.",
        )

    def test_ingestion_verification_step_is_gated_fail_closed_on_dry_run(self):
        # verify-app-store-build.py now runs in its own "Verify App Store
        # ingestion" step, deliberately separate from the altool upload step
        # (see the workflow's own comment above that step). Both steps must
        # still fall between the IPA export and the dry-run-stop step, and
        # both must independently carry the same fail-closed gate -- a
        # shared gate on only one of them would let the other run
        # unconditionally.
        export_ipa_start = self.workflow.index("Export signed IPA")
        dry_run_stop_start = self.workflow.index(
            "- name: Dry run stop before Apple transport"
        )
        self.assertLess(export_ipa_start, dry_run_stop_start)
        gated_block = self.workflow[export_ipa_start:dry_run_stop_start]
        self.assertIn("verify-app-store-build.py", gated_block)
        self.assertEqual(
            gated_block.count("if: " + self.DRY_RUN_GATE),
            2,
            "Expected exactly two fail-closed "
            f"'if: {self.DRY_RUN_GATE}' gates between IPA export and the "
            "dry-run-stop step: one for the 'Upload IPA to TestFlight' step "
            "and one for the separate 'Verify App Store ingestion' step. A "
            "single shared gate would mean one of the two steps runs "
            "unconditionally.",
        )

    def test_dry_run_stop_gate_is_the_exact_negation_of_the_transport_gate(self):
        # Statically provable coverage: the stop step's condition is the
        # literal negation of the transport gate, so for ANY value of
        # dry_run exactly one of the two branches runs. Without this, an
        # ambiguous value could skip both and leave no record in the log of
        # which path the run took.
        stop_idx = self.workflow.index("- name: Dry run stop before Apple transport")
        stop_block = self.workflow[stop_idx : stop_idx + 400]
        self.assertIn(
            "if: " + self.DRY_RUN_STOP_GATE,
            stop_block,
            "The dry-run-stop step's condition must be the exact negation "
            f"of the transport gate, i.e. 'if: {self.DRY_RUN_STOP_GATE}'. "
            "Any other condition can leave a value of dry_run for which "
            "neither the transport nor the stop step runs.",
        )

    def test_dry_run_stop_step_fails_closed_on_an_ambiguous_value(self):
        # The stop step now also covers the ambiguous case (it is the
        # negation of "explicitly false", so it runs for true AND for
        # anything unrecognized). It must not report a clean dry-run PASS
        # for a value that was never a real dry-run request.
        stop_idx = self.workflow.index("- name: Dry run stop before Apple transport")
        end_idx = self.workflow.index("- name: Preserve iOS privacy audit reports")
        stop_block = self.workflow[stop_idx:end_idx]
        self.assertIn('if [[ "${DRY_RUN:-}" == "true" ]]; then', stop_block)
        self.assertIn("DRY_RUN_STOP_BEFORE_TRANSPORT: PASS", stop_block)
        self.assertIn("BLOCKED_DRY_RUN_AMBIGUOUS", stop_block)
        ambiguous_idx = stop_block.index("BLOCKED_DRY_RUN_AMBIGUOUS")
        self.assertIn(
            "exit 1",
            stop_block[ambiguous_idx:],
            "An ambiguous dry_run value must fail the run instead of being "
            "reported as a successful dry run.",
        )

    # -- F2. Declared success marker must actually be emitted -------------

    def test_success_marker_is_emitted_by_the_workflow(self):
        self.assertIn(
            "TESTFLIGHT_AVAILABLE",
            self.workflow,
            "config/release-manifest.json declares "
            "ios.successMarker = TESTFLIGHT_AVAILABLE as the iOS "
            "auto-completion boundary. If no step ever prints it, every "
            "successful iOS release looks like a failure to any consumer "
            "that looks for the marker.",
        )

    def test_success_marker_is_emitted_only_after_ingestion_passes(self):
        # Transport success and TestFlight availability are different
        # events. The marker must live in the ingestion-verification step,
        # after the ingestion gate message -- never in the transport step
        # (which only proves Apple accepted the binary) and never in the
        # dry-run stop step (which never talks to Apple at all).
        ingestion_idx = self.workflow.index("- name: Verify App Store ingestion")
        stop_idx = self.workflow.index("- name: Dry run stop before Apple transport")
        upload_idx = self.workflow.index("- name: Upload IPA to TestFlight")
        ingestion_block = self.workflow[ingestion_idx:stop_idx]
        upload_block = self.workflow[upload_idx:ingestion_idx]
        stop_block = self.workflow[stop_idx:]
        self.assertNotIn(
            "TESTFLIGHT_AVAILABLE",
            upload_block,
            "The success marker must not be printed by the Apple transport "
            "step: an accepted upload does not mean the build is available "
            "on TestFlight.",
        )
        self.assertNotIn(
            "TESTFLIGHT_AVAILABLE",
            stop_block,
            "The success marker must never be printed on the dry-run path.",
        )
        marker_idx = ingestion_block.find('echo "TESTFLIGHT_AVAILABLE')
        self.assertNotEqual(
            marker_idx,
            -1,
            "Expected the ingestion-verification step to echo the "
            "TESTFLIGHT_AVAILABLE marker.",
        )
        gate_idx = ingestion_block.index("App Store build ingestion gate:")
        failure_exit_idx = ingestion_block.index('exit "$ingestion_status"')
        self.assertLess(
            failure_exit_idx,
            marker_idx,
            "The marker must come after the ingestion-failure exit, so a "
            "failed ingestion can never print it.",
        )
        self.assertLess(
            gate_idx,
            marker_idx,
            "The marker must be printed after the ingestion gate message, "
            "i.e. only once ingestion verification actually passed.",
        )

    def test_manifest_success_marker_matches_a_marker_the_workflow_prints(self):
        manifest_path = ROOT / "config" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        marker = manifest["ios"]["successMarker"]
        self.assertTrue(marker, "config/release-manifest.json declares no marker.")
        self.assertIn(
            f'echo "{marker}',
            self.workflow,
            "config/release-manifest.json's ios.successMarker "
            f"({marker!r}) is not echoed anywhere in ios-release.yml. The "
            "manifest and the workflow must be fixed together, or the "
            "declared iOS completion boundary is unobservable.",
        )

    # -- F3. $GITHUB_ENV is written only with already-validated values ----

    def test_pinned_build_number_is_validated_before_github_env_write(self):
        pinned_block = self._pinned_branch_block()
        validation_idx = pinned_block.find(
            'if [[ ! "$INPUT_BUILD_NUMBER" =~ ^[1-9][0-9]{0,9}$ ]]; then'
        )
        self.assertNotEqual(
            validation_idx,
            -1,
            "Expected the pinned build_number to be format-validated "
            "(digits, no leading zero, <=10 chars, no newline) inside the "
            "resolve step.",
        )
        write_idx = pinned_block.index("printf 'IOS_BUILD_NUMBER=%s")
        self.assertLess(
            validation_idx,
            write_idx,
            "The build_number format check must run BEFORE the value is "
            "appended to $GITHUB_ENV. A multi-line build_number written "
            "first would inject a second environment variable (for example "
            "a forged ASC_LATEST_TRAIN) and silently defeat the "
            "version-train guard.",
        )
        self.assertIn("BLOCKED_IOS_BUILD_NUMBER_CONFIG", pinned_block)

    def test_build_name_is_validated_before_github_env_write(self):
        block = self._resolve_step_block()
        validation_idx = block.find(
            r'if [[ ! "$build_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then'
        )
        self.assertNotEqual(
            validation_idx,
            -1,
            "Expected the resolved marketing version to be format-validated "
            "inside the resolve step.",
        )
        write_idx = block.index("printf 'IOS_BUILD_NAME=%s")
        self.assertLess(
            validation_idx,
            write_idx,
            "The build_name format check must run BEFORE the value is "
            "appended to $GITHUB_ENV, for the same environment-injection "
            "reason as build_number.",
        )

    def test_version_train_is_validated_before_github_env_write(self):
        block = self._resolve_step_block()
        validation_idx = block.find(
            r'elif [[ ! "$asc_latest_train" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then'
        )
        self.assertNotEqual(
            validation_idx,
            -1,
            "Expected the App Store Connect version train value to be "
            "format-validated before it is exported.",
        )
        write_idx = block.index("printf 'ASC_LATEST_TRAIN=%s")
        self.assertLess(
            validation_idx,
            write_idx,
            "ASC_LATEST_TRAIN must be validated before it is written to "
            "$GITHUB_ENV.",
        )

    def test_identity_gate_still_revalidates_build_number(self):
        # Double defense: removing the resolve-step check or the identity
        # gate check alone must not silently reduce the number of layers.
        block = self._identity_gate_block()
        self.assertIn('if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then', block)
        self.assertIn("${#build_number} > 10", block)
        self.assertIn("10#$build_number <= 0", block)

    def test_leading_zero_build_number_is_rejected(self):
        # 0022 passes a digits-only/length/greater-than-zero check but ships
        # to Apple as CFBundleVersion 0022, which then never string-matches
        # the "22" App Store Connect reports back when a retry is pinned.
        # Rejected rather than normalized: silently rewriting the operator's
        # number would produce a build under a number nobody asked for.
        block = self._identity_gate_block()
        reject_idx = block.find('if [[ "$build_number" =~ ^0 ]]; then')
        self.assertNotEqual(
            reject_idx,
            -1,
            "Expected the identity gate to reject a build number with a "
            "leading zero.",
        )
        self.assertIn("exit 1", block[reject_idx:])
        # And on the pinned-input path, before $GITHUB_ENV is written.
        self.assertIn("^[1-9][0-9]{0,9}$", self._pinned_branch_block())

    def test_upload_and_ingestion_are_separate_steps(self):
        # Both step names must exist independently in the workflow text and
        # neither name may be a substring match that collapses them into one
        # step block; the "Upload IPA to TestFlight..." step's run body must
        # not itself invoke verify-app-store-build.py, and the "Verify App
        # Store ingestion" step's run body must not itself invoke altool.
        upload_idx = self.workflow.index("- name: Upload IPA to TestFlight")
        ingestion_idx = self.workflow.index("- name: Verify App Store ingestion")
        self.assertLess(
            upload_idx,
            ingestion_idx,
            "The ingestion-verification step must come after the upload step.",
        )
        upload_block = self.workflow[upload_idx:ingestion_idx]
        self.assertNotIn(
            "verify-app-store-build.py",
            upload_block,
            "verify-app-store-build.py must not run inside the "
            "'Upload IPA to TestFlight' step body; it must be its own step "
            "so an ingestion-polling failure is never mistaken for a "
            "transport failure by the orchestrator's retry verdict.",
        )
        next_marker = self.workflow.index("Dry run stop before Apple transport")
        ingestion_block = self.workflow[ingestion_idx:next_marker]
        self.assertNotIn(
            "--upload-app",
            ingestion_block,
            "'xcrun altool --upload-app' must not run inside the "
            "'Verify App Store ingestion' step body.",
        )

    def test_dry_run_stop_marker_exists(self):
        self.assertIn("DRY_RUN_STOP_BEFORE_TRANSPORT", self.workflow)

    # -- O. Privacy key coverage: the three "for privacy_key in ...; do" ---
    # -- gates (source Info.plist, archive, exported IPA) must actually ---
    # -- require the full privacy-key set, including both Calendars keys. --
    #
    # This closes a real gap, not a hypothetical one: a prior Dart contract
    # test (test/ios_release_contract_test.dart) asserted an exact 6-key
    # list that omitted NSCalendarsUsageDescription and
    # NSCalendarsFullAccessUsageDescription, so it always failed against
    # this 8-key workflow and never actually guarded the calendar keys.
    # Build 22's on-device fix for EKEventStore.requestFullAccessToEvents
    # (see commit bc05df2f) depends on
    # NSCalendarsFullAccessUsageDescription being present on iOS 17+; if it
    # is silently dropped from any of the three gates below, nobody would
    # notice until Apple review or a runtime crash.

    # A lower-bound (subset) assertion is used deliberately, not an exact
    # set: the workflow is free to add a legitimately new privacy key to a
    # gate without this test failing. What must never happen silently is
    # one of these required keys disappearing from a gate, which
    # assertTrue(required.issubset(actual)) still catches. An exact-set
    # assertion would instead fail the moment an unrelated new permission
    # (e.g. NSContactsUsageDescription) is legitimately added, which is not
    # the failure mode this task is guarding against.
    REQUIRED_PRIVACY_KEYS = frozenset(
        {
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
            "NSUserTrackingUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSCalendarsUsageDescription",
            "NSCalendarsFullAccessUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
        }
    )

    def _privacy_key_for_loops(self):
        # Returns the ordered list of privacy keys declared in each
        # "for privacy_key in ...; do" loop, in the order the loops appear
        # in the file. Every loop in this workflow currently targets the
        # same shell variable name and list shape, so a single regex finds
        # all of them without needing separate per-step extraction logic.
        matches = re.findall(
            r"for privacy_key in ([A-Za-z0-9 ]+?); do", self.workflow
        )
        return [match.split() for match in matches]

    def test_exactly_three_privacy_key_gates_exist(self):
        # One gate for the source Info.plist (Preflight protected release
        # gates), one for the archived Runner.app (Archive step), and one
        # for the exported IPA (Export signed IPA step). If a fourth
        # appears, or one disappears, the layer-by-layer assumptions below
        # no longer hold and must be re-examined rather than silently
        # passing against the wrong loop.
        loops = self._privacy_key_for_loops()
        self.assertEqual(
            len(loops),
            3,
            "Expected exactly 3 'for privacy_key in ...; do' gates (source "
            "Info.plist, archive, exported IPA). Found "
            f"{len(loops)}: {loops!r}",
        )

    def test_every_privacy_key_gate_requires_the_full_required_key_set(self):
        # Subset check at all three layers: source, archive, and exported
        # IPA. This is the assertion that would have caught the calendar
        # keys being absent from a stale contract, and it is written so
        # that removing NSCalendarsFullAccessUsageDescription (or any other
        # required key) from ANY of the three layers fails this test.
        loops = self._privacy_key_for_loops()
        self.assertEqual(len(loops), 3, "Precondition: expected 3 gates.")
        layer_names = ["source Info.plist", "archive", "exported IPA"]
        for layer_name, keys in zip(layer_names, loops):
            with self.subTest(layer=layer_name):
                actual = set(keys)
                missing = self.REQUIRED_PRIVACY_KEYS - actual
                self.assertFalse(
                    missing,
                    f"The {layer_name} privacy-key gate is missing required "
                    f"key(s) {sorted(missing)!r}. Full required set: "
                    f"{sorted(self.REQUIRED_PRIVACY_KEYS)!r}; actual gate "
                    f"list: {keys!r}.",
                )

    def test_calendars_full_access_key_is_required_at_all_three_layers(self):
        # Isolated, single-purpose assertion for the exact key this task
        # was opened over. Kept separate from the broader subset test above
        # so a future refactor that breaks calendar coverage specifically
        # produces an unambiguous failure message instead of being buried
        # in a larger subTest diff.
        loops = self._privacy_key_for_loops()
        self.assertEqual(len(loops), 3, "Precondition: expected 3 gates.")
        layer_names = ["source Info.plist", "archive", "exported IPA"]
        for layer_name, keys in zip(layer_names, loops):
            with self.subTest(layer=layer_name):
                self.assertIn(
                    "NSCalendarsFullAccessUsageDescription",
                    keys,
                    f"The {layer_name} privacy-key gate must require "
                    "NSCalendarsFullAccessUsageDescription. Build 22's "
                    "on-device fix for "
                    "EKEventStore.requestFullAccessToEvents (commit "
                    "bc05df2f) depends on this key being declared on iOS "
                    "17+, and nothing else in this workflow's tests "
                    "enforces its presence.",
                )
                self.assertIn(
                    "NSCalendarsUsageDescription",
                    keys,
                    f"The {layer_name} privacy-key gate must also require "
                    "the legacy NSCalendarsUsageDescription key (used on "
                    "iOS versions before the full-access API split).",
                )

    def test_privacy_key_gates_are_identical_across_all_three_layers(self):
        # As currently written, the source, archive, and exported-IPA gates
        # enforce the exact same list in the exact same order (this was
        # confirmed by reading the workflow, not assumed). If one layer's
        # list is ever narrowed relative to the others -- for example, a
        # key added only at the source layer but never propagated to the
        # archive or IPA gate -- that divergence itself is a regression
        # this test is designed to catch. This assertion is intentionally
        # about list identity, not just the required subset above.
        loops = self._privacy_key_for_loops()
        self.assertEqual(len(loops), 3, "Precondition: expected 3 gates.")
        source_keys, archive_keys, ipa_keys = loops
        self.assertEqual(
            source_keys,
            archive_keys,
            "The source Info.plist privacy-key gate and the archive "
            "privacy-key gate must declare the identical key list in the "
            "identical order.",
        )
        self.assertEqual(
            archive_keys,
            ipa_keys,
            "The archive privacy-key gate and the exported-IPA "
            "privacy-key gate must declare the identical key list in the "
            "identical order.",
        )

    def test_widget_must_not_contain_privacy_keys_check_exists_at_archive_layer(
        self,
    ):
        # Only the archive gate additionally asserts the WidgetKit
        # extension's Info.plist does NOT contain each Runner privacy key
        # (BLOCKED_WIDGET_PRIVACY). This is a distinct, narrower guarantee
        # than "the key exists on Runner" and is not covered by the subset
        # tests above, so it gets its own assertion.
        archive_start = self.workflow.index(
            "- name: Archive Runner with embedded WidgetKit extension"
        )
        archive_end = self.workflow.index(
            "- name: Verify and retain exact arm64 Runner symbols"
        )
        archive_block = self.workflow[archive_start:archive_end]
        self.assertIn("BLOCKED_WIDGET_PRIVACY", archive_block)
        self.assertIn(
            'Print :$privacy_key" "$archive_widget_plist"',
            archive_block,
            "Expected the archive gate to probe the widget's Info.plist "
            "for each Runner privacy key so a key leaking into the widget "
            "extension is caught (BLOCKED_WIDGET_PRIVACY).",
        )

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

    # -- J. Version-train guard: fail-closed on unverifiable ASC lookup ----
    #
    # A prior version of this guard printed "guard skipped" and let an
    # unverifiable App Store Connect version-train lookup pass silently.
    # That is a fail-open hole: it can hide an unintended version-train
    # change behind a transient API failure. The guard must now fail closed
    # unless the operator explicitly opts in via allow_version_train_change.

    def _identity_gate_block(self):
        start = self.workflow.index("- name: Fail-closed build identity gates")
        end = self.workflow.index("- name: Preflight protected release gates")
        self.assertLess(start, end)
        return self.workflow[start:end]

    def test_version_train_unverified_error_code_exists(self):
        self.assertIn("BLOCKED_VERSION_TRAIN_UNVERIFIED", self.workflow)

    def test_version_train_change_error_code_still_exists(self):
        # Distinct from BLOCKED_VERSION_TRAIN_UNVERIFIED: this fires when the
        # train *was* verified and differs from the resolved build name.
        self.assertIn("BLOCKED_VERSION_TRAIN_CHANGE", self.workflow)
        self.assertNotEqual(
            "BLOCKED_VERSION_TRAIN_CHANGE", "BLOCKED_VERSION_TRAIN_UNVERIFIED"
        )

    def test_no_unconditional_fail_open_skip_phrase_for_version_train_guard(self):
        # Regression guard for the exact defect that was just fixed: the old
        # implementation printed a "skipped" message and continued past the
        # guard whenever the ASC lookup failed, regardless of
        # allow_version_train_change.
        block = self._identity_gate_block()
        self.assertNotRegex(
            block,
            r"guard\s+skipped",
            "Found a 'guard skipped' fail-open message inside the build "
            "identity gates step; an unverifiable version train must fail "
            "closed unless allow_version_train_change: true is set.",
        )
        self.assertNotRegex(
            block,
            r"will\s+be\s+skipped",
            "Found a 'will be skipped' fail-open message inside the build "
            "identity gates step for the version-train guard.",
        )

    def test_unverified_train_branch_gates_its_error_on_allow_flag(self):
        # Extract just the "ASC_LATEST_TRAIN is empty" branch (up to the
        # sibling elif for the "train differs" branch) and assert that the
        # ALLOW_VERSION_TRAIN_CHANGE check textually precedes the
        # fail-closed error/exit for this branch. If the guard fires
        # unconditionally (fail-open removed the flag check, or the flag
        # check no longer gates the exit), this ordering breaks.
        block = self._identity_gate_block()
        unverified_start = block.index('if [[ -z "${ASC_LATEST_TRAIN:-}" ]]; then')
        mismatch_start = block.index(
            'elif [[ "$build_name" != "$ASC_LATEST_TRAIN" ]]; then'
        )
        self.assertLess(unverified_start, mismatch_start)
        unverified_block = block[unverified_start:mismatch_start]
        self.assertIn("ALLOW_VERSION_TRAIN_CHANGE", unverified_block)
        self.assertIn("BLOCKED_VERSION_TRAIN_UNVERIFIED", unverified_block)
        allow_idx = unverified_block.index("ALLOW_VERSION_TRAIN_CHANGE")
        error_idx = unverified_block.index("BLOCKED_VERSION_TRAIN_UNVERIFIED")
        self.assertLess(
            allow_idx,
            error_idx,
            "Expected the ALLOW_VERSION_TRAIN_CHANGE check to gate the "
            "BLOCKED_VERSION_TRAIN_UNVERIFIED error (the check must appear "
            "before the error in the unverified-train branch), otherwise "
            "the branch can raise (or skip) the error unconditionally.",
        )
        self.assertIn(
            "exit 1",
            unverified_block[error_idx:],
            "Expected BLOCKED_VERSION_TRAIN_UNVERIFIED to be followed by "
            "exit 1 in the same branch so the guard actually fails closed.",
        )

    # -- N. Build-number recovery marker (cross-repo coupling with the ---
    # -- flux-release orchestrator) ---------------------------------------
    #
    # E:\FluxStudio\tools\flux-release\FluxRelease.Ios.ps1,
    # Get-IosBuildNumberFromLogText, parses the workflow run log for this
    # exact echo line to recover the build number a completed run actually
    # used, via the regex 'Build identity gates:\s*build=(\S+?)\s+version='.
    # That recovered number is what lets the orchestrator pin a retry to the
    # SAME build number instead of burning a new one. Recovery failure is a
    # non-fatal warning path (NOT_FOUND), so nothing else in the pipeline
    # will flag a silent drift here -- these two tests are the only guard.

    def test_build_identity_marker_exists_verbatim_for_orchestrator_parsing(self):
        marker = 'echo "Build identity gates: build=$build_number version=$build_name."'
        self.assertIn(
            marker,
            self.workflow,
            "The exact 'Build identity gates: build=... version=...' echo "
            "line was not found verbatim in ios-release.yml. "
            "FluxRelease.Ios.ps1's Get-IosBuildNumberFromLogText parses "
            "this literal text out of the workflow run log to recover the "
            "iOS build number a run actually used, which is what lets a "
            "failed run be retried under the SAME build number instead of "
            "burning a new one. If this echo line's wording changes here "
            "without updating the regex in "
            r"E:\FluxStudio\tools\flux-release\FluxRelease.Ios.ps1"
            ", build-number recovery silently degrades to NOT_FOUND (a "
            "non-fatal warning, not a release failure) and the retry-pin "
            "feature is silently disabled. Fix both files together.",
        )

    def test_build_identity_marker_is_emitted_after_identity_validation(self):
        marker = 'echo "Build identity gates: build=$build_number version=$build_name."'
        block = self._identity_gate_block()
        self.assertIn(
            marker,
            block,
            "The build-identity-gates echo marker must live inside the "
            "'Fail-closed build identity gates' step.",
        )
        marker_idx = block.index(marker)
        preceding_validation_markers = [
            "BLOCKED_IOS_BUILD_NUMBER_CONFIG",
            "BLOCKED_IOS_BUILD_NAME_CONFIG",
            "BLOCKED_VERSION_TRAIN_UNVERIFIED",
            "BLOCKED_VERSION_TRAIN_CHANGE",
        ]
        for validation_marker in preceding_validation_markers:
            with self.subTest(validation_marker=validation_marker):
                validation_idx = block.rindex(validation_marker)
                self.assertLess(
                    validation_idx,
                    marker_idx,
                    f"Expected {validation_marker!r} to appear before the "
                    "'Build identity gates: build=...' echo marker. "
                    "FluxRelease.Ios.ps1's Get-IosBuildNumberFromLogText "
                    "treats this echo line as proof that the build number "
                    "and marketing version were already confirmed and the "
                    "version-train gate was already passed. If a "
                    "validation/error branch is ever moved to fire AFTER "
                    "this echo (e.g. during a future refactor), the "
                    "orchestrator could recover and pin a build number that "
                    "the workflow subsequently rejected, defeating the "
                    "point of the fail-closed gates. Fix "
                    r"E:\FluxStudio\tools\flux-release\FluxRelease.Ios.ps1"
                    " and this workflow step together if the ordering is "
                    "intentionally changing.",
                )

    def test_mismatched_train_branch_gates_its_error_on_allow_flag(self):
        # Same shape of assertion as the unverified branch above, but for
        # the sibling "train resolved but differs from ASC" branch, which
        # uses the pre-existing BLOCKED_VERSION_TRAIN_CHANGE code.
        block = self._identity_gate_block()
        mismatch_start = block.index(
            'elif [[ "$build_name" != "$ASC_LATEST_TRAIN" ]]; then'
        )
        matched_start = block.index('echo "Version train unchanged: $build_name."')
        self.assertLess(mismatch_start, matched_start)
        mismatch_block = block[mismatch_start:matched_start]
        self.assertIn("ALLOW_VERSION_TRAIN_CHANGE", mismatch_block)
        self.assertIn("BLOCKED_VERSION_TRAIN_CHANGE", mismatch_block)
        allow_idx = mismatch_block.index("ALLOW_VERSION_TRAIN_CHANGE")
        error_idx = mismatch_block.index("BLOCKED_VERSION_TRAIN_CHANGE")
        self.assertLess(
            allow_idx,
            error_idx,
            "Expected the ALLOW_VERSION_TRAIN_CHANGE check to gate the "
            "BLOCKED_VERSION_TRAIN_CHANGE error in the mismatched-train "
            "branch.",
        )
        self.assertIn("exit 1", mismatch_block[error_idx:])

    # -- K. Version-train lookup runs regardless of build_number pin -------
    #
    # A prior version skipped the ASC lookup entirely whenever build_number
    # was pinned (a retry), which disabled the version-train guard for every
    # pinned/retry run. The lookup (and therefore the guard) must now run on
    # both the pinned and the auto-assign path.

    def _resolve_step_block(self):
        start = self.workflow.index(
            "- name: Resolve iOS build number and marketing version"
        )
        end = self.workflow.index("- name: Fail-closed build identity gates")
        self.assertLess(start, end)
        return self.workflow[start:end]

    def _pinned_branch_block(self):
        block = self._resolve_step_block()
        pin_start = block.index(
            'echo "Build number source: workflow_dispatch input (retry pin)."'
        )
        auto_start = block.index(
            'echo "Build number source: App Store Connect latest build + 1."'
        )
        self.assertLess(pin_start, auto_start)
        return block[pin_start:auto_start]

    def _auto_branch_block(self):
        block = self._resolve_step_block()
        auto_start = block.index(
            'echo "Build number source: App Store Connect latest build + 1."'
        )
        lookup_result_start = block.index(
            'if [[ "$asc_lookup_ok" == "true" ]]; then'
        )
        self.assertLess(auto_start, lookup_result_start)
        return block[auto_start:lookup_result_start]

    def test_pinned_build_number_branch_still_queries_asc(self):
        pinned_block = self._pinned_branch_block()
        self.assertIn(
            "scripts/asc-next-build-number.py",
            pinned_block,
            "Expected the pinned/retry build_number branch to still call "
            "asc-next-build-number.py so the version-train guard is not "
            "disabled whenever a build number is pinned.",
        )

    def test_pinned_build_number_branch_does_not_overwrite_the_pin(self):
        # The pinned branch must query ASC without --emit-github-env, which
        # would overwrite IOS_BUILD_NUMBER with the auto-assigned value and
        # defeat the pin. Isolate the actual invocation line (not the
        # surrounding comment, which mentions --emit-github-env by name to
        # explain why it is intentionally omitted).
        pinned_block = self._pinned_branch_block()
        call_start = pinned_block.index("python3 scripts/asc-next-build-number.py")
        call_end = pinned_block.index("> \"$asc_json\"", call_start)
        call_line = pinned_block[call_start:call_end]
        self.assertNotIn(
            "--emit-github-env",
            call_line,
            "The pinned build_number branch's asc-next-build-number.py "
            "invocation must not pass --emit-github-env; doing so would "
            "overwrite the pinned IOS_BUILD_NUMBER. Invocation text: "
            f"{call_line!r}",
        )

    # -- L. Single ASC scan per execution path (M6) -------------------------

    def test_auto_branch_calls_asc_script_exactly_once_with_both_flags(self):
        auto_block = self._auto_branch_block()
        self.assertEqual(
            auto_block.count("scripts/asc-next-build-number.py"),
            1,
            "Expected exactly one asc-next-build-number.py invocation on "
            "the auto-assign path; a second call would re-scan App Store "
            "Connect and could disagree with the first about the version "
            "train.",
        )
        self.assertIn("--emit-github-env", auto_block)
        self.assertIn("--json", auto_block)

    def test_pinned_branch_calls_asc_script_at_most_once(self):
        pinned_block = self._pinned_branch_block()
        self.assertLessEqual(
            pinned_block.count("scripts/asc-next-build-number.py"),
            1,
            "Expected at most one asc-next-build-number.py invocation on "
            "the pinned build_number path.",
        )

    def test_asc_script_referenced_exactly_twice_total(self):
        # Once per execution path (pinned branch, auto-assign branch); never
        # both in the same run, and never a stray third reference elsewhere
        # in the file that would indicate a leftover duplicate scan.
        self.assertEqual(
            self.workflow.count("scripts/asc-next-build-number.py"),
            2,
            "Expected exactly two references to asc-next-build-number.py "
            "in the whole workflow: one in the pinned build_number branch "
            "and one in the auto-assign branch.",
        )

    # -- M. Ingestion-failure guidance must be actionable (M5) --------------

    def test_ingestion_failure_guidance_acknowledges_no_single_step_retry(self):
        self.assertIn(
            "GitHub Actions cannot re-run a single step",
            self.workflow,
            "Expected the ingestion-verification failure message to "
            "acknowledge that GitHub Actions cannot re-run a single step, "
            "and to give an actionable alternative instead.",
        )

    def test_ingestion_failure_guidance_does_not_suggest_impossible_step_retry(self):
        forbidden_patterns = [
            r"retry\s+(just\s+|only\s+)?this\s+step",
            r"re-?run\s+(just\s+|only\s+)?this\s+step\b(?!.{0,40}re-?running)",
            r"retry\s+the\s+ingestion\s+step\b",
        ]
        for pattern in forbidden_patterns:
            with self.subTest(pattern=pattern):
                self.assertNotRegex(
                    self.workflow,
                    pattern,
                    "Found guidance suggesting an individual GitHub Actions "
                    "step can be retried in isolation, which is not "
                    "possible; matched pattern: " + pattern,
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
        cls.steps = cls.doc["jobs"]["signed-release"]["steps"]

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

    # -- I. Apple transport point cardinality (retry-verdict contract) ----
    #
    # A separate orchestrator (Get-IosRetryVerdict, in another repo) decides
    # whether a failed run can be retried under the same build number by
    # inspecting only the *name* of the failed step:
    #   - name contains "upload ipa to testflight"      -> NEXT_BUILD_REQUIRED
    #   - name contains "ingestion" or
    #     "verify-app-store-build"                       -> INGESTION_PENDING
    #   - anything else                                  -> RETRY_SAME_BUILD_ALLOWED
    # The last rule is only safe if this workflow has exactly one point where
    # a build is actually handed to Apple. If a second `--upload-app` call
    # were ever added, a pre-transport failure at that second call site would
    # be misclassified as RETRY_SAME_BUILD_ALLOWED even though the build
    # number may already have been consumed by Apple.

    def _find_upload_app_steps(self):
        return [
            step
            for step in self.steps
            if isinstance(step.get("run"), str) and "--upload-app" in step["run"]
        ]

    def _find_steps_by_name_substring(self, substring):
        substring = substring.lower()
        return [
            step
            for step in self.steps
            if isinstance(step.get("name"), str) and substring in step["name"].lower()
        ]

    def test_exactly_one_apple_transport_step(self):
        upload_app_steps = self._find_upload_app_steps()
        self.assertEqual(
            len(upload_app_steps),
            1,
            "Expected exactly one step invoking `xcrun altool --upload-app` "
            "(the sole Apple transport point in this workflow). The "
            "orchestrator's Get-IosRetryVerdict classifies any failure that "
            "does not match the upload or ingestion step-name keywords as "
            "RETRY_SAME_BUILD_ALLOWED, on the assumption that such a "
            "failure happened before the build reached Apple. A second "
            "transport point breaks that assumption: a pre-transport "
            "failure at the second site could be retried under the same "
            "build number even though Apple may already have received it. "
            f"Found {len(upload_app_steps)} matching step(s): "
            f"{[s.get('name') for s in upload_app_steps]!r}",
        )

    def test_upload_step_name_keyword_is_unique(self):
        matches = self._find_steps_by_name_substring("upload ipa to testflight")
        self.assertEqual(
            len(matches),
            1,
            "Expected exactly one step whose name contains "
            "'upload ipa to testflight' (case-insensitive), the keyword the "
            "orchestrator matches to return NEXT_BUILD_REQUIRED. Found "
            f"{len(matches)}: {[s.get('name') for s in matches]!r}",
        )

    def test_ingestion_step_name_keyword_exists(self):
        matches = self._find_steps_by_name_substring(
            "ingestion"
        ) + self._find_steps_by_name_substring("verify-app-store-build")
        self.assertGreaterEqual(
            len(matches),
            1,
            "Expected at least one step whose name contains 'ingestion' or "
            "'verify-app-store-build', the keywords the orchestrator "
            "matches to return INGESTION_PENDING.",
        )

    def test_upload_and_ingestion_keywords_do_not_match_the_same_step(self):
        # This is a regression test for the exact defect this change fixes:
        # when ingestion verification lived inside the upload step, its name
        # ("Upload IPA to TestFlight...") matched the upload keyword only,
        # so INGESTION_PENDING could never be returned for an ingestion
        # timeout -- it would always be misclassified as
        # NEXT_BUILD_REQUIRED, which would falsely burn a new build number
        # for what is actually a pending-on-Apple's-side condition.
        upload_matches = self._find_steps_by_name_substring(
            "upload ipa to testflight"
        )
        ingestion_matches = self._find_steps_by_name_substring(
            "ingestion"
        ) + self._find_steps_by_name_substring("verify-app-store-build")
        self.assertTrue(upload_matches, "No step matched the upload keyword.")
        self.assertTrue(ingestion_matches, "No step matched the ingestion keyword.")
        upload_names = {step.get("name") for step in upload_matches}
        ingestion_names = {step.get("name") for step in ingestion_matches}
        self.assertTrue(
            upload_names.isdisjoint(ingestion_names),
            "The upload-step-name keyword and the ingestion-step-name "
            "keyword must never match the same step, or INGESTION_PENDING "
            "can never be returned (see regression note above). Overlapping "
            f"step name(s): {upload_names & ingestion_names!r}",
        )

    def test_ingestion_step_comes_after_upload_step_in_yaml_order(self):
        names = [step.get("name") for step in self.steps]
        upload_matches = self._find_steps_by_name_substring(
            "upload ipa to testflight"
        )
        ingestion_matches = self._find_steps_by_name_substring(
            "ingestion"
        ) + self._find_steps_by_name_substring("verify-app-store-build")
        upload_idx = names.index(upload_matches[0]["name"])
        ingestion_idx = names.index(ingestion_matches[0]["name"])
        self.assertLess(
            upload_idx,
            ingestion_idx,
            "The ingestion-verification step must be declared after the "
            "Apple transport (upload) step.",
        )

    def test_upload_and_ingestion_steps_are_each_gated_on_dry_run(self):
        upload_matches = self._find_steps_by_name_substring(
            "upload ipa to testflight"
        )
        ingestion_matches = self._find_steps_by_name_substring(
            "ingestion"
        ) + self._find_steps_by_name_substring("verify-app-store-build")
        for step in upload_matches + ingestion_matches:
            with self.subTest(step_name=step.get("name")):
                condition = str(step.get("if", ""))
                self.assertIn(
                    "dry_run",
                    condition,
                    f"Step {step.get('name')!r} must have its own 'if' "
                    "condition referencing dry_run; a missing per-step gate "
                    "would let it run even when dry_run is requested, "
                    "leaking Apple transport or ingestion calls (and their "
                    "secret material) during a dry run.",
                )

    def test_cleanup_step_is_gated_on_always(self):
        cleanup_steps = self._find_steps_by_name_substring(
            "cleanup protected artifacts"
        )
        self.assertEqual(len(cleanup_steps), 1)
        condition = str(cleanup_steps[0].get("if", ""))
        self.assertIn(
            "always()",
            condition,
            "Cleanup protected artifacts must run unconditionally via "
            "always(), including when dry_run stops the run before the "
            "new separate upload/ingestion steps, or protected secret "
            "material is left on the runner.",
        )


if __name__ == "__main__":
    unittest.main()
