-- 20260808000000_voice_conversation_entitlement.sql
-- AI일정대화(VoiceConversationScreen) 무료체험 정책 확장.
--
-- 정책: 최초 누적 N회(기본 3) 무료 -> 소진 후 매일 1회(기본 1) 무료(KST 기준
-- 매일 리셋) -> 그마저 소진되면 리워드광고 1편 = 1세션.
--
-- 기존 voice_conversation_free_trial_used(20260805000000)는 "최초 무료
-- 누적 사용횟수"로 그대로 재사용한다. 이 마이그레이션은 일일 무료 사용량과
-- 멱등성 판정을 위한 세션 ID를 추가하고, 판정/소비용 RPC 2개를 추가한다.

alter table public.user_settings
  add column if not exists voice_conversation_daily_free_date date,
  add column if not exists voice_conversation_daily_free_used integer not null default 0,
  add column if not exists voice_conversation_last_session_id text;

-- ============================================================================
-- voice_conversation_entitlement_peek: 읽기 전용 조회(부작용 없음).
-- 현재 사용자의 잔여 무료 횟수를 클라이언트가 UI 표시용으로 조회한다.
-- ============================================================================
drop function if exists public.voice_conversation_entitlement_peek(integer, integer);

create or replace function public.voice_conversation_entitlement_peek(
  p_initial_limit integer default 3,
  p_daily_limit integer default 1
)
returns table (
  initial_remaining integer,
  daily_remaining integer,
  requires_ad boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_initial_limit integer := least(greatest(coalesce(p_initial_limit, 3), 0), 10);
  v_daily_limit integer := least(greatest(coalesce(p_daily_limit, 1), 0), 5);
  v_initial_used integer := 0;
  v_daily_used integer := 0;
  v_daily_date date;
  v_today date := ((timezone('Asia/Seoul', now()))::date);
  v_initial_remaining integer;
  v_daily_remaining integer;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;

  select voice_conversation_free_trial_used,
         voice_conversation_daily_free_used,
         voice_conversation_daily_free_date
    into v_initial_used, v_daily_used, v_daily_date
    from public.user_settings
   where user_id = v_uid;

  -- user_settings row가 아직 없는 신규 사용자: 미사용 상태로 간주.
  v_initial_used := coalesce(v_initial_used, 0);
  v_daily_used := coalesce(v_daily_used, 0);

  -- 일일 리셋 판정: 저장된 날짜가 오늘(KST)이 아니면 0으로 간주(물리적 갱신 없음).
  if v_daily_date is distinct from v_today then
    v_daily_used := 0;
  end if;

  v_initial_remaining := greatest(v_initial_limit - v_initial_used, 0);
  v_daily_remaining := greatest(v_daily_limit - v_daily_used, 0);

  return query
    select
      v_initial_remaining,
      v_daily_remaining,
      (v_initial_remaining = 0 and v_daily_remaining = 0);
end;
$$;

revoke all on function public.voice_conversation_entitlement_peek(integer, integer)
  from public, anon;
grant execute on function public.voice_conversation_entitlement_peek(integer, integer)
  to authenticated;

-- ============================================================================
-- consume_voice_conversation_free_usage: 실제 소비(트랜잭션, row lock).
-- 같은 p_session_id로 재호출되면 멱등적으로 현재 상태만 반환하고 차감하지 않는다
-- (네트워크 재시도·중복 호출로 인한 이중 차감 방지).
-- ============================================================================
drop function if exists public.consume_voice_conversation_free_usage(text, integer, integer);

create or replace function public.consume_voice_conversation_free_usage(
  p_session_id text,
  p_initial_limit integer default 3,
  p_daily_limit integer default 1
)
returns table (
  source text,
  initial_remaining integer,
  daily_remaining integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_initial_limit integer := least(greatest(coalesce(p_initial_limit, 3), 0), 10);
  v_daily_limit integer := least(greatest(coalesce(p_daily_limit, 1), 0), 5);
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
  if v_row.voice_conversation_daily_free_date is distinct from v_today then
    v_row.voice_conversation_daily_free_used := 0;
  end if;

  -- 멱등성: 동일 세션 ID로 이미 소비 처리된 호출이면 차감 없이 현재 상태만 반환.
  if v_row.voice_conversation_last_session_id = p_session_id then
    return query
      select
        case
          when v_row.voice_conversation_free_trial_used > 0
               and v_row.voice_conversation_free_trial_used <= v_initial_limit
            then 'initial_free'
          when v_row.voice_conversation_daily_free_used > 0
            then 'daily_free'
          else 'ad_required'
        end,
        greatest(v_initial_limit - v_row.voice_conversation_free_trial_used, 0),
        greatest(v_daily_limit - v_row.voice_conversation_daily_free_used, 0);
    return;
  end if;

  if v_row.voice_conversation_free_trial_used < v_initial_limit then
    update public.user_settings
       set voice_conversation_free_trial_used = voice_conversation_free_trial_used + 1,
           voice_conversation_last_session_id = p_session_id
     where user_id = v_uid
    returning * into v_row;
    v_source := 'initial_free';
  elsif v_row.voice_conversation_daily_free_date is distinct from v_today then
    update public.user_settings
       set voice_conversation_daily_free_date = v_today,
           voice_conversation_daily_free_used = 1,
           voice_conversation_last_session_id = p_session_id
     where user_id = v_uid
    returning * into v_row;
    v_source := 'daily_free';
  elsif v_row.voice_conversation_daily_free_used < v_daily_limit then
    update public.user_settings
       set voice_conversation_daily_free_used = voice_conversation_daily_free_used + 1,
           voice_conversation_last_session_id = p_session_id
     where user_id = v_uid
    returning * into v_row;
    v_source := 'daily_free';
  else
    update public.user_settings
       set voice_conversation_last_session_id = p_session_id
     where user_id = v_uid
    returning * into v_row;
    v_source := 'ad_required';
  end if;

  return query
    select
      v_source,
      greatest(v_initial_limit - v_row.voice_conversation_free_trial_used, 0),
      greatest(v_daily_limit - v_row.voice_conversation_daily_free_used, 0);
end;
$$;

revoke all on function public.consume_voice_conversation_free_usage(text, integer, integer)
  from public, anon;
grant execute on function public.consume_voice_conversation_free_usage(text, integer, integer)
  to authenticated;
