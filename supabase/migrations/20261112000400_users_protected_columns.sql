-- B2: Protect profile identity and use the verified JWT email for invitations.
-- Preflight: this must return zero before creating the unique index.
-- select count(*) from (
--   select lower(invite_code) from public.users
--   where invite_code is not null
--   group by lower(invite_code) having count(*) > 1
-- ) as duplicate_codes;

begin;

create unique index if not exists users_invite_code_lower_uidx
  on public.users (lower(invite_code));

-- Auth owns the canonical email. This lookup can only answer for the caller.
create or replace function public.matches_current_auth_email(profile_email text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from auth.users
     where id = auth.uid()
       and coalesce(nullif(lower(btrim(email)), ''), '')
         = coalesce(nullif(lower(btrim(profile_email)), ''), '')
  );
$$;

revoke execute on function public.matches_current_auth_email(text) from public, anon;
grant execute on function public.matches_current_auth_email(text) to authenticated;

create or replace function public.protect_users_identity_columns()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  -- The signup and profile-sync RPCs run with their owner as current_user.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if current_user = 'anon' or new.id is distinct from auth.uid() then
    raise exception 'A profile must belong to the authenticated user.'
      using errcode = '42501';
  end if;

  if tg_op = 'INSERT' then
    if not public.matches_current_auth_email(new.email) then
      raise exception 'Profile email must match the authenticated account.'
        using errcode = '42501';
    end if;
    new.invite_code := lower(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 10));
    return new;
  end if;

  if new.id is distinct from old.id
    or new.invite_code is distinct from old.invite_code
    or (
      new.email is distinct from old.email
      and not public.matches_current_auth_email(new.email)
    )
  then
    raise exception 'Profile identity fields cannot be changed directly.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke execute on function public.protect_users_identity_columns()
  from public, anon, authenticated;

drop trigger if exists users_protect_identity_columns on public.users;
create trigger users_protect_identity_columns
  before insert or update on public.users
  for each row execute function public.protect_users_identity_columns();

drop policy if exists "users_insert_own" on public.users;
create policy "users_insert_own"
  on public.users
  for insert
  to authenticated
  with check (auth.uid() = id);

drop policy if exists "users_delete_own" on public.users;
revoke delete, truncate on table public.users from public, anon, authenticated;

create or replace function public.is_group_invite_target(
  invited_user_id_input uuid,
  invited_email_input text,
  invited_invite_code_input text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.users
    where id = auth.uid()
      and (
        (
          invited_user_id_input is not null
          and invited_user_id_input = id
        )
        or (
          invited_email_input is not null
          and lower(invited_email_input) = lower(auth.jwt() ->> 'email')
        )
        or (
          invited_invite_code_input is not null
          and invite_code is not null
          and lower(invited_invite_code_input) = lower(invite_code)
        )
      )
  );
$$;

commit;
