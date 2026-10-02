create table if not exists public.feedback_report_groups (
  id uuid primary key default gen_random_uuid(),
  product text not null check (product = any (array['planflow', 'finflow', 'valueflow', 'nexusflow', 'general'])),
  type text not null check (type = any (array['bug', 'voice', 'calendar_sync', 'notification', 'map_location', 'feature_request', 'other'])),
  title text not null,
  summary text not null default '',
  issue_fingerprint text not null,
  status text not null default 'new' check (status = any (array['new', 'triaged', 'fixed', 'closed'])),
  first_report_id uuid,
  last_report_id uuid,
  report_count integer not null default 0,
  suggested_related_group_id uuid references public.feedback_report_groups(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.feedback_reports
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by text,
  add column if not exists completed_at timestamptz,
  add column if not exists group_id uuid references public.feedback_report_groups(id) on delete set null,
  add column if not exists suggested_related_group_id uuid references public.feedback_report_groups(id) on delete set null;

alter table public.contact_messages
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by text,
  add column if not exists completed_at timestamptz;

create index if not exists feedback_reports_active_idx
  on public.feedback_reports (status, created_at desc)
  where archived_at is null;

create index if not exists contact_messages_active_idx
  on public.contact_messages (status, created_at desc)
  where archived_at is null;

create index if not exists feedback_report_groups_lookup_idx
  on public.feedback_report_groups (product, type, status, updated_at desc);

alter table public.feedback_report_groups enable row level security;

drop policy if exists feedback_report_groups_select_admin on public.feedback_report_groups;
create policy feedback_report_groups_select_admin on public.feedback_report_groups
for select
to authenticated
using (
  exists (
    select 1
    from public.admin_roles ar
    where ar.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
);
;
