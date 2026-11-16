-- B1: Only backups created by the server RPCs can be restored.
-- Retain historical snapshots and check restored references and event links.
begin;

-- The link guard records these fields. Define them before installing restore
-- so backups without metadata retain the existing legacy actor behavior.
alter table public.group_members
  add column if not exists requires_explicit_reinvite boolean not null default false;
alter table public.group_backups
  add column if not exists reinvite_required_user_ids uuid[] not null default '{}'::uuid[];

-- Historical snapshot rows are preserved but never granted provenance retroactively.
alter table public.group_backups
  add column if not exists created_by_backup_rpc boolean not null default false;

revoke insert, update, delete on table public.group_backups from authenticated;
revoke insert, update, delete on table public.group_backups from public, anon;
revoke truncate, references, trigger on table public.group_backups from public, anon, authenticated;
grant select on table public.group_backups to authenticated;

drop policy if exists "group_backups_insert_leader" on public.group_backups;
drop policy if exists "group_backups_update_restore_leader" on public.group_backups;
drop policy if exists "group_backups_update_owner" on public.group_backups;
drop policy if exists "group_backups_delete_owner" on public.group_backups;

create or replace function public.prevent_group_backup_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Permit only the foreign keys' detachments when their parent rows are deleted.
  if (
       new.group_id is distinct from old.group_id
       and not (
         new.group_id is null
         and pg_trigger_depth() > 1
         and not exists (select 1 from public.groups where id = old.group_id)
       )
     )
    or (
      new.created_by is distinct from old.created_by
      and not (
        new.created_by is null
        and pg_trigger_depth() > 1
        and not exists (select 1 from public.users where id = old.created_by)
      )
    )
    or new.backup_type is distinct from old.backup_type
    or new.snapshot is distinct from old.snapshot
    or new.created_at is distinct from old.created_at
    or new.created_by_backup_rpc is distinct from old.created_by_backup_rpc
  then
    raise exception 'group_backups immutable fields cannot change';
  end if;

  return new;
end;
$$;

revoke execute on function public.prevent_group_backup_immutable_changes()
  from public, anon, authenticated;

drop trigger if exists group_backups_prevent_immutable_changes on public.group_backups;
create trigger group_backups_prevent_immutable_changes
  before update on public.group_backups
  for each row execute function public.prevent_group_backup_immutable_changes();

create or replace function public.archive_group_with_backup(group_id_input uuid)
returns public.group_backups
language plpgsql
security definer
set search_path = public, pg_temp
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
            'display_name', group_members.display_name,
            'joined_at', group_members.joined_at,
            'created_at', group_members.created_at,
            'updated_at', group_members.updated_at
          )
        )
        from public.group_members
        where group_members.group_id = group_row.id
          and group_members.status = 'active'
      ),
      '[]'::jsonb
    ),
    'all_members',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'user_id', group_members.user_id,
            'role', group_members.role,
            'display_name', group_members.display_name,
            'status', group_members.status,
            'joined_at', group_members.joined_at,
            'removed_at', group_members.removed_at,
            'removed_by', group_members.removed_by,
            'created_at', group_members.created_at,
            'updated_at', group_members.updated_at
          )
        )
        from public.group_members
        where group_members.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'events',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_events))
        from public.group_events
        where group_events.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'event_reports',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_event_reports))
        from public.group_event_reports
        where group_event_reports.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'event_comments',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_event_comments))
        from public.group_event_comments
        where group_event_comments.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'role_delegations',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_role_delegations))
        from public.group_role_delegations
        where group_role_delegations.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'invites',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_invites))
        from public.group_invites
        where group_invites.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'personal_event_links',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'event_id', events.id,
            'group_event_id', events.group_event_id,
            'user_id', events.user_id
          )
        )
        from public.events
        where events.group_event_id in (
          select id from public.group_events where group_id = group_row.id
        )
      ),
      '[]'::jsonb
    )
  );

  insert into public.group_backups (
    group_id,
    backup_type,
    snapshot,
    created_by,
    created_at,
    created_by_backup_rpc
  )
  values (
    group_row.id,
    'archive',
    snapshot_payload,
    current_user_id,
    now(),
    true
  )
  returning * into backup_row;

  update public.group_invites
     set status = 'cancelled',
         cancelled_at = now(),
         acted_by = current_user_id
   where group_id = group_row.id
     and status = 'pending';

  update public.groups
     set status = 'archived',
         archived_at = now()
   where id = group_row.id;

  return backup_row;
