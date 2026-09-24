-- Keep legacy backup functions working while the canonical membership field is removed_at.
alter table public.group_members
  add column if not exists left_at timestamptz generated always as (removed_at) stored;

create table if not exists public.group_deletion_notices (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references public.users (id) on delete cascade,
  group_name text not null,
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz
);

create index if not exists group_deletion_notices_recipient_pending_idx
  on public.group_deletion_notices (recipient_user_id, created_at)
  where acknowledged_at is null;

alter table public.group_deletion_notices enable row level security;
revoke all on table public.group_deletion_notices from public, anon, authenticated;

create or replace function public.create_group_deletion_notices_before_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
     or not public.is_group_leader(old.id, auth.uid()) then
    return old;
  end if;

  insert into public.group_deletion_notices (recipient_user_id, group_name)
  select gm.user_id, old.name
    from public.group_members gm
   where gm.group_id = old.id
     and gm.status = 'active'
     and gm.user_id is distinct from auth.uid();

  return old;
end;
$$;
revoke all on function public.create_group_deletion_notices_before_delete() from public, anon, authenticated;

drop trigger if exists groups_create_deletion_notices on public.groups;
create trigger groups_create_deletion_notices
  before delete on public.groups
  for each row execute function public.create_group_deletion_notices_before_delete();

create or replace function public.list_my_group_deletion_notices()
returns setof public.group_deletion_notices
language sql
security definer
set search_path = public
as $$
  select notice.*
    from public.group_deletion_notices notice
   where auth.uid() is not null
     and notice.recipient_user_id = auth.uid()
     and notice.acknowledged_at is null
   order by notice.created_at, notice.id;
$$;
revoke all on function public.list_my_group_deletion_notices() from public, anon, authenticated;

create or replace function public.acknowledge_group_deletion_notice(notice_id_input uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  update public.group_deletion_notices
     set acknowledged_at = coalesce(acknowledged_at, now())
   where id = notice_id_input
     and recipient_user_id = auth.uid();
end;
$$;
revoke all on function public.acknowledge_group_deletion_notice(uuid) from public, anon, authenticated;

grant execute on function public.list_my_group_deletion_notices() to authenticated;
grant execute on function public.acknowledge_group_deletion_notice(uuid) to authenticated;
