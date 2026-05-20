-- Align the live feedback inbox admin RLS policy with the app admin list.
-- The status update also touches updated_at through feedback_reports_set_updated_at.

grant update (status, updated_at) on table public.feedback_reports to authenticated;

drop policy if exists "feedback_reports_select_admin" on public.feedback_reports;
create policy "feedback_reports_select_admin"
  on public.feedback_reports
  for select
  using (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  );

drop policy if exists "feedback_reports_update_status_admin" on public.feedback_reports;
create policy "feedback_reports_update_status_admin"
  on public.feedback_reports
  for update
  using (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  )
  with check (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  );
