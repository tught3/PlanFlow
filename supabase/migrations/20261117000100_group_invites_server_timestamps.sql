begin;

create or replace function public.set_group_invite_insert_timestamps()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $$
begin
  -- Restore and service writes keep their historical timestamps.
  if current_user in ('authenticated', 'anon') then
    new.created_at := now();
    if new.expires_at > new.created_at + interval '7 days' then
      new.expires_at := new.created_at + interval '7 days';
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.set_group_invite_insert_timestamps()
  from public, anon, authenticated;

drop trigger if exists group_invites_set_insert_timestamps on public.group_invites;
create trigger group_invites_set_insert_timestamps
  before insert on public.group_invites
  for each row execute function public.set_group_invite_insert_timestamps();

commit;
