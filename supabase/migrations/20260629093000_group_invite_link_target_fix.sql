-- Keep link-created invites compatible with the production target check:
-- exactly one of invited_user_id, invited_email, invited_invite_code.

create or replace function public.accept_group_invite_link(
  group_id_input uuid,
  invite_token_input text
)
returns public.group_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  group_row public.groups%rowtype;
  profile_row public.users%rowtype;
  invite_row public.group_invites%rowtype;
  updated_invite public.group_invites%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if group_id_input is null or trim(coalesce(invite_token_input, '')) = '' then
    raise exception '초대 링크가 올바르지 않습니다.';
  end if;

  select *
    into group_row
    from public.groups
   where id = group_id_input
     and invite_token = lower(trim(invite_token_input))
     and status = 'active';

  if not found then
    raise exception '초대 링크가 유효하지 않습니다.';
  end if;

  if exists (
    select 1
      from public.group_members
     where group_id = group_row.id
       and user_id = auth.uid()
       and status = 'active'
  ) then
    raise exception '이미 활성 멤버입니다.';
  end if;

  select *
    into profile_row
    from public.users
   where id = auth.uid();

  select *
    into invite_row
    from public.group_invites
   where group_id = group_row.id
     and invited_user_id = auth.uid()
     and status = 'pending'
   order by created_at desc
   limit 1
   for update;

  if not found then
    insert into public.group_invites (
      group_id,
      invited_user_id,
      invited_email,
      invited_invite_code,
      invited_by,
      status,
      expires_at,
      created_at,
      updated_at
    )
    values (
      group_row.id,
      auth.uid(),
      null,
      null,
      group_row.created_by,
      'pending',
      now() + interval '7 days',
      now(),
      now()
    )
    returning * into invite_row;
  end if;

  if invite_row.expires_at <= now() then
    raise exception '만료된 초대는 수락할 수 없습니다.';
  end if;

  insert into public.group_members (
    group_id,
    user_id,
    role,
    status,
    joined_at,
    removed_at,
    removed_by,
    created_at,
    updated_at
  )
  values (
    group_row.id,
    auth.uid(),
    'member',
    'active',
    now(),
    null,
    null,
    now(),
    now()
  )
  on conflict (group_id, user_id) do update
     set role = 'member',
         status = 'active',
         joined_at = now(),
         removed_at = null,
         removed_by = null,
         updated_at = now();

  update public.group_invites
     set status = 'accepted',
         accepted_at = now(),
         acted_by = auth.uid()
   where id = invite_row.id
   returning * into updated_invite;

  return updated_invite;
end;
$$;

grant execute on function public.accept_group_invite_link(uuid, text)
  to authenticated;
