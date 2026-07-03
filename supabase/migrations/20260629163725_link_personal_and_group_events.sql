alter table public.events
  add column if not exists group_event_id uuid references public.group_events (id) on delete set null;

alter table public.group_events
  add column if not exists personal_event_id uuid references public.events (id) on delete set null;

create index if not exists events_group_event_id_idx
  on public.events (group_event_id);

create index if not exists group_events_personal_event_id_idx
  on public.group_events (personal_event_id);