end;
$$;

revoke execute on function public.archive_group_with_backup(uuid) from public, anon;
grant execute on function public.archive_group_with_backup(uuid) to authenticated;

create or replace function public.delete_group_with_backup(group_id_input uuid)
returns public.group_backups
language plpgsql
security definer
set search_path = public, pg_temp
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

  if not public.is_group_leader(group_row.id, current_user_id) then
    raise exception '팀 리더만 그룹을 삭제할 수 있습니다.';
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
            'display_name', group_members.display_name,
            'joined_at', group_members.joined_at,
            'created_at', group_members.created_at,
            'updated_at', group_members.updated_at
          )
        )
        from public.group_members
        where group_members.group_id = group_row.id
          and group_members.status = 'active'
      ),
      '[]'::jsonb
    ),
    'all_members',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'user_id', group_members.user_id,
            'role', group_members.role,
            'display_name', group_members.display_name,
            'status', group_members.status,
            'joined_at', group_members.joined_at,
            'removed_at', group_members.removed_at,
            'removed_by', group_members.removed_by,
            'created_at', group_members.created_at,
            'updated_at', group_members.updated_at
          )
        )
        from public.group_members
        where group_members.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'events',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_events))
        from public.group_events
        where group_events.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'event_reports',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_event_reports))
        from public.group_event_reports
        where group_event_reports.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'event_comments',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_event_comments))
        from public.group_event_comments
        where group_event_comments.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'role_delegations',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_role_delegations))
        from public.group_role_delegations
        where group_role_delegations.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'invites',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_invites))
        from public.group_invites
        where group_invites.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'personal_event_links',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'event_id', events.id,
            'group_event_id', events.group_event_id,
            'user_id', events.user_id
          )
        )
        from public.events
        where events.group_event_id in (
          select id from public.group_events where group_id = group_row.id
        )
      ),
      '[]'::jsonb
    )
  );

  insert into public.group_backups (
    group_id,
    backup_type,
    snapshot,
    created_by,
    created_at,
    created_by_backup_rpc
  )
  values (
    group_row.id,
    'delete',
    snapshot_payload,
    current_user_id,
    now(),
    true
  )
  returning * into backup_row;

  delete from public.groups where id = group_row.id;

  return backup_row;
end;
$$;

revoke execute on function public.delete_group_with_backup(uuid) from public, anon;
grant execute on function public.delete_group_with_backup(uuid) to authenticated;

