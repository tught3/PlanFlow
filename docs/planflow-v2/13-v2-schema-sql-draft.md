# PlanFlow V2 Schema SQL Draft

이 문서는 V2 ERD와 RLS 정책을 기준으로 실제 적용 전 검토용 SQL 초안이다.

- 실제 `supabase/schema.sql` 수정 금지
- 기존 개인 일정 테이블 `events` / `pre_actions` / `reminders` / `voice_logs`는 유지
- V2 테이블은 기존 개인 기능과 분리

## 1. 문서 목적

- 실제 적용 전 검토용 SQL 초안이다.
- 스키마 반영이 아니라 검토/합의용 문서다.
- 개인 일정과 그룹 일정은 저장 구조부터 분리한다.

## 2. `profiles` / `users` 확장 초안

### 필드 후보

- `invite_code` unique
- `display_name`
- `email`
- `created_at`
- `updated_at`

### 고려사항

- `invite_code` 생성과 중복 방지 정책 필요
- `profiles`에 둘지 `users` 확장으로 둘지 구현 전 확인 필요

### 인덱스 후보

- `invite_code` unique index
- `email` index

## 3. `groups` SQL 초안

### 필드 후보

- `id`
- `parent_group_id` nullable self reference
- `name`
- `description` nullable
- `status` active/archived/deleted_pending
- `created_by`
- `archived_at` nullable
- `created_at`
- `updated_at`

### 포함 고려사항

- `parent_group_id` self FK
- `created_by` FK
- `status` check constraint 또는 enum 후보
- `parent_group_id` 인덱스
- `status` 인덱스
- `created_by` 인덱스

### 주의

- recursive group tree 구조를 전제로 한다.
- parent archived 시 child 조회 정책은 RLS와 쿼리에서 함께 고려한다.

## 4. `group_members` SQL 초안

### 필드 후보

- `id`
- `group_id`
- `user_id`
- `role` leader/member
- `status` active/removed
- `joined_at`
- `created_at`
- `updated_at`

### 포함 고려사항

- `unique(group_id, user_id)`
- `group_id` 인덱스
- `user_id` 인덱스
- `role` / `status` check constraint 또는 enum 후보

### 주의

- user 자체 role은 금지한다.
- role은 membership에만 존재한다.
- `removed`는 삭제가 아니라 상태 전환이다.

## 5. `group_invites` SQL 초안

### 필드 후보

- `id`
- `group_id`
- `invited_user_id` nullable
- `invited_email` nullable
- `invited_invite_code` nullable
- `invited_by`
- `status` pending/accepted/rejected/cancelled/expired
- `expires_at`
- `accepted_at` nullable
- `created_at`
- `updated_at`

### 포함 고려사항

- `group_id` FK
- `invited_by` FK
- `invited_user_id` FK nullable
- pending 중복 초대 방지 후보
- `status` 인덱스
- `expires_at` 인덱스

### 주의

- 초대 ID 또는 이메일 둘 다 가능
- 이미 `group_members`인 사용자는 초대 불가
- pending 중복 초대 불가
- 만료 후 수락 불가

## 6. `group_role_delegations` SQL 초안

### 필드 후보

- `id`
- `group_id`
- `delegator_user_id`
- `delegate_user_id`
- `permissions` jsonb
- `starts_at`
- `ends_at`
- `status` active/expired/cancelled
- `created_at`
- `updated_at`

### 포함 고려사항

- `group_id` FK
- `delegator_user_id` FK
- `delegate_user_id` FK
- 기간 인덱스
- `status` 인덱스

### permissions 예시

- `create_group_event`
- `update_group_event`
- `cancel_group_event`
- `view_group_dashboard`

### 금지 권한

- `delete_group`
- `create_child_group`
- `remove_member`
- `delegate_permission`
- `permanent_delete`

### 주의

- role 자체 변경은 금지다.
- 기간 만료 시 무효다.
- delegation 해석 복잡도 리스크가 있다.

## 7. `group_events` SQL 초안

### 필드 후보

- `id`
- `group_id`
- `title`
- `description` nullable
- `location` nullable
- `start_at`
- `end_at`
- `all_day` boolean
- `recurrence_type` none/daily/weekly/monthly
- `recurrence_until` nullable
- `created_by`
- `updated_by` nullable
- `status` active/cancelled/archived
- `created_at`
- `updated_at`

### 포함 고려사항

- `group_id` FK
- `created_by` FK
- `updated_by` FK nullable
- `start_at` / `end_at` 인덱스
- `group_id + start_at` 복합 인덱스
- `recurrence_type` check constraint 또는 enum 후보

### 주의

- 기존 개인 `events`와 분리한다.
- UI에서만 개인 일정 + 그룹 일정 오버레이한다.
- 복잡한 RRULE은 V2 제외다.
- 반복 일정은 `none/daily/weekly/monthly`만 지원한다.

## 8. `group_backups` SQL 초안

### 필드 후보

- `id`
- `group_id`
- `backup_type` archive/delete
- `snapshot` jsonb
- `created_by`
- `created_at`
- `restored_at` nullable
- `restored_by` nullable

### 포함 고려사항

- `group_id` FK
- `created_by` FK
- `restored_by` FK nullable
- `backup_type` check constraint 또는 enum 후보

### 주의

- archived 전 snapshot 저장
- 특정 leader 개인 소유가 아니라 시스템 데이터
- 복원 범위는 별도 정책이 필요

## 9. RLS 적용 순서 초안

실제 SQL은 작성하지 않고 순서만 정리한다.

1. `profiles` / `users` invite_code
2. `groups`
3. `group_members`
4. `group_invites`
5. `group_role_delegations`
6. `group_events`
7. `group_backups`

## 10. SQL 적용 전 확인사항

- `profiles` / `users` 확장 위치
- recursive group tree 처리 방식
- RLS helper function 필요 여부
- archived group 기본 조회 제외 방식
- `group_events` 반복 일정 생성 방식
- delegation `permissions` jsonb 구조 확정 여부

## 11. V2 제외 테이블 명시

이번 SQL 초안에서 제외한다.

- `meeting_notes`
- `meeting_note_versions`
- `meeting_tags`
- `action_items`
- `tasks`
- `coaching_reports`
- `vector_embeddings`

## 12. 최종 결론

이 문서는 실제 적용 전 검토용 초안이며, V2의 그룹형 일정 공유 기능만 다룬다.

실제 스키마 반영 전에는 [11-v2-erd-draft.md](./11-v2-erd-draft.md)와 [12-v2-rls-policy-design.md](./12-v2-rls-policy-design.md)와 함께 검토해야 한다.
