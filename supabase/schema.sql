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

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, name)
  values (
    new.id,
    new.email,
    coalesce(
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'nickname'
    )
  )
  on conflict (id) do update
    set email = excluded.email,
        name = coalesce(excluded.name, public.users.name);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

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
  supplies_checked text[] not null default '{}',
  participants text[] not null default '{}',
  targets text[] not null default '{}',
  is_critical boolean not null default false,
  recurrence_rule text,
  recurrence_end_date date,
  recurrence_count integer,
  is_all_day boolean not null default false,
  is_multi_day boolean not null default false,
  parent_event_id uuid references public.events (id) on delete set null,
  category text not null default '기타',
  source text not null default 'manual',
  external_id text,
  external_calendar_id text,
  external_etag text,
  external_updated_at timestamptz,
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.events
  add column if not exists location_lat double precision,
  add column if not exists location_lng double precision,
  add column if not exists supplies_checked text[] not null default '{}',
  add column if not exists participants text[] not null default '{}',
  add column if not exists targets text[] not null default '{}',
  add column if not exists recurrence_rule text,
  add column if not exists recurrence_end_date date,
  add column if not exists recurrence_count integer,
  add column if not exists is_all_day boolean not null default false,
  add column if not exists is_multi_day boolean not null default false,
  add column if not exists parent_event_id uuid references public.events (id) on delete set null,
  add column if not exists category text not null default '기타',
  add column if not exists external_calendar_id text,
  add column if not exists external_etag text,
  add column if not exists external_updated_at timestamptz,
  add column if not exists last_synced_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

update public.events
set category = '건강'
where category = '가족';

alter table public.events drop constraint if exists events_category_check;
alter table public.events add constraint events_category_check
  check (category in ('업무', '개인', '건강', '교육', '기타'));

create index if not exists events_user_source_external_idx
  on public.events (user_id, source, external_id)
  where external_id is not null;

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

-- 3. pre_actions
create table if not exists public.pre_actions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  title text not null,
  notify_at timestamptz not null,
  is_done boolean not null default false,
  source text,
  created_at timestamptz not null default now()
);

alter table public.pre_actions
  add column if not exists source text;

update public.pre_actions
set source = 'external_preparation'
where source is null
  and (
    title in (
      '10분 뒤부터 준비 시작하세요 🔔',
      '30분 뒤부터 준비 시작하세요 🔔',
      '지금 준비 시작하세요 🚿',
      '10분 뒤 출발해야 해요 🔔',
      '30분 뒤 출발해야 해요 🔔',
      '지금 준비 시작하세요 🚿 / 10분 뒤 출발해야 해요 🔔',
      '지금 준비 시작하세요 🚿 / 30분 뒤 출발해야 해요 🔔'
    )
    or title like '지금 출발하세요 🚗 (%'
  );

create or replace function public.infer_pre_action_source()
returns trigger
language plpgsql
as $$
begin
  if new.source is null
    and (
      new.title in (
        '10분 뒤부터 준비 시작하세요 🔔',
        '30분 뒤부터 준비 시작하세요 🔔',
        '지금 준비 시작하세요 🚿',
        '10분 뒤 출발해야 해요 🔔',
        '30분 뒤 출발해야 해요 🔔',
        '지금 준비 시작하세요 🚿 / 10분 뒤 출발해야 해요 🔔',
        '지금 준비 시작하세요 🚿 / 30분 뒤 출발해야 해요 🔔'
      )
      or new.title like '지금 출발하세요 🚗 (%'
    ) then
    new.source := 'external_preparation';
  end if;
  return new;
end;
$$;

