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

drop policy if exists "toss_identities_select_own" on public.toss_identities;
create policy "toss_identities_select_own"
  on public.toss_identities
  for select
  using (auth.uid() = user_id);

drop trigger if exists toss_identities_set_updated_at on public.toss_identities;
create trigger toss_identities_set_updated_at
  before update on public.toss_identities
  for each row execute function public.set_updated_at();;
