# PlanFlow V2 Schema SQL Final Draft

이 문서는 [09-v2-final-master-design.md](./09-v2-final-master-design.md), [10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md), [11-v2-erd-draft.md](./11-v2-erd-draft.md), [12-v2-rls-policy-design.md](./12-v2-rls-policy-design.md), [13-v2-schema-sql-draft.md](./13-v2-schema-sql-draft.md), [15-v2-erd-review.md](./15-v2-erd-review.md)를 기준으로 작성한 V2 실제 적용 전 최종 SQL 초안이다.

이 문서는 검토용 초안이며, 실제 `supabase/schema.sql`에는 반영하지 않는다.

## 1. 문서 목적

- 실제 적용 전 최종 SQL 초안 정리
- `supabase/schema.sql` 수정 금지
- 기존 개인 일정 테이블 유지
- V2 테이블만 별도로 추가하는 전제

## 2. profiles 확장 SQL

### 반영 방향

- `invite_code`는 `profiles`에 둔다.
- `invite_code`는 unique로 관리한다.
- `invite_code` 인덱스를 둔다.
- `updated_at`은 유지하는 편이 좋다.

### SQL 초안 포인트

- `invite_code` text unique
- `invite_code` index candidate
- `updated_at` timestamp nullable/managed

### 주의사항

- `auth.users`를 직접 확장하는 방식은 피한다.
- invite_code는 초대 식별과 초대 수락 검증에만 사용한다.

## 3. groups SQL

### 반영 방향

- `parent_group_id` self reference
- `status`는 `active / archived / deleted_pending`
- `created_by` 포함
- `archived_at` 포함
- `created_at / updated_at` 포함
- `restored_at / restored_by`는 두지 않는다

### SQL 초안 포인트

- `id`
- `parent_group_id` nullable self FK
- `name`
- `description` nullable
- `status`
- `created_by`
- `archived_at` nullable
- `created_at`
- `updated_at`

### 제외 명시

- `restored_at`
- `restored_by`

### 주의사항

- 복원 이력은 `group_backups`에서 관리한다.
- parent/child 관계는 recursive tree를 전제로 한다.

## 4. group_members SQL

### 반영 방향

- `role`은 `leader / member`
- `status`는 `active / removed`
- `removed_at` 추가
- `removed_by` 추가
- `unique(group_id, user_id)` 필요

### SQL 초안 포인트

- `id`
- `group_id`
- `user_id`
- `role`
- `status`
- `joined_at`
- `removed_at`
- `removed_by`
- `created_at`
- `updated_at`

### 인덱스 후보

- `group_id`
- `user_id`
- `(group_id, role)`
- `(group_id, status)`

### 주의사항

- membership 삭제는 상태 전환으로 다룬다.
- primary group 전용 필드는 두지 않는다.

## 5. group_invites SQL

### 반영 방향

- 상태는 `pending / accepted / rejected / cancelled / expired`
- `invited_user_id / invited_email / invited_invite_code` nullable 구조 유지
- `invited_by` 포함
- `accepted_at` 추가
- `rejected_at` 추가
- `cancelled_at` 추가
- `expired_at` 추가
- `acted_by` 추가

### SQL 초안 포인트

- `id`
- `group_id`
- `invited_user_id` nullable
- `invited_email` nullable
- `invited_invite_code` nullable
- `invited_by`
- `status`
- `expires_at`
- `accepted_at` nullable
- `rejected_at` nullable
- `cancelled_at` nullable
- `expired_at` nullable
- `acted_by` nullable
- `created_at`
- `updated_at`

### pending 중복 방지 partial unique index 후보

- `group_id + invited_user_id` where `status = 'pending'`
- `group_id + lower(invited_email)` where `status = 'pending'`
- `group_id + invited_invite_code` where `status = 'pending'`

### 주의사항

- 이미 member인 사용자는 초대 불가다.
- 초대 ID 또는 이메일 둘 다 허용하되 중복 pending은 막아야 한다.

## 6. group_role_delegations SQL

### 반영 방향

- `permissions`는 `jsonb`
- `starts_at / ends_at` 포함
- `status`는 `active / expired / cancelled`
- `cancelled_at` 추가
- `cancelled_by` 추가

