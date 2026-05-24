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
set search_path = public, planflow, backup, pg_temp
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
    'planflow.early_bird_emails',
    'public.early_bird_emails',
    'public.user_backups',
    'public.feedback_reports',
    'public.admin_roles',
    'public.contact_messages',
    'public.product_early_birds',
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
set search_path = public, planflow, backup, pg_temp
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
set search_path = public, planflow, backup, pg_temp
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
    'public.contact_messages',
    'public.product_early_birds',
    'public.calendar_connections',
    'public.user_backups',
    'public.user_settings',
    'public.events',
    'planflow.early_bird_emails',
    'public.early_bird_emails',
    'public.admin_roles',
    'public.user_behavior_logs',
    'public.users'
  ];
  insert_order text[] := array[
    'public.users',
    'public.user_behavior_logs',
    'public.admin_roles',
    'planflow.early_bird_emails',
    'public.early_bird_emails',
    'public.events',
    'public.user_settings',
    'public.calendar_connections',
    'public.user_backups',
    'public.feedback_reports',
    'public.contact_messages',
    'public.product_early_birds',
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
