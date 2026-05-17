-- PlanFlow schema split migration.
-- Apply STEP 2-7 before running the destructive cleanup block at the end.

create extension if not exists pgcrypto;

create schema if not exists shared;
create schema if not exists planflow;
create schema if not exists nexusflow;

grant usage on schema shared to anon, authenticated, service_role;
grant usage on schema planflow to anon, authenticated, service_role;
grant usage on schema nexusflow to anon, authenticated, service_role;

alter role authenticator
  set pgrst.db_schemas = 'public,storage,graphql_public,shared,planflow,nexusflow';
notify pgrst, 'reload config';

grant all on all tables in schema shared to anon, authenticated, service_role;
grant all on all tables in schema planflow to anon, authenticated, service_role;
grant all on all tables in schema nexusflow to anon, authenticated, service_role;
grant all on all routines in schema shared to anon, authenticated, service_role;
grant all on all routines in schema planflow to anon, authenticated, service_role;
grant all on all routines in schema nexusflow to anon, authenticated, service_role;
grant all on all sequences in schema shared to anon, authenticated, service_role;
grant all on all sequences in schema planflow to anon, authenticated, service_role;
grant all on all sequences in schema nexusflow to anon, authenticated, service_role;

alter default privileges for role postgres in schema shared
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema planflow
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema nexusflow
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema shared
  grant all on routines to anon, authenticated, service_role;
alter default privileges for role postgres in schema planflow
  grant all on routines to anon, authenticated, service_role;
alter default privileges for role postgres in schema nexusflow
  grant all on routines to anon, authenticated, service_role;
alter default privileges for role postgres in schema shared
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema planflow
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema nexusflow
  grant all on sequences to anon, authenticated, service_role;

create table if not exists shared.user_profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  name text,
  planflow_enabled boolean not null default true,
  nexusflow_enabled boolean not null default false,
  active_apps text[] not null default '{planflow}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into shared.user_profiles (id, email, name, created_at)
select id, email, name, created_at from public.users
on conflict (id) do update
  set email = excluded.email,
      name = coalesce(excluded.name, shared.user_profiles.name),
      planflow_enabled = true,
      updated_at = now();

create table if not exists shared.voice_inputs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references shared.user_profiles (id) on delete cascade,
  app text not null default 'planflow' check (app in ('planflow', 'nexusflow')),
  raw_text text,
  stt_text text,
  parsed_json jsonb,
  status text not null default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists shared.ai_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references shared.user_profiles (id) on delete cascade,
  app text not null check (app in ('planflow', 'nexusflow')),
  job_type text not null,
  input_data jsonb,
  output_data jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'done', 'failed')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists shared.app_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references shared.user_profiles (id) on delete cascade,
  app text not null check (app in ('planflow', 'nexusflow', 'bundle')),
  plan text not null default 'free',
  status text not null default 'active',
  started_at timestamptz not null default now(),
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists planflow.events (like public.events including all);
create table if not exists planflow.pre_actions (like public.pre_actions including all);
create table if not exists planflow.reminders (like public.reminders including all);
create table if not exists planflow.voice_logs (like public.voice_logs including all);
create table if not exists planflow.location_history (like public.location_history including all);
create table if not exists planflow.user_settings (like public.user_settings including all);
create table if not exists planflow.calendar_connections (like public.calendar_connections including all);
create table if not exists planflow.early_bird_emails (like public.early_bird_emails including all);
create table if not exists planflow.user_backups (like public.user_backups including all);
create table if not exists planflow.feedback_reports (like public.feedback_reports including all);

do $$
begin
  if to_regclass('public.user_behavior_logs') is not null then
    create table if not exists planflow.user_behavior_logs
      (like public.user_behavior_logs including all);
    insert into planflow.user_behavior_logs
      select * from public.user_behavior_logs
      on conflict (id) do nothing;
  end if;
end;
$$;

insert into planflow.events select * from public.events on conflict (id) do nothing;
insert into planflow.pre_actions select * from public.pre_actions on conflict (id) do nothing;
insert into planflow.reminders select * from public.reminders on conflict (id) do nothing;
insert into planflow.voice_logs select * from public.voice_logs on conflict (id) do nothing;
insert into planflow.location_history select * from public.location_history on conflict (id) do nothing;
insert into planflow.user_settings select * from public.user_settings on conflict (id) do nothing;
insert into planflow.calendar_connections select * from public.calendar_connections on conflict (id) do nothing;
insert into planflow.early_bird_emails select * from public.early_bird_emails on conflict (id) do nothing;
insert into planflow.user_backups select * from public.user_backups on conflict (id) do nothing;
insert into planflow.feedback_reports select * from public.feedback_reports on conflict (id) do nothing;

