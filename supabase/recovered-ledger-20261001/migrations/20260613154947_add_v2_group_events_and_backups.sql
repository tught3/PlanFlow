begin;

create table if not exists public.group_events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  title text not null,
  description text,
  location text,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  recurrence_type text not null default 'none',
  recurrence_until timestamptz,
  created_by uuid not null references public.users(id) on delete restrict,
  updated_by uuid references public.users(id) on delete set null,
  cancelled_at timestamptz,
  cancelled_by uuid references public.users(id) on delete set null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_events_recurrence_type_check check (recurrence_type in ('none', 'daily', 'weekly', 'monthly')),
  constraint group_events_status_check check (status in ('active', 'cancelled', 'archived')),
  constraint group_events_time_check check (end_at >= start_at)
);

create table if not exists public.group_backups (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  backup_type text not null,
  snapshot jsonb not null,
  created_by uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  restored_at timestamptz,
  restored_by uuid references public.users(id) on delete set null,
  constraint group_backups_backup_type_check check (backup_type in ('archive', 'delete'))
);

create index if not exists group_events_group_id_idx on public.group_events (group_id);
create index if not exists group_events_created_by_idx on public.group_events (created_by);
create index if not exists group_events_updated_by_idx on public.group_events (updated_by);
create index if not exists group_events_cancelled_by_idx on public.group_events (cancelled_by);
create index if not exists group_events_status_idx on public.group_events (status);
create index if not exists group_events_start_at_idx on public.group_events (start_at);
create index if not exists group_events_group_start_idx on public.group_events (group_id, start_at);
create index if not exists group_events_group_status_start_idx on public.group_events (group_id, status, start_at);

create index if not exists group_backups_group_id_idx on public.group_backups (group_id);
create index if not exists group_backups_created_by_idx on public.group_backups (created_by);
create index if not exists group_backups_restored_by_idx on public.group_backups (restored_by);
create index if not exists group_backups_created_at_idx on public.group_backups (created_at);

create trigger group_events_set_updated_at
before update on public.group_events
for each row execute function public.set_updated_at();

commit;;
