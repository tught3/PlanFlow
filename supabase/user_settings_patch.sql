-- PlanFlow dynamic departure margin patch.
-- Apply this in Supabase SQL Editor for projects that still need the column.

alter table public.user_settings
  add column if not exists departure_safety_margin_min integer not null default 20;
