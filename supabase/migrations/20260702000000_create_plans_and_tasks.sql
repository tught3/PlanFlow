-- ============================================================
-- Migration: plans 테이블 및 tasks 테이블 생성 + RLS 정책
-- 작업자: W04
-- ============================================================
-- plans: 사용자별 계획(Plan)을 저장한다.
-- tasks: 특정 plan에 속하는 하위 태스크를 저장한다.
-- 두 테이블 모두 RLS를 활성화하여 사용자는 본인 데이터만
-- 조회/수정/삭제할 수 있도록 한다.
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 1. plans 테이블
-- ============================================================

create table if not exists public.plans (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  title       text,
  description text,
  status      text not null default 'draft',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists plans_user_id_idx
  on public.plans (user_id);

create index if not exists plans_status_idx
  on public.plans (status);

-- updated_at 자동 갱신 트리거
drop trigger if exists plans_set_updated_at on public.plans;
create trigger plans_set_updated_at
  before update on public.plans
  for each row execute function public.set_updated_at();

-- ============================================================
-- 2. tasks 테이블
-- ============================================================

create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null references public.plans (id) on delete cascade,
  title       text,
  status      text not null default 'todo',
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists tasks_plan_id_idx
  on public.tasks (plan_id);

create index if not exists tasks_sort_order_idx
  on public.tasks (plan_id, sort_order);

-- updated_at 자동 갱신 트리거
drop trigger if exists tasks_set_updated_at on public.tasks;
create trigger tasks_set_updated_at
  before update on public.tasks
  for each row execute function public.set_updated_at();

-- ============================================================
-- 3. RLS (Row Level Security) 활성화
-- ============================================================

alter table public.plans enable row level security;
alter table public.tasks enable row level security;

-- authenticated 역할에 기본 권한 부여
grant select, insert, update, delete on table public.plans to authenticated;
grant select, insert, update, delete on table public.tasks to authenticated;

-- ============================================================
-- 4. plans RLS 정책 (본인 데이터만 접근 가능)
-- ============================================================

-- SELECT: 본인 plan만 조회
drop policy if exists "plans_select_own" on public.plans;
create policy "plans_select_own"
  on public.plans
  for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT: 본인 plan만 생성
drop policy if exists "plans_insert_own" on public.plans;
create policy "plans_insert_own"
  on public.plans
  for insert
  to authenticated
  with check (user_id = auth.uid());

-- UPDATE: 본인 plan만 수정
drop policy if exists "plans_update_own" on public.plans;
create policy "plans_update_own"
  on public.plans
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- DELETE: 본인 plan만 삭제
drop policy if exists "plans_delete_own" on public.plans;
create policy "plans_delete_own"
  on public.plans
  for delete
  to authenticated
  using (user_id = auth.uid());

-- ============================================================
-- 5. tasks RLS 정책 (소유자의 plan에 속한 task만 접근 가능)
-- ============================================================

-- SELECT: 본인 plan의 task만 조회
drop policy if exists "tasks_select_own" on public.tasks;
create policy "tasks_select_own"
  on public.tasks
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.plans
      where plans.id = tasks.plan_id
        and plans.user_id = auth.uid()
    )
  );

-- INSERT: 본인 plan에만 task 생성
drop policy if exists "tasks_insert_own" on public.tasks;
create policy "tasks_insert_own"
  on public.tasks
  for insert
  to authenticated
  with check (
    exists (
      select 1
      from public.plans
      where plans.id = tasks.plan_id
        and plans.user_id = auth.uid()
    )
  );

-- UPDATE: 본인 plan의 task만 수정
drop policy if exists "tasks_update_own" on public.tasks;
create policy "tasks_update_own"
  on public.tasks
  for update
  to authenticated
  using (
    exists (
      select 1
      from public.plans
      where plans.id = tasks.plan_id
        and plans.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.plans
      where plans.id = tasks.plan_id
        and plans.user_id = auth.uid()
    )
  );

-- DELETE: 본인 plan의 task만 삭제
drop policy if exists "tasks_delete_own" on public.tasks;
create policy "tasks_delete_own"
  on public.tasks
  for delete
  to authenticated
  using (
    exists (
      select 1
      from public.plans
      where plans.id = tasks.plan_id
        and plans.user_id = auth.uid()
    )
  );
