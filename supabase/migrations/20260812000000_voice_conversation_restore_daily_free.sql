-- 20260812000000_voice_conversation_restore_daily_free.sql
--
-- 정책 복원(CEO 결정, 2026-08-12): "최초 3회 무료 소진 후 매일 1회 무료,
-- 그 다음부터 광고" 정책을 서버까지 복원한다.
--
-- 20260809000000/20260810000000 마이그레이션이 공개 RPC
-- (voice_conversation_entitlement_peek / consume_voice_conversation_free_usage)
-- 를 얇은 wrapper로 바꾸면서 호출자가 넘긴 p_initial_limit/p_daily_limit
-- 인자를 전부 무시하고 항상 (3, 0)만 legacy 함수에 전달하도록 하드코딩했다.
-- 그 결과 클라이언트가 무엇을 보내든 일일 무료 경로가 항상 비활성이었다.
--
-- 이 마이그레이션은 그 두 마이그레이션이 만든 _legacy 함수(20260808에 구현된
-- 최초/일일 무료 계산 로직 원본, 그대로 보존)는 건드리지 않고, 그 위의 공개
-- wrapper 2개만 CREATE OR REPLACE로 다시 감싸 호출자가 전달한 인자를 그대로
-- legacy 함수에 전달하도록 고친다(무시하지 않음). 시그니처는 기존과 동일
-- (integer, integer) / (text, integer, integer)이므로 기존 grant/revoke는
-- CREATE OR REPLACE로 유지되지만, 이 파일에서도 명시적으로 재선언해 이전
-- 마이그레이션들과 동일한 스타일을 유지한다.
--
-- 20260809000000/20260810000000 마이그레이션 파일 자체는 이 저장소의 마이그
-- 레이션 규약(과거 이력 수정 금지, 항상 추가)에 따라 수정하지 않는다.

create or replace function public.voice_conversation_entitlement_peek(
  p_initial_limit integer default 3,
  p_daily_limit integer default 1
)
returns table (initial_remaining integer, daily_remaining integer, requires_ad boolean)
language sql security definer set search_path = public as $$
  select initial_remaining, daily_remaining, requires_ad
  from public.voice_conversation_entitlement_peek_legacy(p_initial_limit, p_daily_limit);
$$;

revoke all on function public.voice_conversation_entitlement_peek(integer, integer)
  from public, anon;
grant execute on function public.voice_conversation_entitlement_peek(integer, integer)
  to authenticated;

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
language sql
security definer
set search_path = public
as $$
  select source, initial_remaining, daily_remaining
  from public.consume_voice_conversation_free_usage_legacy(
    p_session_id,
    p_initial_limit,
    p_daily_limit
  );
$$;

revoke all on function public.consume_voice_conversation_free_usage(text, integer, integer)
  from public, anon;
grant execute on function public.consume_voice_conversation_free_usage(text, integer, integer)
  to authenticated;
