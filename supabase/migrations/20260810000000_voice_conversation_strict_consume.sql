-- Preserve the legacy function signature for older clients, but enforce the
-- product policy in the public RPC: exactly three initial free sessions and
-- no daily-free fallback. The legacy function keeps the row-lock and
-- session-idempotency implementation.
alter function public.consume_voice_conversation_free_usage(text, integer, integer)
  rename to consume_voice_conversation_free_usage_legacy;

create function public.consume_voice_conversation_free_usage(
  p_session_id text,
  p_initial_limit integer default 3,
  p_daily_limit integer default 0
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
  select source, initial_remaining, 0
  from public.consume_voice_conversation_free_usage_legacy(
    p_session_id,
    3,
    0
  );
$$;

revoke all on function public.consume_voice_conversation_free_usage(text, integer, integer)
  from public, anon;
grant execute on function public.consume_voice_conversation_free_usage(text, integer, integer)
  to authenticated;