alter table planflow.events
  add column if not exists recurrence_end_date date,
  add column if not exists recurrence_count integer,
  add column if not exists parent_event_id uuid;

alter table planflow.user_settings
  add column if not exists preferred_map_provider text not null default 'naver',
  add column if not exists country_code text not null default 'KR',
  add column if not exists locale_code text not null default 'ko-KR',
  add column if not exists time_zone_id text not null default 'Asia/Seoul';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'planflow_user_settings_preferred_map_provider_check'
      and conrelid = 'planflow.user_settings'::regclass
  ) then
    alter table planflow.user_settings
      add constraint planflow_user_settings_preferred_map_provider_check
      check (preferred_map_provider in ('naver', 'google', 'tmap'));
  end if;
end;
$$;

do $$
declare
  fk record;
begin
  for fk in
    select *
    from (
      values
        ('planflow_events_user_id_fkey', 'planflow.events', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_events_parent_event_id_fkey', 'planflow.events', 'parent_event_id', 'planflow.events', 'id', 'set null'),
        ('planflow_pre_actions_event_id_fkey', 'planflow.pre_actions', 'event_id', 'planflow.events', 'id', 'cascade'),
        ('planflow_pre_actions_user_id_fkey', 'planflow.pre_actions', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_reminders_event_id_fkey', 'planflow.reminders', 'event_id', 'planflow.events', 'id', 'cascade'),
        ('planflow_reminders_user_id_fkey', 'planflow.reminders', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_voice_logs_user_id_fkey', 'planflow.voice_logs', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_voice_logs_event_id_fkey', 'planflow.voice_logs', 'event_id', 'planflow.events', 'id', 'set null'),
        ('planflow_location_history_user_id_fkey', 'planflow.location_history', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_location_history_event_id_fkey', 'planflow.location_history', 'event_id', 'planflow.events', 'id', 'set null'),
        ('planflow_user_settings_user_id_fkey', 'planflow.user_settings', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_calendar_connections_user_id_fkey', 'planflow.calendar_connections', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_user_backups_user_id_fkey', 'planflow.user_backups', 'user_id', 'shared.user_profiles', 'id', 'cascade'),
        ('planflow_feedback_reports_user_id_fkey', 'planflow.feedback_reports', 'user_id', 'shared.user_profiles', 'id', 'cascade')
    ) as v (constraint_name, source_table, source_column, target_table, target_column, delete_action)
  loop
    if not exists (
      select 1
      from pg_constraint
      where conname = fk.constraint_name
        and conrelid = fk.source_table::regclass
    ) then
      execute format(
        'alter table %s add constraint %I foreign key (%I) references %s (%I) on delete %s',
        fk.source_table,
        fk.constraint_name,
        fk.source_column,
        fk.target_table,
        fk.target_column,
        fk.delete_action
      );
    end if;
  end loop;

  if to_regclass('planflow.user_behavior_logs') is not null
    and not exists (
      select 1
      from pg_constraint
      where conname = 'planflow_user_behavior_logs_user_id_fkey'
        and conrelid = 'planflow.user_behavior_logs'::regclass
    )
  then
    alter table planflow.user_behavior_logs
      add constraint planflow_user_behavior_logs_user_id_fkey
      foreign key (user_id) references auth.users (id) on delete cascade;
  end if;
end;
$$;

alter table shared.user_profiles enable row level security;
alter table shared.voice_inputs enable row level security;
alter table shared.ai_jobs enable row level security;
alter table shared.app_subscriptions enable row level security;

alter table planflow.events enable row level security;
alter table planflow.pre_actions enable row level security;
alter table planflow.reminders enable row level security;
alter table planflow.voice_logs enable row level security;
alter table planflow.location_history enable row level security;
alter table planflow.user_settings enable row level security;
alter table planflow.calendar_connections enable row level security;
alter table planflow.early_bird_emails enable row level security;
alter table planflow.user_backups enable row level security;
alter table planflow.feedback_reports enable row level security;

do $$
begin
  if to_regclass('planflow.user_behavior_logs') is not null then
    execute 'alter table planflow.user_behavior_logs enable row level security';
    execute 'drop policy if exists "user_behavior_logs_own" on planflow.user_behavior_logs';
    execute 'create policy "user_behavior_logs_own" on planflow.user_behavior_logs for all using (auth.uid() = user_id) with check (auth.uid() = user_id)';
  end if;
end;
$$;

drop policy if exists "user_profiles_select_own" on shared.user_profiles;
drop policy if exists "user_profiles_insert_own" on shared.user_profiles;
drop policy if exists "user_profiles_update_own" on shared.user_profiles;
create policy "user_profiles_select_own" on shared.user_profiles
  for select using (auth.uid() = id);
create policy "user_profiles_insert_own" on shared.user_profiles
  for insert with check (auth.uid() = id);
create policy "user_profiles_update_own" on shared.user_profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "voice_inputs_own" on shared.voice_inputs;
drop policy if exists "ai_jobs_own" on shared.ai_jobs;
drop policy if exists "app_subscriptions_own" on shared.app_subscriptions;
create policy "voice_inputs_own" on shared.voice_inputs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "ai_jobs_own" on shared.ai_jobs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "app_subscriptions_own" on shared.app_subscriptions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "events_own" on planflow.events;
drop policy if exists "events_select_own" on planflow.events;
drop policy if exists "events_insert_own" on planflow.events;
drop policy if exists "events_update_own" on planflow.events;
drop policy if exists "events_delete_own" on planflow.events;
drop policy if exists "pre_actions_own" on planflow.pre_actions;
drop policy if exists "pre_actions_select_own" on planflow.pre_actions;
drop policy if exists "pre_actions_insert_own" on planflow.pre_actions;
drop policy if exists "pre_actions_update_own" on planflow.pre_actions;
drop policy if exists "pre_actions_delete_own" on planflow.pre_actions;
drop policy if exists "reminders_own" on planflow.reminders;
drop policy if exists "reminders_select_own" on planflow.reminders;
drop policy if exists "reminders_insert_own" on planflow.reminders;
drop policy if exists "reminders_update_own" on planflow.reminders;
drop policy if exists "reminders_delete_own" on planflow.reminders;
drop policy if exists "voice_logs_own" on planflow.voice_logs;
drop policy if exists "voice_logs_select_own" on planflow.voice_logs;
drop policy if exists "voice_logs_insert_own" on planflow.voice_logs;
drop policy if exists "voice_logs_update_own" on planflow.voice_logs;
drop policy if exists "voice_logs_delete_own" on planflow.voice_logs;
drop policy if exists "location_history_own" on planflow.location_history;
drop policy if exists "location_history_select_own" on planflow.location_history;
drop policy if exists "location_history_insert_own" on planflow.location_history;
drop policy if exists "location_history_update_own" on planflow.location_history;
drop policy if exists "location_history_delete_own" on planflow.location_history;
drop policy if exists "user_settings_own" on planflow.user_settings;
drop policy if exists "calendar_connections_own" on planflow.calendar_connections;
drop policy if exists "user_backups_own" on planflow.user_backups;
drop policy if exists "feedback_reports_own" on planflow.feedback_reports;
drop policy if exists "feedback_reports_select_own" on planflow.feedback_reports;
drop policy if exists "feedback_reports_insert_own" on planflow.feedback_reports;
drop policy if exists "feedback_reports_admin_select" on planflow.feedback_reports;
drop policy if exists "feedback_reports_admin_update" on planflow.feedback_reports;
drop policy if exists "feedback_reports_select_admin" on planflow.feedback_reports;
drop policy if exists "feedback_reports_update_status_admin" on planflow.feedback_reports;

create policy "events_select_own" on planflow.events
  for select using (auth.uid() = user_id);
create policy "events_insert_own" on planflow.events
  for insert with check (auth.uid() = user_id);
create policy "events_update_own" on planflow.events
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "events_delete_own" on planflow.events
  for delete using (auth.uid() = user_id);

create policy "pre_actions_select_own" on planflow.pre_actions
  for select using (auth.uid() = user_id);
create policy "pre_actions_insert_own" on planflow.pre_actions
  for insert with check (
    auth.uid() = user_id
    and exists (
      select 1
      from planflow.events
      where events.id = pre_actions.event_id
        and events.user_id = auth.uid()
    )
  );
create policy "pre_actions_update_own" on planflow.pre_actions
  for update using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from planflow.events
      where events.id = pre_actions.event_id
        and events.user_id = auth.uid()
    )
  );
create policy "pre_actions_delete_own" on planflow.pre_actions
  for delete using (auth.uid() = user_id);

create policy "reminders_select_own" on planflow.reminders
  for select using (auth.uid() = user_id);
create policy "reminders_insert_own" on planflow.reminders
  for insert with check (
    auth.uid() = user_id
    and exists (
      select 1
      from planflow.events
      where events.id = reminders.event_id
        and events.user_id = auth.uid()
    )
  );
create policy "reminders_update_own" on planflow.reminders
  for update using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (
      select 1
      from planflow.events
      where events.id = reminders.event_id
        and events.user_id = auth.uid()
    )
  );
