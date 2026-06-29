-- Add use_strong_alarm column to events table.
-- Separates visual "important" flag (is_critical) from strong alarm behavior.
alter table public.events
  add column if not exists use_strong_alarm boolean not null default false;
