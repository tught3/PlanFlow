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

notify pgrst, 'reload schema';;