create or replace function public.permanently_delete_backup(backup_id_input uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  backup_row public.group_backups%rowtype;
begin
  if current_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
    into backup_row
    from public.group_backups
   where id = backup_id_input
   for update;

  if not found then
    raise exception '백업을 찾을 수 없습니다.';
  end if;

  if backup_row.restored_at is not null then
    raise exception '이미 복원된 백업은 감사 보존을 위해 삭제할 수 없습니다.';
  end if;

  if backup_row.created_by is distinct from current_user_id then
    raise exception '본인 백업만 삭제할 수 있습니다.';
  end if;

  delete from public.group_backups where id = backup_row.id;
end;
$$;

revoke execute on function public.permanently_delete_backup(uuid) from public, anon;
grant execute on function public.permanently_delete_backup(uuid) to authenticated;

create or replace function public.restore_group_from_backup(backup_id_input uuid)
returns public.group_backups
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  backup_row public.group_backups%rowtype;
  snapshot_payload jsonb;
  group_record jsonb;
  snapshot_members jsonb;
  snapshot_creator_id uuid;
  restored_owner_id uuid;
  restored_member_id uuid;
  event_author_id uuid;
  new_group_id uuid;
  member_record jsonb;
  event_record jsonb;
  event_old_to_new jsonb := '{}'::jsonb;
  comment_record jsonb;
  delegation_record jsonb;
  invite_record jsonb;
  link_record jsonb;
  old_event_id text;
  old_event_id_text text;
  new_event_id uuid;
  insert_status text;
begin
  if current_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  -- Use the same user-before-backup lock order as account deletion.
  perform 1
    from public.users
   where id = current_user_id
   for key share;

  if not found then
    raise exception '사용자 프로필을 찾을 수 없습니다.';
  end if;

  select *
    into backup_row
    from public.group_backups
   where id = backup_id_input
   for update;

  if not found then
    raise exception '백업을 찾을 수 없습니다.';
  end if;

  if backup_row.restored_at is not null then
    raise exception '이미 복원된 백업입니다.';
  end if;

  if backup_row.created_by is distinct from current_user_id then
    raise exception '본인 백업만 복원할 수 있습니다.';
  end if;

  if not backup_row.created_by_backup_rpc then
    raise exception '출처를 확인할 수 없는 백업은 복원할 수 없습니다.';
  end if;

  snapshot_payload := backup_row.snapshot;

  group_record := snapshot_payload->'group';
  if group_record is null then
    raise exception '스냅샷에 그룹 정보가 없습니다.';
  end if;

  snapshot_members := coalesce(
    snapshot_payload->'all_members',
    snapshot_payload->'active_members',
    '[]'::jsonb
  );
  snapshot_creator_id := nullif(group_record->>'created_by', '')::uuid;
  restored_owner_id := current_user_id;
  -- An active co-leader can create a normal backup. Preserve the creator
  -- only when that user still exists and was recorded as an active leader.
  if exists (
    select 1
      from jsonb_array_elements(snapshot_members) as member(value)
      join public.users u on u.id = snapshot_creator_id
     where nullif(member.value->>'user_id', '')::uuid = u.id
       and member.value->>'role' = 'leader'
       and coalesce(member.value->>'status', 'active') = 'active'
  ) then
    restored_owner_id := snapshot_creator_id;
  end if;

  insert into public.groups (
    id,
    name,
    description,
    created_by,
    status,
    archived_at,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    group_record->>'name',
    group_record->>'description',
    restored_owner_id,
    'active',
    null,
    coalesce((group_record->>'created_at')::timestamptz, now()),
    now()
  )
  returning id into new_group_id;

  for member_record in
    select jsonb_array_elements(snapshot_members)
  loop
    if coalesce(member_record->>'role', '') not in ('leader', 'member') then
      continue;
    end if;

    select u.id into restored_member_id
      from public.users u
     where u.id = nullif(member_record->>'user_id', '')::uuid;
    if not found then
      continue;
    end if;

    insert into public.group_members (
      group_id,
      user_id,
      role,
      display_name,
      status,
      joined_at,
      removed_at,
      removed_by,
      requires_explicit_reinvite,
      created_at,
      updated_at
    )
    values (
      new_group_id,
      restored_member_id,
      member_record->>'role',
      member_record->>'display_name',
      coalesce(member_record->>'status', 'active'),
      coalesce((member_record->>'joined_at')::timestamptz, now()),
      (member_record->>'removed_at')::timestamptz,
      (select u.id from public.users u
        where u.id = nullif(member_record->>'removed_by', '')::uuid),
      restored_member_id = any(backup_row.reinvite_required_user_ids),
      coalesce((member_record->>'created_at')::timestamptz, now()),
      coalesce((member_record->>'updated_at')::timestamptz, now())
    )
    on conflict do nothing;
  end loop;

  insert into public.group_members (group_id, user_id, role, status)
  values (new_group_id, current_user_id, 'leader', 'active')
  on conflict (group_id, user_id) do update
     set role = 'leader',
         status = 'active',
         removed_at = null,
         removed_by = null,
         updated_at = now()
   where group_members.role <> 'leader' or group_members.status <> 'active';

  for event_record in
    select jsonb_array_elements(snapshot_payload->'events')
  loop
    old_event_id := event_record->>'id';
    select u.id into event_author_id
      from public.users u
     where u.id = nullif(event_record->>'created_by', '')::uuid;
    insert into public.group_events (
      id,
      group_id,
      title,
      description,
      location,
      start_at,
      end_at,
      all_day,
      is_multi_day,
      is_critical,
      use_strong_alarm,
      recurrence_rule,
      recurrence_type,
      recurrence_until,
      created_by,
      updated_by,
      cancelled_at,
      cancelled_by,
      personal_event_id,
      status,
      created_at,
      updated_at
    )
    values (
      gen_random_uuid(),
      new_group_id,
      event_record->>'title',
      event_record->>'description',
      event_record->>'location',
      (event_record->>'start_at')::timestamptz,
      (event_record->>'end_at')::timestamptz,
      coalesce((event_record->>'all_day')::boolean, false),
      coalesce((event_record->>'is_multi_day')::boolean, false),
      coalesce((event_record->>'is_critical')::boolean, false),
      coalesce((event_record->>'use_strong_alarm')::boolean, false),
      event_record->>'recurrence_rule',
      coalesce(event_record->>'recurrence_type', 'none'),
      (event_record->>'recurrence_until')::timestamptz,
      event_author_id,
      (select u.id from public.users u
        where u.id = nullif(event_record->>'updated_by', '')::uuid),
      (event_record->>'cancelled_at')::timestamptz,
      (select u.id from public.users u
        where u.id = nullif(event_record->>'cancelled_by', '')::uuid),
      (select e.id
         from public.events e
         join public.group_members m
           on m.group_id = new_group_id and m.user_id = e.user_id
        where e.id = nullif(event_record->>'personal_event_id', '')::uuid
          and e.user_id = event_author_id),
      coalesce(event_record->>'status', 'active'),
      coalesce((event_record->>'created_at')::timestamptz, now()),
      coalesce((event_record->>'updated_at')::timestamptz, now())
    )
    returning id into new_event_id;

    event_old_to_new := jsonb_set(
      event_old_to_new,
      array[old_event_id],
      to_jsonb(new_event_id)
    );
  end loop;

  for link_record in
    select jsonb_array_elements(snapshot_payload->'personal_event_links')
  loop
    if (event_old_to_new ? (link_record->>'group_event_id')) then
      update public.events
         set group_event_id = (event_old_to_new->>(link_record->>'group_event_id'))::uuid
       where id = (link_record->>'event_id')::uuid
         and (group_event_id is null
              or group_event_id = (link_record->>'group_event_id')::uuid)
         and exists (
           select 1 from public.group_members m
            where m.group_id = new_group_id and m.user_id = events.user_id
         );
    end if;
  end loop;

  for old_event_id_text in
    select jsonb_object_keys(event_old_to_new)
  loop
    new_event_id := (event_old_to_new->>old_event_id_text)::uuid;
    update public.group_events ge
       set personal_event_id = coalesce(
         ge.personal_event_id,
         (
           select id from public.events
           where group_event_id = new_event_id
           limit 1
         )
       )
     where ge.id = new_event_id;
  end loop;

  for comment_record in
    select jsonb_array_elements(snapshot_payload->'event_reports')
  loop
    if (event_old_to_new ? (comment_record->>'group_event_id'))
       and exists (
         select 1 from public.users u
          where u.id = nullif(comment_record->>'reporter_id', '')::uuid
       ) then
      insert into public.group_event_reports (
        id,
        reporter_id,
        group_event_id,
        group_id,
        reason,
        detail,
        status,
        content_owner_id,
        created_at
      )
      values (
        gen_random_uuid(),
        (comment_record->>'reporter_id')::uuid,
        (event_old_to_new->>(comment_record->>'group_event_id'))::uuid,
        new_group_id,
        comment_record->>'reason',
        comment_record->>'detail',
        coalesce(comment_record->>'status', 'new'),
        (select u.id from public.users u
          where u.id = nullif(comment_record->>'content_owner_id', '')::uuid),
        coalesce((comment_record->>'created_at')::timestamptz, now())
      )
      on conflict do nothing;
    end if;
  end loop;

  for comment_record in
    select jsonb_array_elements(snapshot_payload->'event_comments')
  loop
    if (event_old_to_new ? (comment_record->>'group_event_id'))
       and exists (
         select 1 from public.users u
          where u.id = nullif(comment_record->>'target_user_id', '')::uuid
       ) then
      insert into public.group_event_comments (
        id,
        group_event_id,
        group_id,
        author_user_id,
        target_user_id,
        content,
        confirmed_at,
        created_at,
        updated_at
      )
      values (
        gen_random_uuid(),
        (event_old_to_new->>(comment_record->>'group_event_id'))::uuid,
        new_group_id,
        (select u.id from public.users u
          where u.id = nullif(comment_record->>'author_user_id', '')::uuid),
        (comment_record->>'target_user_id')::uuid,
        comment_record->>'content',
        (comment_record->>'confirmed_at')::timestamptz,
        coalesce((comment_record->>'created_at')::timestamptz, now()),
        coalesce((comment_record->>'updated_at')::timestamptz, now())
      )
      on conflict do nothing;
    end if;
  end loop;

  for delegation_record in
    select jsonb_array_elements(snapshot_payload->'role_delegations')
  loop
    if not exists (
      select 1 from public.users u
       where u.id = nullif(delegation_record->>'delegate_user_id', '')::uuid
    ) then
      continue;
    end if;

    insert into public.group_role_delegations (
      id,
      group_id,
      delegator_user_id,
      delegate_user_id,
      permissions,
      starts_at,
      ends_at,
      status,
      cancelled_at,
      cancelled_by,
      created_at,
      updated_at
    )
    values (
      gen_random_uuid(),
      new_group_id,
      (select u.id from public.users u
        where u.id = nullif(delegation_record->>'delegator_user_id', '')::uuid),
      (delegation_record->>'delegate_user_id')::uuid,
      coalesce(delegation_record->'permissions', '[]'::jsonb),
      (delegation_record->>'starts_at')::timestamptz,
      (delegation_record->>'ends_at')::timestamptz,
      coalesce(delegation_record->>'status', 'active'),
      (delegation_record->>'cancelled_at')::timestamptz,
      (select u.id from public.users u
        where u.id = nullif(delegation_record->>'cancelled_by', '')::uuid),
      coalesce((delegation_record->>'created_at')::timestamptz, now()),
      coalesce((delegation_record->>'updated_at')::timestamptz, now())
    )
    on conflict do nothing;
  end loop;

  for invite_record in
    select jsonb_array_elements(snapshot_payload->'invites')
  loop
    insert_status := invite_record->>'status';
    if insert_status is null or insert_status not in ('pending', 'accepted')
       -- A pending invite must keep its original age for the removal cutoff.
       or (
         insert_status = 'pending'
         and nullif(invite_record->>'created_at', '') is null
       )
       -- Detached invite history stays in the snapshot and cannot reactivate.
       or num_nonnulls(
         nullif(invite_record->>'invited_user_id', ''),
         invite_record->>'invited_email',
         invite_record->>'invited_invite_code'
       ) <> 1
       or not exists (
         select 1 from public.users u
          where u.id = nullif(invite_record->>'invited_by', '')::uuid
       )
       or (
         nullif(invite_record->>'invited_user_id', '') is not null
         and not exists (
           select 1 from public.users u
            where u.id = (invite_record->>'invited_user_id')::uuid
         )
       ) then
      continue;
    end if;

    insert into public.group_invites (
      id,
      group_id,
      invited_user_id,
      invited_email,
      invited_invite_code,
      invited_by,
      status,
      expires_at,
      accepted_at,
      rejected_at,
      cancelled_at,
      expired_at,
      acted_by,
      created_at,
      updated_at
    )
    values (
      gen_random_uuid(),
      new_group_id,
      nullif(invite_record->>'invited_user_id', '')::uuid,
      invite_record->>'invited_email',
      invite_record->>'invited_invite_code',
      (invite_record->>'invited_by')::uuid,
      insert_status,
      coalesce((invite_record->>'expires_at')::timestamptz, now() + interval '7 days'),
      (invite_record->>'accepted_at')::timestamptz,
      (invite_record->>'rejected_at')::timestamptz,
      (invite_record->>'cancelled_at')::timestamptz,
      (invite_record->>'expired_at')::timestamptz,
      (select u.id from public.users u
        where u.id = nullif(invite_record->>'acted_by', '')::uuid),
      coalesce((invite_record->>'created_at')::timestamptz, now()),
      coalesce((invite_record->>'updated_at')::timestamptz, now())
    )
    on conflict do nothing;
  end loop;

  update public.group_backups
     set restored_at = now(),
         restored_by = current_user_id
   where id = backup_row.id
   returning * into backup_row;

  return backup_row;
exception
  when others then
    raise exception 'restore_group_from_backup failed: %', sqlerrm;
end;
$$;

revoke execute on function public.restore_group_from_backup(uuid) from public, anon;
grant execute on function public.restore_group_from_backup(uuid) to authenticated;

commit;
