-- 그룹일정을 만든 본인(created_by)도 자기가 만든 그룹일정을 수정/취소할 수 있게
-- RLS를 확장한다. 기존에는 리더 또는 위임받은 멤버만 가능했으나, 개인일정을
-- 여러 그룹에 공유한 뒤 작성자가 그 사본들을 수정/삭제(전파)할 수 있어야 하므로
-- created_by = auth.uid() 조건을 OR로 추가한다(순수 권한 확장, 데이터 변경 없음).
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
    and (
      created_by = auth.uid()
      or public.is_group_leader(group_id, auth.uid())
      or public.has_group_delegated_permission(group_id, auth.uid(), 'update_group_event')
    )
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
    and (
      created_by = auth.uid()
      or public.is_group_leader(group_id, auth.uid())
      or public.has_group_delegated_permission(group_id, auth.uid(), 'cancel_group_event')
    )
  )
  with check (
    status = 'cancelled'
    and cancelled_at is not null
    and cancelled_by = auth.uid()
  );
