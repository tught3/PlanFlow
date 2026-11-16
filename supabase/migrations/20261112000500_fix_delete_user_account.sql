-- B3: Delete account-owned backup data and detach received invites.
begin;

-- Replace either target check definition, including deployments that renamed it.
lock table public.group_invites in access exclusive mode;
do $$
declare
  target_check record;
begin
  for target_check in
    select conname
    from pg_constraint
    where conrelid = 'public.group_invites'::regclass
      and contype = 'c'
      and regexp_replace(lower(pg_get_expr(conbin, conrelid)), '[[:space:]]+', '', 'g') in (
        '(num_nonnulls(invited_user_id,invited_email,invited_invite_code)=1)',
        '((num_nonnulls(invited_user_id,invited_email,invited_invite_code)=1)or'
        '((num_nonnulls(invited_user_id,invited_email,invited_invite_code)=0)and(status<>''pending''::text)))'
      )
  loop
    execute format('alter table public.group_invites drop constraint %I', target_check.conname);
  end loop;
end;
$$;

alter table public.group_invites
  add constraint group_invites_target_check
  check (
    num_nonnulls(invited_user_id, invited_email, invited_invite_code) = 1
    or (
      num_nonnulls(invited_user_id, invited_email, invited_invite_code) = 0
      and status <> 'pending'
    )
  );

create or replace function public.prevent_group_invite_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if num_nonnulls(new.invited_user_id, new.invited_email, new.invited_invite_code) <> 1 then
      raise exception 'group_invites requires one target';
    end if;
    return new;
  end if;

  if new.group_id is distinct from old.group_id
    or new.invited_email is distinct from old.invited_email
    or new.invited_invite_code is distinct from old.invited_invite_code
    or new.invited_by is distinct from old.invited_by
    or new.expires_at is distinct from old.expires_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_invites immutable fields cannot change';
  end if;

  if new.invited_user_id is distinct from old.invited_user_id then
    -- Only the foreign key can detach an invite from a deleted recipient.
    if new.invited_user_id is not null
      or pg_trigger_depth() <= 1
      or exists (select 1 from public.users where id = old.invited_user_id)
    then
      raise exception 'group_invites target cannot change';
    end if;

    if old.status = 'pending' then
      new.status := 'expired';
      new.expired_at := now();
    else
      new.status := old.status;
    end if;
  elsif num_nonnulls(old.invited_user_id, old.invited_email, old.invited_invite_code) = 0
    and new.status is distinct from old.status
  then
    raise exception 'detached group_invites cannot change status';
  end if;

  return new;
end;
$$;

revoke execute on function public.prevent_group_invite_immutable_changes()
  from public, anon, authenticated;

drop trigger if exists group_invites_prevent_immutable_changes on public.group_invites;
create trigger group_invites_prevent_immutable_changes
  before insert or update on public.group_invites
  for each row execute function public.prevent_group_invite_immutable_changes();

create or replace function public.prevent_group_event_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.group_id is distinct from old.group_id
    or (
      new.created_by is distinct from old.created_by
      and not (
        new.created_by is null
        and pg_trigger_depth() > 1
        and not exists (select 1 from public.users where id = old.created_by)
      )
    )
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_events immutable fields cannot change';
  end if;

  return new;
end;
$$;

create or replace function public.delete_user_account(target_user_id uuid)
returns table(success boolean, blocked_reason text, leader_groups jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  leader_group_rows jsonb;
  user_email text;
begin
  -- service_role 게이트: 이 함수는 service_role JWT로만 호출 가능.
  -- 일반 authenticated 사용자의 JWT로 호출하면 current_setting('role')가
  -- 'authenticated'이므로 여기서 차단된다.
  if current_setting('role', true) is distinct from 'service_role' then
    raise exception '이 작업은 서비스 권한이 필요합니다.';
  end if;

  if target_user_id is null then
    raise exception '대상 사용자 ID가 필요합니다.';
  end if;

  -- Serialize cleanup with new backups referencing this user through a foreign key.
  perform 1
    from public.users
   where id = target_user_id
   for update;

  -- 1) groups.created_by는 상태와 관계없이 사용자 삭제를 제한한다.
  select coalesce(
    (
      select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'status', status))
      from public.groups
      where created_by = target_user_id
    ),
    '[]'::jsonb
  ) into leader_group_rows;

  if jsonb_array_length(leader_group_rows) > 0 then
    return query select false, 'leader_groups'::text, leader_group_rows;
    return;
  end if;

  -- 2) 개인 데이터 일괄 삭제. CASCADE FK가 잡혀있지만 명시적으로 순서대로 삭제해
  --    audit log를 명확히 한다. events 삭제 시 pre_actions/reminders는 CASCADE로 같이 삭제됨.
  -- 2-1) 그룹 멤버십 제거 (사용자가 속한 그룹에서 모두 leave 처리).
  --      소유 그룹은 위에서 이미 확인했다.
  delete from public.group_members where user_id = target_user_id;

  -- Remove owned snapshots before deleting the user, regardless of the backup FK.
  delete from public.group_backups where created_by = target_user_id;

  -- 2-2) 그룹 댓글·위임·초대 중 사용자가 만든 것 정리 (FK CASCADE가 안 걸려있을 수 있어 명시).
  delete from public.group_event_comments
    where author_user_id = delete_user_account.target_user_id;
  delete from public.group_role_delegations
    where delegator_user_id = target_user_id or delegate_user_id = target_user_id;
  delete from public.group_invites where invited_by = target_user_id;

  -- 2-3) 사용자 개인 일정 관련 데이터 (events CASCADE → pre_actions/reminders 자동 삭제).
  delete from public.location_history where user_id = target_user_id;
  delete from public.voice_logs where user_id = target_user_id;
  delete from public.user_backups where user_id = target_user_id;
  delete from public.feedback_reports where user_id = target_user_id;
  delete from public.user_settings where user_id = target_user_id;
  delete from public.events where user_id = target_user_id;

  select email into user_email
    from auth.users
   where id = target_user_id;
  user_email := nullif(lower(btrim(user_email)), '');
  if user_email is not null
    and to_regclass('planflow.early_bird_emails') is not null then
    delete from planflow.early_bird_emails where email = user_email;
  end if;

  -- 3) 마지막으로 users 테이블에서 사용자 행 삭제.
  --      (auth.users는 Edge Function에서 auth.admin.deleteUser로 삭제.)
  delete from public.users where id = target_user_id;

  return query select true, null::text, '[]'::jsonb;
exception
  when others then
    -- plpgsql 함수는 자동 트랜잭션이라 예외 시 전체 ROLLBACK.
    raise exception 'delete_user_account failed: %', sqlerrm;
end;
$$;

revoke execute on function public.delete_user_account(uuid) from public, anon, authenticated;
grant execute on function public.delete_user_account(uuid) to service_role;

commit;
