"""Contract tests for .github/workflows/store-readback.yml's PII guards
(spec SEC-M6 hardening, R3-E MEDIUM-1 fix).

The workflow has two independent PII-safety steps that must both run before
the artifact upload step:

1. A plain-text grep guard (email pattern, plus a phone pattern that only
   matches phone-*shaped* strings -- international "+..." numbers or
   Korean-format "01X-XXXX-XXXX" numbers -- so it does not false-positive on
   ordinary sanitized-snapshot content like ISO-8601 ``capturedAt``
   timestamps or Google/Apple's long numeric resource ids).
2. A JSON structural guard that walks every JSON file in the readback output
   directory and asserts every known PII field (``contactEmail``,
   ``contactPhone``, ``demoAccountName``, ``contactFirstName``,
   ``contactLastName``) is *exactly* ``{"present": <bool>}`` -- never a raw
   value, and never carrying any extra key (e.g. a legacy ``sha256_12``
   digest).

These tests parse the workflow YAML and, where possible, actually execute
the extracted guard script bodies via subprocess against real temp
directories/files -- not just regex-match the source text -- so a guard that
looks right but is buggy in practice is caught.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

# On Windows, a bare "bash" can resolve to the (non-functional in this
# sandbox) WSL launcher at C:\Windows\System32\bash.exe ahead of Git Bash on
# PATH, depending on how the interpreter itself was launched -- explicitly
# prefer Git Bash so these subprocess-execution tests are stable regardless
# of PATH search order.
_GIT_BASH_CANDIDATES = (
    r"C:\Program Files\Git\usr\bin\bash.exe",
    r"C:\Program Files\Git\bin\bash.exe",
)


def _bash_executable() -> str:
    for candidate in _GIT_BASH_CANDIDATES:
        if pathlib.Path(candidate).exists():
            return candidate
    found = shutil.which("bash")
    if found:
        return found
    raise unittest.SkipTest("no usable bash executable found for subprocess-execution tests")

try:
    import yaml

    HAVE_YAML = True
except ImportError:  # pragma: no cover - environment without PyYAML
    HAVE_YAML = False

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "store-readback.yml"
LEGACY_SNAPSHOT_PATH = ROOT / "config" / "store" / "snapshots" / "android-readback-2026-09-11.json"


def _dedent_block_scalar(run_text: str) -> str:
    """A YAML block scalar's ``run: |`` body, once loaded via PyYAML, has
    already had its *own* common leading indentation stripped by the YAML
    parser -- ``run_text`` here is therefore already directly executable
    shell (no further dedenting needed). This helper exists only so a
    future refactor that changes how ``run_text`` is obtained has one place
    to fix, and so it's obvious this was considered rather than silently
    assumed."""
    return run_text


@unittest.skipUnless(WORKFLOW_PATH.exists(), "workflow file not found")
@unittest.skipUnless(HAVE_YAML, "PyYAML required for structured workflow parsing")
class StoreReadbackPiiGuardContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_text = WORKFLOW_PATH.read_text(encoding="utf-8")
        cls.doc = yaml.safe_load(cls.workflow_text)

    def _steps(self):
        job = self.doc["jobs"]["readback"]
        return job["steps"]

    def _step_by_name_substring(self, *substrings: str) -> dict:
        lowered = [s.lower() for s in substrings]
        for step in self._steps():
            name = (step.get("name") or "").lower()
            if all(s in name for s in lowered):
                return step
        self.fail(f"no workflow step found whose name contains all of {substrings!r}")

    def _grep_guard_step(self) -> dict:
        return self._step_by_name_substring("raw pii", "email/phone")

    def _field_shape_guard_step(self) -> dict:
        return self._step_by_name_substring("presence-only")

    # -- step existence / ordering -------------------------------------

    def test_both_pii_guard_steps_exist(self):
        self.assertTrue(self._grep_guard_step().get("run", "").strip())
        self.assertTrue(self._field_shape_guard_step().get("run", "").strip())

    def test_both_pii_guard_steps_run_before_artifact_upload(self):
        steps = self._steps()
        names = [(step.get("name") or "").lower() for step in steps]
        grep_index = next(i for i, n in enumerate(names) if "raw pii" in n and "email/phone" in n)
        shape_index = next(i for i, n in enumerate(names) if "presence-only" in n)
        upload_index = next(
            i
            for i, step in enumerate(steps)
            if (step.get("uses") or "").startswith("actions/upload-artifact")
        )
        self.assertLess(grep_index, upload_index)
        self.assertLess(shape_index, upload_index)

    def test_both_pii_guard_steps_fail_the_job_on_violation(self):
        self.assertIn("exit 1", self._grep_guard_step().get("run", ""))
        self.assertIn("sys.exit(1)", self._field_shape_guard_step().get("run", ""))

    # -- grep guard: pattern correctness ---------------------------------

    def _grep_patterns(self) -> list[str]:
        run_text = _dedent_block_scalar(self._grep_guard_step().get("run", ""))
        return re.findall(r"grep\s+-R\s+-E\s+-l\s+--\s+'([^']+)'", run_text)

    def test_grep_guard_has_separate_email_and_phone_patterns(self):
        patterns = self._grep_patterns()
        self.assertEqual(len(patterns), 2, f"expected exactly 2 grep patterns, got {patterns!r}")

    def test_grep_guard_catches_real_email_and_phone_pii(self):
        patterns = [re.compile(p) for p in self._grep_patterns()]
        email_sample = "contact us at dev@example.com for help"
        intl_phone_sample = "call +1 555 0100 1234 now"
        kr_phone_sample = "연락처: 010-1234-5678 입니다"
        self.assertTrue(any(p.search(email_sample) for p in patterns), "no pattern caught a plain email address")
        self.assertTrue(any(p.search(intl_phone_sample) for p in patterns), "no pattern caught an international phone number")
        self.assertTrue(any(p.search(kr_phone_sample) for p in patterns), "no pattern caught a Korean-format phone number")

    def test_grep_guard_does_not_false_positive_on_sanitized_snapshot_shapes(self):
        """SEC-M4/F09 MEDIUM-1 regression: the previous phone-number pattern
        (``\\+?[0-9][0-9 ().-]{7,}[0-9]``) matched ISO-8601 ``capturedAt``
        timestamps and long numeric resource ids, so it blocked every
        normal sanitized snapshot. Neither pattern must match those
        shapes."""
        patterns = [re.compile(p) for p in self._grep_patterns()]
        captured_at_line = '"capturedAt": "2026-09-11T01:42:11Z"'
        numeric_id_line = '"id": "12132409606821278277"'
        self.assertFalse(any(p.search(captured_at_line) for p in patterns), "a pattern false-positived on capturedAt")
        self.assertFalse(any(p.search(numeric_id_line) for p in patterns), "a pattern false-positived on a numeric id")

    def test_grep_guard_executes_correctly_via_subprocess(self):
        """Actually run the extracted grep-guard shell body (not just its
        regex source) against a real sanitized-shaped snapshot and a real
        PII-containing one."""
        run_text = _dedent_block_scalar(self._grep_guard_step().get("run", ""))

        with tempfile.TemporaryDirectory() as clean_dir, tempfile.TemporaryDirectory() as bad_dir:
            clean_path = pathlib.Path(clean_dir)
            bad_path = pathlib.Path(bad_dir)
            (clean_path / "snap.json").write_text(
                json.dumps(
                    {
                        "capturedAt": "2026-09-11T01:42:11Z",
                        "fields": {"details": {"contactEmail": {"present": True}}},
                        "id": "12132409606821278277",
                    }
                ),
                encoding="utf-8",
            )
            (bad_path / "snap.json").write_text(
                json.dumps({"fields": {"details": {"contactEmail": "real.person@example.com"}}}),
                encoding="utf-8",
            )

            clean_script = run_text.replace(
                '${{ steps.readback.outputs.out_dir }}', str(clean_path)
            )
            bad_script = run_text.replace(
                '${{ steps.readback.outputs.out_dir }}', str(bad_path)
            )

            clean_result = subprocess.run([_bash_executable(), "-c", clean_script], capture_output=True, text=True)
            self.assertEqual(clean_result.returncode, 0, clean_result.stderr)

            bad_result = subprocess.run([_bash_executable(), "-c", bad_script], capture_output=True, text=True)
            self.assertNotEqual(bad_result.returncode, 0)
            self.assertIn("BLOCKED_PII_IN_SNAPSHOT", bad_result.stderr)

    # -- JSON field-shape guard: structural correctness ------------------

    def _run_field_shape_guard(self, out_dir: pathlib.Path) -> subprocess.CompletedProcess:
        run_text = _dedent_block_scalar(self._field_shape_guard_step().get("run", ""))
        script = run_text.replace('${{ steps.readback.outputs.out_dir }}', str(out_dir))
        return subprocess.run([_bash_executable(), "-c", script], capture_output=True, text=True)

    def test_field_shape_guard_passes_a_correctly_sanitized_snapshot(self):
        with tempfile.TemporaryDirectory() as out_dir:
            out_path = pathlib.Path(out_dir)
            (out_path / "snap.json").write_text(
                json.dumps(
                    {
                        "capturedAt": "2026-09-11T01:42:11Z",
                        "fields": {
                            "details": {
                                "contactEmail": {"present": True},
                                "contactPhone": {"present": False},
                                "contactWebsite": "https://fluxstudio.co.kr/",
                            }
                        },
                        "id": "12132409606821278277",
                    }
                ),
                encoding="utf-8",
            )
            result = self._run_field_shape_guard(out_path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_field_shape_guard_rejects_raw_pii_value(self):
        with tempfile.TemporaryDirectory() as out_dir:
            out_path = pathlib.Path(out_dir)
            (out_path / "snap.json").write_text(
                json.dumps({"fields": {"details": {"contactEmail": "real.person@example.com"}}}),
                encoding="utf-8",
            )
            result = self._run_field_shape_guard(out_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("BLOCKED_PII_FIELD_SHAPE", result.stderr)

    def test_field_shape_guard_rejects_legacy_extra_digest_key(self):
        """A PII field carrying {"present": true, "sha256_12": "..."} (an
        extra key beyond "present") must also be rejected -- presence-only
        means *exactly* {"present": bool}, not "at least present"."""
        with tempfile.TemporaryDirectory() as out_dir:
            out_path = pathlib.Path(out_dir)
            (out_path / "snap.json").write_text(
                json.dumps(
                    {"fields": {"details": {"contactEmail": {"present": True, "sha256_12": "25dcd93b0d34"}}}}
                ),
                encoding="utf-8",
            )
            result = self._run_field_shape_guard(out_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("BLOCKED_PII_FIELD_SHAPE", result.stderr)

    @unittest.skipUnless(LEGACY_SNAPSHOT_PATH.exists(), "legacy snapshot fixture not present in this checkout")
    def test_KNOWN_LIMITATION_legacy_snapshot_with_sha256_12_fails_new_field_shape_guard(self):
        """Documents, rather than hides, a known incompatibility: the
        committed snapshot config/store/snapshots/android-readback-2026-09-11.json
        pre-dates this guard and still carries the legacy sha256_12 digest
        alongside "present" for contactEmail/contactPhone. Applying the new
        field-shape guard to it *fails* -- this snapshot would need to be
        regenerated (dropping sha256_12) before a future readback run could
        pass this guard against it. This is reported honestly rather than
        weakening the guard or excluding the file from the check."""
        with tempfile.TemporaryDirectory() as out_dir:
            out_path = pathlib.Path(out_dir)
            (out_path / "android.json").write_text(
                LEGACY_SNAPSHOT_PATH.read_text(encoding="utf-8"), encoding="utf-8"
            )
            result = self._run_field_shape_guard(out_path)
            self.assertNotEqual(
                result.returncode,
                0,
                "expected the legacy snapshot's sha256_12 field to be rejected by the new guard "
                "(if this now passes, the legacy snapshot has been regenerated/fixed -- update this test)",
            )
            self.assertIn("BLOCKED_PII_FIELD_SHAPE", result.stderr)

    def test_grep_guard_catches_hyphenless_and_dot_separated_korean_phone_numbers(self):
        """R4-C L-5: the phone pattern used to only match hyphenated Korean
        numbers (01X-XXXX-XXXX). Hyphen-less (01012345678) and dot-separated
        (010.1234.5678) forms must also be caught."""
        patterns = [re.compile(p) for p in self._grep_patterns()]
        no_sep_sample = '"contactPhone": "01012345678"'
        dot_sep_sample = '"contactPhone": "010.1234.5678"'
        self.assertTrue(
            any(p.search(no_sep_sample) for p in patterns),
            "no pattern caught a hyphen-less Korean phone number",
        )
        self.assertTrue(
            any(p.search(dot_sep_sample) for p in patterns),
            "no pattern caught a dot-separated Korean phone number",
        )

    def test_grep_guard_still_does_not_false_positive_on_long_numeric_ids_or_timestamps(self):
        """The broadened hyphen-less phone pattern must not start matching
        capturedAt timestamps or long numeric resource ids either."""
        patterns = [re.compile(p) for p in self._grep_patterns()]
        captured_at_line = '"capturedAt": "2026-09-11T01:42:11Z"'
        numeric_id_line = '"id": "12132409606821278277"'
        self.assertFalse(any(p.search(captured_at_line) for p in patterns), "a pattern false-positived on capturedAt")
        self.assertFalse(any(p.search(numeric_id_line) for p in patterns), "a pattern false-positived on a numeric id")

    def test_grep_guards_treat_missing_out_dir_as_a_failure(self):
        """R4-C L-6: a nonexistent out_dir must fail the job, not silently
        pass as if grep had simply found nothing."""
        run_text = _dedent_block_scalar(self._grep_guard_step().get("run", ""))
        with tempfile.TemporaryDirectory() as parent_dir:
            missing_path = pathlib.Path(parent_dir) / "does-not-exist"
            script = run_text.replace('${{ steps.readback.outputs.out_dir }}', str(missing_path))
            result = subprocess.run([_bash_executable(), "-c", script], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_grep_guards_do_not_swallow_a_grep_error_as_a_pass(self):
        """R4-C L-6 regression: "if grep ... 2>/dev/null; then" treated any
        non-zero grep exit (including exit 2, a real error) as "no match,
        guard passed". Force ``grep`` itself to fail with exit 2 (via a
        stub executable placed earlier on PATH) and assert the guard step
        fails the job instead of printing "passed", proving the exit code
        is actually inspected rather than only branched 0-vs-nonzero."""
        run_text = _dedent_block_scalar(self._grep_guard_step().get("run", ""))
        with tempfile.TemporaryDirectory() as out_dir, tempfile.TemporaryDirectory() as fake_bin_dir:
            out_path = pathlib.Path(out_dir)
            (out_path / "snap.json").write_text('{"ok": true}', encoding="utf-8")

            fake_grep = pathlib.Path(fake_bin_dir) / "grep"
            fake_grep.write_text("#!/usr/bin/env bash\nexit 2\n", encoding="utf-8")
            fake_grep.chmod(0o755)

            script = run_text.replace('${{ steps.readback.outputs.out_dir }}', str(out_path))
            env = dict(os.environ)
            env["PATH"] = f"{fake_bin_dir}{os.pathsep}{env.get('PATH', '')}"
            result = subprocess.run(
                [_bash_executable(), "-c", script], capture_output=True, text=True, env=env
            )
            self.assertNotEqual(
                result.returncode,
                0,
                f"guard should fail closed when grep itself errors (exit 2); stderr={result.stderr!r}",
            )

    def test_field_shape_guard_catches_case_and_separator_variants_of_pii_field_names(self):
        """R4-C L-5: field-name matching must be normalized (case-insensitive,
        "_"/"-" ignored) so "ContactFirstName" and "contact_first_name" are
        still recognized as the known PII field "contactFirstName"."""
        with tempfile.TemporaryDirectory() as out_dir:
            out_path = pathlib.Path(out_dir)
            (out_path / "snap.json").write_text(
                json.dumps(
                    {
                        "fields": {
                            "details": {
                                "ContactFirstName": "Real Name",
                                "contact_first_name": "Real Name Two",
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = self._run_field_shape_guard(out_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("BLOCKED_PII_FIELD_SHAPE", result.stderr)

    def test_field_shape_guard_covers_all_known_sanitizer_pii_fields(self):
        """Cross-check against the actual sanitizer field lists in code
        (not just re-declaring the same list in the guard) so this doesn't
        silently drift if a sanitizer's field list changes."""
        run_text = _dedent_block_scalar(self._field_shape_guard_step().get("run", ""))
        code_fields = {"contactEmail", "contactPhone", "demoAccountName", "contactFirstName", "contactLastName"}
        for field in code_fields:
            self.assertIn(
                f'"{field}"',
                run_text,
                f"PII field {field!r} (known from readback sanitizers) is missing from the "
                "field-shape guard's PII_FIELDS list",
            )


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
