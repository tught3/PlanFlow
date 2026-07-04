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

-- V2 groups
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  parent_group_id uuid references public.groups (id) on delete set null,
  name text not null,
  description text,
  invite_token text not null default lower(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 16)),
  status text not null default 'active' check (status in ('active', 'archived', 'deleted_pending')),
  created_by uuid not null references public.users (id) on delete restrict,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  role text not null default 'member' check (role in ('leader', 'member')),
  status text not null default 'active' check (status in ('active', 'removed')),
  display_name text,
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by uuid references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_members_group_user_unique unique (group_id, user_id)
);

create index if not exists groups_parent_group_id_idx
  on public.groups (parent_group_id);

create index if not exists groups_status_idx
  on public.groups (status);

alter table public.groups
  add column if not exists invite_token text;

update public.groups
set invite_token = lower(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 16))
where invite_token is null or trim(invite_token) = '';

alter table public.groups
  alter column invite_token set default lower(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 16)),
  alter column invite_token set not null;

create unique index if not exists groups_invite_token_uidx
  on public.groups (invite_token);

create index if not exists groups_created_by_idx
  on public.groups (created_by);

create index if not exists group_members_group_id_idx
  on public.group_members (group_id);

create index if not exists group_members_user_id_idx
  on public.group_members (user_id);

create index if not exists group_members_group_id_role_idx
  on public.group_members (group_id, role);

create or replace function public.handle_new_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.group_members (
    group_id,
    user_id,
    role,
    status,
    joined_at,
    created_at,
    updated_at
  )
  values (
    new.id,
    new.created_by,
    'leader',
    'active',
    now(),
    now(),
    now()
  )
  on conflict (group_id, user_id) do update
    set role = 'leader',
        status = 'active',
        removed_at = null,
        removed_by = null,
        joined_at = now(),
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists groups_set_updated_at on public.groups;
create trigger groups_set_updated_at
  before update on public.groups
  for each row execute function public.set_updated_at();

drop trigger if exists group_members_set_updated_at on public.group_members;
create trigger group_members_set_updated_at
  before update on public.group_members
  for each row execute function public.set_updated_at();

drop trigger if exists groups_handle_new_group on public.groups;
create trigger groups_handle_new_group
  after insert on public.groups
  for each row execute function public.handle_new_group();

alter table public.groups enable row level security;
alter table public.group_members enable row level security;

grant select, insert, update on table public.groups to authenticated;
grant select, insert, update on table public.group_members to authenticated;

create or replace function public.is_group_member(group_id_input uuid, user_id_input uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_members
    where group_id = group_id_input
      and user_id = user_id_input
      and status = 'active'
  );
$$;

create or replace function public.is_group_leader(group_id_input uuid, user_id_input uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_members
    where group_id = group_id_input
      and user_id = user_id_input
      and role = 'leader'
      and status = 'active'
  );
$$;

drop policy if exists "groups_select_member" on public.groups;
drop policy if exists "groups_insert_leader" on public.groups;
drop policy if exists "groups_update_leader" on public.groups;
create policy "groups_select_member"
  on public.groups
  for select
  using (
    status = 'active'
    and public.is_group_member(id, auth.uid())
  );
create policy "groups_insert_leader"
  on public.groups
  for insert
  with check (
    auth.uid() = created_by
    and status = 'active'
  );
create policy "groups_update_leader"
  on public.groups
  for update
  using (
    status = 'active'
    and public.is_group_leader(id, auth.uid())
  )
  with check (
    status = 'active'
    and public.is_group_leader(id, auth.uid())
  );

-- 3. group_invites
create table if not exists public.group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  invited_user_id uuid references public.users (id) on delete set null,
  invited_email text,
  invited_invite_code text,
  invited_by uuid not null references public.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected', 'cancelled', 'expired')),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  rejected_at timestamptz,
  cancelled_at timestamptz,
  expired_at timestamptz,
  acted_by uuid references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_invites_target_check
    check (num_nonnulls(invited_user_id, invited_email, invited_invite_code) = 1)
);

create index if not exists group_invites_group_id_idx
  on public.group_invites (group_id);

create index if not exists group_invites_invited_by_idx
  on public.group_invites (invited_by);

create index if not exists group_invites_invited_user_id_idx
  on public.group_invites (invited_user_id);

create index if not exists group_invites_invited_email_idx
  on public.group_invites (invited_email);

create index if not exists group_invites_invited_invite_code_idx
  on public.group_invites (invited_invite_code);

create index if not exists group_invites_status_idx
  on public.group_invites (status);

create index if not exists group_invites_expires_at_idx
  on public.group_invites (expires_at);

create unique index if not exists group_invites_group_pending_user_uidx
  on public.group_invites (group_id, invited_user_id)
  where status = 'pending'
    and invited_user_id is not null;

create unique index if not exists group_invites_group_pending_email_uidx
  on public.group_invites (group_id, lower(invited_email))
  where status = 'pending'
    and invited_email is not null;

create unique index if not exists group_invites_group_pending_invite_code_uidx
  on public.group_invites (group_id, lower(invited_invite_code))
  where status = 'pending'
    and invited_invite_code is not null;

create or replace function public.is_group_invite_target(
  invited_user_id_input uuid,
  invited_email_input text,
  invited_invite_code_input text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users
    where id = auth.uid()
      and (
        (
          invited_user_id_input is not null
          and invited_user_id_input = id
        )
        or (
          invited_email_input is not null
          and email is not null
          and lower(invited_email_input) = lower(email)
        )
        or (
          invited_invite_code_input is not null
          and invite_code is not null
          and lower(invited_invite_code_input) = lower(invite_code)
        )
      )
  );
$$;

drop trigger if exists group_invites_set_updated_at on public.group_invites;
create trigger group_invites_set_updated_at
  before update on public.group_invites
  for each row execute function public.set_updated_at();

