-- B4: Keep explicit re-invitations, block removed members on shared links,
-- and rotate the token on removal. The groups row lock orders both actions.
begin;

create or replace function public.protect_member_reinvite_requirement()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Explicit reactivation starts a new membership period.
  if new.status <> 'removed' then
    new.requires_explicit_reinvite := false;
  elsif tg_op = 'UPDATE' then
    if old.status = 'removed' then
      -- Account deletion can clear removed_by via ON DELETE SET NULL.
      -- Preserve only known removals; old actor-less rows keep their policy.
      new.requires_explicit_reinvite := old.requires_explicit_reinvite
        or coalesce(old.removed_by <> old.user_id, false);
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.protect_member_reinvite_requirement() from public;

drop trigger if exists group_members_protect_reinvite_requirement on public.group_members;
create trigger group_members_protect_reinvite_requirement
  before insert or update on public.group_members
  for each row execute function public.protect_member_reinvite_requirement();

create or replace function public.capture_backup_reinvite_requirements()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    new.reinvite_required_user_ids := old.reinvite_required_user_ids;
    return new;
  end if;

  -- Archive and delete create the backup while the live group still exists.
  -- Keep this metadata separate from historical client-written snapshot JSON.
  new.reinvite_required_user_ids := array(
    select member.user_id
      from public.group_members as member
     where member.group_id = new.group_id
       and member.status = 'removed'
       and (member.requires_explicit_reinvite or member.removed_by <> member.user_id)
     order by member.user_id
  );
  return new;
end;
$$;

revoke execute on function public.capture_backup_reinvite_requirements() from public;

drop trigger if exists group_backups_capture_reinvite_requirements on public.group_backups;
create trigger group_backups_capture_reinvite_requirements
  before insert or update of reinvite_required_user_ids on public.group_backups
  for each row execute function public.capture_backup_reinvite_requirements();

create or replace function public.accept_group_invite_link(
  group_id_input uuid,
  invite_token_input text
)
returns public.group_invites
language plpgsql
security definer
set search_path = public, pg_temp
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
     and status = 'active'
   for update;

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

  -- A recorded kick requires an explicit invitation even if its actor was
  -- deleted. Legacy rows with no marker still use the original actor check.
  if exists (
    select 1
      from public.group_members
     where group_id = group_row.id
       and user_id = auth.uid()
       and status = 'removed'
       and (
         requires_explicit_reinvite
         or (removed_by is not null and removed_by <> auth.uid())
       )
  ) then
    raise exception '리더의 초대가 필요합니다.';
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

create or replace function public.remove_group_member(
  group_id_input uuid,
  member_user_id_input uuid
)
returns public.group_members
language plpgsql
security definer
set search_path = public, pg_temp
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
         requires_explicit_reinvite = true,
         updated_at = now()
   where id = target_member.id
   returning * into updated_member;

  -- Rotate the link while holding the same group lock used for joining.
  update public.groups
     set invite_token = default
   where id = group_row.id;

  return updated_member;
end;
$$;

commit;
