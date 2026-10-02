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

notify pgrst, 'reload schema';;
