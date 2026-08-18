-- 20260818000000_schedule_parse_entitlement.sql
--
-- ConfirmScreen의 AI 일정분석(GPT 파싱, schedule_parse)에 대한 하루 무료
-- 사용 엔타이틀먼트. voice_conversation_entitlement(20260808000000)과 완전히
-- 독립된 카운터를 쓴다(별도 RPC, 별도 user_settings 컬럼) — 기존
-- voice_conversation_* 컬럼/RPC는 이 마이그레이션에서 전혀 건드리지 않는다.
--
-- 정책: 이 기능은 voice_conversation과 달리 "최초 누적 무료"가 없다
-- (lib/services/schedule_parse_entitlement.dart 주석 참고 — 클라이언트는
-- p_initial_limit을 항상 0으로 호출한다). 하루 N회(기본 3, KST 기준 매일
-- 리셋) 무료로 GPT 파싱을 사용할 수 있고, 그마저 소진되면 리워드광고 1편
-- = 1세션이 필요하다.
--
-- RPC 시그니처는 voice_conversation 쪽과 대칭을 맞추기 위해 p_initial_limit
-- 파라미터를 그대로 받지만(스키마 없음, 항상 무시), 이 기능에는 최초 누적
-- 무료 개념이 없으므로 실제 로직에서는 사용하지 않는다.

alter table public.user_settings
  add column if not exists schedule_parse_last_reset_date date,
  add column if not exists schedule_parse_daily_used_count integer not null default 0,
  add column if not exists schedule_parse_last_session_id text;

-- ============================================================================
-- schedule_parse_entitlement_peek: 읽기 전용 조회(부작용 없음).
-- 현재 사용자의 잔여 무료 횟수를 클라이언트가 UI 표시/게이트 판정용으로
-- 조회한다.
-- ============================================================================
drop function if exists public.schedule_parse_entitlement_peek(integer, integer);

create or replace function public.schedule_parse_entitlement_peek(
  p_initial_limit integer default 0,
  p_daily_limit integer default 3
)
returns table (
  daily_remaining integer,
  requires_ad boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_daily_limit integer := least(greatest(coalesce(p_daily_limit, 3), 0), 20);
  v_daily_used integer := 0;
  v_reset_date date;
  v_today date := ((timezone('Asia/Seoul', now()))::date);
  v_daily_remaining integer;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;

  select schedule_parse_daily_used_count,
         schedule_parse_last_reset_date
    into v_daily_used, v_reset_date
    from public.user_settings
   where user_id = v_uid;

  -- user_settings row가 아직 없는 신규 사용자: 미사용 상태로 간주.
  v_daily_used := coalesce(v_daily_used, 0);

  -- 일일 리셋 판정: 저장된 날짜가 오늘(KST)이 아니면 0으로 간주(물리적 갱신 없음).
  if v_reset_date is distinct from v_today then
    v_daily_used := 0;
  end if;

  v_daily_remaining := greatest(v_daily_limit - v_daily_used, 0);

  return query
    select
      v_daily_remaining,
      (v_daily_remaining = 0);
end;
$$;

revoke all on function public.schedule_parse_entitlement_peek(integer, integer)
  from public, anon;
grant execute on function public.schedule_parse_entitlement_peek(integer, integer)
  to authenticated;

-- ============================================================================
-- consume_schedule_parse_free_usage: 실제 소비(트랜잭션, row lock).
-- 같은 p_session_id로 재호출되면 멱등적으로 현재 상태만 반환하고 차감하지
-- 않는다(네트워크 재시도·중복 호출로 인한 이중 차감 방지).
-- ============================================================================
drop function if exists public.consume_schedule_parse_free_usage(text, integer, integer);

create or replace function public.consume_schedule_parse_free_usage(
  p_session_id text,
  p_initial_limit integer default 0,
  p_daily_limit integer default 3
)
returns table (
  source text,
  daily_remaining integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_daily_limit integer := least(greatest(coalesce(p_daily_limit, 3), 0), 20);
  v_today date := ((timezone('Asia/Seoul', now()))::date);
  v_row public.user_settings%rowtype;
  v_source text;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;

  if p_session_id is null or char_length(trim(p_session_id)) = 0 then
    raise exception 'p_session_id는 필수입니다.' using errcode = '22023';
  end if;

  -- row가 없으면 먼저 만들어 둔다(다른 컬럼은 테이블 기본값 사용).
  insert into public.user_settings (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  -- 동시 요청 방지를 위한 row lock. 위 insert로 row 존재가 보장된다.
  select *
    into v_row
    from public.user_settings
   where user_id = v_uid
     for update;

  -- 일일 리셋 판정(잠금 상태에서 최신값 기준으로 재확인).
  if v_row.schedule_parse_last_reset_date is distinct from v_today then
    v_row.schedule_parse_daily_used_count := 0;
  end if;

  -- 멱등성: 동일 세션 ID로 이미 소비 처리된 호출이면 차감 없이 현재 상태만 반환.
  if v_row.schedule_parse_last_session_id = p_session_id then
    return query
      select
        case
          when v_row.schedule_parse_daily_used_count > 0
               and (v_row.schedule_parse_last_reset_date is not distinct from v_today)
            then 'daily_free'
          else 'ad_required'
        end,
        greatest(v_daily_limit - v_row.schedule_parse_daily_used_count, 0);
    return;
  end if;

  if v_daily_limit > 0
     and v_row.schedule_parse_last_reset_date is distinct from v_today then
    update public.user_settings
       set schedule_parse_last_reset_date = v_today,
           schedule_parse_daily_used_count = 1,
           schedule_parse_last_session_id = p_session_id
     where user_id = v_uid
    returning * into v_row;
    v_source := 'daily_free';
  elsif v_row.schedule_parse_daily_used_count < v_daily_limit then
    update public.user_settings
       set schedule_parse_daily_used_count = schedule_parse_daily_used_count + 1,
           schedule_parse_last_session_id = p_session_id
     where user_id = v_uid
    returning * into v_row;
    v_source := 'daily_free';
  else
    update public.user_settings
       set schedule_parse_last_session_id = p_session_id
     where user_id = v_uid
    returning * into v_row;
    v_source := 'ad_required';
  end if;

  return query
    select
      v_source,
      greatest(v_daily_limit - v_row.schedule_parse_daily_used_count, 0);
end;
$$;

revoke all on function public.consume_schedule_parse_free_usage(text, integer, integer)
  from public, anon;
grant execute on function public.consume_schedule_parse_free_usage(text, integer, integer)
  to authenticated;