create or replace function public.prevent_group_invite_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.group_id is distinct from old.group_id
    or new.invited_user_id is distinct from old.invited_user_id
    or new.invited_email is distinct from old.invited_email
    or new.invited_invite_code is distinct from old.invited_invite_code
    or new.invited_by is distinct from old.invited_by
    or new.expires_at is distinct from old.expires_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_invites immutable fields cannot change';
  end if;

  return new;
end;
$$;

drop trigger if exists group_invites_prevent_immutable_changes on public.group_invites;
create trigger group_invites_prevent_immutable_changes
  before update on public.group_invites
  for each row execute function public.prevent_group_invite_immutable_changes();

create or replace function public.accept_group_invite(invite_id_input uuid)
returns public.group_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  invite_row public.group_invites%rowtype;
  member_id uuid;
  updated_invite public.group_invites%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
    into invite_row
    from public.group_invites
   where id = invite_id_input
   for update;

  if not found then
    raise exception 'group invite not found';
  end if;

  if invite_row.status <> 'pending' then
    raise exception 'pending invite만 수락할 수 있습니다.';
  end if;

  if invite_row.expires_at <= now() then
    raise exception '만료된 초대는 수락할 수 없습니다.';
  end if;

  if not public.is_group_invite_target(
    invite_row.invited_user_id,
    invite_row.invited_email,
    invite_row.invited_invite_code
  ) then
    raise exception '내 초대만 처리할 수 있습니다.';
  end if;

  if not exists (
    select 1
      from public.groups
     where id = invite_row.group_id
       and status = 'active'
  ) then
    raise exception '활성화된 그룹만 초대 수락이 가능합니다.';
  end if;

  if exists (
    select 1
      from public.group_members
     where group_id = invite_row.group_id
       and user_id = auth.uid()
       and status = 'active'
  ) then
    raise exception '이미 활성 멤버입니다.';
  end if;

  insert into public.group_members (
    group_id,
    user_id,
    role,
    status,
    joined_at,
    created_at,
    updated_at
  )
  values (
    invite_row.group_id,
    auth.uid(),
    'member',
    'active',
    now(),
    now(),
    now()
  )
  on conflict (group_id, user_id) do nothing
  returning id into member_id;

  if member_id is null then
    raise exception '이미 활성 멤버입니다.';
  end if;

  update public.group_invites
     set status = 'accepted',
         accepted_at = now(),
         acted_by = auth.uid()
   where id = invite_row.id
   returning * into updated_invite;

  return updated_invite;
end;
$$;

grant execute on function public.accept_group_invite(uuid) to authenticated;

create or replace function public.accept_group_invite_link(
  group_id_input uuid,
  invite_token_input text
)
returns public.group_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  group_row public.groups%rowtype;
  profile_row public.users%rowtype;
  invite_row public.group_invites%rowtype;
  updated_invite public.group_invites%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if group_id_input is null or trim(coalesce(invite_token_input, '')) = '' then
    raise exception '초대 링크가 올바르지 않습니다.';
  end if;

  select *
    into group_row
    from public.groups
   where id = group_id_input
     and invite_token = lower(trim(invite_token_input))
     and status = 'active';

  if not found then
    raise exception '초대 링크가 유효하지 않습니다.';
  end if;

  if exists (
    select 1
      from public.group_members
     where group_id = group_row.id
       and user_id = auth.uid()
       and status = 'active'
  ) then
    raise exception '이미 활성 멤버입니다.';
  end if;

  select *
    into profile_row
    from public.users
   where id = auth.uid();

  select *
    into invite_row
    from public.group_invites
   where group_id = group_row.id
     and invited_user_id = auth.uid()
     and status = 'pending'
   order by created_at desc
   limit 1
   for update;

  if not found then
    insert into public.group_invites (
      group_id,
      invited_user_id,
      invited_email,
      invited_invite_code,
      invited_by,
      status,
      expires_at,
      created_at,
      updated_at
    )
    values (
      group_row.id,
      auth.uid(),
      null,
      null,
      group_row.created_by,
      'pending',
      now() + interval '7 days',
      now(),
      now()
    )
    returning * into invite_row;
  end if;

  if invite_row.expires_at <= now() then
    raise exception '만료된 초대는 수락할 수 없습니다.';
  end if;

  insert into public.group_members (
    group_id,
    user_id,
    role,
    status,
    joined_at,
    removed_at,
    removed_by,
    created_at,
    updated_at
  )
  values (
    group_row.id,
    auth.uid(),
    'member',
    'active',
    now(),
    null,
    null,
    now(),
    now()
  )
  on conflict (group_id, user_id) do update
     set role = 'member',
         status = 'active',
         joined_at = now(),
         removed_at = null,
         removed_by = null,
         updated_at = now();

  update public.group_invites
     set status = 'accepted',
         accepted_at = now(),
         acted_by = auth.uid()
   where id = invite_row.id
   returning * into updated_invite;

  return updated_invite;
end;
$$;

grant execute on function public.accept_group_invite_link(uuid, text)
  to authenticated;

alter table public.group_invites enable row level security;

grant select, insert, update on table public.group_invites to authenticated;

drop policy if exists "group_invites_select_access" on public.group_invites;
drop policy if exists "group_invites_insert_leader" on public.group_invites;
drop policy if exists "group_invites_update_target" on public.group_invites;
drop policy if exists "group_invites_update_leader_cancel" on public.group_invites;
create policy "group_invites_select_access"
  on public.group_invites
  for select
  using (
    exists (
      select 1
      from public.groups
      where groups.id = group_invites.group_id
        and groups.status = 'active'
        and public.is_group_leader(groups.id, auth.uid())
    )
    or invited_by = auth.uid()
    or (
      status = 'pending'
      and public.is_group_invite_target(
        invited_user_id,
        invited_email,
        invited_invite_code
      )
    )
  );
create policy "group_invites_insert_leader"
  on public.group_invites
  for insert
  with check (
    status = 'pending'
    and invited_by = auth.uid()
    and exists (
      select 1
      from public.groups
      where groups.id = group_invites.group_id
        and groups.status = 'active'
        and public.is_group_leader(groups.id, auth.uid())
    )
  );
