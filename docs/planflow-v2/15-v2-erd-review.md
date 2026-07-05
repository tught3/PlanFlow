# PlanFlow V2 ERD Review

이 문서는 [09-v2-final-master-design.md](./09-v2-final-master-design.md), [10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md), [11-v2-erd-draft.md](./11-v2-erd-draft.md), [12-v2-rls-policy-design.md](./12-v2-rls-policy-design.md), [13-v2-schema-sql-draft.md](./13-v2-schema-sql-draft.md), [14-v2-flutter-module-plan.md](./14-v2-flutter-module-plan.md)를 기준으로 V2 ERD와 SQL 초안의 최종 검수 포인트를 정리한다.

이 문서는 검토/보완용이며, 실제 SQL 반영이나 코드 구현은 하지 않는다.

## 1. 검토 결과 요약

- V2 ERD의 큰 방향은 타당하다.
- 개인 일정과 그룹 일정을 분리한 구조는 유지해야 한다.
- `profiles/users`, `groups`, `group_members`, `group_invites`, `group_role_delegations`, `group_events`, `group_backups` 범위는 적절하다.
- 다만 RLS와 SQL Final 단계에서 바로 반영해야 할 보완점이 몇 가지 있다.
- 가장 큰 리스크는 recursive group tree, invite 상태 이력, membership 이력, delegation 기간 해석, archived group 복원 흐름이다.

## 2. 테이블/컬럼 검토

### 2.1 profiles / users

검토 결론:

- `invite_code`는 `profiles` 확장에 두는 방향을 유지하는 것이 맞다.
- `auth.users`를 직접 수정하는 방식은 피하는 것이 안전하다.
- `invite_code` unique 제약은 필요하다.
- `invite_code` 재발급 가능성은 운영 규칙으로 열어둘 수 있지만, V2 ERD에 별도 테이블까지 추가할 필요는 없다.

보완 판단:

- `invite_code`는 초대 식별자 역할만 하도록 유지한다.
- 공개 프로필 목록에서 과도하게 노출되지 않도록 정책을 문서화해야 한다.
- `updated_at`은 프로필 수정 추적용으로 유지하는 편이 좋다.

### 2.2 groups

검토 결론:

- `parent_group_id` 재귀 구조는 충분하다.
- `status`는 `active / archived / deleted_pending`으로 유지해도 된다.
- `archived_at`만으로 archive 시점을 추적하는 것은 충분하다.
- `restored_at / restored_by`는 `groups`에 넣기보다 `group_backups` 복원 이력으로 두는 편이 더 깔끔하다.
- `created_by`는 필요하다.
- `updated_by`는 V2 필수는 아니다.

보완 판단:

- `deleted_pending`는 V2에서 permanent delete를 실제로 내지 않는다면 필수는 아니다.
- 다만 향후 확장 여지를 남기려면 status 후보로 유지할 수는 있다.
- archive 복원 감사 정보는 `groups`가 아니라 `group_backups`에서 관리하는 편이 더 일관적이다.

### 2.3 group_members

검토 결론:

- `unique(group_id, user_id)`는 필수다.
- `role`은 `leader / member`만으로 충분하다.
- `status`는 `active / removed`만으로도 충분하다.
- 기본 group context를 위해 `is_primary_group`를 ERD에 넣는 것은 비추천이다.
- `joined_at`은 유지하고, `removed_at`과 `removed_by`는 추가하는 편이 좋다.

보완 판단:

- 기본 group context는 별도 `user_preferences` 계열 저장소나 앱의 최근 선택값으로 처리하는 편이 낫다.
- membership 자체에 primary 플래그를 두면 다중 group 구조와 충돌하기 쉽다.
- 제거는 삭제가 아니라 상태 전환으로 기록해야 한다.

### 2.4 group_invites

검토 결론:

- `invited_user_id / invited_email / invited_invite_code`의 nullable 구조는 적절하다.
- 초대 수락 시에는 실제 로그인 사용자와 초대 대상 값의 매칭을 다시 확인해야 한다.
- `accepted_at` 외에 `rejected_at / cancelled_at / expired_at`을 두는 것이 이력 관리에 더 안전하다.
- `acted_by`도 있으면 운영 추적에 도움이 된다.

보완 판단:

- pending 중복 초대 방지를 위해 partial unique index가 필요하다.
- `group_id + invited_user_id`는 pending에서 unique하도록 검토한다.
- `group_id + lower(invited_email)`도 pending에서 unique하도록 검토한다.
- `group_id + invited_invite_code`도 pending에서 unique하도록 검토한다.

### 2.5 group_role_delegations

검토 결론:

- `permissions jsonb`는 V2 범위에서는 적절하다.
- 별도 enum 테이블로 분리할 필요는 아직 없다.
- `starts_at / ends_at / status`만으로도 만료 처리는 가능하다.
- `cancelled_at / cancelled_by`는 추가하는 편이 좋다.

보완 판단:

- role 자체 변경이 아니라 delegation 레코드로 관리하는 방향을 유지한다.
- V2에서는 권한 문자열을 소수의 허용값으로 제한한다.
- JSONB는 유연하지만, 허용 키 목록은 문서와 코드에서 고정해야 한다.

### 2.6 group_events

검토 결론:

- `created_by / updated_by`는 적절하다.
- `cancelled_by / cancelled_at`은 추가하는 편이 좋다.
- `status active / cancelled / archived`는 충분하다.
- `recurrence_type none / daily / weekly / monthly`는 V2 범위에 충분하다.
- `recurrence_until`만으로 반복 종료 조건을 표현하는 것도 충분하다.
- 참석자 전용 테이블은 V2에 넣지 않는 것이 맞다.