### SQL 초안 포인트

- `id`
- `group_id`
- `delegator_user_id`
- `delegate_user_id`
- `permissions` jsonb
- `starts_at`
- `ends_at`
- `status`
- `cancelled_at` nullable
- `cancelled_by` nullable
- `created_at`
- `updated_at`

### 인덱스 후보

- `group_id`
- `delegate_user_id`
- `(group_id, delegate_user_id, status)`
- `(starts_at, ends_at)`

### 주의사항

- role 자체 변경은 하지 않는다.
- delegation은 기간과 permissions 안에서만 유효하다.

## 7. group_events SQL

### 반영 방향

- `recurrence_type`은 `none / daily / weekly / monthly`
- `status`는 `active / cancelled / archived`
- `cancelled_at` 추가
- `cancelled_by` 추가
- `group_id + start_at` 인덱스 준비
- 기존 `events`와 분리 명시

### SQL 초안 포인트

- `id`
- `group_id`
- `title`
- `description` nullable
- `location` nullable
- `start_at`
- `end_at`
- `all_day`
- `recurrence_type`
- `recurrence_until` nullable
- `created_by`
- `updated_by` nullable
- `status`
- `cancelled_at` nullable
- `cancelled_by` nullable
- `created_at`
- `updated_at`

### 인덱스 후보

- `group_id`
- `start_at`
- `group_id + start_at`
- `created_by`
- `status`

### 주의사항

- 개인 `events`와 절대 섞지 않는다.
- 캘린더 UI에서만 오버레이한다.
- 반복 일정은 V2 범위에서만 단순화된 형태로 유지한다.

## 8. group_backups SQL

### 반영 방향

- `snapshot`은 `jsonb`
- `backup_type`은 `archive / delete`
- `restored_at` 포함
- `restored_by` 포함
- parent/child group archive 복원 고려 필요

### SQL 초안 포인트

- `id`
- `group_id`
- `backup_type`
- `snapshot` jsonb
- `created_by`
- `created_at`
- `restored_at` nullable
- `restored_by` nullable

### 주의사항

- 복원 이력은 `group_backups`가 기준이 된다.
- 부모 그룹 archive 시 자식 그룹 포함 여부는 SQL만으로 해결하지 말고 제품 정책과 함께 본다.

## 9. RLS helper functions 후보

SQL 실제 구현 전 helper 후보를 정리한다.

- `is_group_member(group_id, user_id)`
- `is_group_leader(group_id, user_id)`
- `get_descendant_group_ids(group_id)`
- `can_view_group(group_id, user_id)`
- `can_manage_group_event(group_id, user_id)`
- `has_group_delegated_permission(group_id, user_id, permission)`

### 주의사항

- recursive group tree 때문에 helper function이 사실상 필요하다.
- archived group 제외 규칙은 helper 또는 공통 정책에 일관되게 반영해야 한다.
- `SECURITY DEFINER` 여부는 SQL Final에서 별도 검토가 필요하다.

## 10. 적용 순서

1. `profiles` invite_code
2. `groups`
3. `group_members`
4. `group_invites`
5. `group_role_delegations`
6. `group_events`
7. `group_backups`
8. helper functions
9. RLS policies

## 11. V2 제외

아래는 SQL Final에서도 제외한다.

- `meeting_notes`
- `action_items`
- `tasks`
- `coaching_reports`
- `vector_embeddings`
- AI 회의록
- AI 코칭
- 성과 분석

## 12. SQL 적용 전 주의사항

- 현재 워킹트리에 `.planning/context/ACTIVE_SUMMARY.md` 충돌 표식이 남아 있으면 실제 SQL 적용 전에 반드시 해결해야 한다.
- 실제 `supabase/schema.sql` 반영은 별도 작업으로 진행한다.
- 실제 코드 구현 전 `agents.md` 확인이 필요하다.

## 13. 최종 결론

V2 SQL Final 초안은 ERD 리뷰 결과를 반영했으며, 실제 적용 전에는 이 문서와 [15-v2-erd-review.md](./15-v2-erd-review.md), [12-v2-rls-policy-design.md](./12-v2-rls-policy-design.md)를 함께 검토해야 한다.