create policy "group_invites_update_target"
  on public.group_invites
  for update
  using (
    status = 'pending'
    and public.is_group_invite_target(
      invited_user_id,
      invited_email,
      invited_invite_code
    )
  )
  with check (
    status in ('accepted', 'rejected')
    and acted_by = auth.uid()
    and (
      (status = 'accepted' and accepted_at is not null)
      or (status = 'rejected' and rejected_at is not null)
    )
  );
create policy "group_invites_update_leader_cancel"
  on public.group_invites
  for update
  using (
    status = 'pending'
    and invited_by = auth.uid()
    and exists (
      select 1
      from public.groups
      where groups.id = group_invites.group_id
        and groups.status = 'active'
        and public.is_group_leader(groups.id, auth.uid())
    )
  )
  with check (
    status = 'cancelled'
    and acted_by = auth.uid()
    and cancelled_at is not null
  );

drop policy if exists "group_members_select_member" on public.group_members;
drop policy if exists "group_members_insert_leader" on public.group_members;
drop policy if exists "group_members_update_leader" on public.group_members;
create policy "group_members_select_member"
  on public.group_members
  for select
  using (
    exists (
      select 1
      from public.groups
      where groups.id = group_members.group_id
        and groups.status = 'active'
        and public.is_group_member(groups.id, auth.uid())
    )
  );
create policy "group_members_insert_leader"
  on public.group_members
  for insert
  with check (
    (
      exists (
        select 1
        from public.groups
        where groups.id = group_members.group_id
          and groups.status = 'active'
          and public.is_group_leader(groups.id, auth.uid())
      )
      or exists (
        select 1
        from public.group_invites
        where group_invites.group_id = group_members.group_id
          and group_invites.status = 'accepted'
          and public.is_group_invite_target(
            group_invites.invited_user_id,
            group_invites.invited_email,
            group_invites.invited_invite_code
          )
      )
    )
    and exists (
      select 1
      from public.groups
      where groups.id = group_members.group_id
        and groups.status = 'active'
    )
    and role = 'member'
    and status = 'active'
    and removed_at is null
    and removed_by is null
  );
create policy "group_members_update_leader"
  on public.group_members
  for update
  using (
    exists (
      select 1
      from public.groups
      where groups.id = group_members.group_id
        and groups.status = 'active'
        and public.is_group_leader(groups.id, auth.uid())
    )
  )
  with check (
    exists (
      select 1
      from public.groups
      where groups.id = group_members.group_id
        and groups.status = 'active'
        and public.is_group_leader(groups.id, auth.uid())
    )
    and status = 'active'
    and removed_at is null
    and removed_by is null
  );

create or replace function public.remove_group_member(
  group_id_input uuid,
  member_user_id_input uuid
)
returns public.group_members
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  group_row public.groups%rowtype;
  target_member public.group_members%rowtype;
  updated_member public.group_members%rowtype;
  active_leader_count integer;
begin
  if current_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if member_user_id_input = current_user_id then
    raise exception '자기 자신은 제거할 수 없습니다.';
  end if;

  select *
    into group_row
    from public.groups
   where id = group_id_input
   for update;

  if not found then
    raise exception 'group not found';
  end if;

  if group_row.status <> 'active' then
    raise exception 'active group만 멤버를 제거할 수 있습니다.';
  end if;

  if not public.is_group_leader(group_row.id, current_user_id) then
    raise exception '팀 리더만 멤버를 제거할 수 있습니다.';
  end if;

  select *
    into target_member
    from public.group_members
   where group_id = group_row.id
     and user_id = member_user_id_input
   for update;

  if not found then
    raise exception 'group member not found';
  end if;

  if target_member.status <> 'active' then
    raise exception 'active 멤버만 제거할 수 있습니다.';
  end if;

  if target_member.role = 'leader' then
    select count(*)
      into active_leader_count
      from public.group_members
     where group_id = group_row.id
       and role = 'leader'
       and status = 'active';

    if active_leader_count <= 1 then
      raise exception '마지막 리더는 제거할 수 없습니다.';
    end if;
  end if;

  update public.group_members
     set status = 'removed',
         removed_at = now(),
         removed_by = current_user_id,
         updated_at = now()
   where id = target_member.id
   returning * into updated_member;

  return updated_member;
end;
$$;

grant execute on function public.remove_group_member(uuid, uuid) to authenticated;

-- 팀원(멤버)이 스스로 그룹을 나갈 수 있게 하는 함수. 리더 권한을 요구하지 않되,
-- 본인이 마지막 active 리더면 예외를 던져 그룹이 리더 없이 남는 것을 막는다.
create or replace function public.leave_group(group_id_input uuid)
returns public.group_members
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  group_row public.groups%rowtype;
  target_member public.group_members%rowtype;
  updated_member public.group_members%rowtype;
  active_leader_count integer;
begin
  if current_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
    into group_row
    from public.groups
   where id = group_id_input
   for update;

  if not found then
    raise exception 'group not found';
  end if;

  if group_row.status <> 'active' then
    raise exception 'active group에서만 나갈 수 있습니다.';
  end if;

  select *
    into target_member
    from public.group_members
   where group_id = group_row.id
     and user_id = current_user_id
   for update;

  if not found then
    raise exception 'group member not found';
  end if;

  if target_member.status <> 'active' then
    raise exception '이미 나간 그룹이에요.';
  end if;

  if target_member.role = 'leader' then
    select count(*)
      into active_leader_count
      from public.group_members
     where group_id = group_row.id
       and role = 'leader'
       and status = 'active';

    if active_leader_count <= 1 then
      -- 앱에 '다른 멤버를 리더로 지정'하는 기능이 없어(role 변경 UI 부재),
      -- 사용자에게 실제로 가능한 조치(그룹 삭제)만 안내한다.
      raise exception '마지막 리더는 나갈 수 없어요. 그룹이 필요 없으면 삭제해 주세요.';
    end if;
  end if;

  update public.group_members
     set status = 'removed',
         removed_at = now(),
         removed_by = current_user_id,
         updated_at = now()
   where id = target_member.id
   returning * into updated_member;

  return updated_member;
