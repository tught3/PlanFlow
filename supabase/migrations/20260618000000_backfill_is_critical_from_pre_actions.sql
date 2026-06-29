-- Backfill event critical status from existing pre-actions.
-- RLS policy shape is unchanged; this only updates existing event rows.

update public.events
set is_critical = true
where id in (
  select distinct event_id
  from public.pre_actions
  where event_id is not null
)
and (is_critical is null or is_critical = false);
