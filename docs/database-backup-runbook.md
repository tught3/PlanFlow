# PlanFlow database backup runbook

This runbook is for a whole database safety copy. It is separate from the in-app
`user_backups` feature, which stores per-user app snapshots inside the same
Supabase project.

## Goal

- Source DB: PlanFlow production Supabase project `xqvvfnvmytjlblcngipn`.
- Backup DB: a separate PostgreSQL database, ideally a separate Supabase/Neon
  project that is not used by the app.
- Schedule: once per day.
- Restore posture: if the production DB is damaged, use the latest dump or the
  warmed backup DB to restore into a new production DB.

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
