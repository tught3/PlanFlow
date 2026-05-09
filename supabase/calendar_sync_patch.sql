-- PlanFlow calendar sync patch
-- Apply this in Supabase SQL Editor if the full schema.sql is too large.

create extension if not exists pgcrypto;

alter table public.user_settings
  add column if not exists voice_auto_start boolean not null default false;

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