drop trigger if exists pre_actions_infer_source on public.pre_actions;
create trigger pre_actions_infer_source
  before insert or update of title, source
  on public.pre_actions
  for each row
  execute function public.infer_pre_action_source();

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
  prep_time_min integer not null default 30,
  prep_pre_alarm_offset integer not null default 30,
  depart_pre_alarm_offset integer not null default 30,
  travel_mode text not null default 'car',
  voice_auto_start boolean not null default false,
  preferred_map_provider text not null default 'naver'
    check (preferred_map_provider in ('naver', 'google', 'tmap')),
  country_code text not null default 'KR',
  locale_code text not null default 'ko-KR',
  time_zone_id text not null default 'Asia/Seoul',
  google_calendar_token text,
  naver_calendar_token text,
  created_at timestamptz not null default now()
);

  alter table public.user_settings
  add column if not exists travel_mode text not null default 'car';

  alter table public.user_settings
  add column if not exists voice_auto_start boolean not null default false;

  alter table public.user_settings
  add column if not exists preferred_map_provider text not null default 'naver';

  alter table public.user_settings
  add column if not exists country_code text not null default 'KR';

  alter table public.user_settings
  add column if not exists locale_code text not null default 'ko-KR';

  alter table public.user_settings
  add column if not exists time_zone_id text not null default 'Asia/Seoul';

  alter table public.user_settings
  add column if not exists prep_time_min integer not null default 30;

  alter table public.user_settings
  add column if not exists prep_pre_alarm_offset integer not null default 30;

  alter table public.user_settings
  add column if not exists depart_pre_alarm_offset integer not null default 30;

  alter table public.user_settings
  add column if not exists naver_calendar_token text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'user_settings_preferred_map_provider_check'
      and conrelid = 'public.user_settings'::regclass
  ) then
    alter table public.user_settings
      add constraint user_settings_preferred_map_provider_check
      check (preferred_map_provider in ('naver', 'google', 'tmap'));
  end if;
end;
$$;

-- 8. calendar_connections
create table if not exists public.calendar_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  provider text not null check (provider in ('google', 'naver')),
  provider_account_email text,
  status text not null default 'disconnected'
    check (status in ('disconnected', 'connected', 'reauth_required', 'failed')),
  access_token text,
  refresh_token text,
  naver_caldav_credentials_encrypted bytea,
  naver_caldav_credentials_updated_at timestamptz,
  last_synced_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider)
);

alter table public.calendar_connections
  add column if not exists naver_caldav_credentials_encrypted bytea,
  add column if not exists naver_caldav_credentials_updated_at timestamptz;

create index if not exists calendar_connections_user_provider_idx
  on public.calendar_connections (user_id, provider);

drop trigger if exists calendar_connections_set_updated_at
  on public.calendar_connections;
create trigger calendar_connections_set_updated_at
  before update on public.calendar_connections
  for each row execute function public.set_updated_at();

-- 9. early_bird_emails
create table if not exists public.early_bird_emails (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  created_at timestamptz not null default now()
);

-- 10. user_backups
create table if not exists public.user_backups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  label text,
  payload jsonb not null default '{}'::jsonb,
  item_counts jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists user_backups_user_created_idx
  on public.user_backups (user_id, created_at desc);

-- 11. feedback_reports
create table if not exists public.feedback_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  type text not null check (
    type in (
      'bug',
      'voice',
      'calendar_sync',
      'notification',
      'map_location',
      'feature_request',
      'other'
    )
  ),
  message text not null check (char_length(trim(message)) >= 5),
  expected_behavior text,
  app_version text,
  platform text,
  device_summary text,
  route_or_screen text,
  diagnostics jsonb not null default '{}'::jsonb,
  status text not null default 'new' check (
    status in ('new', 'triaged', 'fixed', 'closed')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists feedback_reports_user_created_idx
  on public.feedback_reports (user_id, created_at desc);

create index if not exists feedback_reports_status_created_idx
  on public.feedback_reports (status, created_at desc);

drop trigger if exists feedback_reports_set_updated_at
  on public.feedback_reports;
create trigger feedback_reports_set_updated_at
  before update on public.feedback_reports
  for each row execute function public.set_updated_at();

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'early_bird_emails_email_format'
      and conrelid = 'public.early_bird_emails'::regclass
  ) then
    alter table public.early_bird_emails
      add constraint early_bird_emails_email_format
      check (
        char_length(email) <= 254
        and email = lower(trim(email))
        and email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      );
  end if;
end;
$$;

alter table public.users enable row level security;
alter table public.events enable row level security;
alter table public.pre_actions enable row level security;
alter table public.reminders enable row level security;
alter table public.voice_logs enable row level security;
alter table public.location_history enable row level security;
alter table public.user_settings enable row level security;
alter table public.calendar_connections enable row level security;
alter table public.early_bird_emails enable row level security;
alter table public.user_backups enable row level security;
alter table public.feedback_reports enable row level security;