end;
$$;

grant execute on function public.leave_group(uuid) to authenticated;

create or replace function public.is_valid_group_role_delegation_permissions(
  permissions_input jsonb
)
returns boolean
language sql
immutable
security definer
set search_path = public
as $$
  select
    permissions_input is not null
    and jsonb_typeof(permissions_input) = 'array'
    and jsonb_array_length(permissions_input) > 0
    and not exists (
      select 1
      from jsonb_array_elements_text(permissions_input) as permission(permission_value)
      where permission_value not in (
        'create_group_event',
        'update_group_event',
        'cancel_group_event',
        'view_group_dashboard'
      )
    );
$$;

-- 4. group_role_delegations
create table if not exists public.group_role_delegations (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  delegator_user_id uuid not null references public.users (id) on delete cascade,
  delegate_user_id uuid not null references public.users (id) on delete cascade,
  permissions jsonb not null default '[]'::jsonb,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'active' check (status in ('active', 'expired', 'cancelled')),
  cancelled_at timestamptz,
  cancelled_by uuid references public.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_role_delegations_time_check check (ends_at > starts_at),
  constraint group_role_delegations_permissions_check check (
    jsonb_typeof(permissions) = 'array'
    and jsonb_array_length(permissions) > 0
    and public.is_valid_group_role_delegation_permissions(permissions)
  )
);

create index if not exists group_role_delegations_group_id_idx
  on public.group_role_delegations (group_id);

create index if not exists group_role_delegations_delegator_user_id_idx
  on public.group_role_delegations (delegator_user_id);

create index if not exists group_role_delegations_delegate_user_id_idx
  on public.group_role_delegations (delegate_user_id);

create index if not exists group_role_delegations_status_idx
  on public.group_role_delegations (status);

create index if not exists group_role_delegations_starts_at_idx
  on public.group_role_delegations (starts_at);

create index if not exists group_role_delegations_ends_at_idx
  on public.group_role_delegations (ends_at);

create index if not exists group_role_delegations_group_delegate_status_idx
  on public.group_role_delegations (group_id, delegate_user_id, status);

create unique index if not exists group_role_delegations_group_delegate_active_uidx
  on public.group_role_delegations (group_id, delegate_user_id)
  where status = 'active';

create or replace function public.prevent_group_role_delegation_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.group_id is distinct from old.group_id
    or new.delegator_user_id is distinct from old.delegator_user_id
    or new.delegate_user_id is distinct from old.delegate_user_id
    or new.permissions is distinct from old.permissions
    or new.starts_at is distinct from old.starts_at
    or new.ends_at is distinct from old.ends_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_role_delegations immutable fields cannot change';
  end if;

  return new;
end;
$$;

drop trigger if exists group_role_delegations_set_updated_at on public.group_role_delegations;
create trigger group_role_delegations_set_updated_at
  before update on public.group_role_delegations
  for each row execute function public.set_updated_at();

drop trigger if exists group_role_delegations_prevent_immutable_changes on public.group_role_delegations;
create trigger group_role_delegations_prevent_immutable_changes
  before update on public.group_role_delegations
  for each row execute function public.prevent_group_role_delegation_immutable_changes();

alter table public.group_role_delegations enable row level security;

grant select, insert, update on table public.group_role_delegations to authenticated;

drop policy if exists "group_role_delegations_select_access" on public.group_role_delegations;
drop policy if exists "group_role_delegations_insert_leader" on public.group_role_delegations;
drop policy if exists "group_role_delegations_update_cancel_access" on public.group_role_delegations;
create policy "group_role_delegations_select_access"
  on public.group_role_delegations
  for select
  using (
    delegator_user_id = auth.uid()
    or delegate_user_id = auth.uid()
    or exists (
      select 1
      from public.groups
      where groups.id = group_role_delegations.group_id
        and groups.status = 'active'
        and public.is_group_leader(groups.id, auth.uid())
    )
  );
create policy "group_role_delegations_insert_leader"
  on public.group_role_delegations
  for insert
  with check (
    status = 'active'
    and delegator_user_id = auth.uid()
    and exists (
      select 1
      from public.groups
      where groups.id = group_role_delegations.group_id
        and groups.status = 'active'
        and public.is_group_leader(groups.id, auth.uid())
    )
  );
create policy "group_role_delegations_update_cancel_access"
  on public.group_role_delegations
  for update
  using (
    status = 'active'
    and (
      delegator_user_id = auth.uid()
      or exists (
        select 1
        from public.groups
        where groups.id = group_role_delegations.group_id
          and groups.status = 'active'
          and public.is_group_leader(groups.id, auth.uid())
      )
    )
  )
  with check (
    status = 'cancelled'
    and cancelled_by = auth.uid()
    and cancelled_at is not null
  );

create or replace function public.has_group_delegated_permission(
  group_id_input uuid,
  user_id_input uuid,
  permission_input text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_role_delegations
    where group_id = group_id_input
      and delegate_user_id = user_id_input
      and status = 'active'
      and starts_at <= now()
      and ends_at >= now()
      and permissions ? permission_input
      and permission_input in (
        'create_group_event',
        'update_group_event',
        'cancel_group_event',
        'view_group_dashboard'
      )
      and exists (
        select 1
        from public.groups
        where groups.id = group_id_input
          and groups.status = 'active'
      )
  );
$$;

