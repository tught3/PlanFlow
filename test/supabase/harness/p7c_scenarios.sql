\set ON_ERROR_STOP on
do $$
begin
  if current_database() not like $pattern$p7c\_%$pattern$ then
    raise exception 'P7c scenarios require a disposable database with a p7c_ prefix';
  end if;
end;
$$;

\set leader 10000000-0000-4000-8000-000000000001
\set member 10000000-0000-4000-8000-000000000002
\set recipient 10000000-0000-4000-8000-000000000003
\set withdrawing 10000000-0000-4000-8000-000000000004
\set group_id 20000000-0000-4000-8000-000000000001
\set backup_group 20000000-0000-4000-8000-000000000004
\set restore_group 20000000-0000-4000-8000-000000000005

create function pg_temp.require(ok boolean, description text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then
    raise exception '%', description;
  end if;
end;
$$;

insert into auth.users (id, email) values
  (:'leader', 'leader@example.test'),
  (:'member', 'member@example.test'),
  (:'recipient', 'recipient@example.test'),
  (:'withdrawing', 'withdrawing@example.test');

insert into public.groups (id, name, created_by) values
  (:'group_id', 'P7c invitation tests', :'leader'),
  (:'backup_group', 'P7c backup fixture', :'withdrawing'),
  (:'restore_group', 'P7c restore clock fixture', :'leader');
insert into public.group_members (group_id, user_id, role, status)
values (:'group_id', :'member', 'member', 'active');

-- Identity columns are protected with enabled row guards on actual tables.
select pg_temp.require(
  (
    select count(*) = 2
    from pg_trigger
    where tgenabled = 'O'
      and (tgrelid, tgname) in (
        ('public.groups'::regclass, 'groups_protect_identity'),
        ('public.group_members'::regclass, 'group_members_protect_identity')
      )
  ),
  'B1/B2: identity guards are enabled'
);
select set_config('request.jwt.claims', jsonb_build_object('sub', :'leader')::text, false);
select set_config('p7c.group_id', :'group_id', false);
select set_config('p7c.member', :'member', false);
select set_config('p7c.recipient', :'recipient', false);

set role authenticated;
do $$
declare
  group_id_input uuid := current_setting('p7c.group_id')::uuid;
  member_id_input uuid := current_setting('p7c.member')::uuid;
  recipient_id uuid := current_setting('p7c.recipient')::uuid;
begin
  -- Expected denials in the patched disposable database. Match the guard error
  -- as well as the code so a different authorization failure isn't a pass.
  begin
    update public.groups set created_by = recipient_id where id = group_id_input;
    raise exception 'B1: group owner changed';
  exception when insufficient_privilege then
    if sqlerrm <> 'groups.created_by cannot change' then raise; end if;
  end;
  begin
    update public.group_members set user_id = recipient_id
    where group_id = group_id_input and user_id = member_id_input;
    raise exception 'B2: membership identity changed';
  exception when insufficient_privilege then
    if sqlerrm <> 'group_members.user_id cannot change' then raise; end if;
  end;
end;
$$;
reset role;
select pg_temp.require(
  (select created_by = :'leader'::uuid from public.groups where id = :'group_id'),
  'B1: the original group owner is intact'
);
select pg_temp.require(
  exists (select 1 from public.group_members where group_id = :'group_id' and user_id = :'member'),
  'B2: the original membership is intact'
);
\echo PASS B1 and B2 identity protections

-- Use an invite for a fixture with no removal history to test the clock alone.
set role authenticated;
with inserted as (
  insert into public.group_invites
    (group_id, invited_user_id, invited_by, created_at, expires_at)
  values (:'group_id', :'recipient', :'leader', now() + interval '1 day',
          now() + interval '8 days')
  returning created_at, expires_at
)
select pg_temp.require(
  (select created_at = now() and expires_at = created_at + interval '7 days' from inserted),
  'P7c: client timestamp and maximum expiry use the server clock'
);

with inserted as (
  insert into public.group_invites (group_id, invited_email, invited_by, expires_at)
  values (:'group_id', 'short@example.test', :'leader', now() + interval '1 day')
  returning created_at, expires_at
)
select pg_temp.require(
  (select created_at = now() and expires_at = now() + interval '1 day' from inserted),
  'P7c: shorter expiry is preserved'
);
reset role;

-- Anon has no invite insert grant. Exercise the role branch on a temporary
-- test table without changing permissions on the application table.
create temp table p7c_timestamp_probe (created_at timestamptz, expires_at timestamptz);
create trigger timestamp_probe before insert on p7c_timestamp_probe
for each row execute function public.set_group_invite_insert_timestamps();
grant insert, select on p7c_timestamp_probe to anon;
set role anon;
with inserted as (
  insert into p7c_timestamp_probe values (now() + interval '1 day', now() + interval '8 days')
  returning *
)
select pg_temp.require(
  (select created_at = now() and expires_at = now() + interval '7 days' from inserted),
  'P7c: anon timestamp branch'
);
reset role;

-- Supabase's trusted writer can insert historical fixture rows.
grant insert, select on public.group_invites to service_role;
set role service_role;
with inserted as (
  insert into public.group_invites
    (group_id, invited_email, invited_by, created_at, expires_at)
  values (:'group_id', 'historical@example.test', :'leader', now() - interval '2 days',
          now() + interval '20 days')
  returning created_at, expires_at
)
select pg_temp.require(
  (select created_at = now() - interval '2 days' and expires_at = now() + interval '20 days' from inserted),
  'P7c: service writes preserve both timestamps'
);
reset role;
set role service_role;
insert into public.group_invites
  (group_id, invited_user_id, invited_by, created_at, expires_at)
values (:'restore_group', :'recipient', :'leader', now() - interval '2 days',
        now() + interval '20 days')
returning created_at as historical_created, expires_at as historical_expires \gset
reset role;

set role authenticated;
select (public.delete_group_with_backup(:'restore_group')).id as restore_backup \gset
select public.restore_group_from_backup(:'restore_backup') is not null;
reset role;
select pg_temp.require(
  exists (
    select 1 from public.group_invites as invite
    join public.groups as restored on restored.id = invite.group_id
    where restored.name = 'P7c restore clock fixture'
      and restored.id <> :'restore_group'
      and invite.invited_user_id = :'recipient'
      and invite.created_at = :'historical_created'
      and invite.expires_at = :'historical_expires'
  ),
  'P7c: backup RPC restores both timestamps while called by authenticated'
);
\echo PASS P7c client clock, expiry cap, service write, and restore

-- Use actual single-transaction group and account RPCs for B3.
select set_config('request.jwt.claims', jsonb_build_object('sub', :'withdrawing')::text, false);
set role authenticated;
select (public.delete_group_with_backup(:'backup_group')).id as detached_backup \gset
reset role;
insert into public.user_backups (user_id, label) values (:'withdrawing', 'P7c test') returning id as user_backup \gset
select pg_temp.require(
  (select group_id is null and created_by = :'withdrawing'::uuid
   from public.group_backups where id = :'detached_backup'),
  'B3: group deletion retains the detached backup'
);
set role service_role;
select pg_temp.require(
  (select success from public.delete_user_account(:'withdrawing')),
  'B3: account withdrawal succeeds'
);
reset role;
select pg_temp.require(
  not exists (select 1 from public.user_backups where id = :'user_backup')
  and not exists (select 1 from public.group_backups where id = :'detached_backup')
  and not exists (select 1 from public.users where id = :'withdrawing'),
  'B3: account withdrawal removes its owned backups and public profile'
);
\echo PASS B3 group backup detachment and owned backup cleanup

-- Capture a normal invite before group removal for the historical-row fixture.
select set_config('request.jwt.claims', jsonb_build_object('sub', :'leader')::text, false);
set role authenticated;
insert into public.group_invites (group_id, invited_user_id, invited_by)
values (:'group_id', :'member', :'leader')
returning id as old_invite, created_at as issued_at, expires_at as until_at \gset

select public.remove_group_member(:'group_id', :'member');
reset role;
select pg_temp.require(
  (select status = 'cancelled' from public.group_invites where id = :'old_invite'),
  'B4: removal cancels existing invites'
);

-- Trusted fixture models historical pending invite data restored after a removal.
set role service_role;
insert into public.group_invites
  (group_id, invited_user_id, invited_by, created_at, expires_at)
values (:'group_id', :'member', :'leader', :'issued_at', :'until_at')
returning id as restored_invite \gset
reset role;
select set_config('request.jwt.claims', jsonb_build_object('sub', :'member')::text, false);
select set_config('p7c.restored_invite', :'restored_invite', false);
set role authenticated;
do $$
begin
  begin
    perform public.accept_group_invite(current_setting('p7c.restored_invite')::uuid);
    raise exception 'B4: old invite was accepted';
  exception when raise_exception then
    if sqlerrm <> '강퇴 후 새로 발급된 초대가 필요합니다.' then raise; end if;
  end;
end;
$$;
reset role;

-- Leave the historical row terminal and send a new invitation as the leader.
update public.group_invites set status = 'cancelled' where id = :'restored_invite';
select set_config('request.jwt.claims', jsonb_build_object('sub', :'leader')::text, false);
set role authenticated;
insert into public.group_invites (group_id, invited_user_id, invited_by)
values (:'group_id', :'member', :'leader') returning id as fresh_invite \gset

select set_config('request.jwt.claims', jsonb_build_object('sub', :'member')::text, false);
select public.accept_group_invite(:'fresh_invite');
reset role;
select pg_temp.require(
  (select status = 'active' and not requires_explicit_reinvite
   from public.group_members where group_id = :'group_id' and user_id = :'member'),
  'B4: a freshly issued invite reactivates the member'
);
\echo PASS B4 stale invite declined and fresh invite accepted
