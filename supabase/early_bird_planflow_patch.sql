-- Align PlanFlow early-bird submissions with the product schema used in production.
-- This is intentionally additive: legacy public/product tables are kept intact.

create schema if not exists planflow;

create table if not exists planflow.early_bird_emails (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists planflow_early_bird_emails_created_idx
  on planflow.early_bird_emails (created_at desc);

create table if not exists public.early_bird_emails (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  product text not null default 'planflow',
  source text not null default 'app',
  created_at timestamptz not null default now()
);

alter table public.early_bird_emails
  add column if not exists product text not null default 'planflow',
  add column if not exists source text not null default 'app';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'early_bird_emails_email_format'
      and conrelid = 'planflow.early_bird_emails'::regclass
  ) then
    alter table planflow.early_bird_emails
      add constraint early_bird_emails_email_format
      check (
        char_length(email) <= 254
        and email = lower(trim(email))
        and email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      );
  end if;
end;
$$;

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

alter table planflow.early_bird_emails enable row level security;
alter table public.early_bird_emails enable row level security;

revoke all on schema planflow from anon;
revoke all on schema planflow from authenticated;
revoke all on table planflow.early_bird_emails from anon;
revoke all on table planflow.early_bird_emails from authenticated;

insert into planflow.early_bird_emails (email, created_at)
select lower(trim(email)), min(created_at)
from public.early_bird_emails
where email is not null
group by lower(trim(email))
on conflict (email) do nothing;

insert into planflow.early_bird_emails (email, created_at)
select lower(trim(email)), min(created_at)
from public.product_early_birds
where product = 'planflow'
  and email is not null
group by lower(trim(email))
on conflict (email) do nothing;

create or replace function public.submit_early_bird_email(input_email text)
returns void
language plpgsql
security definer
set search_path = planflow, public, pg_temp
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

revoke all on function public.submit_early_bird_email(text) from public;
grant execute on function public.submit_early_bird_email(text) to anon, authenticated;

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