-- 5. group_events
create table if not exists public.group_events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  title text not null,
  description text,
  location text,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  recurrence_type text not null default 'none' check (recurrence_type in ('none', 'daily', 'weekly', 'monthly')),
  recurrence_until timestamptz,
  created_by uuid not null references public.users (id) on delete cascade,
  updated_by uuid references public.users (id) on delete set null,
  cancelled_at timestamptz,
  cancelled_by uuid references public.users (id) on delete set null,
  personal_event_id uuid references public.events (id) on delete set null,
  status text not null default 'active' check (status in ('active', 'cancelled', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_events_end_after_start_check check (end_at >= start_at)
);

create index if not exists group_events_group_id_idx
  on public.group_events (group_id);

create index if not exists group_events_created_by_idx
  on public.group_events (created_by);

create index if not exists group_events_updated_by_idx
  on public.group_events (updated_by);

create index if not exists group_events_cancelled_by_idx
  on public.group_events (cancelled_by);

create index if not exists group_events_personal_event_id_idx
  on public.group_events (personal_event_id);

create index if not exists group_events_status_idx
  on public.group_events (status);

create index if not exists group_events_start_at_idx
  on public.group_events (start_at);

create index if not exists group_events_group_start_at_idx
  on public.group_events (group_id, start_at);

create index if not exists group_events_group_status_start_at_idx
  on public.group_events (group_id, status, start_at);

alter table public.events
  add column if not exists group_event_id uuid references public.group_events (id) on delete set null;

alter table public.group_events
  add column if not exists personal_event_id uuid references public.events (id) on delete set null;

create index if not exists events_group_event_id_idx
  on public.events (group_event_id);

create or replace function public.prevent_group_event_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.group_id is distinct from old.group_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_events immutable fields cannot change';
  end if;

  return new;
end;
$$;

drop trigger if exists group_events_set_updated_at on public.group_events;
create trigger group_events_set_updated_at
  before update on public.group_events
  for each row execute function public.set_updated_at();

drop trigger if exists group_events_prevent_immutable_changes on public.group_events;
create trigger group_events_prevent_immutable_changes
  before update on public.group_events
  for each row execute function public.prevent_group_event_immutable_changes();

alter table public.group_events enable row level security;

grant select, insert, update on table public.group_events to authenticated;

drop policy if exists "group_events_select_access" on public.group_events;
drop policy if exists "group_events_insert_access" on public.group_events;
drop policy if exists "group_events_insert_leader_or_delegate" on public.group_events;
drop policy if exists "group_events_update_access" on public.group_events;
drop policy if exists "group_events_cancel_access" on public.group_events;
create policy "group_events_select_access"
  on public.group_events
  for select
  using (
    status = 'active'
    and exists (
      select 1
      from public.groups
      where groups.id = group_events.group_id
        and groups.status = 'active'
    )
    and (
      public.is_group_member(group_id, auth.uid())
      or public.is_group_leader(group_id, auth.uid())
      or public.has_group_delegated_permission(group_id, auth.uid(), 'create_group_event')
      or public.has_group_delegated_permission(group_id, auth.uid(), 'update_group_event')
      or public.has_group_delegated_permission(group_id, auth.uid(), 'cancel_group_event')
      or public.has_group_delegated_permission(group_id, auth.uid(), 'view_group_dashboard')
    )
  );
create policy "group_events_insert_leader_or_delegate"
  on public.group_events
  for insert
  with check (
    status = 'active'
    and created_by = auth.uid()
    and exists (
      select 1
      from public.groups
      where groups.id = group_events.group_id
        and groups.status = 'active'
    )
    and (
      public.is_group_member(group_id, auth.uid())
      or public.is_group_leader(group_id, auth.uid())
      or public.has_group_delegated_permission(group_id, auth.uid(), 'create_group_event')
    )
  );
create policy "group_events_update_access"
  on public.group_events
  for update
  using (
    status = 'active'
    and exists (
      select 1
      from public.groups
      where groups.id = group_events.group_id
        and groups.status = 'active'
    )
    -- 그룹일정 수정은 만든 작성자 본인만. 리더라도 남의 공유일정은 수정 불가
    -- (리더는 '리더 지시' 댓글로만 관여).
    and created_by = auth.uid()
  )
  with check (
    status in ('active', 'archived')
    and updated_by = auth.uid()
  );
create policy "group_events_cancel_access"
  on public.group_events
  for update
  using (
    status = 'active'
    and exists (
      select 1
      from public.groups
      where groups.id = group_events.group_id
        and groups.status = 'active'
    )
    -- 그룹일정 취소(삭제)도 만든 작성자 본인만. 리더라도 남의 공유일정은 삭제 불가.
    and created_by = auth.uid()
  )
  with check (
    status = 'cancelled'
    and cancelled_at is not null
    and cancelled_by = auth.uid()
  );

-- 5.5 group_event_comments
create table if not exists public.group_event_comments (
  id uuid primary key default gen_random_uuid(),
  group_event_id uuid not null references public.group_events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  author_user_id uuid not null references public.users (id) on delete cascade,
  target_user_id uuid not null references public.users (id) on delete cascade,
  content text not null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists group_event_comments_group_event_id_idx
  on public.group_event_comments (group_event_id);

create index if not exists group_event_comments_group_id_idx
  on public.group_event_comments (group_id);

create index if not exists group_event_comments_target_user_id_idx
  on public.group_event_comments (target_user_id);

create index if not exists group_event_comments_created_at_desc_idx
  on public.group_event_comments (created_at desc);

create or replace function public.prevent_group_event_comment_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.group_event_id is distinct from old.group_event_id
    or new.group_id is distinct from old.group_id
    or new.author_user_id is distinct from old.author_user_id
    or new.target_user_id is distinct from old.target_user_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_event_comments immutable fields cannot change';
  end if;

  return new;
end;
$$;

drop trigger if exists group_event_comments_set_updated_at on public.group_event_comments;
create trigger group_event_comments_set_updated_at
  before update on public.group_event_comments
  for each row execute function public.set_updated_at();

drop trigger if exists group_event_comments_prevent_immutable_changes on public.group_event_comments;
create trigger group_event_comments_prevent_immutable_changes
  before update on public.group_event_comments
  for each row execute function public.prevent_group_event_comment_immutable_changes();

alter table public.group_event_comments enable row level security;

grant select, insert, update on table public.group_event_comments to authenticated;

drop policy if exists "group_event_comments_select_access" on public.group_event_comments;
create policy "group_event_comments_select_access"
  on public.group_event_comments
  for select
  using (
    exists (
      select 1
      from public.groups
      where groups.id = group_event_comments.group_id
        and groups.status = 'active'
    )
    and (
      public.is_group_member(group_id, auth.uid())
      or public.is_group_leader(group_id, auth.uid())
    )
  );

drop policy if exists "group_event_comments_insert_access" on public.group_event_comments;
create policy "group_event_comments_insert_access"
  on public.group_event_comments
  for insert
  with check (
    author_user_id = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
    and exists (
      select 1
      from public.groups
      where groups.id = group_event_comments.group_id
        and groups.status = 'active'
    )
    and exists (
      select 1
      from public.group_members
      where group_members.group_id = group_event_comments.group_id
        and group_members.user_id = group_event_comments.target_user_id
        and group_members.status = 'active'
    )
    -- 지시 대상(target)은 해당 그룹 일정의 공유자(created_by)여야 하고,
    -- group_event_id 가 group_id 에 실제로 속하는지도 함께 검증한다.
    and exists (
      select 1
      from public.group_events ge
      where ge.id = group_event_comments.group_event_id
        and ge.group_id = group_event_comments.group_id
        and ge.created_by = group_event_comments.target_user_id
        and ge.status = 'active'
    )
  );

drop policy if exists "group_event_comments_update_confirm" on public.group_event_comments;
create policy "group_event_comments_update_confirm"
  on public.group_event_comments
  for update
  using (
    target_user_id = auth.uid()
    and confirmed_at is null
  )
  with check (
    target_user_id = auth.uid()
    and confirmed_at is not null
  );

drop policy if exists "group_event_comments_update_leader_edit" on public.group_event_comments;
create policy "group_event_comments_update_leader_edit"
  on public.group_event_comments
  for update
  using (
    author_user_id = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
    and confirmed_at is null
  )
  with check (
    author_user_id = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
    and confirmed_at is null
  );

-- 6. group_backups
create table if not exists public.group_backups (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  backup_type text not null check (backup_type in ('archive', 'delete')),
  snapshot jsonb not null default '{}'::jsonb,
  created_by uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  restored_at timestamptz,
  restored_by uuid references public.users (id) on delete set null
);

create index if not exists group_backups_group_id_idx
  on public.group_backups (group_id);

create index if not exists group_backups_created_by_idx
  on public.group_backups (created_by);

create index if not exists group_backups_restored_by_idx
  on public.group_backups (restored_by);

create index if not exists group_backups_created_at_idx
  on public.group_backups (created_at);

create or replace function public.prevent_group_backup_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.group_id is distinct from old.group_id
    or new.backup_type is distinct from old.backup_type
    or new.snapshot is distinct from old.snapshot
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_backups immutable fields cannot change';
  end if;

  return new;
end;
$$;

drop trigger if exists group_backups_prevent_immutable_changes on public.group_backups;
create trigger group_backups_prevent_immutable_changes
  before update on public.group_backups
  for each row execute function public.prevent_group_backup_immutable_changes();

create or replace function public.archive_group_with_backup(group_id_input uuid)
returns public.group_backups
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  group_row public.groups%rowtype;
  backup_row public.group_backups%rowtype;
  snapshot_payload jsonb;
begin
  if current_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
    into group_row
    from public.groups
   where id = group_id_input
   for update;

  if not found then
    raise exception 'group not found';
  end if;

  if group_row.status <> 'active' then
    raise exception 'active group만 보관할 수 있습니다.';
  end if;

  if not public.is_group_leader(group_row.id, current_user_id) then
    raise exception '팀 리더만 그룹을 보관할 수 있습니다.';
  end if;

  snapshot_payload := jsonb_build_object(
    'group', to_jsonb(group_row),
    'active_members',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'user_id', group_members.user_id,
            'role', group_members.role,
            'joined_at', group_members.joined_at,
            'created_at', group_members.created_at
          )
        )
        from public.group_members
        where group_members.group_id = group_row.id
          and group_members.status = 'active'
      ),
      '[]'::jsonb
    )
  );

  insert into public.group_backups (
    group_id,
    backup_type,
    snapshot,
    created_by,
    created_at
  )
  values (
    group_row.id,
    'archive',
    snapshot_payload,
    current_user_id,
    now()
  )
  returning * into backup_row;

  update public.groups
     set status = 'archived',
         archived_at = now()
   where id = group_row.id;

  return backup_row;
