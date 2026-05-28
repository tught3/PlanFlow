-- Voice correction learning rules.
-- Stores minimal correction patterns, not full utterances or memos.

alter table public.user_settings
  add column if not exists voice_correction_learning_enabled boolean not null default true,
  add column if not exists voice_common_learning_opt_in boolean not null default false;

create table if not exists public.voice_correction_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  stage text not null check (stage in ('stt', 'parse')),
  field_name text not null check (
    field_name in (
      'transcript',
      'title',
      'location',
      'startAt',
      'endAt',
      'recurrence',
      'isCritical',
      'supplies'
    )
  ),
  from_text text not null,
  to_text text not null,
  context_before text not null default '',
  context_after text not null default '',
  confidence_count integer not null default 1,
  reject_count integer not null default 0,
  enabled boolean not null default true,
  is_sensitive boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint voice_correction_rules_unique unique (
    user_id,
    stage,
    field_name,
    from_text,
    to_text,
    context_before,
    context_after
  )
);

create table if not exists public.voice_common_correction_rules (
  id uuid primary key default gen_random_uuid(),
  stage text not null check (stage in ('stt', 'parse')),
  field_name text not null check (
    field_name in (
      'transcript',
      'title',
      'location',
      'startAt',
      'endAt',
      'recurrence',
      'isCritical',
      'supplies'
    )
  ),
  from_text text not null,
  to_text text not null,
  context_before text not null default '',
  context_after text not null default '',
  support_count integer not null default 0,
  conflict_count integer not null default 0,
  confidence_score double precision not null default 0,
  enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint voice_common_correction_rules_unique unique (
    stage,
    field_name,
    from_text,
    to_text,
    context_before,
    context_after
  )
);

create index if not exists voice_correction_rules_user_enabled_idx
  on public.voice_correction_rules (user_id, enabled, confidence_count desc);

create index if not exists voice_common_correction_rules_trusted_idx
  on public.voice_common_correction_rules (
    enabled,
    support_count desc,
    conflict_count,
    confidence_score desc
  );

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists voice_correction_rules_set_updated_at
  on public.voice_correction_rules;
create trigger voice_correction_rules_set_updated_at
  before update on public.voice_correction_rules
  for each row execute function public.set_updated_at();

drop trigger if exists voice_common_correction_rules_set_updated_at
  on public.voice_common_correction_rules;
create trigger voice_common_correction_rules_set_updated_at
  before update on public.voice_common_correction_rules
  for each row execute function public.set_updated_at();

alter table public.voice_correction_rules enable row level security;
alter table public.voice_common_correction_rules enable row level security;

grant select, insert, update, delete
  on table public.voice_correction_rules to authenticated;
grant select on table public.voice_common_correction_rules to authenticated;

drop policy if exists "voice_correction_rules_select_own"
  on public.voice_correction_rules;
drop policy if exists "voice_correction_rules_insert_own"
  on public.voice_correction_rules;
drop policy if exists "voice_correction_rules_update_own"
  on public.voice_correction_rules;
drop policy if exists "voice_correction_rules_delete_own"
  on public.voice_correction_rules;
drop policy if exists "voice_common_correction_rules_select_authenticated"
  on public.voice_common_correction_rules;

create policy "voice_correction_rules_select_own"
  on public.voice_correction_rules
  for select
  using (user_id = auth.uid());

create policy "voice_correction_rules_insert_own"
  on public.voice_correction_rules
  for insert
  with check (user_id = auth.uid());

create policy "voice_correction_rules_update_own"
  on public.voice_correction_rules
  for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "voice_correction_rules_delete_own"
  on public.voice_correction_rules
  for delete
  using (user_id = auth.uid());

create policy "voice_common_correction_rules_select_authenticated"
  on public.voice_common_correction_rules
  for select
  to authenticated
  using (enabled = true);
