-- PlanFlow 1차 BM: 그룹 백업/복원/영구삭제 RPC + RLS 보강
-- 1) archive_group_with_backup 스냅샷에 group_events/comments/delegations/invites 추가
-- 2) restore_group_from_backup 신규 (트랜잭션, 새 group_id로 재생성)
-- 3) permanently_delete_backup 신규 (복원 안 한 백업만)
-- 4) delete_group_with_backup 신규 (archive(delete) 성공 후에만 원본 삭제)
-- 5) RLS: created_by 본인만 select/insert/update/delete (정책 일관성 보강)

set search_path = public;

-- ============================================================
-- 1) archive_group_with_backup 확장
--    스냅샷에 group_events, group_event_comments, group_role_delegations,
--    group_invites 포함. group_members는 display_name까지 포함.
-- ============================================================

create or replace function public.archive_group_with_backup(
  group_id_input uuid
)
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
            'left_at', group_members.left_at,
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
    -- events 테이블에서 group_event_id가 이 그룹 일정들을 가리키는 링크를 함께 저장
    -- (복원 시 events.group_event_id 재연결에 사용)
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

-- ============================================================
-- 2) delete_group_with_backup(group_id_input uuid)
--    archive(delete) 성공 후에만 delete_group_for_user 호출.
--    백업 실패 시 그룹 삭제하지 않음 (원자성 보장).
-- ============================================================

create or replace function public.delete_group_with_backup(
  group_id_input uuid
)
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

  if not public.is_group_leader(group_row.id, current_user_id) then
    raise exception '팀 리더만 그룹을 삭제할 수 있습니다.';
  end if;

  -- 기존 archive_group_with_backup을 호출하되 backup_type='delete'인 별도 백업을 직접 만든다
  -- (delete_group_with_backup은 그룹을 즉시 삭제해야 하므로 'archived' 마커를 찍지 않는다)
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
            'left_at', group_members.left_at,
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
    created_at
  )
  values (
    group_row.id,
    'delete',
    snapshot_payload,
    current_user_id,
    now()
  )
  returning * into backup_row;

  -- 백업 성공 후에만 원본 그룹 삭제
  delete from public.groups where id = group_row.id;

  return backup_row;
end;
$$;

grant execute on function public.delete_group_with_backup(uuid) to authenticated;

-- ============================================================
-- 3) restore_group_from_backup(backup_id_input uuid)
--    트랜잭션 내에서:
--      a) groups INSERT (새 id)
--      b) group_members INSERT (user_id 유지, 새 group_id, role/display_name 유지)
--      c) group_events INSERT (새 id, 새 group_id, personal_event_id 연결 끊김)
--      d) events.group_event_id → 새 group_event.id 재연결
--      e) group_event_comments INSERT (group_event_id 재매핑)
--      f) group_role_delegations INSERT
--      g) group_invites INSERT (pending/accepted만)
--      h) backup.restored_at, restored_by 업데이트
--    중간 실패 시 전체 ROLLBACK
-- ============================================================