end;
$$;

grant execute on function public.archive_group_with_backup(uuid) to authenticated;

alter table public.group_backups enable row level security;

grant select, insert, update on table public.group_backups to authenticated;

drop policy if exists "group_backups_select_leader" on public.group_backups;
drop policy if exists "group_backups_insert_leader" on public.group_backups;
drop policy if exists "group_backups_update_restore_leader" on public.group_backups;
create policy "group_backups_select_leader"
  on public.group_backups
  for select
  using (
    public.is_group_leader(group_id, auth.uid())
  );
create policy "group_backups_insert_leader"
  on public.group_backups
  for insert
  with check (
    created_by = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
  );
create policy "group_backups_update_restore_leader"
  on public.group_backups
  for update
  using (
    public.is_group_leader(group_id, auth.uid())
  )
  with check (
    restored_by = auth.uid()
    and restored_at is not null
  );

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
  departure_safety_margin_min integer not null default 20,
  travel_mode text not null default 'car',
  voice_auto_start boolean not null default false,
  voice_correction_learning_enabled boolean not null default true,
  voice_common_learning_opt_in boolean not null default false,
  preferred_map_provider text not null default 'naver'
    check (preferred_map_provider in ('naver', 'google', 'tmap')),
  country_code text not null default 'KR',
  locale_code text not null default 'ko-KR',
  time_zone_id text not null default 'Asia/Seoul',
  google_calendar_token text,
  naver_calendar_token text,
  naver_caldav_id text,
  naver_caldav_app_password text,
  created_at timestamptz not null default now()
);

  alter table public.user_settings
  add column if not exists travel_mode text not null default 'car';

  alter table public.user_settings
  add column if not exists voice_auto_start boolean not null default false;

  alter table public.user_settings
  add column if not exists voice_correction_learning_enabled boolean not null default true;

  alter table public.user_settings
  add column if not exists voice_common_learning_opt_in boolean not null default false;

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
  add column if not exists departure_safety_margin_min integer not null default 20;

  alter table public.user_settings
  add column if not exists naver_calendar_token text;

  alter table public.user_settings
  add column if not exists naver_caldav_id text,
  add column if not exists naver_caldav_app_password text;

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

