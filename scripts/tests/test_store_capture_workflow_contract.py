"""Contract tests for .github/workflows/store-screenshot-capture.yml.

This workflow is a SCAFFOLD ONLY (spec #43, Store Intelligence screenshot
automation). It must never contain a Store upload step -- it is blocked on
three prerequisites (no demo account secret, no Flutter integration_test
driver, and workflow_dispatch requiring a push to main) and is designed to
print BLOCKED_ON_PREREQ and exit early until all three are resolved.

These tests read the workflow YAML from disk (no network calls, no workflow
dispatch) and assert the scaffold's safety properties: dispatch-only trigger,
read-only permissions, no Store/ASC/Play upload surface, only the two demo
secrets referenced, a fail-closed prerequisite guard gating the capture
steps, a 9:41 status bar override placeholder, an artifact upload step, and
alignment with the capture plan contract (schema keys: devices, shots,
width, height, simulator, determinism) that a separate implementer (S05)
owns under config/store/capture-plan.json.
"""

import json
import pathlib
import re
import unittest

try:
    import yaml

    HAVE_YAML = True
except ImportError:  # pragma: no cover - environment without PyYAML
    HAVE_YAML = False

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "store-screenshot-capture.yml"

# The capture plan contract fixture, as fixed by the orchestrator. This is a
# literal copy of the JSON shape S05 is expected to produce at
# config/store/capture-plan.json; it is used here only to assert that this
# workflow's key names line up with the contract, not to read S05's file
# (which may not exist yet in this working tree).
CAPTURE_PLAN_FIXTURE = {
    "schemaVersion": 1,
    "projectId": "planflow",
    "platform": "ios",
    "devices": [
        {
            "slot": "IPHONE",
            "displayClass": "6.9",
            "simulator": "iPhone 16 Pro Max",
            "width": 1320,
            "height": 2868,
        },
        {
            "slot": "IPAD",
            "displayClass": "13",
            "simulator": "iPad Pro 13-inch (M4)",
            "width": 2064,
            "height": 2752,
        },
    ],
    "shots": [
        {
            "screenshotId": "ios-01-calendar",
            "featureIds": ["calendar-month"],
            "route": "/calendar",
            "fixture": "demo-default",
        }
    ],
    "determinism": {
        "locale": "ko_KR",
        "theme": "light",
        "statusBarOverride": {
            "time": "9:41",
            "battery": 100,
            "wifi": 3,
            "cellular": 4,
        },
    },
}


def _load_workflow_text():
    return WORKFLOW_PATH.read_text(encoding="utf-8")


class WorkflowExistsTests(unittest.TestCase):
    def test_workflow_file_exists(self):
        self.assertTrue(
            WORKFLOW_PATH.exists(),
            f"Expected scaffold workflow at {WORKFLOW_PATH}",
        )


class WorkflowTextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = _load_workflow_text()

    # -- Trigger: workflow_dispatch only ----------------------------------

    def test_no_push_schedule_or_pull_request_trigger(self):
        for forbidden in ("push:", "schedule:", "pull_request:"):
            with self.subTest(trigger=forbidden):
                self.assertNotIn(
                    forbidden,
                    self.workflow,
                    f"Scaffold must only be triggered via workflow_dispatch; "
                    f"found forbidden trigger {forbidden!r}.",
                )

    def test_capture_plan_path_and_driver_ready_inputs_declared(self):
        self.assertIn("capture_plan_path:", self.workflow)
        self.assertIn("driver_ready:", self.workflow)

    # -- Permissions: read-only --------------------------------------------

    def test_permissions_are_contents_read_only(self):
        match = re.search(r"permissions:\s*\n\s*contents:\s*(\S+)", self.workflow)
        self.assertIsNotNone(match, "Expected a top-level permissions block.")
        self.assertEqual(match.group(1), "read")

    # -- No Store/ASC/Play upload surface -----------------------------------

    FORBIDDEN_UPLOAD_STRINGS = [
        "altool",
        "notarytool",
        "upload-app",
        "appScreenshots",
        "appstoreconnect",
        "androidpublisher",
        "publishListing",
        "APP_STORE_CONNECT_API_KEY_P8",
        "APP_STORE_CONNECT_KEY_ID",
        "APP_STORE_CONNECT_ISSUER_ID",
    ]

    def test_no_store_upload_strings_anywhere(self):
        for forbidden in self.FORBIDDEN_UPLOAD_STRINGS:
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(
                    forbidden,
                    self.workflow,
                    f"Found forbidden Store-upload-related string {forbidden!r} "
                    "in a scaffold that must never talk to App Store Connect "
                    "or Play.",
                )

    # -- Secret surface: only the two demo account secrets ------------------

    ALLOWED_SECRETS = {
        "PLANFLOW_REVIEW_DEMO_USERNAME",
        "PLANFLOW_REVIEW_DEMO_PASSWORD",
    }

    def test_only_demo_account_secrets_are_referenced(self):
        referenced = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", self.workflow))
        self.assertTrue(
            referenced,
            "Expected at least the two demo account secrets to be referenced.",
        )
        unexpected = referenced - self.ALLOWED_SECRETS
        self.assertFalse(
            unexpected,
            f"Found unexpected secret reference(s): {sorted(unexpected)!r}. "
            f"Only {sorted(self.ALLOWED_SECRETS)!r} are allowed in this scaffold.",
        )

    def test_both_demo_secrets_are_referenced(self):
        for secret in self.ALLOWED_SECRETS:
            with self.subTest(secret=secret):
                self.assertIn(f"secrets.{secret}", self.workflow)

    def test_secrets_never_echoed_and_no_set_dash_x(self):
        self.assertNotIn("set -x", self.workflow)
        for secret in self.ALLOWED_SECRETS:
            with self.subTest(secret=secret):
                self.assertNotRegex(
                    self.workflow,
                    r"echo[^\n]*\$\{?" + re.escape(secret),
                    f"Secret {secret} must not be echoed directly.",
                )

    # -- Prerequisite guard: fail-closed, gates capture steps ---------------

    def test_prerequisite_guard_step_exists(self):
        self.assertIn("Check capture prerequisites", self.workflow)
        self.assertIn("BLOCKED_ON_PREREQ", self.workflow)

    def test_guard_checks_all_three_prerequisites(self):
        guard_idx = self.workflow.index("Check capture prerequisites")
        next_marker = self.workflow.index(
            "Prepare Flutter (placeholder for future capture)"
        )
        guard_block = self.workflow[guard_idx:next_marker]
        self.assertIn("DRIVER_READY", guard_block)
        self.assertIn("HAS_DEMO_USERNAME", guard_block)
        self.assertIn("HAS_DEMO_PASSWORD", guard_block)

    def test_capture_steps_are_conditioned_on_guard_output(self):
        # Every placeholder capture step after the guard must be gated on
        # steps.guard.outputs.ready so the scaffold never actually attempts
        # driving/capturing while blocked.
        capture_step_names = [
            "Prepare Flutter (placeholder for future capture)",
            "Boot simulator per device slot (placeholder)",
            "Set deterministic status bar (placeholder)",
            "Set deterministic locale (placeholder)",
            "Drive app to each shot route (placeholder)",
            "Capture screenshot per device x shot (placeholder)",
            "Verify captured PNG dimensions against capture plan (placeholder)",
        ]
        for name in capture_step_names:
            with self.subTest(step=name):
                idx = self.workflow.index(f"name: {name}")
                following = self.workflow[idx : idx + 400]
                self.assertIn(
                    "steps.guard.outputs.ready == 'true'",
                    following,
                    f"Step {name!r} must be gated on the prerequisite guard's "
                    "ready output.",
                )

    def test_guard_exits_zero_not_a_hard_failure(self):
        guard_idx = self.workflow.index("Check capture prerequisites")
        next_marker = self.workflow.index(
            "Prepare Flutter (placeholder for future capture)"
        )
        guard_block = self.workflow[guard_idx:next_marker]
        blocked_idx = guard_block.index("BLOCKED_ON_PREREQ")
        exit_idx = guard_block.index("exit 0", blocked_idx)
        self.assertNotEqual(
            exit_idx,
            -1,
            "The prerequisite guard must exit 0 (not fail the job) when "
            "blocked, since this scaffold is expected to be blocked today.",
        )

    def test_driver_not_implemented_marker_present(self):
        self.assertIn("SCAFFOLD: driver not implemented", self.workflow)

    # -- Status bar override: 9:41 -------------------------------------------

    def test_status_bar_override_step_targets_941(self):
        self.assertIn("Set deterministic status bar (placeholder)", self.workflow)
        idx = self.workflow.index("Set deterministic status bar (placeholder)")
        block = self.workflow[idx : idx + 600]
        self.assertIn("9:41", block)
        self.assertIn("status_bar", block)

    # -- Artifact upload ------------------------------------------------------

    def test_upload_artifact_step_exists(self):
        self.assertIn("actions/upload-artifact@v4", self.workflow)

    def test_upload_artifact_step_runs_always(self):
        idx = self.workflow.rindex("actions/upload-artifact@v4")
        preceding = self.workflow[max(0, idx - 200) : idx]
        self.assertIn("always()", preceding)

    # -- Capture plan contract alignment ------------------------------------

    CAPTURE_PLAN_KEYS = [
        "devices",
        "shots",
        "width",
        "height",
        "simulator",
        "determinism",
    ]

    def test_workflow_references_all_capture_plan_contract_keys(self):
        for key in self.CAPTURE_PLAN_KEYS:
            with self.subTest(key=key):
                self.assertIn(
                    key,
                    self.workflow,
                    f"Expected the workflow to reference capture plan key "
                    f"{key!r} so it stays aligned with the fixed contract.",
                )

    def test_capture_plan_fixture_matches_the_frozen_contract_shape(self):
        # This is a guard on the *fixture in this test file*, not on any
        # runtime file, so it fails loudly (rather than silently drifting)
        # if a future edit to this test accidentally changes the contract
        # shape it is supposed to be pinned to.
        plan = CAPTURE_PLAN_FIXTURE
        self.assertEqual(plan["schemaVersion"], 1)
        self.assertIn("devices", plan)
        self.assertIn("shots", plan)
        self.assertIn("determinism", plan)
        for device in plan["devices"]:
            for key in ("slot", "displayClass", "simulator", "width", "height"):
                self.assertIn(key, device)
        for shot in plan["shots"]:
            for key in ("screenshotId", "featureIds", "route", "fixture"):
                self.assertIn(key, shot)
        self.assertIn("statusBarOverride", plan["determinism"])
        self.assertEqual(plan["determinism"]["statusBarOverride"]["time"], "9:41")

    def test_capture_plan_path_default_matches_orchestrator_contract(self):
        self.assertIn("config/store/capture-plan.json", self.workflow)

    def test_capture_plan_json_is_parsed_via_jq_not_hardcoded(self):
        # The scaffold must read the plan dynamically (jq against the file
        # path input), not hardcode device/shot values inline, so it stays
        # correct as S05's capture-plan.json evolves.
        self.assertIn("jq -r '.schemaVersion", self.workflow)
        self.assertIn(".devices | length", self.workflow)
        self.assertIn(".shots | length", self.workflow)


