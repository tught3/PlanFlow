-- Fix: group_events.created_by NOT NULL → nullable
-- C2 수정: FK가 ON DELETE SET NULL인데 컬럼이 NOT NULL이면 사용자 삭제 시 충돌

ALTER TABLE public.group_events
  ALTER COLUMN created_by DROP NOT NULL;

ALTER TABLE public.group_event_comments
  ALTER COLUMN author_user_id DROP NOT NULL;

ALTER TABLE public.group_role_delegations
  ALTER COLUMN delegator_user_id DROP NOT NULL;

-- 검증 시나리오 (주석)
-- 1. createdBy가 NULL인 일정 insert 가능해야 함:
--      insert into group_events (group_id, title, start_at, end_at, created_by)
--      values ('<gid>', '테스트', now(), now() + interval '1 hour', null);
-- 2. 사용자 삭제 시 createdBy가 자동 NULL이 되어야 함:
--      delete from users where id = '<test_user_id>';
--      select created_by from group_events where id = '<event_id>';  -- NULL
-- 3. 계정 삭제 RPC(예: delete_user_account)는 group_events.created_by를 SET NULL로
--    처리하면 충돌 없이 통과한다. comments/delegations도 동일 패턴.