-- 7a. voice correction learning rules
create table if not exists public.voice_correction_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  stage text not null check (stage in ('stt', 'parse')),
  field_name text not null check (
    field_name in (
      'transcript',
      'title',
      'location',
      'startAt',
      'endAt',
      'recurrence',
      'isCritical',
      'supplies'
    )
  ),
  from_text text not null,
  to_text text not null,
  context_before text not null default '',
  context_after text not null default '',
  confidence_count integer not null default 1,
  reject_count integer not null default 0,
  enabled boolean not null default true,
  is_sensitive boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint voice_correction_rules_unique unique (
    user_id,
    stage,
    field_name,
    from_text,
    to_text,
    context_before,
    context_after
  )
);

create table if not exists public.voice_common_correction_rules (
  id uuid primary key default gen_random_uuid(),
  stage text not null check (stage in ('stt', 'parse')),
  field_name text not null check (
    field_name in (
      'transcript',
      'title',
      'location',
      'startAt',
      'endAt',
      'recurrence',
      'isCritical',
      'supplies'
    )
  ),
  from_text text not null,
  to_text text not null,
  context_before text not null default '',
  context_after text not null default '',
  support_count integer not null default 0,
  conflict_count integer not null default 0,
  confidence_score double precision not null default 0,
  enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint voice_common_correction_rules_unique unique (
    stage,
    field_name,
    from_text,
    to_text,
    context_before,
    context_after
  )
);

create index if not exists voice_correction_rules_user_enabled_idx
  on public.voice_correction_rules (user_id, enabled, confidence_count desc);

create index if not exists voice_common_correction_rules_trusted_idx
  on public.voice_common_correction_rules (
    enabled,
    support_count desc,
    conflict_count,
    confidence_score desc
  );

drop trigger if exists voice_correction_rules_set_updated_at
  on public.voice_correction_rules;
create trigger voice_correction_rules_set_updated_at
  before update on public.voice_correction_rules
  for each row execute function public.set_updated_at();

drop trigger if exists voice_common_correction_rules_set_updated_at
  on public.voice_common_correction_rules;
create trigger voice_common_correction_rules_set_updated_at
  before update on public.voice_common_correction_rules
  for each row execute function public.set_updated_at();

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
-- PlanFlow app submissions are stored in the product schema. Keep the public
-- RPC as the app-facing gateway so clients never insert into the table directly.
create schema if not exists planflow;

create table if not exists planflow.early_bird_emails (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists planflow_early_bird_emails_created_idx
  on planflow.early_bird_emails (created_at desc);

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
  user_id uuid references public.users (id) on delete cascade,
  product text not null default 'planflow' check (
    product in ('planflow', 'finflow', 'valueflow', 'nexusflow', 'general')
  ),
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
  source text not null default 'app' check (
    source in ('app', 'android-app', 'homepage')
  ),
  email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.feedback_reports
  add column if not exists product text not null default 'planflow',
  add column if not exists source text,
  add column if not exists email text;

update public.feedback_reports
set source = 'app'
where source is null;

alter table public.feedback_reports
  alter column user_id drop not null,
  alter column source set default 'app',
  alter column source set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'feedback_reports_product_check'
      and conrelid = 'public.feedback_reports'::regclass
  ) then
    alter table public.feedback_reports
      add constraint feedback_reports_product_check
      check (product in ('planflow', 'finflow', 'valueflow', 'nexusflow', 'general'));
  end if;

end;
$$;

alter table public.feedback_reports
  drop constraint if exists feedback_reports_source_check;

alter table public.feedback_reports
  add constraint feedback_reports_source_check
  check (source in ('app', 'android-app', 'homepage'));

create index if not exists feedback_reports_user_created_idx
  on public.feedback_reports (user_id, created_at desc);

create index if not exists feedback_reports_status_created_idx
  on public.feedback_reports (status, created_at desc);

create index if not exists feedback_reports_source_idx
  on public.feedback_reports (source, created_at desc);

drop trigger if exists feedback_reports_set_updated_at
  on public.feedback_reports;
create trigger feedback_reports_set_updated_at
  before update on public.feedback_reports
  for each row execute function public.set_updated_at();

