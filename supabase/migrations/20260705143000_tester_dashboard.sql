-- PlanFlow 관리자 Tester Dashboard 지원 마이그레이션
-- public.users 테이블에 활동 추적 컬럼을 추가하고 인덱스·RLS·RPC를 구성한다.
--
-- 추가 컬럼:
--   last_login_at   timestamptz  로그인 성공 시각
--   last_active_at  timestamptz  앱 실행/포그라운드 복귀 시각
--   app_version     text         앱 버전(예: 1.1.1)
--   build_number    text         빌드 번호(문자열로 저장, 비교 시 숫자로 변환)
--   platform        text         android / ios / web
--   updated_at      timestamptz  자동 갱신(set_updated_at 트리거 재사용)
--
-- 보안 모델:
--   기존 users_select_own / users_select_group_members 유지
--   admin_roles에 등록된 이메일은 모든 users 행을 조회할 수 있다
--   (대시보드 전용 RPC get_tester_dashboard/get_tester_stats는 SECURITY DEFINER로 admin 게이트 통과)

alter table public.users
  add column if not exists last_login_at timestamptz;

alter table public.users
  add column if not exists last_active_at timestamptz;

alter table public.users
  add column if not exists app_version text;

alter table public.users
  add column if not exists build_number text;

alter table public.users
  add column if not exists platform text
  check (platform is null or platform in ('android', 'ios', 'web', 'macos', 'windows', 'linux'));

alter table public.users
  add column if not exists updated_at timestamptz not null default now();

-- set_updated_at() 함수는 schema.sql에 이미 정의되어 있으므로 재사용한다.
drop trigger if exists users_set_updated_at on public.users;
create trigger users_set_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

-- 성능 인덱스: 대시보드 정렬/필터에 사용되는 컬럼.
create index if not exists users_last_active_at_idx
  on public.users (last_active_at desc);

create index if not exists users_last_login_at_idx
  on public.users (last_login_at desc);

create index if not exists users_email_idx
  on public.users (email);

create index if not exists users_platform_idx
  on public.users (platform);

create index if not exists users_app_version_idx
  on public.users (app_version);

-- ============================================================================
-- RLS: 관리자 전용 users 전체 조회 정책 추가
-- ============================================================================
-- 일반 사용자는 자기 행만, 같은 그룹 멤버 행만 조회(기존 정책 유지).
-- admin_roles에 등록된 이메일은 모든 사용자 행을 조회할 수 있다.
-- (본 정책은 Tester Dashboard뿐 아니라 admin 업무 전반에 안전하게 적용된다.)

drop policy if exists "users_select_admin" on public.users;
create policy "users_select_admin"
  on public.users
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.admin_roles ar
      where ar.email = lower(coalesce(auth.jwt() ->> 'email', ''))
        and ar.role in ('admin', 'owner')
    )
  );

-- ============================================================================
-- RPC: 관리자 전용 대시보드 데이터 조회
-- ============================================================================
-- 클라이언트가 직접 users 테이블을 SELECT하는 대신 SECURITY DEFINER RPC로
-- 접근한다. admin이 아닌 호출은 즉시 거부된다(fail-closed).
-- 일반 사용자용 자기 활동 갱신은 record_user_activity RPC를 사용한다.

