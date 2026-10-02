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

alter table shared.user_profiles enable row level security;
alter table shared.voice_inputs enable row level security;
alter table shared.ai_jobs enable row level security;
alter table shared.app_subscriptions enable row level security;

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

notify pgrst, 'reload schema';;
