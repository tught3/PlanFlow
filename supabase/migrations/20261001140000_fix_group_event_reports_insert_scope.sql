-- Forward-only fix for the group_event_reports INSERT policy.
-- Explicitly correlate the referenced event to the report row's group.
-- This migration changes policy logic only; it does not modify table data.

drop policy if exists "group_event_reports_insert_member"
  on public.group_event_reports;

create policy "group_event_reports_insert_member"
  on public.group_event_reports
  for insert
  to authenticated
  with check (
    reporter_id = auth.uid()
    and public.is_group_member(group_id, auth.uid())
    and exists (
      select 1
      from public.group_events ge
      where ge.id = group_event_reports.group_event_id
        and ge.group_id = group_event_reports.group_id
        and ge.status = 'active'
    )
  );