-- 클라이언트가 자기 행의 활동 정보를 갱신한다.
-- 일반 사용자는 이 RPC로 자기 last_active_at/app_version/build_number/platform만 갱신 가능.
drop function if exists public.record_user_activity(
  text, text, text, text
);
create or replace function public.record_user_activity(
  p_app_version text default null,
  p_build_number text default null,
  p_platform text default null,
  p_mark_login boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;

  update public.users
     set last_active_at = now(),
         app_version = coalesce(p_app_version, public.users.app_version),
         build_number = coalesce(p_build_number, public.users.build_number),
         platform = case
           when p_platform is null or char_length(trim(p_platform)) = 0
             then public.users.platform
           else lower(trim(p_platform))
         end,
         last_login_at = case
           when p_mark_login then now()
           else public.users.last_login_at
         end
   where id = uid;
end;
$$;

grant execute on function public.record_user_activity(
  text, text, text, boolean
) to authenticated;

-- 관리자 전용: 대시보드용 사용자 목록 조회(필터/정렬/페이지네이션 내장).
drop function if exists public.get_tester_dashboard(
  text, text, text, text, text, int, int
);
create or replace function public.get_tester_dashboard(
  p_search text default null,
  p_status text default null,      -- online | recent | inactive | null
  p_platform text default null,    -- android | ios | null
  p_app_version text default null,
  p_sort text default 'last_active',
  p_limit int default 50,
  p_offset int default 0
)
returns table (
  id uuid,
  email text,
  display_name text,
  name text,
  created_at timestamptz,
  last_login_at timestamptz,
  last_active_at timestamptz,
  app_version text,
  build_number text,
  platform text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_email text;
  is_admin boolean := false;
begin
  caller_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  select exists(
    select 1
    from public.admin_roles ar
    where ar.email = caller_email
      and ar.role in ('admin', 'owner')
  ) into is_admin;

  if not is_admin then
    raise exception '관리자 권한이 필요합니다.' using errcode = '42501';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 500 then
    p_limit := 50;
  end if;
  if p_offset is null or p_offset < 0 then
    p_offset := 0;
  end if;

  return query
  select
    u.id,
    u.email,
    u.display_name,
    u.name,
    u.created_at,
    u.last_login_at,
    u.last_active_at,
    u.app_version,
    u.build_number,
    u.platform
  from public.users u
  where
    (
      p_search is null
      or char_length(trim(p_search)) = 0
      or u.email ilike '%' || trim(p_search) || '%'
      or coalesce(u.display_name, '') ilike '%' || trim(p_search) || '%'
      or coalesce(u.name, '') ilike '%' || trim(p_search) || '%'
    )
    and (
      p_platform is null
      or char_length(trim(p_platform)) = 0
      or u.platform = lower(trim(p_platform))
    )
    and (
      p_app_version is null
      or char_length(trim(p_app_version)) = 0
      or u.app_version = trim(p_app_version)
    )
    and case
      when p_status = 'online' then
        u.last_active_at is not null
        and u.last_active_at >= now() - interval '5 minutes'
      when p_status = 'recent' then
        u.last_active_at is not null
        and u.last_active_at >= now() - interval '7 days'
        and u.last_active_at < now() - interval '5 minutes'
      when p_status = 'inactive' then
        u.last_active_at is null
        or u.last_active_at < now() - interval '7 days'
      else true
    end
  order by
    case when p_sort = 'created' then u.created_at end desc,
    case when p_sort is distinct from 'created' then coalesce(u.last_active_at, u.created_at) end desc
  limit p_limit
  offset p_offset;
end;
$$;

grant execute on function public.get_tester_dashboard(
  text, text, text, text, text, int, int
) to authenticated;

-- 관리자 전용: 통계 카드용 집계 결과.
drop function if exists public.get_tester_stats();
create or replace function public.get_tester_stats()
returns table (
  total_testers bigint,
  active_7d bigint,
  logged_in_today bigint,
  inactive_30d bigint,
  online_now bigint,
  android_count bigint,
  ios_count bigint,
  latest_version text,
  latest_version_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_email text;
  is_admin boolean := false;
  latest_ver text;
begin
  caller_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  select exists(
    select 1
    from public.admin_roles ar
    where ar.email = caller_email
      and ar.role in ('admin', 'owner')
  ) into is_admin;

  if not is_admin then
    raise exception '관리자 권한이 필요합니다.' using errcode = '42501';
  end if;

  -- 최신 버전(빌드 번호 기준 내림차순, 동점이면 app_version 문자열 내림차순)
  select u.app_version
    into latest_ver
    from public.users u
   where u.app_version is not null
   order by
     coalesce(nullif(u.build_number, '')::int, 0) desc,
     u.app_version desc
   limit 1;

  return query
  select
    count(*)::bigint as total_testers,
    count(*) filter (
      where last_active_at is not null
        and last_active_at >= now() - interval '7 days'
    )::bigint as active_7d,
    count(*) filter (
      where last_login_at is not null
        and last_login_at >= date_trunc('day', now())
    )::bigint as logged_in_today,
    count(*) filter (
      where last_active_at is null
        or last_active_at < now() - interval '30 days'
    )::bigint as inactive_30d,
    count(*) filter (
      where last_active_at is not null
        and last_active_at >= now() - interval '5 minutes'
    )::bigint as online_now,
    count(*) filter (where platform = 'android')::bigint as android_count,
    count(*) filter (where platform = 'ios')::bigint as ios_count,
    latest_ver as latest_version,
    count(*) filter (
      where app_version is not null
        and app_version = latest_ver
    )::bigint as latest_version_count;
end;
$$;

grant execute on function public.get_tester_stats() to authenticated;

-- ============================================================================
-- Realtime: users 테이블 변경 알림을 위해 publication에 추가(이미 있으면 no-op)
-- ============================================================================
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'users'
  ) then
    begin
      alter publication supabase_realtime add table public.users;
    exception
      when others then null;
    end;
  end if;
end $$;
