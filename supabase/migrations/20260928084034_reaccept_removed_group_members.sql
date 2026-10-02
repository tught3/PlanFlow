-- Explicit group-invite acceptance must reactivate the user's existing
-- soft-removed membership row instead of failing the unique(group_id,user_id)
-- constraint. Keep the row id and original created_at as membership history.
-- The checked-in pre-migration schema returned a composite group_invites row,
-- while production returns the membership UUID. PostgreSQL cannot change a
-- function's return type with CREATE OR REPLACE. Drop only this overload,
-- without CASCADE, so unexpected dependencies fail the migration safely.
drop function if exists public.accept_group_invite(uuid);

create function public.accept_group_invite(invite_id_input uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  invite_row public.group_invites%rowtype;
  locked_group public.groups%rowtype;
  invite_group_id uuid;
  member_id uuid;
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  -- Archive/delete lock the group row before changing its invites. Use the
  -- same group -> invite order here to avoid a lock inversion. This first
  -- lookup only discovers the group id; all authorization/state checks happen
  -- again after both rows are locked.
  select group_id
    into invite_group_id
    from public.group_invites
   where id = invite_id_input;

  if not found then
    raise exception 'group invite not found';
  end if;

  select *
    into locked_group
    from public.groups
   where id = invite_group_id
   for update;

  if not found then
    raise exception '초대된 그룹을 찾을 수 없습니다.';
  end if;

  select *
    into invite_row
    from public.group_invites
   where id = invite_id_input
   for update;

  if not found or invite_row.group_id is distinct from invite_group_id then
    raise exception 'group invite not found';
  end if;

  if locked_group.status <> 'active' then
    raise exception '활성화된 그룹만 초대 수락이 가능합니다.';
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

  if exists (
    select 1
      from public.group_members
     where group_id = invite_row.group_id
       and user_id = current_user_id
       and status = 'active'
  ) then
    raise exception '이미 활성 멤버입니다.';
  end if;

  -- This stays atomic: any later membership failure rolls the invite update
  -- back with the membership write.
  update public.group_invites
     set status = 'accepted',
         accepted_at = now(),
         acted_by = current_user_id
   where id = invite_row.id;

  if not found then
    raise exception '초대 수락 상태를 갱신할 수 없습니다.';
  end if;

  -- Do not combine this with INSERT ... ON CONFLICT: the latter applies the
  -- INSERT WITH CHECK policy even when it takes the conflict-update branch.
  -- Explicitly update the removed row or insert a genuinely new membership.
  update public.group_members
     set role = 'member',
         status = 'active',
         joined_at = now(),
         removed_at = null,
         removed_by = null,
         updated_at = now()
   where group_id = invite_row.group_id
     and user_id = current_user_id
     and status = 'removed'
  returning id into member_id;

  if member_id is null then
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
      current_user_id,
      'member',
      'active',
      now(),
      now(),
      now()
    )
    returning id into member_id;
  end if;

  if member_id is null then
    raise exception '이미 활성 멤버입니다.';
  end if;

  return member_id;
end;
$$;

revoke all on function public.accept_group_invite(uuid) from public;
revoke all on function public.accept_group_invite(uuid) from anon;
grant execute on function public.accept_group_invite(uuid) to authenticated;
grant execute on function public.accept_group_invite(uuid) to service_role;

-- The invitee can inspect only the active group named by their own pending
-- invite. The invite SELECT policy uses the SECURITY DEFINER membership helper
-- for its leader branch, avoiding groups<->invites RLS recursion.
drop policy if exists "groups_select_member" on public.groups;
create policy "groups_select_member"
  on public.groups
  for select
  using (
    (status = 'active' and public.is_group_member(id, auth.uid()))
    or (status = 'archived' and created_by = auth.uid())
    or (
      status = 'active'
      and exists (
        select 1 from public.group_invites
         where group_invites.group_id = groups.id
           and group_invites.status = 'pending'
           and public.is_group_invite_target(
             group_invites.invited_user_id,
             group_invites.invited_email,
             group_invites.invited_invite_code
           )
      )
    )
  );

-- The invitee still needs read access to their own pending/accepted invite.
-- Membership mutation itself is confined to the validated SECURITY DEFINER RPC
-- above so Postgres does not apply INSERT RLS before an ON CONFLICT path.
drop policy if exists "group_invites_select_access" on public.group_invites;
create policy "group_invites_select_access"
  on public.group_invites
  for select
  using (
    public.is_group_leader(group_invites.group_id, auth.uid())
    or invited_by = auth.uid()
    or (
      status in ('pending', 'accepted')
      and public.is_group_invite_target(
        invited_user_id, invited_email, invited_invite_code
      )
    )
  );

drop policy if exists "group_members_insert_leader" on public.group_members;
create policy "group_members_insert_leader"
  on public.group_members
  for insert
  with check (
    role = 'member'
    and status = 'active'
    and removed_at is null
    and removed_by is null
    and (
      exists (
        select 1 from public.groups
         where groups.id = group_members.group_id
           and groups.status = 'active'
           and public.is_group_leader(groups.id, auth.uid())
      )
      or (
        user_id = auth.uid()
        and exists (
          select 1 from public.group_invites
           where group_invites.group_id = group_members.group_id
             and group_invites.status = 'accepted'
             and group_invites.acted_by = auth.uid()
             and public.is_group_invite_target(
               group_invites.invited_user_id,
               group_invites.invited_email,
               group_invites.invited_invite_code
             )
        )
      )
    )
  );

drop policy if exists "group_members_select_self_invite_reactivation"
  on public.group_members;
drop policy if exists "group_members_update_self_invite_reactivation"
  on public.group_members;
