alter table public.toss_identities
  add column if not exists disconnected_at timestamptz;

alter table public.toss_identities
  add column if not exists disconnect_referrer text;

create index if not exists idx_toss_identities_disconnected
  on public.toss_identities (disconnected_at)
  where disconnected_at is not null;

comment on column public.toss_identities.disconnected_at is
  'NULL이면 현재 연결된 상태, non-null이면 연결이 끊긴 시각. toss-disconnect-callback Edge Function이 콜백 수신 시 기록한다. public.events나 auth.users에는 영향을 주지 않는다.';

comment on column public.toss_identities.disconnect_referrer is
  '연결 끊기를 유발한 토스 콜백 referrer 값(UNLINK / WITHDRAWAL_TERMS / WITHDRAWAL_TOSS 등)의 감사(audit) 기록.';;
