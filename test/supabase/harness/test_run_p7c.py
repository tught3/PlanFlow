"""Regression tests for the disposable PostgreSQL launcher."""

import argparse
from contextlib import ExitStack, redirect_stdout
from io import StringIO
from pathlib import Path
import tempfile
import unittest
from unittest.mock import call, patch

import run_p7c as harness


class HarnessTest(unittest.TestCase):
    def setUp(self):
        resources = ExitStack()
        self.addCleanup(resources.close)
        enter = resources.enter_context
        scratch_root = enter(tempfile.TemporaryDirectory())
        self.args = argparse.Namespace(
            scratch_root=Path(scratch_root), migration_root=None,
            schema_only=False, baseline_rev=None,
        )
        enter(patch.object(argparse.ArgumentParser, "parse_args", return_value=self.args))
        self.stdout = enter(redirect_stdout(StringIO()))
        self.pg = enter(patch.object(harness, "Postgres")).return_value
        self.schema = enter(patch.object(harness, "local_schema", return_value="select 1;"))
        self.paths = [Path(name) for name in harness.MIGRATIONS]
        self.migrations = enter(patch.object(harness, "migration_files", return_value=self.paths))
        self.exercise = enter(patch.object(harness, "exercise"))

    def test_baseline_starts_from_revision_and_runs_chain_once_in_order(self):
        self.args.baseline_rev = "7fd8e80b"
        harness.main()

        self.schema.assert_called_once_with("7fd8e80b")
        self.assertEqual(
            [call.args[1].name for call in self.pg.file.call_args_list],
            ["p7c_auth.sql", "schema.sql", *harness.MIGRATIONS],
        )
        self.exercise.assert_called_once_with(self.pg, "p7c_baseline")
        self.assertNotIn("drop trigger", str(self.pg.sql.call_args_list))

    def test_schema_only_starts_with_gate_warning(self):
        self.args.schema_only = True
        harness.main()

        self.assertIn("migration gate not run", self.stdout.getvalue().splitlines()[0].lower())
        self.migrations.assert_not_called()
        self.exercise.assert_called_once_with(self.pg, "p7c_schema")

    def test_test_failure_and_cleanup_failure_are_both_reported(self):
        self.pg.start.side_effect = RuntimeError("test setup failed")
        self.pg.stop.side_effect = RuntimeError("shutdown could not be confirmed")

        with self.assertRaises(RuntimeError) as failure:
            harness.main()

        self.assertIn("test setup failed", str(failure.exception))
        self.assertIn("shutdown could not be confirmed", str(failure.exception))


class PostgresTest(unittest.TestCase):
    def test_windows_flags_apply_to_initdb_and_pg_ctl_start(self):
        with tempfile.TemporaryDirectory() as scratch, \
                patch.object(harness.shutil, "which", side_effect=lambda name: name), \
                patch.object(harness.subprocess, "run") as run:
            run.return_value.returncode = 0
            harness.Postgres(Path(scratch)).start()

        self.assertEqual([call.args[0][0] for call in run.call_args_list], ["initdb", "pg_ctl"])
        for command in run.call_args_list:
            self.assertEqual(command.kwargs.get("creationflags"),
                             getattr(harness.subprocess, "CREATE_NO_WINDOW", 0))

    def test_scenarios_check_database_before_setting_up_fixtures(self):
        sql = (harness.HERE / "p7c_scenarios.sql").read_text(encoding="utf-8")
        first_block = sql.split("$$;", 1)[0]

        self.assertIn("current_database()", first_block)
        self.assertIn("p7c\\_%", first_block)
        self.assertNotIn("\\set leader", first_block)

    def test_exercise_requests_both_lock_orders(self):
        with patch.object(harness, "Postgres") as postgres, \
                patch.object(harness, "concurrent_restore_and_withdrawal") as race, \
                redirect_stdout(StringIO()):
            pg = postgres.return_value
            harness.exercise(pg, "p7c_schema")

        self.assertEqual(race.call_args_list, [
            call(pg, "p7c_schema", restore_first=False),
            call(pg, "p7c_schema", restore_first=True),
        ])


if __name__ == "__main__":
    unittest.main()
