-- 그룹일정 수정/취소는 "만든 작성자 본인"만 할 수 있게 한다.
-- 리더라도 남이 공유한 일정을 마음대로 수정/삭제하면 안 되기 때문이다
-- (리더는 '리더 지시' 댓글로만 관여). 자기가 만든 그룹일정은 created_by가
-- 본인이므로 그대로 수정/취소할 수 있다.
-- 앞선 20260704140000(created_by OR 리더 OR 위임)을 작성자 전용으로 좁힌다.
drop policy if exists "group_events_update_access" on public.group_events;
drop policy if exists "group_events_cancel_access" on public.group_events;

create policy "group_events_update_access"
  on public.group_events
  for update
  using (
    status = 'active'
    and exists (
      select 1
      from public.groups
      where groups.id = group_events.group_id
        and groups.status = 'active'
    )
    and created_by = auth.uid()
  )
  with check (
    status in ('active', 'archived')
    and updated_by = auth.uid()
  );

create policy "group_events_cancel_access"
  on public.group_events
  for update
  using (
    status = 'active'
    and exists (
      select 1
      from public.groups
      where groups.id = group_events.group_id
        and groups.status = 'active'
    )
    and created_by = auth.uid()
  )
  with check (
    status = 'cancelled'
    and cancelled_at is not null
    and cancelled_by = auth.uid()
  );
