-- Durable, recipient-addressed notices for members removed by a leader's
-- permanent group deletion. Archive is a status UPDATE and intentionally does
-- not emit this notice.
create table if not exists public.group_deletion_notices (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references public.users (id) on delete cascade,
  deleted_group_id uuid not null,
  group_name text not null,
  deleted_by uuid references public.users (id) on delete set null,
  deleted_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists group_deletion_notices_pending_recipient_idx
  on public.group_deletion_notices (recipient_user_id, deleted_at)
  where acknowledged_at is null;

alter table public.group_deletion_notices enable row level security;
revoke all on table public.group_deletion_notices from anon;
revoke all on table public.group_deletion_notices from authenticated;
grant select on table public.group_deletion_notices to authenticated;
grant update (acknowledged_at) on table public.group_deletion_notices to authenticated;

drop policy if exists "group_deletion_notices_select_recipient"
  on public.group_deletion_notices;
create policy "group_deletion_notices_select_recipient"
  on public.group_deletion_notices
  for select
  using (recipient_user_id = auth.uid());

drop policy if exists "group_deletion_notices_ack_recipient"
  on public.group_deletion_notices;
create policy "group_deletion_notices_ack_recipient"
  on public.group_deletion_notices
  for update
  using (recipient_user_id = auth.uid() and acknowledged_at is null)
  with check (recipient_user_id = auth.uid() and acknowledged_at is not null);

create or replace function public.capture_group_deletion_notices()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Only a signed-in active leader's physical deletion emits notices. The
  -- delete RPC validates the same leader boundary; this guard keeps unrelated
  -- cascades/service maintenance from manufacturing member-facing messages.
  if auth.uid() is null
     or not public.is_group_leader(old.id, auth.uid()) then
    return old;
  end if;

  insert into public.group_deletion_notices (
    recipient_user_id,
    deleted_group_id,
    group_name,
    deleted_by,
    deleted_at
  )
  select gm.user_id, old.id, old.name, auth.uid(), now()
    from public.group_members as gm
   where gm.group_id = old.id
     and gm.status = 'active'
     and gm.removed_at is null
     and gm.user_id <> auth.uid();

  return old;
end;
$$;

revoke all on function public.capture_group_deletion_notices() from public;
revoke all on function public.capture_group_deletion_notices() from anon;
revoke all on function public.capture_group_deletion_notices() from authenticated;

drop trigger if exists groups_capture_deletion_notices on public.groups;
create trigger groups_capture_deletion_notices
  before delete on public.groups
  for each row execute function public.capture_group_deletion_notices();
