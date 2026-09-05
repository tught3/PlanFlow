-- Apps-in-Toss 사용자 식별 매핑 테이블.
-- Toss 앱 내 실행 컨텍스트(userKey/referrer)를 PlanFlow 계정(public.users)에 연결한다.
--
-- delete_user_account(target_user_id)는 마지막 단계에서
-- `delete from public.users where id = target_user_id`를 실행하며,
-- 이 테이블의 user_id가 public.users(id)를 on delete cascade로 참조하므로
-- 사용자가 삭제되면 이 테이블의 행도 자동으로 함께 삭제된다.
-- 즉 delete_user_account 함수 본문을 별도로 수정할 필요가 없다.

create table if not exists public.toss_identities (
  user_id uuid primary key references public.users (id) on delete cascade,
  toss_user_key text not null,
  referrer text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_login_at timestamptz
);

create unique index if not exists toss_identities_toss_user_key_uidx
  on public.toss_identities (toss_user_key);

alter table public.toss_identities enable row level security;

-- select만 허용한다. insert/update/delete 정책은 만들지 않는다 —
-- 이 매핑은 서버(Edge Function 등)가 service_role로 기록하며,
-- service_role은 RLS를 우회하므로 별도 정책이 필요 없다.
-- 클라이언트(authenticated) 쪽 쓰기는 정책 부재로 fail-closed 차단된다.
drop policy if exists "toss_identities_select_own" on public.toss_identities;
create policy "toss_identities_select_own"
  on public.toss_identities
  for select
  using (auth.uid() = user_id);

drop trigger if exists toss_identities_set_updated_at on public.toss_identities;
create trigger toss_identities_set_updated_at
  before update on public.toss_identities
  for each row execute function public.set_updated_at();
