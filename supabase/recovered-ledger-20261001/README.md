# Recovered production migration evidence bundle

**Status: non-active evidence bundle.** This is not the project's configured Supabase migration directory and is not wired into deployment.

## Contents and provenance

- `migrations/` contains 46 SQL files: 43 historical remote migrations reconstructed from ordered statements stored in `supabase_migrations.schema_migrations.statements`, plus the three feature migrations below, copied from the committed feature branch.
- The recovered SQL preserves statement order, but the original authored comments and formatting are not recoverable from the ledger. Version `20260626180000` was compared with the existing local file and matched when whitespace and blank lines were ignored.
- The three feature migrations were applied to PlanFlow production with explicit user approval on 2026-10-01: `20260928075255`, `20260928084034`, and `20260928161356`.
- `SHA256SUMS.txt` records the SHA-256 of every SQL file in `migrations/`.

## Important boundaries

- Do not run `db push` from this evidence directory. To use this history in a future deployment, first assemble an isolated Supabase workdir, verify its linked project, hashes, migration list, and dry-run.
- The project's active `supabase/migrations/` directory was left unchanged. It still contains 33 local-only migrations whose effects are mixed: some are represented in production under other IDs, while some have distinct schema or data effects. Do not blindly apply, archive, or mark them applied. Audit them against production and create forward-only migrations for any still-required behavior.
- This bundle is a historical record, not proof of a clean empty-database replay or a full database backup. The live catalog was checked separately; the full schema dump was unavailable because Docker was not running.
- No project link metadata, pooler URL, database password, or row data is included.

## Verified state at capture

An isolated CLI candidate built from these 46 migration files matched the production ledger after the three approved migrations: 46 local versions, 46 remote versions, zero pending. This was a dry-run/list verification only for this bundle; no deployment action is authorized by this file.