create policy "reminders_delete_own" on planflow.reminders
  for delete using (auth.uid() = user_id);

create policy "voice_logs_select_own" on planflow.voice_logs
  for select using (auth.uid() = user_id);
create policy "voice_logs_insert_own" on planflow.voice_logs
  for insert with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from planflow.events
        where events.id = voice_logs.event_id
          and events.user_id = auth.uid()
      )
    )
  );
create policy "voice_logs_update_own" on planflow.voice_logs
  for update using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from planflow.events
        where events.id = voice_logs.event_id
          and events.user_id = auth.uid()
      )
    )
  );
create policy "voice_logs_delete_own" on planflow.voice_logs
  for delete using (auth.uid() = user_id);

create policy "location_history_select_own" on planflow.location_history
  for select using (auth.uid() = user_id);
create policy "location_history_insert_own" on planflow.location_history
  for insert with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from planflow.events
        where events.id = location_history.event_id
          and events.user_id = auth.uid()
      )
    )
  );
create policy "location_history_update_own" on planflow.location_history
  for update using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and (
      event_id is null
      or exists (
        select 1
        from planflow.events
        where events.id = location_history.event_id
          and events.user_id = auth.uid()
      )
    )
  );
create policy "location_history_delete_own" on planflow.location_history
  for delete using (auth.uid() = user_id);

