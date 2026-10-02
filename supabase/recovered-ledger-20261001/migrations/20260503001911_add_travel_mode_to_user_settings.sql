alter table public.user_settings
  add column if not exists travel_mode text not null default 'car';;
