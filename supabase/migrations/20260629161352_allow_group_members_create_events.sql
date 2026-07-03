drop policy if exists "group_events_insert_access" on public.group_events;
drop policy if exists "group_events_insert_leader_or_delegate" on public.group_events;
create policy "group_events_insert_leader_or_delegate"
  on public.group_events
  for insert
  with check (
    status = 'active'
    and created_by = auth.uid()
    and exists (
      select 1
      from public.groups
      where groups.id = group_events.group_id
        and groups.status = 'active'
    )
    and (
      public.is_group_member(group_id, auth.uid())
      or public.is_group_leader(group_id, auth.uid())
      or public.has_group_delegated_permission(group_id, auth.uid(), 'create_group_event')
    )
  );
