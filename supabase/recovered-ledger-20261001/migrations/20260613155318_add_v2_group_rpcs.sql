begin;

create or replace function public.is_group_member(group_id_input uuid, user_id_input uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.group_members gm
    where gm.group_id = group_id_input
      and gm.user_id = user_id_input
      and gm.status = 'active'
  );
$$;

create or replace function public.is_group_leader(group_id_input uuid, user_id_input uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.group_members gm
    where gm.group_id = group_id_input
      and gm.user_id = user_id_input
      and gm.role = 'leader'
      and gm.status = 'active'
  );
$$;

create or replace function public.has_group_delegated_permission(group_id_input uuid, user_id_input uuid, permission_input text)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.group_role_delegations grd
    where grd.group_id = group_id_input
      and grd.delegate_user_id = user_id_input
      and grd.status = 'active'
      and grd.starts_at <= now()
      and grd.ends_at > now()
      and grd.permissions ? permission_input
  );
$$;

create or replace function public.accept_group_invite(invite_id_input uuid)
returns uuid
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_user public.users%rowtype;
  v_invite public.group_invites%rowtype;
  v_member_id uuid;
begin
  if v_user_id is null then
    raise exception 'authentication required';
  end if;

  select * into v_user
  from public.users
  where id = v_user_id;

  if not found then
    raise exception 'current user not found';
  end if;

  select * into v_invite
  from public.group_invites
  where id = invite_id_input
  for update;

  if not found then
    raise exception 'invite not found';
  end if;

  if v_invite.status <> 'pending' then
    raise exception 'invite is not pending';
  end if;

  if v_invite.expires_at <= now() then
    update public.group_invites
    set status = 'expired',
        expired_at = coalesce(expired_at, now()),
        acted_by = v_user_id,
        updated_at = now()
    where id = v_invite.id;
    raise exception 'invite expired';
  end if;

  if not (
    (v_invite.invited_user_id is not null and v_invite.invited_user_id = v_user_id)
    or (v_invite.invited_email is not null and v_user.email is not null and lower(v_invite.invited_email) = lower(v_user.email))
    or (v_invite.invited_invite_code is not null and v_user.invite_code is not null and v_invite.invited_invite_code = v_user.invite_code)
  ) then
    raise exception 'invite target mismatch';
  end if;

  if exists (
    select 1
    from public.group_members gm
    where gm.group_id = v_invite.group_id
      and gm.user_id = v_user_id
      and gm.status = 'active'
  ) then
    raise exception 'already active member';
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
  ) values (
    v_invite.group_id,
    v_user_id,
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
        joined_at = excluded.joined_at,
        removed_at = null,
        removed_by = null,
        updated_at = now()
  returning id into v_member_id;

  update public.group_invites
  set status = 'accepted',
      accepted_at = now(),
      acted_by = v_user_id,
      updated_at = now()
  where id = v_invite.id;

  return v_member_id;
end;
$$;

create or replace function public.archive_group_with_backup(group_id_input uuid)
returns uuid
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_group public.groups%rowtype;
  v_backup_id uuid;
  v_snapshot jsonb;
begin
  if v_user_id is null then
    raise exception 'authentication required';
  end if;

  select * into v_group
  from public.groups
  where id = group_id_input
  for update;

  if not found then
    raise exception 'group not found';
  end if;

  if v_group.status <> 'active' then
    raise exception 'group is not active';
  end if;

  if not public.is_group_leader(group_id_input, v_user_id) then
    raise exception 'leader permission required';
  end if;

  v_snapshot := jsonb_build_object(
    'group', to_jsonb(v_group),
    'members', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from public.group_members m where m.group_id = v_group.id), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at) from public.group_invites i where i.group_id = v_group.id), '[]'::jsonb),
    'delegations', coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at) from public.group_role_delegations d where d.group_id = v_group.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.start_at) from public.group_events e where e.group_id = v_group.id), '[]'::jsonb)
  );

  insert into public.group_backups (
    group_id,
    backup_type,
    snapshot,
    created_by,
    created_at,
    restored_at,
    restored_by
  ) values (
    v_group.id,
    'archive',
    v_snapshot,
    v_user_id,
    now(),
    null,
    null
  )
  returning id into v_backup_id;

  update public.groups
  set status = 'archived',
      archived_at = now(),
      updated_at = now()
  where id = v_group.id;

  return v_backup_id;
end;
$$;

create or replace function public.remove_group_member(group_id_input uuid, member_user_id_input uuid)
returns uuid
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_target public.group_members%rowtype;
  v_active_leader_count integer;
begin
  if v_user_id is null then
    raise exception 'authentication required';
  end if;

  if v_user_id = member_user_id_input then
    raise exception 'self removal is not allowed';
  end if;

  if not public.is_group_leader(group_id_input, v_user_id) then
    raise exception 'leader permission required';
  end if;

  select * into v_target
  from public.group_members
  where group_id = group_id_input
    and user_id = member_user_id_input
  for update;

  if not found then
    raise exception 'member not found';
  end if;

  if v_target.status <> 'active' then
    raise exception 'member is not active';
  end if;

  if v_target.role = 'leader' then
    select count(*) into v_active_leader_count
    from public.group_members gm
    where gm.group_id = group_id_input
      and gm.role = 'leader'
      and gm.status = 'active';

    if v_active_leader_count <= 1 then
      raise exception 'last leader cannot be removed';
    end if;
  end if;

  update public.group_members
  set status = 'removed',
      removed_at = now(),
      removed_by = v_user_id,
      updated_at = now()
  where id = v_target.id;

  return v_target.id;
end;
$$;

commit;;
