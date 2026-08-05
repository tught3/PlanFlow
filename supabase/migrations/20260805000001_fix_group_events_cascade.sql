-- Fix: group_events.created_by ON DELETE CASCADE → SET NULL
-- 회원 탈퇴 시 본인이 만든 그룹 공유 일정이 자동 삭제되는 문제 해결
-- docs/account-deletion.html은 "그룹 공유 일정은 유지됩니다"라고 안내하나
-- 실제 동작과 불일치하여 수정

alter table public.group_events
  drop constraint if exists group_events_created_by_fkey,
  add constraint group_events_created_by_fkey
    foreign key (created_by) references public.users (id) on delete set null;

alter table public.group_event_comments
  drop constraint if exists group_event_comments_author_user_id_fkey,
  add constraint group_event_comments_author_user_id_fkey
    foreign key (author_user_id) references public.users (id) on delete set null;

alter table public.group_role_delegations
  drop constraint if exists group_role_delegations_delegator_user_id_fkey,
  add constraint group_role_delegations_delegator_user_id_fkey
    foreign key (delegator_user_id) references public.users (id) on delete set null;