@unittest.skipUnless(HAVE_YAML, "PyYAML is not installed in this environment")
class WorkflowYamlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = yaml.safe_load(_load_workflow_text())
        # "on:" parses to the boolean key True under PyYAML's default resolver.
        cls.on_block = cls.doc[True]
        cls.job = cls.doc["jobs"]["capture"]
        cls.steps = cls.job["steps"]

    def test_on_block_has_exactly_workflow_dispatch(self):
        self.assertEqual(set(self.on_block.keys()), {"workflow_dispatch"})

    def test_workflow_dispatch_inputs_are_exactly_the_two_declared(self):
        inputs = self.on_block["workflow_dispatch"]["inputs"]
        self.assertEqual(
            set(inputs.keys()), {"capture_plan_path", "driver_ready"}
        )

    def test_driver_ready_input_is_boolean_default_false(self):
        spec = self.on_block["workflow_dispatch"]["inputs"]["driver_ready"]
        self.assertEqual(spec.get("type"), "boolean")
        self.assertIs(spec.get("default"), False)

    def test_capture_plan_path_input_defaults_to_contract_path(self):
        spec = self.on_block["workflow_dispatch"]["inputs"]["capture_plan_path"]
        self.assertEqual(spec.get("type"), "string")
        self.assertEqual(spec.get("default"), "config/store/capture-plan.json")

    def test_permissions_yaml_is_contents_read_only(self):
        self.assertEqual(self.doc["permissions"], {"contents": "read"})

    def test_runs_on_macos(self):
        self.assertTrue(str(self.job["runs-on"]).startswith("macos-"))

    def test_matches_ios_simulator_e2e_macos_version(self):
        # Follow the same-runner-generation precedent established by
        # ios-simulator-e2e.yml (macos-15, pinned to avoid an Xcode 26 pod
        # linking regression documented there).
        e2e_path = ROOT / ".github" / "workflows" / "ios-simulator-e2e.yml"
        e2e_doc = yaml.safe_load(e2e_path.read_text(encoding="utf-8"))
        e2e_runs_on = e2e_doc["jobs"]["preflight"]["runs-on"]
        self.assertEqual(self.job["runs-on"], e2e_runs_on)

    def test_upload_artifact_step_has_short_retention(self):
        upload_steps = [
            s
            for s in self.steps
            if isinstance(s.get("uses"), str) and "upload-artifact" in s["uses"]
        ]
        self.assertEqual(len(upload_steps), 1)
        retention = upload_steps[0]["with"].get("retention-days")
        self.assertIsNotNone(retention)
        self.assertLessEqual(int(retention), 14)

    def test_no_step_has_write_permissions_override(self):
        for step in self.steps:
            self.assertNotIn(
                "permissions",
                step,
                "No individual step may declare its own (potentially "
                "elevated) permissions block; only the job-level read-only "
                "permissions should apply.",
            )


if __name__ == "__main__":
    unittest.main()
