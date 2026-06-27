-- Track feedback_reports as a numbered migration and support homepage web intake.
-- Idempotent for the shared PlanFlow Supabase project.

create table if not exists public.feedback_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users (id) on delete cascade,
  product text not null default 'planflow' check (
    product in ('planflow', 'finflow', 'valueflow', 'nexusflow', 'general')
  ),
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
  source text not null default 'app' check (
    source in ('app', 'android-app', 'homepage')
  ),
  email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.feedback_reports
  add column if not exists product text not null default 'planflow',
  add column if not exists source text,
  add column if not exists email text;

update public.feedback_reports
set source = 'app'
where source is null;

alter table public.feedback_reports
  alter column user_id drop not null,
  alter column source set default 'app',
  alter column source set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'feedback_reports_product_check'
      and conrelid = 'public.feedback_reports'::regclass
  ) then
    alter table public.feedback_reports
      add constraint feedback_reports_product_check
      check (product in ('planflow', 'finflow', 'valueflow', 'nexusflow', 'general'));
  end if;

end;
$$;

alter table public.feedback_reports
  drop constraint if exists feedback_reports_source_check;

alter table public.feedback_reports
  add constraint feedback_reports_source_check
  check (source in ('app', 'android-app', 'homepage'));

create index if not exists feedback_reports_user_created_idx
  on public.feedback_reports (user_id, created_at desc);

create index if not exists feedback_reports_status_created_idx
  on public.feedback_reports (status, created_at desc);

create index if not exists feedback_reports_source_idx
  on public.feedback_reports (source, created_at desc);

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
grant update (status, updated_at) on table public.feedback_reports to authenticated;

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
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  );

create policy "feedback_reports_insert_own"
  on public.feedback_reports
  for insert
  with check (auth.uid() = user_id);

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
