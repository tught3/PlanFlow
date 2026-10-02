create table if not exists user_behavior_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  event_name text not null,
  properties jsonb default '{}'::jsonb,
  created_at timestamp with time zone default now()
);

create index if not exists idx_behavior_logs_event_name on user_behavior_logs(event_name);
create index if not exists idx_behavior_logs_user_id on user_behavior_logs(user_id);

alter table user_behavior_logs enable row level security;

-- Drop existing policies if they exist to avoid errors on re-run
drop policy if exists "사용자는 본인의 로그만 생성 가능" on user_behavior_logs;
drop policy if exists "사용자는 본인의 로그만 조회 가능" on user_behavior_logs;

create policy "사용자는 본인의 로그만 생성 가능" on user_behavior_logs for insert with check (auth.uid() = user_id);
create policy "사용자는 본인의 로그만 조회 가능" on user_behavior_logs for select using (auth.uid() = user_id);
;
