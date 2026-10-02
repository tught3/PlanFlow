begin;

drop policy if exists groups_select_owner on public.groups;
drop policy if exists groups_insert_owner on public.groups;
drop policy if exists groups_update_owner on public.groups;

drop policy if exists group_members_select_owner on public.group_members;
drop policy if exists group_members_insert_owner on public.group_members;
drop policy if exists group_members_update_owner on public.group_members;

create policy groups_select_active_members
on public.groups
for select
to authenticated
using (
  status = 'active'
  and public.is_group_member(id, auth.uid())
);

create policy groups_insert_owner
on public.groups
for insert
to authenticated
with check (
  created_by = auth.uid()
  and status = 'active'
);

create policy groups_update_leader
on public.groups
for update
to authenticated
using (
  public.is_group_leader(id, auth.uid())
)
with check (
  public.is_group_leader(id, auth.uid())
);

create policy group_members_select_group_visible
on public.group_members
for select
to authenticated
using (
  public.is_group_member(group_id, auth.uid())
  or public.is_group_leader(group_id, auth.uid())
);

create policy group_members_insert_leader_or_invited_self
on public.group_members
for insert
to authenticated
with check (
  public.is_group_leader(group_id, auth.uid())
  or (
    user_id = auth.uid()
    and exists (
      select 1
      from public.group_invites i
      where i.group_id = group_members.group_id
        and i.status = 'pending'
        and i.expires_at > now()
        and (
          (i.invited_user_id is not null and i.invited_user_id = auth.uid())
          or (
            i.invited_email is not null
            and exists (
              select 1
              from public.users u
              where u.id = auth.uid()
                and lower(u.email) = lower(i.invited_email)
            )
          )
          or (
            i.invited_invite_code is not null
            and exists (
              select 1
              from public.users u
              where u.id = auth.uid()
                and u.invite_code = i.invited_invite_code
            )
          )
        )
    )
  )
);

create policy group_members_update_leader_or_invited_self
on public.group_members
for update
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
  or (
    user_id = auth.uid()
    and exists (
      select 1
      from public.group_invites i
      where i.group_id = group_members.group_id
        and i.status = 'pending'
        and i.expires_at > now()
        and (
          (i.invited_user_id is not null and i.invited_user_id = auth.uid())
          or (
            i.invited_email is not null
            and exists (
              select 1
              from public.users u
              where u.id = auth.uid()
                and lower(u.email) = lower(i.invited_email)
            )
          )
          or (
            i.invited_invite_code is not null
            and exists (
              select 1
              from public.users u
              where u.id = auth.uid()
                and u.invite_code = i.invited_invite_code
            )
          )
        )
    )
  )
)
with check (
  public.is_group_leader(group_id, auth.uid())
  or (
    user_id = auth.uid()
    and role = 'member'
    and status = 'active'
    and removed_at is null
    and removed_by is null
  )
);

create policy group_invites_select_related_users
on public.group_invites
for select
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
  or invited_by = auth.uid()
  or (
    invited_user_id = auth.uid()
    or (
      invited_email is not null
      and exists (
        select 1
        from public.users u
        where u.id = auth.uid()
          and lower(u.email) = lower(group_invites.invited_email)
      )
    )
    or (
      invited_invite_code is not null
      and exists (
        select 1
        from public.users u
        where u.id = auth.uid()
          and u.invite_code = group_invites.invited_invite_code
      )
    )
  )
);

create policy group_invites_insert_leader_only
on public.group_invites
for insert
to authenticated
with check (
  public.is_group_leader(group_id, auth.uid())
);

create policy group_invites_update_leader_or_target
on public.group_invites
for update
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
  or invited_by = auth.uid()
  or invited_user_id = auth.uid()
  or (
    invited_email is not null
    and exists (
      select 1
      from public.users u
      where u.id = auth.uid()
        and lower(u.email) = lower(group_invites.invited_email)
    )
  )
  or (
    invited_invite_code is not null
    and exists (
      select 1
      from public.users u
      where u.id = auth.uid()
        and u.invite_code = group_invites.invited_invite_code
    )
  )
)
with check (
  (
    status = 'cancelled'
    and public.is_group_leader(group_id, auth.uid())
    and acted_by = auth.uid()
  )
  or (
    status in ('accepted', 'rejected')
    and acted_by = auth.uid()
  )
  or (
    status = 'expired'
    and acted_by = auth.uid()
  )
);

create policy group_role_delegations_select_related
on public.group_role_delegations
for select
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
  or delegator_user_id = auth.uid()
  or delegate_user_id = auth.uid()
);

create policy group_role_delegations_insert_leader_only
on public.group_role_delegations
for insert
to authenticated
with check (
  public.is_group_leader(group_id, auth.uid())
  and delegator_user_id = auth.uid()
  and status = 'active'
);

create policy group_role_delegations_update_cancel
on public.group_role_delegations
for update
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
  or delegator_user_id = auth.uid()
)
with check (
  status = 'cancelled'
  and cancelled_by = auth.uid()
);

create policy group_events_select_active_group_members
on public.group_events
for select
to authenticated
using (
  exists (
    select 1
    from public.groups g
    where g.id = group_events.group_id
      and g.status = 'active'
      and public.is_group_member(g.id, auth.uid())
  )
);

create policy group_events_insert_leader_or_delegate
on public.group_events
for insert
to authenticated
with check (
  (
    public.is_group_leader(group_id, auth.uid())
  )
  or public.has_group_delegated_permission(group_id, auth.uid(), 'create_group_event')
);

create policy group_events_update_leader_or_delegate
on public.group_events
for update
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
  or public.has_group_delegated_permission(group_id, auth.uid(), 'update_group_event')
  or public.has_group_delegated_permission(group_id, auth.uid(), 'cancel_group_event')
)
with check (
  public.is_group_leader(group_id, auth.uid())
  or public.has_group_delegated_permission(group_id, auth.uid(), 'update_group_event')
  or public.has_group_delegated_permission(group_id, auth.uid(), 'cancel_group_event')
);

create policy group_events_delete_leader_or_delegate
on public.group_events
for delete
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
  or public.has_group_delegated_permission(group_id, auth.uid(), 'cancel_group_event')
);

create policy group_backups_select_leader_only
on public.group_backups
for select
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
);

create policy group_backups_insert_leader_only
on public.group_backups
for insert
to authenticated
with check (
  public.is_group_leader(group_id, auth.uid())
  and created_by = auth.uid()
);

create policy group_backups_update_leader_only
on public.group_backups
for update
to authenticated
using (
  public.is_group_leader(group_id, auth.uid())
)
with check (
  public.is_group_leader(group_id, auth.uid())
);

commit;;
