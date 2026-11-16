"""Run PlanFlow P7c SQL checks in a disposable loopback-only PostgreSQL cluster."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MIGRATIONS = (
    "20261112000100_events_occurrence_columns.sql",
    "20261112000200_events_updated_at_skip_sync_metadata.sql",
    "20261112000300_group_backups_lockdown.sql",
    "20261112000400_users_protected_columns.sql",
    "20261112000500_fix_delete_user_account.sql",
    "20261112000600_invite_link_removed_member_guard.sql",
    "20261117000100_group_invites_server_timestamps.sql",
)
LOOPBACK = "127.0.0.1"
HARNESS_USER = "p7c_owner"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
UUID = re.compile(r"[0-9a-f-]{36}\Z")
CRON_EXTENSION = "create extension if not exists pg_cron with schema extensions;"
CRON_JOB = re.compile(
    r"^do \$\$\ndeclare\n  existing_job_id bigint;\n"
    r"(?:(?!^\$\$;).)*?planflow-daily-in-project-backup"
    r"(?:(?!^\$\$;).)*?^\$\$;",
    re.DOTALL | re.MULTILINE,
)


def checked(result):
    if result.returncode:
        raise RuntimeError(
            f"{Path(result.args[0]).name} exited {result.returncode}\n"
            f"{result.stdout[-3000:]}\n{result.stderr[-3000:]}"
        )
    return result.stdout.strip()


def local_schema(baseline_rev=None):
    if baseline_rev is None:
        sql = (REPO / "supabase" / "schema.sql").read_text(encoding="utf-8-sig")
    else:
        def git(*args):
            return checked(subprocess.run(
                ["git", *args], cwd=REPO, capture_output=True, text=True,
                encoding="utf-8", timeout=30, creationflags=NO_WINDOW,
            ))

        commit = git("rev-parse", "--verify", "--end-of-options", f"{baseline_rev}^{{commit}}")
        sql = git("show", f"{commit}:supabase/schema.sql").removeprefix("\ufeff")
    # The backup tables/functions are still loaded. The job scheduler is the
    # only Supabase extension excluded from this standalone PostgreSQL fixture.
    if sql.count(CRON_EXTENSION) != 1:
        raise RuntimeError("expected one pg_cron extension declaration")
    stripped, count = CRON_JOB.subn("", sql.replace(CRON_EXTENSION, ""))
    if count != 1:
        raise RuntimeError("expected one PlanFlow daily snapshot registration")
    # The schema snapshot assumes existing objects in two sections:
    # users_set_updated_at depends on a function declared later, and the
    # groups select policy depends on the later invite table and target helper.
    updated_at = re.search(
        r"^create or replace function public\.set_updated_at\(\)\n"
        r".*?^\$\$;",
        stripped, re.DOTALL | re.MULTILINE,
    )
    group_policy = re.search(
        r'^create policy "groups_select_member"\n.*?\n  \);',
        stripped, re.DOTALL | re.MULTILINE,
    )
    if not updated_at or not group_policy:
        raise RuntimeError("schema bootstrap dependencies changed; update the fixture ordering")
    ordered = stripped.replace(updated_at[0], "", 1).replace(group_policy[0], "", 1)
    return f"{updated_at[0]}\n{ordered}\n{group_policy[0]}\n"


def migration_files(p2_root):
    own = REPO / "supabase" / "migrations"
    paths = [own / name for name in MIGRATIONS]
    if p2_root is not None:
        paths[1] = p2_root.resolve(strict=True) / MIGRATIONS[1]
    for path in paths:
        if not path.is_file():
            hint = (
                " Check out P2 commit b9180d24 or a successor and pass its "
                "supabase/migrations directory to --migration-root."
                if path.name == MIGRATIONS[1] else ""
            )
            raise RuntimeError(f"missing migration: {path}.{hint}")
    return paths


class Postgres:
    def __init__(self, scratch):
        self.scratch = scratch
        self.data = scratch / "data"
        self.log = scratch / "postgres.log"
        self.port = None
        self.children = []
        self.tools = {}
        for command in ("initdb", "pg_ctl", "psql"):
            binary = shutil.which(command)
            if binary is None:
                raise RuntimeError(f"{command} is required on PATH")
            self.tools[command] = binary
        # No inherited libpq connection, auth, TLS, or server options.
        self.env = {key: value for key, value in os.environ.items() if not key.upper().startswith("PG")}
        self.env.update(
            PGCLIENTENCODING="UTF8",
            PGCONNECT_TIMEOUT="4",
            PGOPTIONS="-c statement_timeout=45s -c idle_in_transaction_session_timeout=45s -c TimeZone=UTC",
        )

    def run(self, command, *args, stdin=None, timeout=45):
        return subprocess.run(
            [self.tools[command], *map(str, args)],
            cwd=self.scratch,
            env=self.env,
            input=stdin,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            creationflags=NO_WINDOW,
        )

    def start(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind((LOOPBACK, 0))
            self.port = sock.getsockname()[1]

        password = secrets.token_urlsafe(32)
        password_file = self.scratch / "initdb-password"
        password_file.write_text(password + "\n", encoding="ascii")
        try:
            checked(self.run(
                "initdb", "-D", self.data, "-U", HARNESS_USER,
                "--encoding=UTF8", "--locale=C", "--auth=scram-sha-256",
                "--no-sync", f"--pwfile={password_file}", timeout=120,
            ))
        finally:
            password_file.unlink(missing_ok=True)

        # A Windows postmaster can inherit pg_ctl pipe handles. Spool console
        # output to a file so the launcher can return while the server runs.
        control_log = self.scratch / "pg_ctl.log"
        with control_log.open("wb") as output:
            result = subprocess.run(
                [
                    self.tools["pg_ctl"], "-D", str(self.data), "-l", str(self.log),
                    "-w", "-t", "20", "-o",
                    f"-h {LOOPBACK} -p {self.port} -c unix_socket_directories= -c fsync=off",
                    "start",
                ],
                cwd=self.scratch,
                env=self.env,
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=30,
                creationflags=NO_WINDOW,
            )
        if result.returncode:
            logs = (control_log, self.log)
            details = "\n".join(
                log.read_text(encoding="utf-8", errors="replace")[-3000:]
                for log in logs if log.exists()
            )
            raise RuntimeError(f"pg_ctl start exited {result.returncode}: {details}")
        self.env["PGPASSWORD"] = password

    def psql_args(self, db):
        return [
            "-X", "-w", "-h", LOOPBACK, "-p", str(self.port), "-U", HARNESS_USER,
            "-d", db, "-v", "ON_ERROR_STOP=1", "-qAt",
        ]

    def sql(self, db, sql):
        return checked(self.run("psql", *self.psql_args(db), "-f", "-", stdin=sql))

    def file(self, db, path):
        return checked(self.run("psql", *self.psql_args(db), "-f", path))

    def start_session(self, db, app, *args):
        stdout = (self.scratch / f"{app}.out").open("w+b")
        stderr = (self.scratch / f"{app}.err").open("w+b")
        try:
            process = subprocess.Popen(
                [self.tools["psql"], *self.psql_args(db), *args],
                cwd=self.scratch,
                env={**self.env, "PGAPPNAME": app},
                stdin=subprocess.PIPE,
                stdout=stdout,
                stderr=stderr,
                text=True,
                encoding="utf-8",
                creationflags=NO_WINDOW,
            )
        finally:
            stdout.close()
            stderr.close()
        self.children.append(process)
        return process

    def report(self, app, stream):
        return (self.scratch / f"{app}.{stream}").read_text(encoding="utf-8").strip()

    def stop(self):
        for process in self.children:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        if (self.data / "postmaster.pid").exists():
            checked(self.run(
                "pg_ctl", "-D", self.data, "-w", "-t", "45", "-m", "fast", "stop", timeout=55,
            ))
        if (self.data / "PG_VERSION").exists():
            result = self.run("pg_ctl", "-D", self.data, "status")
            if result.returncode != 3:
                raise RuntimeError("PostgreSQL shutdown could not be confirmed")
        if self.port is not None:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.settimeout(1)
                if sock.connect_ex((LOOPBACK, self.port)) == 0:
                    raise RuntimeError(f"loopback port {self.port} still has a listener")


def wait_for(pg, db, query, description):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if pg.sql(db, query) == "t":
            return
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {description}")


def wait_for_lock(pg, db, waiting_app, blocking_app):
    wait_for(pg, db, f"""
        select exists (
          select 1
          from pg_stat_activity as waiting, pg_stat_activity as blocking
          where waiting.application_name = '{waiting_app}'
            and blocking.application_name = '{blocking_app}'
            and blocking.pid = any(pg_blocking_pids(waiting.pid))
        );
    """, f"{waiting_app} to wait behind {blocking_app}")


def concurrent_restore_and_withdrawal(pg, db, *, restore_first):
    suffix = "000000000007" if restore_first else "000000000006"
    user = f"10000000-0000-4000-8000-{suffix}"
    group = f"20000000-0000-4000-8000-{suffix}"
    backup = pg.sql(db, f"""
        insert into auth.users (id, email) values ('{user}', 'concurrent-{suffix}@example.test');
        insert into public.groups (id, name, created_by)
        values ('{group}', 'P7c concurrent fixture', '{user}');
        select set_config('request.jwt.claims',
            jsonb_build_object('sub', '{user}')::text, false);
        set role authenticated;
        select (public.delete_group_with_backup('{group}')).id;
    """).splitlines()[-1]
    if not UUID.fullmatch(backup):
        raise RuntimeError("concurrency fixture did not produce a backup")

    if restore_first:
        reverse_lock_order(pg, db, user, backup)
        return

    withdraw_app = "p7c_withdraw"
    restore_app = "p7c_restore"
    withdraw = pg.start_session(db, withdraw_app, "-f", "-")
    withdraw.stdin.write(f"""
        begin;
        select id from public.users where id = '{user}' for update;
        select 'profile-locked';
    """)
    withdraw.stdin.flush()
    wait_for(pg, db, f"""
        select exists (select 1 from pg_stat_activity
            where application_name = '{withdraw_app}'
              and state = 'idle in transaction' and query like '%profile-locked%');
    """, "withdrawal session to hold the profile lock")

    restore = pg.start_session(db, restore_app, "-f", "-")
    restore.stdin.write(f"""
        select set_config('request.jwt.claims',
            jsonb_build_object('sub', '{user}')::text, false);
        set role authenticated;
        select public.restore_group_from_backup('{backup}') is not null;
    """)
    restore.stdin.close()
    wait_for_lock(pg, db, restore_app, withdraw_app)

    # Restore must wait for the user row before locking its backup row.
    if pg.sql(db, f"select id from public.group_backups where id = '{backup}' for update nowait;") != backup:
        raise RuntimeError("backup row was unavailable during profile wait")

    withdraw.stdin.write(f"""
        set local role service_role;
        select success from public.delete_user_account('{user}');
        commit;
    """)
    withdraw.stdin.close()
    if withdraw.wait(timeout=12) != 0 or pg.report(withdraw_app, "out").splitlines()[-1] != "t":
        raise RuntimeError(f"withdrawal failed: {pg.report(withdraw_app, 'err')}")
    restore_exit = restore.wait(timeout=12)
    restored_error = pg.report(restore_app, "err")
    if restore_exit != 3 or "restore_group_from_backup failed: 사용자 프로필을 찾을 수 없습니다." not in restored_error:
        raise RuntimeError(f"unexpected restore result {restore_exit}: {restored_error}")
    if pg.sql(db, f"""
        select not exists (select 1 from public.group_backups where id = '{backup}')
          and not exists (select 1 from public.users where id = '{user}');
    """) != "t":
        raise RuntimeError("withdrawal did not remove the synthetic owner and backup")
    print("PASS restore waited for withdrawal without a deadlock", flush=True)


def reverse_lock_order(pg, db, user, backup):
    restore_app = "p7c_reverse_restore"
    withdraw_app = "p7c_reverse_withdraw"
    restore = pg.start_session(db, restore_app, "-f", "-")
    restore.stdin.write(f"""
        begin;
        select set_config('request.jwt.claims',
            jsonb_build_object('sub', '{user}')::text, true);
        set local role authenticated;
        select (public.restore_group_from_backup('{backup}')).restored_at is not null;
        select 'restore-open';
    """)
    restore.stdin.flush()
    wait_for(pg, db, f"""
        select exists (select 1 from pg_stat_activity
            where application_name = '{restore_app}'
              and state = 'idle in transaction' and query like '%restore-open%');
    """, "restore session to hold its transaction open")

    withdraw = pg.start_session(db, withdraw_app, "-f", "-")
    withdraw.stdin.write(f"""
        set role service_role;
        select not success and blocked_reason = 'leader_groups'
        from public.delete_user_account('{user}');
    """)
    withdraw.stdin.close()
    wait_for_lock(pg, db, withdraw_app, restore_app)

    restore.stdin.write("commit;\n")
    restore.stdin.close()
    restore_exit = restore.wait(timeout=12)
    restore_result = pg.report(restore_app, "out").splitlines()[-2:]
    if restore_exit != 0 or restore_result != ["t", "restore-open"]:
        raise RuntimeError(f"restore did not commit: {pg.report(restore_app, 'err')}")
    if withdraw.wait(timeout=12) != 0 or pg.report(withdraw_app, "out") != "t":
        raise RuntimeError(f"withdrawal did not see the restored group: {pg.report(withdraw_app, 'err')}")
    if pg.sql(db, f"""
        select exists (select 1 from public.groups where created_by = '{user}')
          and exists (select 1 from public.users where id = '{user}')
          and exists (select 1 from public.group_backups where id = '{backup}' and restored_at is not null);
    """) != "t":
        raise RuntimeError("restore-first race did not preserve the synthetic owner and restored group")
    print("PASS withdrawal waited for restore without a deadlock and saw the restored group", flush=True)


def exercise(pg, db):
    print(f"Testing {db}", flush=True)
    for line in pg.file(db, HERE / "p7c_scenarios.sql").splitlines():
        if line.startswith("PASS "):
            print(line, flush=True)
    concurrent_restore_and_withdrawal(pg, db, restore_first=False)
    concurrent_restore_and_withdrawal(pg, db, restore_first=True)


def apply_migrations(pg, db, migrations, pass_number):
    for path in migrations:
        pg.file(db, path)
        print(f"PASS migration pass {pass_number}: {path.name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migration-root", type=Path, help="supabase/migrations directory containing P2 migration 000200")
    parser.add_argument("--scratch-root", type=Path, default=Path(tempfile.gettempdir()))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--schema-only", action="store_true", help="diagnostic mode; skips the migration gate")
    mode.add_argument("--baseline-rev", help="load this Git commit's schema and apply the ordered chain once")
    args = parser.parse_args()
    if args.schema_only:
        print("Schema-only mode: migration gate not run.", flush=True)
    migrations = () if args.schema_only else migration_files(args.migration_root)
    schema = local_schema(args.baseline_rev)
    root = args.scratch_root.resolve(strict=True)
    scratch = Path(tempfile.mkdtemp(prefix="planflow-p7c-", dir=root)).resolve(strict=True)
    pg = None
    failure = None
    try:
        pg = Postgres(scratch)
        pg.start()
        (scratch / "schema.sql").write_text(schema, encoding="utf-8")
        schema_db = "p7c_baseline" if args.baseline_rev else "p7c_schema"
        pg.sql("postgres", f"create database {schema_db}")
        pg.file(schema_db, HERE / "p7c_auth.sql")
        pg.file(schema_db, scratch / "schema.sql")

        if args.baseline_rev:
            apply_migrations(pg, schema_db, migrations, pass_number=1)
        elif migrations:
            pg.sql("postgres", "create database p7c_migrated template p7c_schema")
            # Reapply earlier migrations over the final schema. For P7c's
            # timestamp guard only, start with the preceding trigger state.
            pg.sql("p7c_migrated", """
                drop trigger group_invites_set_insert_timestamps on public.group_invites;
                drop function public.set_group_invite_insert_timestamps();
            """)
            for pass_number in (1, 2):
                apply_migrations(pg, "p7c_migrated", migrations, pass_number)
            exercise(pg, "p7c_migrated")

        exercise(pg, schema_db)
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            if pg is not None:
                pg.stop()
            if scratch.parent != root or not scratch.name.startswith("planflow-p7c-"):
                raise RuntimeError("scratch path no longer matches the directory created by this run")
            shutil.rmtree(scratch)
            print("Cleaned disposable PostgreSQL process, port, and scratch directory.", flush=True)
        except Exception as error:
            message = f"cleanup failed; inspect owned scratch directory {scratch}: {error}"
            if failure is not None:
                message = f"{type(failure).__name__}: {failure}\n{message}"
            raise RuntimeError(message) from error


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"P7c harness failed: {error}", file=sys.stderr)
        sys.exit(1)
