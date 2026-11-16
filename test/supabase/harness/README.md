# PlanFlow P7c PostgreSQL harness

Run from the repository root with Python 3.10+ and PostgreSQL's `initdb`, `pg_ctl`, and `psql` on PATH. On Unix, use a non-root account, as required by `initdb`.

## Running the migration gate

If this branch does not include the P2 migration, check out P2 commit `b9180d24` or a successor in a separate Git worktree. Fetch `fix/planflow-audit-P2-20261112` from `origin` first if the commit is missing locally. From the P7c checkout:

```powershell
git worktree add --detach ../planflow-p2-harness b9180d24
python test/supabase/harness/run_p7c.py --migration-root ../planflow-p2-harness/supabase/migrations
git worktree remove ../planflow-p2-harness
```

`--migration-root` expects the `supabase/migrations` directory itself. It supplies only `20261112000200_events_updated_at_skip_sync_metadata.sql`. The other migrations are read from the current checkout. Once P2 is in the current checkout, run `python test/supabase/harness/run_p7c.py` without the option. The harness checks for all seven files before starting PostgreSQL.

Default mode checks the canonical schema and a clone with the P7c timestamp trigger and function removed. The migrations run twice on the clone in timestamp order. This checks reapplication over the final schema for the earlier migrations and installation of the P7c timestamp guard from its preceding state.

Use baseline mode to test a full upgrade starting from a pre-Wave1 schema. With `7fd8e80b` available locally, run the following command. Append `--migration-root` if P2 still comes from a separate checkout.

```powershell
python test/supabase/harness/run_p7c.py --baseline-rev 7fd8e80b
```

Baseline mode loads `supabase/schema.sql` from the selected Git revision and runs the same seven migrations once in timestamp order before exercising the migrated database. Both modes use the same minimal Auth fixture, skip the daily snapshot scheduler and its extension, and correct two schema declaration dependencies for fresh databases. The users update trigger needs the shared timestamp function, and the groups SELECT policy needs the invite table and helper.

With `--schema-only`, the first line says `Schema-only mode: migration gate not run.` This mode only checks the current schema for diagnosis.

The harness starts a disposable, password authenticated cluster on a free IPv4 loopback port. Fixtures use synthetic users and never call an external service. Scenarios require a database name beginning with `p7c_`. The process, port, and scratch directory are checked during cleanup. Any failed assertion or cleanup error exits nonzero.

## Deferred checks

- P8 candidate: the invite target's direct update policy can record an accepted status independently of a successful membership transition.
- An older removed membership that requires an explicit reinvite and has no removal timestamp fails the fresh invite cutoff. The aggregate below counts those rows. It is a read-only query for a separately authorized environment.

```sql
select count(*) from public.group_members where status = 'removed' and removed_at is null and (requires_explicit_reinvite or coalesce(removed_by <> user_id, false));
```

## Appendix: invite timestamps before rollout

Run this read-only check in the target environment after separate user approval. It counts existing invites that may need timestamp correction before applying the migration.

```sql
select count(*) from public.group_invites where created_at > now() or expires_at > created_at + interval '7 days';
```
