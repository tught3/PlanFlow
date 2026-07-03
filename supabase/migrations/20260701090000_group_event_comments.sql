create table if not exists public.group_event_comments (
  id uuid primary key default gen_random_uuid(),
  group_event_id uuid not null references public.group_events (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  author_user_id uuid not null references public.users (id) on delete cascade,
  target_user_id uuid not null references public.users (id) on delete cascade,
  content text not null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists group_event_comments_group_event_id_idx
  on public.group_event_comments (group_event_id);

create index if not exists group_event_comments_group_id_idx
  on public.group_event_comments (group_id);

create index if not exists group_event_comments_target_user_id_idx
  on public.group_event_comments (target_user_id);

create index if not exists group_event_comments_created_at_desc_idx
  on public.group_event_comments (created_at desc);

create or replace function public.prevent_group_event_comment_immutable_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.group_event_id is distinct from old.group_event_id
    or new.group_id is distinct from old.group_id
    or new.author_user_id is distinct from old.author_user_id
    or new.target_user_id is distinct from old.target_user_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'group_event_comments immutable fields cannot change';
  end if;

  return new;
end;
$$;

drop trigger if exists group_event_comments_set_updated_at on public.group_event_comments;
create trigger group_event_comments_set_updated_at
  before update on public.group_event_comments
  for each row execute function public.set_updated_at();

drop trigger if exists group_event_comments_prevent_immutable_changes on public.group_event_comments;
create trigger group_event_comments_prevent_immutable_changes
  before update on public.group_event_comments
  for each row execute function public.prevent_group_event_comment_immutable_changes();

alter table public.group_event_comments enable row level security;

grant select, insert, update on table public.group_event_comments to authenticated;

drop policy if exists "group_event_comments_select_access" on public.group_event_comments;
create policy "group_event_comments_select_access"
  on public.group_event_comments
  for select
  using (
    exists (
      select 1
      from public.groups
      where groups.id = group_event_comments.group_id
        and groups.status = 'active'
    )
    and (
      public.is_group_member(group_id, auth.uid())
      or public.is_group_leader(group_id, auth.uid())
    )
  );

drop policy if exists "group_event_comments_insert_access" on public.group_event_comments;
create policy "group_event_comments_insert_access"
  on public.group_event_comments
  for insert
  with check (
    author_user_id = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
    and exists (
      select 1
      from public.groups
      where groups.id = group_event_comments.group_id
        and groups.status = 'active'
    )
    and exists (
      select 1
      from public.group_members
      where group_members.group_id = group_event_comments.group_id
        and group_members.user_id = group_event_comments.target_user_id
        and group_members.status = 'active'
    )
    -- 지시 대상(target)은 해당 그룹 일정의 공유자(created_by)여야 하고,
    -- group_event_id 가 group_id 에 실제로 속하는지도 함께 검증한다.
    and exists (
      select 1
      from public.group_events ge
      where ge.id = group_event_comments.group_event_id
        and ge.group_id = group_event_comments.group_id
        and ge.created_by = group_event_comments.target_user_id
        and ge.status = 'active'
    )
  );

drop policy if exists "group_event_comments_update_confirm" on public.group_event_comments;
create policy "group_event_comments_update_confirm"
  on public.group_event_comments
  for update
  using (
    target_user_id = auth.uid()
    and confirmed_at is null
  )
  with check (
    target_user_id = auth.uid()
    and confirmed_at is not null
  );

drop policy if exists "group_event_comments_update_leader_edit" on public.group_event_comments;
create policy "group_event_comments_update_leader_edit"
  on public.group_event_comments
  for update
  using (
    author_user_id = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
    and confirmed_at is null
  )
  with check (
    author_user_id = auth.uid()
    and public.is_group_leader(group_id, auth.uid())
    and confirmed_at is null
  );
