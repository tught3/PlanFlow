alter table public.events
  add column if not exists parent_event_id uuid references public.events (id) on delete set null;

create index if not exists idx_events_parent_event_id
  on public.events (parent_event_id);

notify pgrst, 'reload schema';
