-- Apps-in-Toss 연결 끊기(Disconnect) 콜백 지원 컬럼 추가.
-- toss-disconnect-callback Edge Function이 사용자의 연결 해제 이벤트를
-- 수신했을 때 이 두 컬럼을 채운다.
--
-- 이 마이그레이션은 public.toss_identities에 컬럼과 부분 인덱스만 추가하며,
-- public.events나 auth.users에는 아무 영향이 없다 — 이 스키마의 FK 방향은
-- public.users -> public.toss_identities(user_id references public.users(id)
-- on delete cascade)이지 반대 방향이 아니므로(20260806000000_toss_identities.sql
-- 및 supabase/schema.sql 참고), toss_identities 쪽 컬럼 추가가 상위 테이블로
-- cascade될 여지가 없다.

alter table public.toss_identities
  add column if not exists disconnected_at timestamptz;

alter table public.toss_identities
  add column if not exists disconnect_referrer text;

create index if not exists idx_toss_identities_disconnected
  on public.toss_identities (disconnected_at)
  where disconnected_at is not null;

comment on column public.toss_identities.disconnected_at is
  'NULL이면 현재 연결된 상태, non-null이면 연결이 끊긴 시각. '
  'toss-disconnect-callback Edge Function이 콜백 수신 시 기록한다. '
  'public.events나 auth.users에는 영향을 주지 않는다 — 이 스키마의 FK는 '
  'public.users -> public.toss_identities 방향이며 그 반대가 아니다.';

comment on column public.toss_identities.disconnect_referrer is
  '연결 끊기를 유발한 토스 콜백 referrer 값(UNLINK / WITHDRAWAL_TERMS / '
  'WITHDRAWAL_TOSS 등)의 감사(audit) 기록.';
