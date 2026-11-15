-- Keep the deleted dates as the JSON array introduced in 20261005000000.
alter table public.events
  add column if not exists overridden_occurrence_date timestamptz,
  add column if not exists deleted_occurrence_dates jsonb;
