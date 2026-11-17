create or replace function public.events_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if to_jsonb(new) - '{external_id,external_calendar_id,external_etag,external_updated_at,last_synced_at,updated_at}'::text[]
     = to_jsonb(old) - '{external_id,external_calendar_id,external_etag,external_updated_at,last_synced_at,updated_at}'::text[] then
    new.updated_at := old.updated_at;
  else
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists events_set_updated_at on public.events;
create trigger events_set_updated_at
  before update on public.events
  for each row execute function public.events_set_updated_at();