grant usage on schema public to authenticated;
grant select, insert on table public.feedback_reports to authenticated;
grant update (status) on table public.feedback_reports to authenticated;

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
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from public.events
      where events.id = pre_actions.event_id
        and events.user_id = auth.uid()
    )
  );
create policy "pre_actions_update_own"
  on public.pre_actions
  for update
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from public.events
      where events.id = pre_actions.event_id
        and events.user_id = auth.uid()
    )
  );
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
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from public.events
      where events.id = reminders.event_id
        and events.user_id = auth.uid()
    )
  );
create policy "reminders_update_own"
  on public.reminders
  for update
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from public.events
      where events.id = reminders.event_id
        and events.user_id = auth.uid()
    )
  );
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
  with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from public.events
        where events.id = voice_logs.event_id
          and events.user_id = auth.uid()
      )
    )
  );
create policy "voice_logs_update_own"
  on public.voice_logs
  for update
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from public.events
        where events.id = voice_logs.event_id
          and events.user_id = auth.uid()
      )
    )
  );
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
  with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from public.events
        where events.id = location_history.event_id
          and events.user_id = auth.uid()
      )
    )
  );
create policy "location_history_update_own"
  on public.location_history
  for update
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from public.events
        where events.id = location_history.event_id
          and events.user_id = auth.uid()
      )
    )
  );
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

drop policy if exists "calendar_connections_select_own" on public.calendar_connections;
drop policy if exists "calendar_connections_insert_own" on public.calendar_connections;
drop policy if exists "calendar_connections_update_own" on public.calendar_connections;
drop policy if exists "calendar_connections_delete_own" on public.calendar_connections;
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

drop policy if exists "feedback_reports_select_own" on public.feedback_reports;
drop policy if exists "feedback_reports_insert_own" on public.feedback_reports;
drop policy if exists "feedback_reports_update_own" on public.feedback_reports;
drop policy if exists "feedback_reports_delete_own" on public.feedback_reports;
drop policy if exists "feedback_reports_select_admin" on public.feedback_reports;
drop policy if exists "feedback_reports_update_status_admin" on public.feedback_reports;
create policy "feedback_reports_select_own"
  on public.feedback_reports
  for select
  using (auth.uid() = user_id);
create policy "feedback_reports_select_admin"
  on public.feedback_reports
  for select
  using (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  );
create policy "feedback_reports_insert_own"
  on public.feedback_reports
  for insert
  with check (auth.uid() = user_id);
create policy "feedback_reports_update_status_admin"
  on public.feedback_reports
  for update
  using (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  )
  with check (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  );

