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
  );;
