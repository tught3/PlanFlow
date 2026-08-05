-- Fix: group_events.created_by NOT NULL → nullable
-- C2 수정: FK가 ON DELETE SET NULL인데 컬럼이 NOT NULL이면 사용자 삭제 시 충돌

ALTER TABLE public.group_events
  ALTER COLUMN created_by DROP NOT NULL;

ALTER TABLE public.group_event_comments
  ALTER COLUMN author_user_id DROP NOT NULL;

ALTER TABLE public.group_role_delegations
  ALTER COLUMN delegator_user_id DROP NOT NULL;
