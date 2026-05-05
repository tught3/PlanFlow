-- PlanFlow calendar sync patch
-- Apply this in Supabase SQL Editor if the full schema.sql is too large.

alter table public.events
  add column if not exists external_calendar_id text,
  add column if not exists external_etag text,
  add column if not exists external_updated_at timestamptz,
  add column if not exists last_synced_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

create index if not exists events_user_source_external_idx
  on public.events (user_id, source, external_id)
  where external_id is not null;

alter table public.events enable row level security;

drop policy if exists "events_select_own" on public.events;
drop policy if exists "events_insert_own" on public.events;
drop policy if exists "events_update_own" on public.events;
drop policy if exists "events_delete_own" on public.events;

create policy "events_select_own"
  on public.events
  for select
  using (auth.uid() = user_id);

create policy "events_insert_own"
  on public.events
  for insert
  with check (auth.uid() = user_id);

create policy "events_update_own"
  on public.events
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "events_delete_own"
  on public.events
  for delete
  using (auth.uid() = user_id);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists events_set_updated_at on public.events;
create trigger events_set_updated_at
  before update on public.events
  for each row execute function public.set_updated_at();

create table if not exists public.calendar_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  provider text not null check (provider in ('google', 'naver')),
  provider_account_email text,
  status text not null default 'disconnected'
    check (status in ('disconnected', 'connected', 'reauth_required', 'failed')),
  access_token text,
  refresh_token text,
  last_synced_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider)
);

create index if not exists calendar_connections_user_provider_idx
  on public.calendar_connections (user_id, provider);

drop trigger if exists calendar_connections_set_updated_at
  on public.calendar_connections;
create trigger calendar_connections_set_updated_at
  before update on public.calendar_connections
  for each row execute function public.set_updated_at();

alter table public.calendar_connections enable row level security;

drop policy if exists "calendar_connections_select_own"
  on public.calendar_connections;
drop policy if exists "calendar_connections_insert_own"
  on public.calendar_connections;
drop policy if exists "calendar_connections_update_own"
  on public.calendar_connections;
drop policy if exists "calendar_connections_delete_own"
  on public.calendar_connections;

create policy "calendar_connections_select_own"
  on public.calendar_connections
  for select
  using (auth.uid() = user_id);

create policy "calendar_connections_insert_own"
  on public.calendar_connections
  for insert
  with check (auth.uid() = user_id);

create policy "calendar_connections_update_own"
  on public.calendar_connections
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "calendar_connections_delete_own"
  on public.calendar_connections
  for delete
  using (auth.uid() = user_id);
