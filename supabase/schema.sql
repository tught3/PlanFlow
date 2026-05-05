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
  is_critical boolean not null default false,
  source text not null default 'manual',
  external_id text,
  created_at timestamptz not null default now()
);

alter table public.events
  add column if not exists location_lat double precision,
  add column if not exists location_lng double precision,
  add column if not exists supplies_checked text[] not null default '{}';

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
  travel_mode text not null default 'car',
  google_calendar_token text,
  naver_calendar_token text,
  created_at timestamptz not null default now()
);

  alter table public.user_settings
  add column if not exists travel_mode text not null default 'car';

  alter table public.user_settings
  add column if not exists naver_calendar_token text;

-- 8. early_bird_emails
create table if not exists public.early_bird_emails (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  created_at timestamptz not null default now()
);

-- 9. user_backups
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
alter table public.early_bird_emails enable row level security;
alter table public.user_backups enable row level security;

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

    insert into public.events (
      id, user_id, title, start_at, end_at, location, location_lat,
      location_lng, memo, supplies, supplies_checked, is_critical, source, external_id,
      created_at
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
      coalesce(nullif(item ->> 'is_critical', '')::boolean, false),
      coalesce(nullif(item ->> 'source', ''), 'manual'),
      nullif(item ->> 'external_id', ''),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
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
          is_critical = excluded.is_critical,
          source = excluded.source,
          external_id = excluded.external_id
      where public.events.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'user_settings', '[]'::jsonb))
  loop
    insert into public.user_settings (
      id, user_id, morning_briefing_at, evening_briefing_at,
      default_reminder_min, travel_mode, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      coalesce(nullif(item ->> 'morning_briefing_at', '')::time, '07:30'::time),
      coalesce(nullif(item ->> 'evening_briefing_at', '')::time, '21:00'::time),
      coalesce(nullif(item ->> 'default_reminder_min', '')::integer, 60),
      case
        when lower(coalesce(item ->> 'travel_mode', '')) = 'transit'
          then 'transit'
        else 'car'
      end,
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (user_id) do update
      set morning_briefing_at = excluded.morning_briefing_at,
          evening_briefing_at = excluded.evening_briefing_at,
          default_reminder_min = excluded.default_reminder_min,
          travel_mode = excluded.travel_mode;
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
      id, event_id, user_id, title, notify_at, is_done, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      event_id_value,
      uid,
      item ->> 'title',
      nullif(item ->> 'notify_at', '')::timestamptz,
      coalesce(nullif(item ->> 'is_done', '')::boolean, false),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set title = excluded.title,
          notify_at = excluded.notify_at,
          is_done = excluded.is_done
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