create or replace function public.restore_group_from_backup(
  backup_id_input uuid
)
returns public.group_backups
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  backup_row public.group_backups%rowtype;
  snapshot_payload jsonb;
  group_record jsonb;
  new_group_id uuid;
  member_record jsonb;
  event_record jsonb;
  event_old_to_new jsonb := '{}'::jsonb;
  comment_record jsonb;
  delegation_record jsonb;
  invite_record jsonb;
  link_record jsonb;
  old_event_id text;
  new_event_id uuid;
  insert_status text;
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
    raise exception '이미 복원된 백업입니다.';
  end if;

  if backup_row.created_by <> current_user_id then
    raise exception '본인 백업만 복원할 수 있습니다.';
  end if;

  snapshot_payload := backup_row.snapshot;

  -- group
  group_record := snapshot_payload->'group';
  if group_record is null then
    raise exception '스냅샷에 그룹 정보가 없습니다.';
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
    (group_record->>'created_by')::uuid,
    'active',
    null,
    coalesce((group_record->>'created_at')::timestamptz, now()),
    now()
  )
  returning id into new_group_id;

  -- group_members (active_members 우선, all_members를 같이 두면 중복)
  for member_record in
    select * from jsonb_array_elements(snapshot_payload->'active_members')
  loop
    insert into public.group_members (
      group_id,
      user_id,
      role,
      display_name,
      status,
      joined_at,
      created_at,
      updated_at
    )
    values (
      new_group_id,
      (member_record->>'user_id')::uuid,
      member_record->>'role',
      member_record->>'display_name',
      'active',
      coalesce((member_record->>'joined_at')::timestamptz, now()),
      coalesce((member_record->>'created_at')::timestamptz, now()),
      coalesce((member_record->>'updated_at')::timestamptz, now())
    )
    on conflict do nothing;
  end loop;

  -- group_events (personal_event_id는 일단 NULL로 끊고, events 재연결 후 채움)
  for event_record in
    select * from jsonb_array_elements(snapshot_payload->'events')
  loop
    old_event_id := event_record->>'id';
    insert into public.group_events (
      id,
      group_id,
      title,
      description,
      location,
      start_at,
      end_at,
      all_day,
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
      coalesce(event_record->>'recurrence_type', 'none'),
      (event_record->>'recurrence_until')::timestamptz,
      (event_record->>'created_by')::uuid,
      (event_record->>'updated_by')::uuid,
      (event_record->>'cancelled_at')::timestamptz,
      (event_record->>'cancelled_by')::uuid,
      null,  -- personal_event_id는 events/group_event_id 재연결 후 별도 업데이트
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

  -- events.group_event_id → 새 group_event.id로 재연결
  -- (events 행은 그대로 두고 group_event_id만 새 값으로 업데이트)
  for link_record in
    select * from jsonb_array_elements(snapshot_payload->'personal_event_links')
  loop
    if (event_old_to_new ? (link_record->>'group_event_id')) then
      update public.events
         set group_event_id = (event_old_to_new->>(link_record->>'group_event_id'))::uuid
       where id = (link_record->>'event_id')::uuid;
    end if;
  end loop;

  -- group_events.personal_event_id 재연결 (events.group_event_id로부터 역방향)
  for old_event_id_text in
    select * from jsonb_object_keys(event_old_to_new)
  loop
    new_event_id := (event_old_to_new->>old_event_id_text)::uuid;
    update public.group_events ge
       set personal_event_id = (
         select id from public.events
         where group_event_id = new_event_id
         limit 1
       )
     where ge.id = new_event_id;
  end loop;

  -- group_event_comments
  for comment_record in
    select * from jsonb_array_elements(snapshot_payload->'event_comments')
  loop
    if (event_old_to_new ? (comment_record->>'group_event_id')) then
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
        (comment_record->>'author_user_id')::uuid,
        (comment_record->>'target_user_id')::uuid,
        comment_record->>'content',
        (comment_record->>'confirmed_at')::timestamptz,
        coalesce((comment_record->>'created_at')::timestamptz, now()),
        coalesce((comment_record->>'updated_at')::timestamptz, now())
      )
      on conflict do nothing;
    end if;
  end loop;

  -- group_role_delegations
  for delegation_record in
    select * from jsonb_array_elements(snapshot_payload->'role_delegations')
  loop
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
      (delegation_record->>'delegator_user_id')::uuid,
      (delegation_record->>'delegate_user_id')::uuid,
      coalesce(delegation_record->'permissions', '[]'::jsonb),
      (delegation_record->>'starts_at')::timestamptz,
      (delegation_record->>'ends_at')::timestamptz,
      coalesce(delegation_record->>'status', 'active'),
      (delegation_record->>'cancelled_at')::timestamptz,
      (delegation_record->>'cancelled_by')::uuid,
      coalesce((delegation_record->>'created_at')::timestamptz, now()),
      coalesce((delegation_record->>'updated_at')::timestamptz, now())
    )
    on conflict do nothing;
  end loop;

  -- group_invites (pending/accepted만 복원)
  for invite_record in
    select * from jsonb_array_elements(snapshot_payload->'invites')
  loop
    insert_status := invite_record->>'status';
    if insert_status is null or insert_status not in ('pending', 'accepted') then
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
      (invite_record->>'invited_user_id')::uuid,
      invite_record->>'invited_email',
      invite_record->>'invited_invite_code',
      (invite_record->>'invited_by')::uuid,
      insert_status,
      coalesce((invite_record->>'expires_at')::timestamptz, now() + interval '7 days'),
      (invite_record->>'accepted_at')::timestamptz,
      (invite_record->>'rejected_at')::timestamptz,
      (invite_record->>'cancelled_at')::timestamptz,
      (invite_record->>'expired_at')::timestamptz,
      (invite_record->>'acted_by')::uuid,
      coalesce((invite_record->>'created_at')::timestamptz, now()),
      coalesce((invite_record->>'updated_at')::timestamptz, now())
    )
    on conflict do nothing;
  end loop;

  -- backup.restored_at, restored_by 업데이트
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

