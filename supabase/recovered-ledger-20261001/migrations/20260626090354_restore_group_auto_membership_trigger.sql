create or replace function public.handle_new_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.group_members (
    group_id,
    user_id,
    role,
    status,
    joined_at,
    created_at,
    updated_at
  )
  values (
    new.id,
    new.created_by,
    'leader',
    'active',
    now(),
    now(),
    now()
  )
  on conflict (group_id, user_id) do update
    set role = 'leader',
        status = 'active',
        removed_at = null,
        removed_by = null,
        joined_at = now(),
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists groups_handle_new_group on public.groups;
create trigger groups_handle_new_group
  after insert on public.groups
  for each row execute function public.handle_new_group();;
