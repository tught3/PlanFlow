-- PlanFlow user feedback reports patch.
-- Apply this in Supabase SQL Editor for project xqvvfnvmytjlblcngipn.

create table if not exists public.feedback_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  type text not null check (
    type in (
      'bug',
      'voice',
      'calendar_sync',
      'notification',
      'map_location',
      'feature_request',
      'other'
    )
  ),
  message text not null check (char_length(trim(message)) >= 5),
  expected_behavior text,
  app_version text,
  platform text,
  device_summary text,
  route_or_screen text,
  diagnostics jsonb not null default '{}'::jsonb,
  status text not null default 'new' check (
    status in ('new', 'triaged', 'fixed', 'closed')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists feedback_reports_user_created_idx
  on public.feedback_reports (user_id, created_at desc);

create index if not exists feedback_reports_status_created_idx
  on public.feedback_reports (status, created_at desc);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists feedback_reports_set_updated_at
  on public.feedback_reports;
create trigger feedback_reports_set_updated_at
  before update on public.feedback_reports
  for each row execute function public.set_updated_at();

alter table public.feedback_reports enable row level security;

grant usage on schema public to authenticated;
grant select, insert on table public.feedback_reports to authenticated;
grant update (status) on table public.feedback_reports to authenticated;

drop policy if exists "feedback_reports_select_own" on public.feedback_reports;
drop policy if exists "feedback_reports_insert_own" on public.feedback_reports;
drop policy if exists "feedback_reports_update_own" on public.feedback_reports;
drop policy if exists "feedback_reports_delete_own" on public.feedback_reports;
drop policy if exists "feedback_reports_select_admin" on public.feedback_reports;
drop policy if exists "feedback_reports_update_status_admin" on public.feedback_reports;

create policy "feedback_reports_select_own"
  on public.feedback_reports
  for select
  using (auth.uid() = user_id);

create policy "feedback_reports_select_admin"
  on public.feedback_reports
  for select
  using (
    lower(coalesce(auth.jwt() ->> 'email', '')) =
      'tught3@naver.com'
  );

create policy "feedback_reports_insert_own"
  on public.feedback_reports
  for insert
  with check (auth.uid() = user_id);

create policy "feedback_reports_update_status_admin"
  on public.feedback_reports
  for update
  using (
    lower(coalesce(auth.jwt() ->> 'email', '')) =
      'tught3@naver.com'
  )
  with check (
    lower(coalesce(auth.jwt() ->> 'email', '')) =
      'tught3@naver.com'
  );
