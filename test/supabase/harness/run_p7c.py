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
CONCURRENT_USER = "10000000-0000-4000-8000-000000000006"
CONCURRENT_GROUP = "20000000-0000-4000-8000-000000000006"
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


def local_schema():
    sql = (REPO / "supabase" / "schema.sql").read_text(encoding="utf-8-sig")
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
            raise RuntimeError(f"missing migration: {path}. For 000200, supply --migration-root.")
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
                "--no-sync", f"--pwfile={password_file}",
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
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
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


def concurrent_restore_and_withdrawal(pg, db):
    backup = pg.sql(db, f"""
        insert into auth.users (id, email) values ('{CONCURRENT_USER}', 'concurrent@example.test');
        insert into public.groups (id, name, created_by)
        values ('{CONCURRENT_GROUP}', 'P7c concurrent fixture', '{CONCURRENT_USER}');
        select set_config('request.jwt.claims',
            jsonb_build_object('sub', '{CONCURRENT_USER}')::text, false);
        set role authenticated;
        select (public.delete_group_with_backup('{CONCURRENT_GROUP}')).id;
    """).splitlines()[-1]
    if not UUID.fullmatch(backup):
        raise RuntimeError("concurrency fixture did not produce a backup")

    withdraw_app = "p7c_withdraw"
    restore_app = "p7c_restore"
    withdraw = pg.start_session(db, withdraw_app, "-f", "-")
    withdraw.stdin.write(f"""
        begin;
        select id from public.users where id = '{CONCURRENT_USER}' for update;
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
            jsonb_build_object('sub', '{CONCURRENT_USER}')::text, false);
        set role authenticated;
        select public.restore_group_from_backup('{backup}') is not null;
    """)
    restore.stdin.close()
    wait_for(pg, db, f"""
        select exists (
          select 1
          from pg_stat_activity as restore, pg_stat_activity as withdrawal
          where restore.application_name = '{restore_app}'
            and withdrawal.application_name = '{withdraw_app}'
            and withdrawal.pid = any(pg_blocking_pids(restore.pid))
        );
    """, "restore to wait behind withdrawal")

    # Restore must wait for the user row before locking its backup row.
    if pg.sql(db, f"select id from public.group_backups where id = '{backup}' for update nowait;") != backup:
        raise RuntimeError("backup row was unavailable during profile wait")

    withdraw.stdin.write(f"""
        set local role service_role;
        select success from public.delete_user_account('{CONCURRENT_USER}');
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
          and not exists (select 1 from public.users where id = '{CONCURRENT_USER}');
    """) != "t":
        raise RuntimeError("withdrawal did not remove the synthetic owner and backup")
    print("PASS restore waited for withdrawal without a deadlock", flush=True)


def exercise(pg, db):
    print(f"Testing {db}", flush=True)
    for line in pg.file(db, HERE / "p7c_scenarios.sql").splitlines():
        if line.startswith("PASS "):
            print(line, flush=True)
    concurrent_restore_and_withdrawal(pg, db)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migration-root", type=Path, help="directory containing P2 migration 000200")
    parser.add_argument("--scratch-root", type=Path, default=Path(tempfile.gettempdir()))
    parser.add_argument("--schema-only", action="store_true", help="diagnostic mode; skips the migration gate")
    args = parser.parse_args()
    migrations = () if args.schema_only else migration_files(args.migration_root)
    schema = local_schema()
    root = args.scratch_root.resolve(strict=True)
    scratch = Path(tempfile.mkdtemp(prefix="planflow-p7c-", dir=root)).resolve(strict=True)
    pg = None
    try:
        pg = Postgres(scratch)
        pg.start()
        (scratch / "schema.sql").write_text(schema, encoding="utf-8")
        pg.sql("postgres", "create database p7c_schema")
        pg.file("p7c_schema", HERE / "p7c_auth.sql")
        pg.file("p7c_schema", scratch / "schema.sql")

        if migrations:
            pg.sql("postgres", "create database p7c_migrated template p7c_schema")
            # Prove a clean upgrade. p7c_schema remains an independent check
            # of the canonical trigger, while p7c_migrated gets it via 000100.
            pg.sql("p7c_migrated", """
                drop trigger group_invites_set_insert_timestamps on public.group_invites;
                drop function public.set_group_invite_insert_timestamps();
            """)
            for pass_number in (1, 2):
                for path in migrations:
                    pg.file("p7c_migrated", path)
                    print(f"PASS migration pass {pass_number}: {path.name}", flush=True)
            exercise(pg, "p7c_migrated")

        exercise(pg, "p7c_schema")
        if args.schema_only:
            print("Schema-only mode: ordered migration chain was not run.", flush=True)
    finally:
        try:
            if pg is not None:
                pg.stop()
            if scratch.parent != root or not scratch.name.startswith("planflow-p7c-"):
                raise RuntimeError("scratch path no longer matches the directory created by this run")
            shutil.rmtree(scratch)
            print("Cleaned disposable PostgreSQL process, port, and scratch directory.", flush=True)
        except Exception as error:
            raise RuntimeError(f"cleanup failed; inspect owned scratch directory {scratch}: {error}") from error


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"P7c harness failed: {error}", file=sys.stderr)
        sys.exit(1)
