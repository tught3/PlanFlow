begin;

alter table public.group_invites enable row level security;
alter table public.group_role_delegations enable row level security;

grant select, insert, update, delete on public.group_invites to authenticated;
grant select, insert, update, delete on public.group_role_delegations to authenticated;

commit;;
