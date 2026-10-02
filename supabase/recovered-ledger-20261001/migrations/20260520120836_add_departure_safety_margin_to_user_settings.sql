alter table public.user_settings
  add column if not exists departure_safety_margin_min integer not null default 20;;
