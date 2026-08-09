-- Keep existing columns for compatibility, but disable the retired daily-free path
-- for all future default RPC calls.
alter function public.voice_conversation_entitlement_peek(integer, integer)
  rename to voice_conversation_entitlement_peek_legacy;

create function public.voice_conversation_entitlement_peek(
  p_initial_limit integer default 3,
  p_daily_limit integer default 0
)
returns table (initial_remaining integer, daily_remaining integer, requires_ad boolean)
language sql security definer set search_path = public as $$
  select initial_remaining, 0, initial_remaining = 0
  from public.voice_conversation_entitlement_peek_legacy(p_initial_limit, 0);
$$;

grant execute on function public.voice_conversation_entitlement_peek(integer, integer) to authenticated;