-- 12. FluxStudio dashboard admin and public intake tables
create table if not exists public.admin_roles (
  email text primary key,
  role text not null default 'admin' check (role in ('admin', 'owner')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admin_roles_email_format check (
    char_length(email) <= 254
    and email = lower(trim(email))
    and email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  )
);

drop trigger if exists admin_roles_set_updated_at
  on public.admin_roles;
create trigger admin_roles_set_updated_at
  before update on public.admin_roles
  for each row execute function public.set_updated_at();

create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  product text check (
    product in ('planflow', 'finflow', 'valueflow', 'nexusflow', 'general')
  ),
  name text not null,
  email text not null,
  subject text not null,
  message text not null,
  status text not null default 'new' check (status in ('new', 'wip', 'done')),
  source text not null default 'homepage' check (source in ('homepage', 'app')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists contact_messages_status_created_idx
  on public.contact_messages (status, created_at desc);

drop trigger if exists contact_messages_set_updated_at
  on public.contact_messages;
create trigger contact_messages_set_updated_at
  before update on public.contact_messages
  for each row execute function public.set_updated_at();

create table if not exists public.product_early_birds (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  product text not null check (
    product in ('planflow', 'finflow', 'valueflow', 'nexusflow')
  ),
  source text not null default 'homepage' check (source in ('homepage', 'app')),
  created_at timestamptz not null default now(),
  constraint product_early_birds_unique unique (email, product)
);

create index if not exists product_early_birds_product_created_idx
  on public.product_early_birds (product, created_at desc);

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

alter table public.users enable row level security;
alter table public.events enable row level security;
alter table public.pre_actions enable row level security;
alter table public.reminders enable row level security;
alter table public.voice_logs enable row level security;
alter table public.location_history enable row level security;
alter table public.user_settings enable row level security;
alter table public.voice_correction_rules enable row level security;
alter table public.voice_common_correction_rules enable row level security;
alter table public.calendar_connections enable row level security;
alter table planflow.early_bird_emails enable row level security;
alter table public.user_backups enable row level security;
alter table public.feedback_reports enable row level security;
alter table public.admin_roles enable row level security;
alter table public.contact_messages enable row level security;
alter table public.product_early_birds enable row level security;

grant usage on schema public to anon;
grant usage on schema public to authenticated;
revoke all on schema planflow from anon;
revoke all on schema planflow from authenticated;
revoke all on table planflow.early_bird_emails from anon;
revoke all on table planflow.early_bird_emails from authenticated;
grant select, insert on table public.feedback_reports to authenticated;
grant update (status, updated_at) on table public.feedback_reports to authenticated;
grant select on table public.admin_roles to authenticated;
grant insert on table public.contact_messages to anon, authenticated;
grant select, update on table public.contact_messages to authenticated;
grant insert on table public.product_early_birds to anon, authenticated;
grant select on table public.product_early_birds to authenticated;
grant select, insert, update, delete on table public.voice_correction_rules to authenticated;
grant select on table public.voice_common_correction_rules to authenticated;

drop policy if exists "users_select_own" on public.users;
drop policy if exists "users_select_group_members" on public.users;
drop policy if exists "users_insert_own" on public.users;
drop policy if exists "users_update_own" on public.users;
drop policy if exists "users_delete_own" on public.users;
create policy "users_select_own"
  on public.users
  for select
  using (auth.uid() = id);
create policy "users_select_group_members"
  on public.users
  for select
  using (
    exists (
      select 1
      from public.group_members my_membership
      join public.group_members target_membership
        on target_membership.group_id = my_membership.group_id
      join public.groups
        on groups.id = my_membership.group_id
      where my_membership.user_id = auth.uid()
        and my_membership.status = 'active'
        and target_membership.user_id = public.users.id
        and target_membership.status = 'active'
        and groups.status = 'active'
    )
  );
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

drop policy if exists "voice_correction_rules_select_own" on public.voice_correction_rules;
drop policy if exists "voice_correction_rules_insert_own" on public.voice_correction_rules;
drop policy if exists "voice_correction_rules_update_own" on public.voice_correction_rules;
drop policy if exists "voice_correction_rules_delete_own" on public.voice_correction_rules;
create policy "voice_correction_rules_select_own"
  on public.voice_correction_rules
  for select
  using (auth.uid() = user_id);
create policy "voice_correction_rules_insert_own"
  on public.voice_correction_rules
  for insert
  with check (auth.uid() = user_id);
create policy "voice_correction_rules_update_own"
  on public.voice_correction_rules
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create policy "voice_correction_rules_delete_own"
  on public.voice_correction_rules
  for delete
  using (auth.uid() = user_id);

drop policy if exists "voice_common_correction_rules_select_authenticated"
  on public.voice_common_correction_rules;
create policy "voice_common_correction_rules_select_authenticated"
  on public.voice_common_correction_rules
  for select
  to authenticated
  using (enabled = true);

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

drop policy if exists "admin_roles_select_own" on public.admin_roles;
drop policy if exists "admin_roles_update_own" on public.admin_roles;
create policy "admin_roles_select_own"
  on public.admin_roles
  for select
  to authenticated
  using (email = lower(coalesce(auth.jwt() ->> 'email', '')));
create policy "admin_roles_update_own"
  on public.admin_roles
  for update
  to authenticated
  using (email = lower(coalesce(auth.jwt() ->> 'email', '')))
  with check (email = lower(coalesce(auth.jwt() ->> 'email', '')));

insert into public.admin_roles (email, role)
values ('tught3@naver.com', 'owner')
on conflict (email) do update
set role = excluded.role;

drop policy if exists "contact_messages_insert_public" on public.contact_messages;
drop policy if exists "contact_messages_select_admin" on public.contact_messages;
drop policy if exists "contact_messages_update_admin" on public.contact_messages;
create policy "contact_messages_insert_public"
  on public.contact_messages
  for insert
  to anon, authenticated
  with check (true);
create policy "contact_messages_select_admin"
  on public.contact_messages
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.admin_roles ar
      where ar.email = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
  );
create policy "contact_messages_update_admin"
  on public.contact_messages
  for update
  to authenticated
  using (
    exists (
      select 1
      from public.admin_roles ar
      where ar.email = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
  )
  with check (
    exists (
      select 1
      from public.admin_roles ar
      where ar.email = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
  );

drop policy if exists "product_early_birds_insert_public" on public.product_early_birds;
drop policy if exists "product_early_birds_select_admin" on public.product_early_birds;
create policy "product_early_birds_insert_public"
  on public.product_early_birds
  for insert
  to anon, authenticated
  with check (true);
create policy "product_early_birds_select_admin"
  on public.product_early_birds
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.admin_roles ar
      where ar.email = lower(coalesce(auth.jwt() ->> 'email', ''))
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
      depart_pre_alarm_offset, departure_safety_margin_min, travel_mode,
      voice_auto_start,
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
      coalesce(nullif(item ->> 'departure_safety_margin_min', '')::integer, 20),
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
          departure_safety_margin_min = excluded.departure_safety_margin_min,
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
    'public.admin_roles',
    'public.user_behavior_logs',
    'public.users'
  ];
  insert_order text[] := array[
    'public.users',
    'public.user_behavior_logs',
    'public.admin_roles',
    'planflow.early_bird_emails',
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
