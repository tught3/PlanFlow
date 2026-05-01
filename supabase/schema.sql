-- PlanFlow checklist 1
-- Supabase schema for the core tables and per-user RLS policies.

create extension if not exists pgcrypto;

-- 1. users
create table if not exists public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  name text,
  created_at timestamptz not null default now()
);

-- 2. events
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  title text not null,
  start_at timestamptz not null,
  end_at timestamptz,
  location text,
  location_lat double precision,
  location_lng double precision,
  memo text,
  supplies text[] not null default '{}',
  is_critical boolean not null default false,
  source text not null default 'manual',
  external_id text,
  created_at timestamptz not null default now()
);

-- 3. pre_actions
create table if not exists public.pre_actions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  title text not null,
  notify_at timestamptz not null,
  is_done boolean not null default false,
  created_at timestamptz not null default now()
);

-- 4. reminders
create table if not exists public.reminders (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  type text not null,
  notify_at timestamptz not null,
  is_sent boolean not null default false,
  created_at timestamptz not null default now()
);

-- 5. voice_logs
create table if not exists public.voice_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  raw_text text,
  parsed_json jsonb,
  event_id uuid references public.events (id) on delete set null,
  created_at timestamptz not null default now()
);

-- 6. location_history
create table if not exists public.location_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  location text,
  supplies text[] not null default '{}',
  event_id uuid references public.events (id) on delete set null,
  visited_at timestamptz not null default now()
);

-- 7. user_settings
create table if not exists public.user_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users (id) on delete cascade,
  morning_briefing_at time not null default '07:30',
  evening_briefing_at time not null default '21:00',
  default_reminder_min integer not null default 60,
  google_calendar_token text,
  naver_calendar_token text,
  created_at timestamptz not null default now()
);

alter table public.users enable row level security;
alter table public.events enable row level security;
alter table public.pre_actions enable row level security;
alter table public.reminders enable row level security;
alter table public.voice_logs enable row level security;
alter table public.location_history enable row level security;
alter table public.user_settings enable row level security;

drop policy if exists "users_select_own" on public.users;
drop policy if exists "users_insert_own" on public.users;
drop policy if exists "users_update_own" on public.users;
drop policy if exists "users_delete_own" on public.users;
create policy "users_select_own"
  on public.users
  for select
  using (auth.uid() = id);
create policy "users_insert_own"
  on public.users
  for insert
  with check (auth.uid() = id);
create policy "users_update_own"
  on public.users
  for update
  using (auth.uid() = id)
  with check (auth.uid() = id);
create policy "users_delete_own"
  on public.users
  for delete
  using (auth.uid() = id);

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

drop policy if exists "pre_actions_select_own" on public.pre_actions;
drop policy if exists "pre_actions_insert_own" on public.pre_actions;
drop policy if exists "pre_actions_update_own" on public.pre_actions;
drop policy if exists "pre_actions_delete_own" on public.pre_actions;
create policy "pre_actions_select_own"
  on public.pre_actions
  for select
  using (auth.uid() = user_id);
create policy "pre_actions_insert_own"
  on public.pre_actions
  for insert
  with check (auth.uid() = user_id);
create policy "pre_actions_update_own"
  on public.pre_actions
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "pre_actions_delete_own"
  on public.pre_actions
  for delete
  using (auth.uid() = user_id);

drop policy if exists "reminders_select_own" on public.reminders;
drop policy if exists "reminders_insert_own" on public.reminders;
drop policy if exists "reminders_update_own" on public.reminders;
drop policy if exists "reminders_delete_own" on public.reminders;
create policy "reminders_select_own"
  on public.reminders
  for select
  using (auth.uid() = user_id);
create policy "reminders_insert_own"
  on public.reminders
  for insert
  with check (auth.uid() = user_id);
create policy "reminders_update_own"
  on public.reminders
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "reminders_delete_own"
  on public.reminders
  for delete
  using (auth.uid() = user_id);

drop policy if exists "voice_logs_select_own" on public.voice_logs;
drop policy if exists "voice_logs_insert_own" on public.voice_logs;
drop policy if exists "voice_logs_update_own" on public.voice_logs;
drop policy if exists "voice_logs_delete_own" on public.voice_logs;
create policy "voice_logs_select_own"
  on public.voice_logs
  for select
  using (auth.uid() = user_id);
create policy "voice_logs_insert_own"
  on public.voice_logs
  for insert
  with check (auth.uid() = user_id);
create policy "voice_logs_update_own"
  on public.voice_logs
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "voice_logs_delete_own"
  on public.voice_logs
  for delete
  using (auth.uid() = user_id);

drop policy if exists "location_history_select_own" on public.location_history;
drop policy if exists "location_history_insert_own" on public.location_history;
drop policy if exists "location_history_update_own" on public.location_history;
drop policy if exists "location_history_delete_own" on public.location_history;
create policy "location_history_select_own"
  on public.location_history
  for select
  using (auth.uid() = user_id);
create policy "location_history_insert_own"
  on public.location_history
  for insert
  with check (auth.uid() = user_id);
create policy "location_history_update_own"
  on public.location_history
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "location_history_delete_own"
  on public.location_history
  for delete
  using (auth.uid() = user_id);

drop policy if exists "user_settings_select_own" on public.user_settings;
drop policy if exists "user_settings_insert_own" on public.user_settings;
drop policy if exists "user_settings_update_own" on public.user_settings;
drop policy if exists "user_settings_delete_own" on public.user_settings;
create policy "user_settings_select_own"
  on public.user_settings
  for select
  using (auth.uid() = user_id);
create policy "user_settings_insert_own"
  on public.user_settings
  for insert
  with check (auth.uid() = user_id);
create policy "user_settings_update_own"
  on public.user_settings
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "user_settings_delete_own"
  on public.user_settings
  for delete
  using (auth.uid() = user_id);
