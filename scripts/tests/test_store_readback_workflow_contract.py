"""Contract tests for .github/workflows/store-readback.yml's PII grep guard
(spec SEC-M6 hardening): the workflow must contain a step that greps the
readback output directory for email/phone-shaped patterns and fails the job
if it finds one, run *before* the artifact upload step.

These tests parse the workflow YAML (falling back to plain text matching if
PyYAML isn't installed) and never execute the workflow itself.
"""

from __future__ import annotations

import pathlib
import re
import unittest

try:
    import yaml

    HAVE_YAML = True
except ImportError:  # pragma: no cover - environment without PyYAML
    HAVE_YAML = False

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "store-readback.yml"


@unittest.skipUnless(WORKFLOW_PATH.exists(), "workflow file not found")
class PiiGuardStepContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_text = WORKFLOW_PATH.read_text(encoding="utf-8")
        if HAVE_YAML:
            cls.doc = yaml.safe_load(cls.workflow_text)
        else:  # pragma: no cover
            cls.doc = None

    def _steps(self):
        assert self.doc is not None
        job = self.doc["jobs"]["readback"]
        return job["steps"]

    def _pii_guard_run(self) -> str:
        if self.doc is not None:
            for step in self._steps():
                name = (step.get("name") or "").lower()
                if "pii" in name and ("guard" in name or "grep" in name):
                    return step.get("run", "")
            self.fail("no PII guard step found among workflow steps")
        # Fallback: plain-text scan when PyYAML is unavailable.
        match = re.search(r"name:.*[Pp][Ii][Ii].*\n(?:.*\n)*?\s*run:\s*\|\n((?:\s+.*\n)+)", self.workflow_text)
        if not match:
            self.fail("no PII guard step found in workflow text")
        return match.group(1)

    def test_pii_guard_step_exists(self):
        run_text = self._pii_guard_run()
        self.assertTrue(run_text.strip(), "PII guard step has no run body")

    def test_pii_guard_runs_before_artifact_upload(self):
        if self.doc is None:
            self.skipTest("PyYAML not installed; ordering check requires structured parsing")
        steps = self._steps()
        pii_index = None
        upload_index = None
        for index, step in enumerate(steps):
            name = (step.get("name") or "").lower()
            if pii_index is None and "pii" in name:
                pii_index = index
            if "upload" in name and step.get("uses", "").startswith("actions/upload-artifact"):
                upload_index = index
        self.assertIsNotNone(pii_index, "PII guard step not found")
        self.assertIsNotNone(upload_index, "artifact upload step not found")
        self.assertLess(pii_index, upload_index, "PII guard must run before the artifact upload step")

    def test_pii_guard_fails_the_job_on_match(self):
        run_text = self._pii_guard_run()
        self.assertIn("exit 1", run_text)

    def test_pii_guard_pattern_matches_sample_email_and_phone(self):
        """Extract the grep -E pattern from the step body and verify it
        actually matches a sample email address and a sample phone number
        -- catches a guard step that exists but whose regex is too narrow
        to catch real PII."""
        run_text = self._pii_guard_run()
        match = re.search(r"grep\s+-R\s+-E\s+-l\s+--\s+'([^']+)'", run_text)
        self.assertIsNotNone(match, "could not find the grep -R -E -l pattern in the PII guard step")
        pattern = re.compile(match.group(1))

        self.assertIsNotNone(pattern.search("contact us at dev@example.com for help"))
        self.assertIsNotNone(pattern.search("call +1-555-0100-1234 now"))
        # A short, non-PII-shaped number (e.g. a version string) should not
        # necessarily trip the guard, but this isn't asserted here -- the
        # contract only requires real PII to be caught, not that the guard
        # is maximally strict everywhere else.


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
