# PlanFlow database backup runbook

PlanFlow has two backup layers:

- In-project snapshots: `backup.daily_snapshots` inside the same Supabase
  project. This is the active daily backup path.
- Optional offsite dump: `pg_dump` to a separate Postgres DB or local dump file.
  This is stronger disaster recovery, but it needs another DB URL.

The in-project backup is separate from the in-app `user_backups` feature.
`user_backups` stores per-user app snapshots; `backup.daily_snapshots` stores
all PlanFlow app tables for operational recovery.

## Active in-project backup

Source project: PlanFlow Supabase project `xqvvfnvmytjlblcngipn`.

Applied SQL:

```text
supabase/in_project_backup.sql
```

Objects:

- `backup.daily_snapshots`: JSONB snapshots for PlanFlow app tables
- `backup.create_daily_snapshot(label, snapshot_date)`: creates a snapshot
- `backup.prune_daily_snapshots(recent_days, monthly_months)`: retention cleanup
- `backup.restore_snapshot(snapshot_id, tables)`: manual restore helper
- `cron.job` entry `planflow-daily-in-project-backup`

Schedule:

```text
30 18 * * * UTC = 03:30 KST daily
```

Retention:

- daily automatic snapshots for 35 days
- one automatic monthly snapshot for 12 months

The `backup` schema and functions are not granted to `anon` or `authenticated`,
so the mobile app cannot call destructive backup restore paths.

## Check backup status

Run in Supabase SQL Editor:

```sql
select id, label, snapshot_date, table_counts, created_at
from backup.daily_snapshots
order by created_at desc
limit 10;

select jobid, jobname, schedule, command, active
from cron.job
where jobname = 'planflow-daily-in-project-backup';
```

## Create a manual snapshot

```sql
select backup.create_daily_snapshot('manual_before_restore');
```

## Restore from a snapshot

This is intentionally manual and should only be run from Supabase SQL Editor
after checking the target snapshot.

```sql
select id, label, snapshot_date, table_counts, created_at
from backup.daily_snapshots
order by created_at desc;

select backup.restore_snapshot('SNAPSHOT_UUID_HERE'::uuid);
```

For a narrower restore, pass specific table names:

```sql
select backup.restore_snapshot(
  'SNAPSHOT_UUID_HERE'::uuid,
  array['public.events', 'public.pre_actions', 'public.reminders']
);
```

Be careful with partial restores because foreign keys can require parent/child
tables to be restored together.

## Offsite backup option

This is not currently required for the active setup, but keep it available for
later. It protects against project-level damage better than in-project
snapshots.

Do not use the existing `AI expense-tracker` Supabase project as the backup
target. It is a different app and should not be overwritten by PlanFlow data.

## Local secret config

Copy the example file and fill local-only connection strings:

```powershell
Copy-Item env\db-backup.example.json env\db-backup.local.json
```

`env/db-backup.local.json` is ignored by Git. Do not commit it.

Required fields:

- `SourceDatabaseUrl`: direct Postgres connection string for the PlanFlow DB.
- `BackupDatabaseUrl`: direct Postgres connection string for the backup DB.
- `DumpDirectory`: local or OneDrive folder that stores dated `.dump` files.
- `Schemas`: defaults to `auth`, `public`, and `storage`.
- `PgBin`: optional folder containing `pg_dump.exe`, `pg_restore.exe`, and
  `psql.exe`.

Use PostgreSQL client tools that match the Supabase Postgres major version
when possible. PlanFlow currently reports Postgres 17, so PostgreSQL 17 client
tools are preferred.

## Run one backup manually

```powershell
.\scripts\planflow-db-backup.ps1
```

This creates a compressed dump and restores it into the backup DB. The script
refuses to run if source and target URLs are identical.

For a dump-only dry operational check:

```powershell
.\scripts\planflow-db-backup.ps1 -SkipRestore
```

## Register the daily schedule

```powershell
.\scripts\register-planflow-db-backup-task.ps1 -At "03:30" -RunNow
```

The task runs as the current Windows user, starts later if the PC was asleep,
and does not clear or modify the production DB.

## Retention

Default local dump retention:

- keep daily dumps for 35 days
- keep one monthly dump for 12 months

The backup DB itself is always overwritten with the latest successful dump.
The dated `.dump` files are the point-in-time archive.

## Restore drill

To restore into a replacement DB, never point the app at the target until the
restore has completed and a small verification query passes.

```powershell
$dump = "C:\Users\tught\OneDrive\PlanFlow Database Backups\planflow-db-YYYYMMDD-HHMMSS.dump"
$target = "postgresql://..."
pg_restore --clean --if-exists --no-owner --no-privileges --dbname $target $dump
psql $target -c "select count(*) from public.events;"
```

After verification, update the app/server environment to point at the restored
Supabase project and run a login/event smoke test.