보완 판단:

- 그룹 일정은 그룹 전체 공유 일정이므로 별도의 attendee 모델이 없어도 된다.
- `all_day`와 `start_at / end_at` 조합은 일반적인 캘린더 표현에 적절하다.
- cancellation audit는 나중에 지원 문의와 복원 이력 추적에 도움이 된다.

### 2.7 group_backups

검토 결론:

- `snapshot jsonb`는 적절하다.
- `backup_type archive / delete`도 충분하다.
- `restored_at / restored_by`는 충분하다.
- parent group archive 시 child group snapshot 처리 방식은 문서와 복원 절차에서 명시해야 한다.

보완 판단:

- `group_backups`는 단순 복구 메타데이터가 아니라 복원 기준점 역할을 하게 된다.
- child group을 함께 복원할지 선택하는 정책은 SQL보다 상위의 제품 규칙으로 관리하는 편이 좋다.

## 3. 관계/인덱스 검토

### 유지할 인덱스

- `groups(parent_group_id)`
- `groups(status)`
- `group_members(group_id, user_id)` unique
- `group_members(user_id)`
- `group_members(group_id, role)`
- `group_invites(group_id, status)`
- `group_invites(invited_email)`
- `group_invites(invited_invite_code)`
- `group_role_delegations(group_id, delegate_user_id, status)`
- `group_events(group_id, start_at)`
- `group_events(created_by)`
- `group_backups(group_id)`

### 추가 검토가 필요한 인덱스

- `groups(parent_group_id, status)`는 archive 제외 조회가 많다면 고려할 만하다.
- `group_events(group_id, status, start_at)`는 일정 목록이 많을 때 도움이 될 수 있다.
- `group_invites(invited_user_id)`는 수락/조회 경로가 많다면 유지 가치가 있다.

### 과한 인덱스 가능성

- `group_members(user_id, status)`는 실제 조회 패턴을 보고 결정해도 늦지 않다.
- `group_role_delegations(starts_at, ends_at)`는 기간 검색이 빈번하지 않으면 후순위로 둘 수 있다.

## 4. RLS / Helper Function 검토

### 권장 helper 후보

- `is_group_member(group_id, user_id)`
- `is_group_leader(group_id, user_id)`
- `has_group_permission(group_id, user_id, permission)`
- `can_view_group(group_id, user_id)`
- `can_manage_group_event(group_id, user_id)`
- `get_descendant_group_ids(group_id)`

### 검토 결론

- recursive group tree 때문에 helper function 없이 RLS만으로 처리하면 복잡도가 높아진다.
- `get_descendant_group_ids`는 필요성이 높다.
- `SECURITY DEFINER` 여부는 성능과 보안 범위를 함께 보고 결정해야 한다.
- archived group 제외는 helper 내부 또는 공통 정책 helper에서 선처리하는 편이 낫다.

### 주의점

- helper가 너무 많아지면 정책 해석이 어려워진다.
- 조회 정책과 수정 정책은 같은 조건으로 묶지 않는 것이 좋다.
- helper는 쿼리 성능과 정책 가독성 사이의 균형이 중요하다.

## 5. V2 범위 이탈 여부

V2 ERD / SQL 초안에서 제외해야 하는 항목은 다음과 같다.

- `meeting_notes`
- `meeting_note_versions`
- `meeting_tags`
- `meeting_favorites`
- `action_items`
- `tasks`
- `coaching_reports`
- `vector_embeddings`
- AI 회의록
- AI 코칭
- 성과 분석

검토 결과:

- 현재 기준 문서들에는 위 항목이 V2 본문으로 끼어들어 있지 않다.
- `meeting_notes`, `action_items`, `tasks`, `coaching_reports`는 V2.5 / V3 예약 범위로 유지하는 것이 맞다.

## 6. SQL Final 전 반드시 반영할 수정사항

- `invite_code`는 `profiles`에 둔다.
- `group_members`에 `removed_at / removed_by`를 추가한다.
- `group_invites`에 `rejected_at / cancelled_at / expired_at / acted_by`를 추가하는 것을 우선 검토한다.
- `group_role_delegations`에 `cancelled_at / cancelled_by`를 추가한다.
- `group_events`에 `cancelled_at / cancelled_by`를 추가한다.
- `groups`에는 `restored_at / restored_by`를 두지 말고 `group_backups`로 복원 이력을 관리한다.
- `is_primary_group`는 ERD에 넣지 않는다.
- helper functions는 SQL Final에서 사실상 필요하다.
- partial unique index를 `group_invites` pending 중복 방지용으로 준비한다.

## 7. SQL Final 진행 가능 여부

가능하다.

다만 아래 조건을 반영한 뒤에 SQL Final로 넘어가는 것이 안전하다.

- invite와 membership 이력 컬럼을 정리할 것
- delegation과 event cancellation audit를 추가할 것
- recursive group tree helper를 전제로 RLS를 설계할 것
- archived group 제외 규칙을 helper와 정책에 일관되게 반영할 것

## 8. 최종 결론

V2 ERD와 SQL 초안은 전체적으로 방향이 맞다.

지금 단계에서 가장 중요한 것은 새로운 큰 구조를 더하는 것이 아니라, 이력 추적과 RLS 보조 함수, 그리고 pending 중복 방지 같은 실무적인 보완을 SQL Final 전에 정리하는 것이다.