-- Naver CalDAV credentials are stored only as encrypted payloads in calendar_connections.
-- If you set the optional custom GUC `planflow.naver_caldav_secret`, these RPCs will
-- use it as the encryption secret; otherwise they fall back to a per-user derived key.
create or replace function public.upsert_naver_caldav_credentials(
  naver_caldav_id text,
  naver_caldav_app_password text,
  provider_account_email_input text default null
)
returns table (
  connection_id uuid,
  provider text,
  provider_account_email text,
  has_credentials boolean,
  credentials_updated_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  uid uuid := auth.uid();
  credential_secret text;
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  if nullif(trim(naver_caldav_id), '') is null then
    raise exception 'Naver CalDAV ID is required.' using errcode = '22023';
  end if;

  if nullif(naver_caldav_app_password, '') is null then
    raise exception 'Naver CalDAV app password is required.' using errcode = '22023';
  end if;

  credential_secret := coalesce(
    nullif(current_setting('planflow.naver_caldav_secret', true), ''),
    encode(digest(uid::text || ':planflow:naver-caldav:v1', 'sha256'), 'hex')
  );

  return query
    insert into public.calendar_connections (
      user_id,
      provider,
      provider_account_email,
      status,
      naver_caldav_credentials_encrypted,
      naver_caldav_credentials_updated_at,
      last_error
    )
    values (
      uid,
      'naver',
      nullif(trim(provider_account_email_input), ''),
      'connected',
      pgp_sym_encrypt(
        jsonb_build_object(
          'version', 1,
          'naver_caldav_id', trim(naver_caldav_id),
          'naver_caldav_app_password', naver_caldav_app_password,
          'saved_at', now()
        )::text,
        credential_secret,
        'cipher-algo=aes256, compress-algo=0'
      ),
      now(),
      null
    )
    on conflict (user_id, provider) do update
      set provider_account_email = coalesce(
            excluded.provider_account_email,
            public.calendar_connections.provider_account_email
          ),
          status = 'connected',
          naver_caldav_credentials_encrypted = excluded.naver_caldav_credentials_encrypted,
          naver_caldav_credentials_updated_at = excluded.naver_caldav_credentials_updated_at,
          last_error = null
    returning
      id,
      provider,
      provider_account_email,
      naver_caldav_credentials_encrypted is not null,
      naver_caldav_credentials_updated_at,
      updated_at;
end;
$$;

create or replace function public.fetch_naver_caldav_credentials()
returns table (
  connection_id uuid,
  provider_account_email text,
  naver_caldav_id text,
  naver_caldav_app_password text,
  credentials_updated_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  uid uuid := auth.uid();
  credential_secret text;
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  credential_secret := coalesce(
    nullif(current_setting('planflow.naver_caldav_secret', true), ''),
    encode(digest(uid::text || ':planflow:naver-caldav:v1', 'sha256'), 'hex')
  );

  return query
    select
      c.id,
      c.provider_account_email,
      decrypted.payload ->> 'naver_caldav_id',
      decrypted.payload ->> 'naver_caldav_app_password',
      c.naver_caldav_credentials_updated_at,
      c.updated_at
    from public.calendar_connections c
    cross join lateral (
      select pgp_sym_decrypt(c.naver_caldav_credentials_encrypted, credential_secret)::jsonb as payload
    ) decrypted
    where c.user_id = uid
      and c.provider = 'naver'
      and c.naver_caldav_credentials_encrypted is not null;
end;
$$;

create or replace function public.clear_naver_caldav_credentials()
returns void
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  update public.calendar_connections
  set naver_caldav_credentials_encrypted = null,
      naver_caldav_credentials_updated_at = null,
      last_error = null,
      status = case
        when access_token is null and refresh_token is null then 'disconnected'
        else status
      end
  where user_id = uid
    and provider = 'naver';
end;
$$;

drop policy if exists "user_backups_select_own" on public.user_backups;
drop policy if exists "user_backups_insert_own" on public.user_backups;
drop policy if exists "user_backups_update_own" on public.user_backups;
drop policy if exists "user_backups_delete_own" on public.user_backups;
create policy "user_backups_select_own"
  on public.user_backups
  for select
  using (auth.uid() = user_id);
create policy "user_backups_insert_own"
  on public.user_backups
  for insert
  with check (auth.uid() = user_id);
create policy "user_backups_update_own"
  on public.user_backups
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "user_backups_delete_own"
  on public.user_backups
  for delete
  using (auth.uid() = user_id);

create or replace function public.restore_user_backup(backup_id_input uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  snapshot jsonb;
  item jsonb;
  event_id_value uuid;
  supplies_value text[];
  supplies_checked_value text[];
  participants_value text[];
  targets_value text[];
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  select payload
    into snapshot
  from public.user_backups
  where id = backup_id_input
    and user_id = uid;

  if snapshot is null then
    raise exception 'Backup not found for the current user.' using errcode = '02000';
  end if;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'events', '[]'::jsonb))
  loop
    if nullif(item ->> 'title', '') is null
      or nullif(item ->> 'start_at', '') is null then
      continue;
    end if;

    supplies_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'supplies', '[]'::jsonb))
    );
    supplies_checked_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'supplies_checked', '[]'::jsonb))
    );
    participants_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'participants', '[]'::jsonb))
    );
    targets_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'targets', '[]'::jsonb))
    );

    insert into public.events (
      id, user_id, title, start_at, end_at, location, location_lat,
      location_lng, memo, supplies, supplies_checked, participants, targets,
      is_critical, source,
      recurrence_rule, is_all_day, is_multi_day, parent_event_id, category,
      external_id, external_calendar_id, external_etag, external_updated_at, last_synced_at,
      created_at, updated_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      item ->> 'title',
      nullif(item ->> 'start_at', '')::timestamptz,
      nullif(item ->> 'end_at', '')::timestamptz,
      nullif(item ->> 'location', ''),
      nullif(item ->> 'location_lat', '')::double precision,
      nullif(item ->> 'location_lng', '')::double precision,
      nullif(item ->> 'memo', ''),
      coalesce(supplies_value, '{}'::text[]),
      coalesce(supplies_checked_value, '{}'::text[]),
      coalesce(participants_value, '{}'::text[]),
      coalesce(targets_value, '{}'::text[]),
      coalesce(nullif(item ->> 'is_critical', '')::boolean, false),
      coalesce(nullif(item ->> 'source', ''), 'manual'),
      nullif(item ->> 'recurrence_rule', ''),
      coalesce(nullif(item ->> 'is_all_day', '')::boolean, false),
      coalesce(nullif(item ->> 'is_multi_day', '')::boolean, false),
      nullif(item ->> 'parent_event_id', '')::uuid,
      case nullif(item ->> 'category', '')
        when '가족' then '건강'
        when '업무' then '업무'
        when '개인' then '개인'
        when '건강' then '건강'
        when '교육' then '교육'
        when '기타' then '기타'
        else '기타'
      end,
      nullif(item ->> 'external_id', ''),
      nullif(item ->> 'external_calendar_id', ''),
      nullif(item ->> 'external_etag', ''),
      nullif(item ->> 'external_updated_at', '')::timestamptz,
      nullif(item ->> 'last_synced_at', '')::timestamptz,
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now()),
      coalesce(nullif(item ->> 'updated_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set title = excluded.title,
          start_at = excluded.start_at,
          end_at = excluded.end_at,
          location = excluded.location,
          location_lat = excluded.location_lat,
          location_lng = excluded.location_lng,
          memo = excluded.memo,
          supplies = excluded.supplies,
          supplies_checked = excluded.supplies_checked,
          participants = excluded.participants,
          targets = excluded.targets,
          is_critical = excluded.is_critical,
          source = excluded.source,
          recurrence_rule = excluded.recurrence_rule,
          is_all_day = excluded.is_all_day,
          is_multi_day = excluded.is_multi_day,
          parent_event_id = excluded.parent_event_id,
          category = excluded.category,
          external_id = excluded.external_id,
          external_calendar_id = excluded.external_calendar_id,
          external_etag = excluded.external_etag,
          external_updated_at = excluded.external_updated_at,
          last_synced_at = excluded.last_synced_at,
          updated_at = excluded.updated_at
      where public.events.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'user_settings', '[]'::jsonb))
  loop
    insert into public.user_settings (
      id, user_id, morning_briefing_at, evening_briefing_at,
      default_reminder_min, prep_time_min, prep_pre_alarm_offset,
      depart_pre_alarm_offset, travel_mode, voice_auto_start,
      preferred_map_provider,
      country_code, locale_code, time_zone_id, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      coalesce(nullif(item ->> 'morning_briefing_at', '')::time, '07:30'::time),
      coalesce(nullif(item ->> 'evening_briefing_at', '')::time, '21:00'::time),
      coalesce(nullif(item ->> 'default_reminder_min', '')::integer, 60),
      coalesce(nullif(item ->> 'prep_time_min', '')::integer, 30),
      coalesce(nullif(item ->> 'prep_pre_alarm_offset', '')::integer, 30),
      coalesce(nullif(item ->> 'depart_pre_alarm_offset', '')::integer, 30),
      case
        when lower(coalesce(item ->> 'travel_mode', '')) = 'transit'
          then 'transit'
        else 'car'
      end,
      coalesce(nullif(item ->> 'voice_auto_start', '')::boolean, false),
      case
        when lower(coalesce(item ->> 'preferred_map_provider', '')) in ('google', 'tmap', 'naver')
          then lower(item ->> 'preferred_map_provider')
        else 'naver'
      end,
      coalesce(nullif(item ->> 'country_code', ''), 'KR'),
      coalesce(nullif(item ->> 'locale_code', ''), 'ko-KR'),
      coalesce(nullif(item ->> 'time_zone_id', ''), 'Asia/Seoul'),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (user_id) do update
      set morning_briefing_at = excluded.morning_briefing_at,
          evening_briefing_at = excluded.evening_briefing_at,
          default_reminder_min = excluded.default_reminder_min,
          prep_time_min = excluded.prep_time_min,
          prep_pre_alarm_offset = excluded.prep_pre_alarm_offset,
          depart_pre_alarm_offset = excluded.depart_pre_alarm_offset,
          travel_mode = excluded.travel_mode,
          voice_auto_start = excluded.voice_auto_start,
          preferred_map_provider = excluded.preferred_map_provider,
          country_code = excluded.country_code,
          locale_code = excluded.locale_code,
          time_zone_id = excluded.time_zone_id;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'pre_actions', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if nullif(item ->> 'event_id', '') is null
      or nullif(item ->> 'title', '') is null
      or nullif(item ->> 'notify_at', '') is null then
      continue;
    end if;
    if not exists (
      select 1 from public.events
      where id = event_id_value
        and user_id = uid
    ) then
      continue;
    end if;

    insert into public.pre_actions (
      id, event_id, user_id, title, notify_at, is_done, source, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      event_id_value,
      uid,
      item ->> 'title',
      nullif(item ->> 'notify_at', '')::timestamptz,
      coalesce(nullif(item ->> 'is_done', '')::boolean, false),
      coalesce(
        nullif(item ->> 'source', ''),
        case
          when item ->> 'title' in (
            '10분 뒤부터 준비 시작하세요 🔔',
            '30분 뒤부터 준비 시작하세요 🔔',
            '지금 준비 시작하세요 🚿',
            '10분 뒤 출발해야 해요 🔔',
            '30분 뒤 출발해야 해요 🔔',
            '지금 준비 시작하세요 🚿 / 10분 뒤 출발해야 해요 🔔',
            '지금 준비 시작하세요 🚿 / 30분 뒤 출발해야 해요 🔔'
          )
            or item ->> 'title' like '지금 출발하세요 🚗 (%'
          then 'external_preparation'
          else null
        end
      ),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set title = excluded.title,
          notify_at = excluded.notify_at,
          is_done = excluded.is_done,
          source = excluded.source
      where public.pre_actions.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'reminders', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if nullif(item ->> 'event_id', '') is null
      or nullif(item ->> 'type', '') is null
      or nullif(item ->> 'notify_at', '') is null then
      continue;
    end if;
    if not exists (
      select 1 from public.events
      where id = event_id_value
        and user_id = uid
    ) then
      continue;
    end if;

    insert into public.reminders (
      id, event_id, user_id, type, notify_at, is_sent, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      event_id_value,
      uid,
      item ->> 'type',
      nullif(item ->> 'notify_at', '')::timestamptz,
      coalesce(nullif(item ->> 'is_sent', '')::boolean, false),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set type = excluded.type,
          notify_at = excluded.notify_at,
          is_sent = excluded.is_sent
      where public.reminders.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'location_history', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if event_id_value is not null and not exists (
      select 1 from public.events
      where id = event_id_value
        and user_id = uid
    ) then
      event_id_value := null;
    end if;
    supplies_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'supplies', '[]'::jsonb))
    );

    insert into public.location_history (
      id, user_id, location, supplies, event_id, visited_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      nullif(item ->> 'location', ''),
      coalesce(supplies_value, '{}'::text[]),
      event_id_value,
      coalesce(nullif(item ->> 'visited_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set location = excluded.location,
          supplies = excluded.supplies,
          event_id = excluded.event_id,
          visited_at = excluded.visited_at
      where public.location_history.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'voice_logs', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if event_id_value is not null and not exists (
      select 1 from public.events
      where id = event_id_value
        and user_id = uid
    ) then
      event_id_value := null;
    end if;

    insert into public.voice_logs (
      id, user_id, raw_text, parsed_json, event_id, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      nullif(item ->> 'raw_text', ''),
      item -> 'parsed_json',
      event_id_value,
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set raw_text = excluded.raw_text,
          parsed_json = excluded.parsed_json,
          event_id = excluded.event_id
      where public.voice_logs.user_id = uid;
  end loop;
end;
$$;

revoke all on function public.restore_user_backup(uuid) from public;
grant execute on function public.restore_user_backup(uuid) to authenticated;

create or replace function public.submit_early_bird_email(input_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_email text := lower(trim(input_email));
begin
  if normalized_email is null
    or char_length(normalized_email) > 254
    or normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception 'A valid email is required.'
      using errcode = '22023';
  end if;

  insert into public.early_bird_emails (email)
  values (normalized_email)
  on conflict (email) do nothing;
end;
$$;

revoke all on function public.submit_early_bird_email(text) from public;
grant execute on function public.submit_early_bird_email(text) to anon, authenticated;

revoke all on function public.upsert_naver_caldav_credentials(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.upsert_naver_caldav_credentials(text, text, text)
  to authenticated;

revoke all on function public.fetch_naver_caldav_credentials()
  from public, anon, authenticated, service_role;
grant execute on function public.fetch_naver_caldav_credentials()
  to authenticated;

revoke all on function public.clear_naver_caldav_credentials()
  from public, anon, authenticated, service_role;
grant execute on function public.clear_naver_caldav_credentials()
  to authenticated;


-- PlanFlow in-project database snapshots.
-- Purpose: app-data recovery inside the same Supabase project.
-- This is not a replacement for an offsite disaster-recovery backup.

create extension if not exists pgcrypto;
create extension if not exists pg_cron with schema extensions;

create schema if not exists backup;

revoke all on schema backup from public;
revoke all on schema backup from anon;
revoke all on schema backup from authenticated;

create table if not exists backup.daily_snapshots (
  id uuid primary key default gen_random_uuid(),
  label text not null default 'automatic',
  snapshot_date date not null default ((timezone('Asia/Seoul', now()))::date),
  source_project_ref text not null default 'xqvvfnvmytjlblcngipn',
  schema_version integer not null default 1,
  table_counts jsonb not null default '{}'::jsonb,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists daily_snapshots_created_idx
  on backup.daily_snapshots (created_at desc);

create unique index if not exists daily_snapshots_label_date_idx
  on backup.daily_snapshots (label, snapshot_date);

alter table backup.daily_snapshots enable row level security;

revoke all on table backup.daily_snapshots from public;
revoke all on table backup.daily_snapshots from anon;
revoke all on table backup.daily_snapshots from authenticated;

create or replace function backup.app_table_names()
returns text[]
language sql
stable
security definer
set search_path = public, backup, pg_temp
as $$
  select array[
    'public.users',
    'public.events',
    'public.pre_actions',
    'public.reminders',
    'public.voice_logs',
    'public.location_history',
    'public.user_settings',
    'public.calendar_connections',
    'public.early_bird_emails',
    'public.user_backups',
    'public.feedback_reports',
    'public.user_behavior_logs'
  ];
$$;

revoke all on function backup.app_table_names() from public;
revoke all on function backup.app_table_names() from anon;
revoke all on function backup.app_table_names() from authenticated;

create or replace function backup.create_daily_snapshot(
  p_label text default 'automatic',
  p_snapshot_date date default ((timezone('Asia/Seoul', now()))::date)
)
returns uuid
language plpgsql
security definer
set search_path = public, backup, pg_temp
as $$
declare
  table_name text;
  table_reg regclass;
  table_rows jsonb;
  table_count bigint;
  snapshot_payload jsonb := '{}'::jsonb;
  snapshot_counts jsonb := '{}'::jsonb;
  snapshot_id uuid;
begin
  if p_label is null or btrim(p_label) = '' then
    raise exception 'Snapshot label is required.';
  end if;

  foreach table_name in array backup.app_table_names()
  loop
    table_reg := to_regclass(table_name);
    if table_reg is null then
      continue;
    end if;

    execute format(
      'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb), count(*) from %s as t',
      table_reg
    )
    into table_rows, table_count;

    snapshot_payload := jsonb_set(
      snapshot_payload,
      array[table_name],
      table_rows,
      true
    );
    snapshot_counts := jsonb_set(
      snapshot_counts,
      array[table_name],
      to_jsonb(table_count),
      true
    );
  end loop;

  if p_label = 'automatic' then
    delete from backup.daily_snapshots
    where label = p_label
      and snapshot_date = p_snapshot_date;
  end if;

  insert into backup.daily_snapshots (
    label,
    snapshot_date,
    table_counts,
    payload
  )
  values (
    p_label,
    p_snapshot_date,
    snapshot_counts,
    snapshot_payload
  )
  returning id into snapshot_id;

  return snapshot_id;
end;
$$;

revoke all on function backup.create_daily_snapshot(text, date) from public;
revoke all on function backup.create_daily_snapshot(text, date) from anon;
revoke all on function backup.create_daily_snapshot(text, date) from authenticated;

create or replace function backup.prune_daily_snapshots(
  p_recent_days integer default 35,
  p_monthly_months integer default 12
)
returns integer
language plpgsql
security definer
set search_path = backup, pg_temp
as $$
declare
  deleted_count integer := 0;
begin
  with ranked as (
    select
      id,
      created_at,
      row_number() over (
        partition by date_trunc('month', created_at)
        order by created_at desc
      ) as monthly_rank
    from backup.daily_snapshots
    where label = 'automatic'
  ),
  deleted as (
    delete from backup.daily_snapshots snapshots
    using ranked
    where snapshots.id = ranked.id
      and (
        ranked.created_at < now() - make_interval(months => p_monthly_months)
        or (
          ranked.created_at < now() - make_interval(days => p_recent_days)
          and ranked.monthly_rank > 1
        )
      )
    returning snapshots.id
  )
  select count(*) into deleted_count from deleted;

  return deleted_count;
end;
$$;

revoke all on function backup.prune_daily_snapshots(integer, integer) from public;
revoke all on function backup.prune_daily_snapshots(integer, integer) from anon;
revoke all on function backup.prune_daily_snapshots(integer, integer) from authenticated;

create or replace function backup.restore_snapshot(
  p_snapshot_id uuid,
  p_tables text[] default null
)
returns void
language plpgsql
security definer
set search_path = public, backup, pg_temp
as $$
declare
  snapshot_payload jsonb;
  table_name text;
  table_reg regclass;
  table_rows jsonb;
  delete_order text[] := array[
    'public.reminders',
    'public.pre_actions',
    'public.voice_logs',
    'public.location_history',
    'public.feedback_reports',
    'public.calendar_connections',
    'public.user_backups',
    'public.user_settings',
    'public.events',
    'public.early_bird_emails',
    'public.user_behavior_logs',
    'public.users'
  ];
  insert_order text[] := array[
    'public.users',
    'public.user_behavior_logs',
    'public.early_bird_emails',
    'public.events',
    'public.user_settings',
    'public.calendar_connections',
    'public.user_backups',
    'public.feedback_reports',
    'public.location_history',
    'public.voice_logs',
    'public.pre_actions',
    'public.reminders'
  ];
begin
  select payload
  into snapshot_payload
  from backup.daily_snapshots
  where id = p_snapshot_id;

  if snapshot_payload is null then
    raise exception 'Backup snapshot not found: %', p_snapshot_id;
  end if;

  foreach table_name in array delete_order
  loop
    if p_tables is not null and not (table_name = any(p_tables)) then
      continue;
    end if;

    table_reg := to_regclass(table_name);
    if table_reg is null then
      continue;
    end if;

    execute format('delete from %s', table_reg);
  end loop;

  foreach table_name in array insert_order
  loop
    if p_tables is not null and not (table_name = any(p_tables)) then
      continue;
    end if;

    table_reg := to_regclass(table_name);
    table_rows := snapshot_payload -> table_name;
    if table_reg is null
      or table_rows is null
      or jsonb_typeof(table_rows) <> 'array'
      or jsonb_array_length(table_rows) = 0 then
      continue;
    end if;

    execute format(
      'insert into %s select * from jsonb_populate_recordset(null::%s, $1)',
      table_reg,
      table_reg
    )
    using table_rows;
  end loop;
end;
$$;

revoke all on function backup.restore_snapshot(uuid, text[]) from public;
revoke all on function backup.restore_snapshot(uuid, text[]) from anon;
revoke all on function backup.restore_snapshot(uuid, text[]) from authenticated;

do $$
declare
  existing_job_id bigint;
begin
  select jobid
  into existing_job_id
  from cron.job
  where jobname = 'planflow-daily-in-project-backup'
  limit 1;

  if existing_job_id is not null then
    perform cron.unschedule(existing_job_id);
  end if;

  perform cron.schedule(
    'planflow-daily-in-project-backup',
    '30 18 * * *',
    'select backup.create_daily_snapshot(''automatic''); select backup.prune_daily_snapshots();'
  );
end;
$$;
