-- Disposable PostgreSQL integration proof for the group deletion migration.
-- Run only in a fresh throwaway database (the paired PowerShell runner does so).
\set ON_ERROR_STOP on

create role authenticated;
create role anon;
create schema auth;
grant usage on schema auth to public;
create table auth.users (id uuid primary key);
create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create table public.users (
  id uuid primary key references auth.users(id) on delete cascade
);
create table public.groups (
  id uuid primary key,
  name text not null,
  created_by uuid not null references public.users(id),
  status text not null default 'active'
);
-- Deliberately omit left_at: the tested migration must supply its compatibility alias.
create table public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null,
  status text not null,
  display_name text,
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, user_id)
);
create table public.group_backups (
  id uuid primary key default gen_random_uuid(),
  group_id uuid references public.groups(id) on delete set null,
  backup_type text not null,
  snapshot jsonb not null default '{}'::jsonb,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  restored_at timestamptz,
  restored_by uuid references public.users(id) on delete set null
);
create table public.group_events (id uuid primary key default gen_random_uuid(), group_id uuid not null references public.groups(id) on delete cascade);
create table public.group_event_comments (id uuid primary key default gen_random_uuid(), group_id uuid not null references public.groups(id) on delete cascade);
create table public.group_role_delegations (id uuid primary key default gen_random_uuid(), group_id uuid not null references public.groups(id) on delete cascade);
create table public.group_invites (id uuid primary key default gen_random_uuid(), group_id uuid not null references public.groups(id) on delete cascade);
create table public.events (id uuid primary key default gen_random_uuid(), group_event_id uuid references public.group_events(id) on delete set null, user_id uuid references public.users(id));

create or replace function public.is_group_leader(group_id_input uuid, user_id_input uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.group_members
     where group_id = group_id_input and user_id = user_id_input
       and role = 'leader' and status = 'active'
  );
$$;

\ir ../../supabase/migrations/20260924090000_group_delete_notices_and_backup_member_compat.sql

-- Canonical delete RPC body from supabase/schema.sql. This exercises the pre-existing
-- backup-before-delete contract, including its legacy group_members.left_at reference.
create or replace function public.delete_group_with_backup(group_id_input uuid)
returns public.group_backups
language plpgsql security definer set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  group_row public.groups%rowtype;
  backup_row public.group_backups%rowtype;
  snapshot_payload jsonb;
begin
  if current_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select * into group_row from public.groups where id = group_id_input for update;
  if not found then raise exception 'group not found'; end if;
  if not public.is_group_leader(group_row.id, current_user_id) then
    raise exception '팀 리더만 그룹을 삭제할 수 있습니다.';
  end if;
  snapshot_payload := jsonb_build_object(
    'group', to_jsonb(group_row),
    'active_members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', gm.user_id, 'role', gm.role, 'display_name', gm.display_name,
        'joined_at', gm.joined_at, 'created_at', gm.created_at, 'updated_at', gm.updated_at
      )) from public.group_members gm where gm.group_id = group_row.id and gm.status = 'active'
    ), '[]'::jsonb),
    'all_members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', gm.user_id, 'role', gm.role, 'display_name', gm.display_name,
        'status', gm.status, 'joined_at', gm.joined_at, 'left_at', gm.left_at,
        'created_at', gm.created_at, 'updated_at', gm.updated_at
      )) from public.group_members gm where gm.group_id = group_row.id
    ), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(ge)) from public.group_events ge where ge.group_id = group_row.id), '[]'::jsonb),
    'event_comments', coalesce((select jsonb_agg(to_jsonb(gc)) from public.group_event_comments gc where gc.group_id = group_row.id), '[]'::jsonb),
    'role_delegations', coalesce((select jsonb_agg(to_jsonb(rd)) from public.group_role_delegations rd where rd.group_id = group_row.id), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(to_jsonb(gi)) from public.group_invites gi where gi.group_id = group_row.id), '[]'::jsonb),
    'personal_event_links', coalesce((
      select jsonb_agg(jsonb_build_object('event_id', e.id, 'group_event_id', e.group_event_id, 'user_id', e.user_id))
      from public.events e where e.group_event_id in (
        select ge.id from public.group_events ge where ge.group_id = group_row.id
      )
    ), '[]'::jsonb)
  );
  insert into public.group_backups(group_id, backup_type, snapshot, created_by, created_at)
  values(group_row.id, 'delete', snapshot_payload, current_user_id, now())
  returning * into backup_row;
  delete from public.groups where id = group_row.id;
  return backup_row;