grant execute on function public.restore_group_from_backup(uuid) to authenticated;

-- ============================================================
-- 4) permanently_delete_backup(backup_id_input uuid)
--    restore 안된 backup만 영구 삭제 가능. isRestored=true면 삭제 거부.
-- ============================================================

create or replace function public.permanently_delete_backup(
  backup_id_input uuid
)
returns void
language plpgsql
security definer
set search_path = public
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

  if backup_row.created_by <> current_user_id then
    raise exception '본인 백업만 삭제할 수 있습니다.';
  end if;

  delete from public.group_backups where id = backup_row.id;
end;
$$;

grant execute on function public.permanently_delete_backup(uuid) to authenticated;

-- ============================================================
-- 5) RLS 정책 보강: created_by 본인만 select/insert/update/delete
--    (기존 정책은 리더십 기반으로 그룹 단위 권한이었지만, delete 후
--    backup은 본인이 만든 것이어야 안전함.)
-- ============================================================

-- SELECT: created_by 본인
-- (기존 'group_backups_select_leader' 정책은 그룹이 삭제되면 is_group_leader가 false가 되어
--  본인도 백업을 볼 수 없게 됨. 본인이 만든 백업은 항상 볼 수 있어야 하므로 with_check/using을
--  backup 조회에 한해 created_by 기준으로 재정의.)
drop policy if exists "group_backups_select_leader" on public.group_backups;
drop policy if exists "group_backups_select_owner" on public.group_backups;
create policy "group_backups_select_owner"
  on public.group_backups
  for select
  using (created_by = auth.uid());

-- INSERT: RPC로만 (group_id_input 그룹의 리더여야 함)
-- 기존 정책이 그대로 유효 (created_by = auth.uid() AND is_group_leader(group_id, auth.uid()))
drop policy if exists "group_backups_insert_leader" on public.group_backups;
create policy "group_backups_insert_leader"
  on public.group_backups
  for insert
  with check (
    created_by = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
  );

-- UPDATE: 복원 완료 표시용 (restored_at, restored_by만 변경)
-- trigger 'prevent_group_backup_immutable_changes'가 이미 group_id/backup_type/snapshot/created_by/created_at 변경을 차단하므로
-- updated_at 컬럼에 대한 정책은 restored_at, restored_by 변경만 허용하도록 유지
drop policy if exists "group_backups_update_restore_leader" on public.group_backups;
create policy "group_backups_update_owner"
  on public.group_backups
  for update
  using (created_by = auth.uid())
  with check (created_by = auth.uid());

-- DELETE: 본인 백업만 + restore 안 된 것
-- (permanently_delete_backup RPC가 restored_at 체크하지만, RLS에서도 한 번 더 막아 안전망)
drop policy if exists "group_backups_delete_owner" on public.group_backups;
create policy "group_backups_delete_owner"
  on public.group_backups
  for delete
  using (created_by = auth.uid() and restored_at is null);

-- grant은 변경 없음
grant select, insert, update, delete on table public.group_backups to authenticated;
