-- New settings records opt in to verified common correction by default.
-- Existing rows (including an explicit false) are intentionally unchanged.
alter table public.user_settings
  alter column voice_common_learning_opt_in set default true;
