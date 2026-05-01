# Checklist 1: Supabase schema

This document tracks checklist item 1 for PlanFlow.

- File to paste into Supabase SQL Editor: `supabase/schema.sql`
- Includes the core tables from the prompt
- Enables row level security on each table
- Adds per-user policies so each user can only access their own rows

Recommended usage:

1. Open Supabase SQL Editor.
2. Paste the contents of `supabase/schema.sql`.
3. Run the script.
4. Verify the tables and policies were created successfully.
