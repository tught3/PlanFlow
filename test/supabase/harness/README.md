# PlanFlow P7c PostgreSQL harness

Run from the repository root with Python 3.10+ and PostgreSQL's `initdb`, `pg_ctl`, and `psql` on PATH. On Unix, use a non-root account, as required by `initdb`.

```powershell
python test/supabase/harness/run_p7c.py --migration-root E:\worktrees\pf-audit-P2-20261112\supabase\migrations --scratch-root E:\worktrees
```

Omit `--migration-root` once the P2 migration is in this checkout. The option supplies only `20261112000200_events_updated_at_skip_sync_metadata.sql` from a separate local checkout. The remaining SQL files come from this checkout and the script checks that all seven files exist before starting PostgreSQL. `--schema-only` runs the canonical schema checks for diagnosis. It skips migration verification.

The harness starts a disposable, password authenticated cluster on a free IPv4 loopback port. It loads the canonical schema with a minimal Auth fixture and excludes the daily snapshot scheduler and its extension. It orders two schema statements after their dependencies for a fresh database: the users update trigger needs the shared timestamp function and the groups SELECT policy needs the invite table and helper. It independently tests the canonical schema and a clone in which the timestamp guard is installed by the seven migrations in timestamp order, twice. Fixtures use synthetic users and never call an external service. The process, port and scratch directory are checked during cleanup. Any failed assertion or cleanup error exits nonzero.

## Deferred checks

- P8 candidate: the invite target's direct update policy can record an accepted status independently of a successful membership transition.
- An older removed membership that requires an explicit reinvite and has no removal timestamp fails the fresh invite cutoff. The aggregate below counts those rows. It is a read-only query for a separately authorized environment.

```sql
select count(*) from public.group_members where status = 'removed' and removed_at is null and (requires_explicit_reinvite or coalesce(removed_by <> user_id, false));
```