create policy "user_settings_own" on planflow.user_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "calendar_connections_own" on planflow.calendar_connections
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "user_backups_own" on planflow.user_backups
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "feedback_reports_select_own" on planflow.feedback_reports
  for select using (auth.uid() = user_id);
create policy "feedback_reports_insert_own" on planflow.feedback_reports
  for insert with check (auth.uid() = user_id);
create policy "feedback_reports_select_admin" on planflow.feedback_reports
  for select using (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  );
create policy "feedback_reports_update_status_admin" on planflow.feedback_reports
  for update using (
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

create table if not exists nexusflow.action_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references shared.user_profiles (id) on delete cascade,
  title text not null,
  due_at timestamptz,
  priority integer not null default 3,
  contact_id uuid,
  account_id uuid,
  linked_schedule_id uuid,
  source text,
  status text not null default 'pending',
  created_at timestamptz not null default now()
);
alter table nexusflow.action_items enable row level security;
drop policy if exists "action_items_own" on nexusflow.action_items;
create policy "action_items_own" on nexusflow.action_items
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

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

drop trigger if exists events_set_updated_at on planflow.events;
create trigger events_set_updated_at
  before update on planflow.events
  for each row execute function public.set_updated_at();

drop trigger if exists calendar_connections_set_updated_at
  on planflow.calendar_connections;
create trigger calendar_connections_set_updated_at
  before update on planflow.calendar_connections
  for each row execute function public.set_updated_at();

drop trigger if exists feedback_reports_set_updated_at
  on planflow.feedback_reports;
create trigger feedback_reports_set_updated_at
  before update on planflow.feedback_reports
  for each row execute function public.set_updated_at();

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

drop trigger if exists pre_actions_infer_source on planflow.pre_actions;
create trigger pre_actions_infer_source
  before insert or update of title, source
  on planflow.pre_actions
  for each row
  execute function public.infer_pre_action_source();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = shared, public
