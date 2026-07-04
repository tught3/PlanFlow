-- 팀원(멤버)이 스스로 그룹을 나갈 수 있게 하는 함수.
-- 기존 remove_group_member(리더가 타인 제거)와 달리, 호출자 본인의 멤버십을
-- 'removed'로 전환한다. 리더 권한을 요구하지 않되, 본인이 마지막 active 리더면
-- 그룹이 리더 없이 남는 것을 막기 위해 예외를 던진다.
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
