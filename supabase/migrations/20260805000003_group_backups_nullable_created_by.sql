-- C2 후속: group_backups.created_by NOT NULL → nullable
-- FK가 ON DELETE SET NULL인데 컬럼이 NOT NULL이면 사용자 삭제 시 충돌
-- (group_events와 동일한 버그 패턴, supabase/schema.sql의 group_backups
--  정의도 이미 nullable로 맞춰둠)

ALTER TABLE public.group_backups
  ALTER COLUMN created_by DROP NOT NULL;