end;
$$;
grant execute on function public.delete_group_with_backup(uuid) to authenticated;
grant usage on schema public to authenticated;

create or replace function public.test_assert(ok boolean, message text)
returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'ASSERTION FAILED: %', message; end if;
end;
$$;

insert into auth.users(id) values
 ('10000000-0000-0000-0000-000000000001'), ('10000000-0000-0000-0000-000000000002'),
 ('10000000-0000-0000-0000-000000000003'), ('10000000-0000-0000-0000-000000000004');
insert into public.users(id) select id from auth.users;

-- Successful leader deletion: backup includes legacy left_at and only active non-leaders
-- receive notices; group/member cascade completes atomically.
insert into public.groups(id, name, created_by) values
 ('20000000-0000-0000-0000-000000000001', 'Leader deletion', '10000000-0000-0000-0000-000000000001');
insert into public.group_members(group_id, user_id, role, status, removed_at) values
 ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'leader', 'active', null),
 ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'member', 'active', null),
 ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', 'member', 'active', null),
 ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000004', 'member', 'removed', now());
insert into public.group_events(id, group_id) values
 ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
insert into public.events(id, group_event_id, user_id) values
 ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', false) \gset
set role authenticated;
do $$ begin perform public.delete_group_with_backup('20000000-0000-0000-0000-000000000001'); end; $$;
reset role;
select public.test_assert((select count(*) = 1 from public.group_backups where snapshot #>> '{group,id}' = '20000000-0000-0000-0000-000000000001' and backup_type = 'delete'), 'leader delete writes one backup');
select public.test_assert((select count(*) = 1 from public.group_backups where snapshot #>> '{group,id}' = '20000000-0000-0000-0000-000000000001' and snapshot #> '{all_members}' is not null), 'backup captures member snapshot');
select public.test_assert((select jsonb_array_length(snapshot #> '{all_members}') = 4 and snapshot #>> '{all_members,3,left_at}' is not null from public.group_backups where snapshot #>> '{group,id}' = '20000000-0000-0000-0000-000000000001'), 'legacy left_at is present in backup snapshot');
select public.test_assert((select count(*) = 2 from public.group_deletion_notices where group_name = 'Leader deletion' and recipient_user_id in ('10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003') and acknowledged_at is null), 'active members each receive a pending notice');
select public.test_assert((select count(*) = 0 from public.group_deletion_notices where group_name = 'Leader deletion' and recipient_user_id = '10000000-0000-0000-0000-000000000001'), 'leader receives no notice');
select public.test_assert(not exists(select 1 from public.groups where id = '20000000-0000-0000-0000-000000000001') and not exists(select 1 from public.group_members where group_id = '20000000-0000-0000-0000-000000000001'), 'group and memberships cascade');
select public.test_assert(not exists(select 1 from public.group_events where id = '40000000-0000-0000-0000-000000000001') and exists(select 1 from public.events where id = '50000000-0000-0000-0000-000000000001' and group_event_id is null), 'group schedules cascade while personal event links are preserved');

-- The canonical RPC rejects a non-leader before deleting anything.
insert into public.groups(id, name, created_by) values
 ('20000000-0000-0000-0000-000000000002', 'Unauthorized deletion', '10000000-0000-0000-0000-000000000001');
insert into public.group_members(group_id, user_id, role, status) values
 ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'leader', 'active'),
 ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'member', 'active');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', false) \gset
set role authenticated;
do $$
declare rejected boolean := false;
begin
  begin
    perform public.delete_group_with_backup('20000000-0000-0000-0000-000000000002');
  exception when others then
    if sqlerrm not like '팀 리더만 그룹을 삭제할 수 있습니다.%' then raise; end if;
    rejected := true;
  end;
  if not rejected then raise exception 'ASSERTION FAILED: non-leader delete was allowed'; end if;
end;
$$;
reset role;
select public.test_assert(exists(select 1 from public.groups where id = '20000000-0000-0000-0000-000000000002') and not exists(select 1 from public.group_deletion_notices where group_name = 'Unauthorized deletion'), 'non-leader rejection leaves group and notices unchanged');

-- Notice list and acknowledgement are recipient-scoped, and the base table is not readable.
insert into public.group_deletion_notices(id, recipient_user_id, group_name) values
 ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', 'Other account only');
select public.test_assert(not has_table_privilege('authenticated', 'public.group_deletion_notices', 'select') and not has_table_privilege('anon', 'public.group_deletion_notices', 'select'), 'notice table is not directly readable');
select public.test_assert(not has_function_privilege('anon', 'public.list_my_group_deletion_notices()', 'execute') and has_function_privilege('authenticated', 'public.list_my_group_deletion_notices()', 'execute'), 'notice list RPC is authenticated-only');
select public.test_assert(not has_function_privilege('anon', 'public.acknowledge_group_deletion_notice(uuid)', 'execute') and has_function_privilege('authenticated', 'public.acknowledge_group_deletion_notice(uuid)', 'execute'), 'notice acknowledgement RPC is authenticated-only');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', false) \gset
set role authenticated;
do $$
declare visible_count integer;
begin
  select count(*) into visible_count from public.list_my_group_deletion_notices();
  if visible_count <> 1 then raise exception 'ASSERTION FAILED: recipient sees only own notice (got %)', visible_count; end if;
  perform public.acknowledge_group_deletion_notice('30000000-0000-0000-0000-000000000001');
end;
$$;
reset role;
select public.test_assert((select acknowledged_at is null from public.group_deletion_notices where id = '30000000-0000-0000-0000-000000000001'), 'another recipient cannot acknowledge notice');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', false) \gset
set role authenticated;
do $$
declare visible_count integer;
begin
  select count(*) into visible_count from public.list_my_group_deletion_notices();
  if visible_count <> 2 then raise exception 'ASSERTION FAILED: member sees only their two notices (got %)', visible_count; end if;
  perform public.acknowledge_group_deletion_notice('30000000-0000-0000-0000-000000000001');
end;
$$;
reset role;
select public.test_assert((select acknowledged_at is not null from public.group_deletion_notices where id = '30000000-0000-0000-0000-000000000001'), 'recipient can acknowledge own notice');

-- A later delete trigger fails after the notice trigger ran. Its notice and backup writes
-- must roll back together with the failed group delete.
create or replace function public.test_fail_group_delete()
returns trigger language plpgsql as $$ begin raise exception 'intentional rollback probe'; end; $$;
create trigger zzzz_test_fail_group_delete before delete on public.groups
for each row execute function public.test_fail_group_delete();
insert into public.groups(id, name, created_by) values
 ('20000000-0000-0000-0000-000000000003', 'Rollback probe', '10000000-0000-0000-0000-000000000001');
insert into public.group_members(group_id, user_id, role, status) values
 ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'leader', 'active'),
 ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'member', 'active');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', false) \gset
set role authenticated;
do $$
declare failed boolean := false;
begin
  begin
    perform public.delete_group_with_backup('20000000-0000-0000-0000-000000000003');
  exception when others then
    if sqlerrm <> 'intentional rollback probe' then raise; end if;
    failed := true;
  end;
  if not failed then raise exception 'ASSERTION FAILED: injected deletion failure did not fire'; end if;
end;
$$;
reset role;
select public.test_assert(exists(select 1 from public.groups where id = '20000000-0000-0000-0000-000000000003'), 'failed delete leaves group intact');
select public.test_assert(not exists(select 1 from public.group_backups where group_id = '20000000-0000-0000-0000-000000000003'), 'failed delete rolls back backup');
select public.test_assert(not exists(select 1 from public.group_deletion_notices where group_name = 'Rollback probe'), 'failed delete rolls back notice');

\echo 'PASS: migration, backup compatibility, leader authorization, recipient isolation, and rollback'
