-- C2: group_events.created_by NOT NULL → nullable
-- FK가 ON DELETE SET NULL인데 컬럼이 NOT NULL이면 사용자 삭제 시 충돌
-- 이미 schema.sql과 20260805000001 에서 FK를 SET NULL로 변경했으므로
-- 컬럼 제약도 일치시킴

ALTER TABLE public.group_events
  ALTER COLUMN created_by DROP NOT NULL;

ALTER TABLE public.group_event_comments
  ALTER COLUMN author_user_id DROP NOT NULL;

ALTER TABLE public.group_role_delegations
  ALTER COLUMN delegator_user_id DROP NOT NULL;
