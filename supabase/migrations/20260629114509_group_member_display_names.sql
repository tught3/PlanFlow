alter table public.users
  add column if not exists display_name text;

alter table public.group_members
  add column if not exists display_name text;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, name, display_name)
  values (
    new.id,
    new.email,
    coalesce(
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'nickname'
    ),
    coalesce(
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'nickname'
    )
  )
  on conflict (id) do update
    set email = excluded.email,
        name = coalesce(excluded.name, public.users.name),
        display_name = coalesce(public.users.display_name, excluded.display_name);

  return new;
end;
$$;

alter table public.group_invites
  drop constraint if exists group_invites_target_required_check;

alter table public.group_invites
  drop constraint if exists group_invites_target_check;

alter table public.group_invites
  add constraint group_invites_target_check
  check (num_nonnulls(invited_user_id, invited_email, invited_invite_code) = 1);

create or replace function public.ensure_current_user_profile()
returns public.users
language plpgsql
security definer
set search_path = public
as $$
declare
  auth_user_row auth.users%rowtype;
  profile public.users%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
    into auth_user_row
    from auth.users
   where id = auth.uid();

  insert into public.users (id, email, name, display_name, invite_code)
  values (
    auth.uid(),
    auth_user_row.email,
    coalesce(
      auth_user_row.raw_user_meta_data ->> 'name',
      auth_user_row.raw_user_meta_data ->> 'full_name',
      auth_user_row.raw_user_meta_data ->> 'nickname'
    ),
    coalesce(
      auth_user_row.raw_user_meta_data ->> 'name',
      auth_user_row.raw_user_meta_data ->> 'full_name',
      auth_user_row.raw_user_meta_data ->> 'nickname'
    ),
    lower(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 10))
  )
  on conflict (id) do update
    set email = excluded.email,
        name = coalesce(public.users.name, excluded.name),
        display_name = coalesce(public.users.display_name, excluded.display_name),
        invite_code = coalesce(
          nullif(public.users.invite_code, ''),
          lower(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 10))
        )
  returning * into profile;

  return profile;
end;
$$;

revoke all on function public.ensure_current_user_profile() from public;
grant execute on function public.ensure_current_user_profile() to authenticated;

drop policy if exists "users_select_group_members" on public.users;
create policy "users_select_group_members"
  on public.users
  for select
  using (
    exists (
      select 1
      from public.group_members my_membership
      join public.group_members target_membership
        on target_membership.group_id = my_membership.group_id
      join public.groups
        on groups.id = my_membership.group_id
      where my_membership.user_id = auth.uid()
        and my_membership.status = 'active'
        and target_membership.user_id = public.users.id
        and target_membership.status = 'active'
        and groups.status = 'active'
    )
  );