as $$
begin
  insert into shared.user_profiles (id, email, name)
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
        name = coalesce(excluded.name, shared.user_profiles.name),
        planflow_enabled = true,
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.restore_user_backup(backup_id_input uuid)
returns void
language plpgsql
security invoker
set search_path = planflow, public
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
  from planflow.user_backups
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

    insert into planflow.events (
      id, user_id, title, start_at, end_at, location, location_lat,
      location_lng, memo, supplies, supplies_checked, is_critical, source,
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
      where planflow.events.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'user_settings', '[]'::jsonb))
  loop
    insert into planflow.user_settings (
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
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      continue;
    end if;

    insert into planflow.pre_actions (
      id, event_id, user_id, title, notify_at, is_done, source, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      event_id_value,
      uid,
      item ->> 'title',
      nullif(item ->> 'notify_at', '')::timestamptz,
      coalesce(nullif(item ->> 'is_done', '')::boolean, false),
      coalesce(nullif(item ->> 'source', ''), null),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set title = excluded.title,
          notify_at = excluded.notify_at,
          is_done = excluded.is_done,
          source = excluded.source
      where planflow.pre_actions.user_id = uid;
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
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      continue;
    end if;

    insert into planflow.reminders (
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
      where planflow.reminders.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'location_history', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if event_id_value is not null and not exists (
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      event_id_value := null;
    end if;
    supplies_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'supplies', '[]'::jsonb))
    );

    insert into planflow.location_history (
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
      where planflow.location_history.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'voice_logs', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if event_id_value is not null and not exists (
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      event_id_value := null;
    end if;

    insert into planflow.voice_logs (
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
      where planflow.voice_logs.user_id = uid;
  end loop;
end;
$$;

revoke all on function public.restore_user_backup(uuid) from public;
grant execute on function public.restore_user_backup(uuid) to authenticated;

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
set search_path = planflow, public, extensions, pg_temp
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
    insert into planflow.calendar_connections (
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
            planflow.calendar_connections.provider_account_email
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
set search_path = planflow, public, extensions, pg_temp
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
    from planflow.calendar_connections c
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
set search_path = planflow, public, pg_temp
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  update planflow.calendar_connections
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

create or replace function public.submit_early_bird_email(input_email text)
returns void
language plpgsql
security definer
set search_path = planflow, public
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

  insert into planflow.early_bird_emails (email)
  values (normalized_email)
  on conflict (email) do nothing;
end;
$$;

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
revoke all on function public.submit_early_bird_email(text) from public;
grant execute on function public.submit_early_bird_email(text)
  to anon, authenticated;

notify pgrst, 'reload schema';

create or replace function pg_temp.planflow_safe_count(relation_name text)
returns bigint
language plpgsql
as $$
declare
  relation_oid regclass := to_regclass(relation_name);
  row_count bigint;
begin
  if relation_oid is null then
    return null;
  end if;

  execute format('select count(*) from %s', relation_oid) into row_count;
  return row_count;
end;
$$;

select
  (select count(*) from public.users) as public_users,
  (select count(*) from shared.user_profiles) as shared_user_profiles,
  (select count(*) from public.events) as public_events,
  (select count(*) from planflow.events) as planflow_events,
  (select count(*) from public.pre_actions) as public_pre_actions,
  (select count(*) from planflow.pre_actions) as planflow_pre_actions,
  (select count(*) from public.reminders) as public_reminders,
  (select count(*) from planflow.reminders) as planflow_reminders,
  (select count(*) from public.voice_logs) as public_voice_logs,
  (select count(*) from planflow.voice_logs) as planflow_voice_logs,
  (select count(*) from public.location_history) as public_location_history,
  (select count(*) from planflow.location_history) as planflow_location_history,
  (select count(*) from public.user_settings) as public_user_settings,
  (select count(*) from planflow.user_settings) as planflow_user_settings,
  (select count(*) from public.calendar_connections) as public_calendar_connections,
  (select count(*) from planflow.calendar_connections) as planflow_calendar_connections,
  (select count(*) from public.early_bird_emails) as public_early_bird_emails,
  (select count(*) from planflow.early_bird_emails) as planflow_early_bird_emails,
  (select count(*) from public.user_backups) as public_user_backups,
  (select count(*) from planflow.user_backups) as planflow_user_backups,
  (select count(*) from public.feedback_reports) as public_feedback_reports,
  (select count(*) from planflow.feedback_reports) as planflow_feedback_reports,
  pg_temp.planflow_safe_count('public.user_behavior_logs') as public_user_behavior_logs,
  pg_temp.planflow_safe_count('planflow.user_behavior_logs') as planflow_user_behavior_logs;

-- STEP 8 only, after STEP 7 has 100% reviewer approval:
-- drop table if exists public.voice_logs;
-- drop table if exists public.location_history;
-- drop table if exists public.pre_actions;
-- drop table if exists public.reminders;
-- drop table if exists public.early_bird_emails;
-- drop table if exists public.user_settings;
-- drop table if exists public.calendar_connections;
-- drop table if exists public.user_backups;
-- drop table if exists public.feedback_reports;
-- drop table if exists public.events;
-- drop table if exists public.users;
