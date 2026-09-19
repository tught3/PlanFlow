-- 그룹 일정 신고 (UGC moderation)
-- 공유된 그룹 일정에 대한 신고를 접수한다. 신고자는 본인 소속 그룹의 활성 일정만 신고 가능.
-- 조회/상태 변경은 운영자(admin email) 전용 — 신고는 write-only (신고자 본인도 조회 불가).

create table if not exists public.group_event_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.users (id) on delete cascade,
  group_event_id uuid not null references public.group_events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  reason text not null check (reason in ('inappropriate', 'spam', 'harassment', 'other')),
  detail text,
  status text not null default 'new' check (status in ('new', 'triaged', 'dismissed', 'actioned')),
  content_owner_id uuid references public.users (id) on delete set null,
  created_at timestamptz not null default now()
);

-- 신고자 1인당 일정 1건만 신고 가능 (중복 신고 방지)
create unique index if not exists group_event_reports_reporter_event_uniq
  on public.group_event_reports (reporter_id, group_event_id);

create index if not exists group_event_reports_status_created_idx
  on public.group_event_reports (status, created_at desc);

create index if not exists group_event_reports_group_event_idx
  on public.group_event_reports (group_event_id);

alter table public.group_event_reports enable row level security;

drop policy if exists "group_event_reports_insert_member" on public.group_event_reports;
drop policy if exists "group_event_reports_select_admin" on public.group_event_reports;
drop policy if exists "group_event_reports_update_status_admin" on public.group_event_reports;
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
      where ge.id = group_event_id
        and ge.group_id = group_id
        and ge.status = 'active'
    )
  );
create policy "group_event_reports_select_admin"
  on public.group_event_reports
  for select
  to authenticated
  using (
    lower(coalesce(auth.jwt() ->> 'email', '')) in (
      'tught3@naver.com',
      'tught3@gmail.com'
    )
  );
create policy "group_event_reports_update_status_admin"
  on public.group_event_reports
  for update
  to authenticated
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

grant insert on table public.group_event_reports to authenticated;
-- 운영자(admin email) triage 경로: select/status update grant (feedback_reports 패턴과 동일)
grant select, update (reason, detail, status) on table public.group_event_reports to authenticated;
