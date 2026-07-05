# PlanFlow V2 ERD Draft

## 1. ERD 목적

V2는 기존 개인 일정 기능을 건드리지 않고 Group Tree 기반 조직 일정 공유 기능을 추가한다.

## 2. 기존 테이블 유지 원칙

- 기존 `events`는 개인 일정용으로 유지한다.
- 기존 `pre_actions` / `reminders` / `voice_logs` 등 개인 기능 테이블은 유지한다.
- `group_events`는 별도 생성한다.
- `events`와 `group_events`를 DB에서 섞지 않는다.
- 캘린더 UI에서만 오버레이한다.

## 3. 테이블별 상세 설계

### profiles / users 확장

목적:
- 그룹 초대와 사용자 식별, 기본 표시 정보를 관리한다.

주요 컬럼:
- `invite_code` unique
- `display_name`
- `email`
- `created_at`

관계:
- `profiles/users.id`는 다른 그룹 테이블의 사용자 참조 기준이 된다.

인덱스 후보:
- `invite_code` unique index
- `email` index

RLS 고려사항:
- 본인 프로필 조회/수정과 시스템 참조를 분리한다.
- invite_code는 초대와 조회에만 사용하고 과도한 공개를 막는다.

주의사항:
- 실제 저장 위치가 `profiles`인지 `users`인지 구현 단계에서 확정이 필요하다.

### groups

목적:
- Group Tree의 단일 조직 노드를 나타낸다.
- 회사, 본부, 사업부, 팀을 모두 같은 구조로 표현한다.

주요 컬럼:
- `id`
- `parent_group_id` nullable
- `name`
- `description` nullable
- `status` active/archived/deleted_pending
- `created_by`
- `archived_at` nullable
- `created_at`
- `updated_at`

관계:
- `groups.parent_group_id → groups.id`
- recursive tree 구조

인덱스 후보:
- `parent_group_id`
- `status`
- `created_by`

RLS 고려사항:
- 본인이 속한 그룹과 하위 그룹 조회 규칙을 분리한다.
- archived group은 기본 조회에서 제외한다.

주의사항:
- 삭제/복원 정책은 `group_backups`와 함께 해석해야 한다.

### group_members

목적:
- 사용자의 그룹 소속과 역할을 관리한다.

주요 컬럼:
- `id`
- `group_id`
- `user_id`
- `role` leader/member
- `status` active/removed
- `joined_at`
- `created_at`

관계:
- `group_members.group_id → groups.id`
- `group_members.user_id → profiles/users.id`
- `unique(group_id, user_id)`

인덱스 후보:
- `group_id`
- `user_id`
- `(group_id, role)`
- `(user_id, status)`

RLS 고려사항:
- 사용자는 자신이 member인 group만 조회 가능하다.
- leader 판정은 `group_members.role`과 위임 테이블을 함께 본다.

주의사항:
- role은 user가 아니라 membership에 저장한다.

### group_invites

목적:
- 그룹 초대 흐름을 관리한다.

주요 컬럼:
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

관계:
- `group_invites.group_id → groups.id`
- `group_invites.invited_by → profiles/users.id`

인덱스 후보:
- `group_id`
- `invited_user_id`
- `invited_email`
- `invited_invite_code`
- `status`
- `expires_at`

RLS 고려사항:
- 초대자와 대상자만 제한적으로 조회 가능하게 설계한다.
- 수락 전에는 group 본문 조회를 허용하지 않는다.

주의사항:
- 초대 ID와 이메일 초대를 모두 허용하되 중복 초대는 막아야 한다.

### group_role_delegations

목적:
- 일정 기간 동안 일부 그룹 권한을 다른 사용자에게 위임한다.

주요 컬럼:
- `id`
- `group_id`
- `delegator_user_id`
- `delegate_user_id`
- `permissions` json/jsonb
- `starts_at`
- `ends_at`
- `status` active/expired/cancelled
- `created_at`

관계:
- `group_role_delegations.group_id → groups.id`
- `delegator_user_id → profiles/users.id`
- `delegate_user_id → profiles/users.id`

인덱스 후보:
- `group_id`
- `delegator_user_id`
- `delegate_user_id`
- `(group_id, status)`
- `(starts_at, ends_at)`

RLS 고려사항:
- 위임 기간과 권한 범위를 모두 확인한다.
- role 자체 변경이 아니라 별도 위임으로 해석한다.

주의사항:
- V2 위임 범위는 일정 생성/수정/삭제 또는 취소/대시보드 조회만 포함한다.

### group_events

목적:
- 그룹 일정 전용 데이터를 저장한다.

주요 컬럼:
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

관계:
- `group_events.group_id → groups.id`
- `created_by → profiles/users.id`

인덱스 후보:
- `group_id`
- `start_at`
- `end_at`
- `status`
- `created_by`
- `(group_id, start_at)`

RLS 고려사항:
- member는 본인이 속한 group 일정 조회 가능해야 한다.
- leader는 본인이 리더인 group과 하위 group 일정 조회 가능해야 한다.
- 형제 group 조회는 막아야 한다.

주의사항:
- 개인 `events`와 분리한다.
- 반복 일정은 V2에서 `none/daily/weekly/monthly`만 지원한다.
- 복잡한 RRULE은 V2 제외다.

### group_backups

목적:
- 그룹 archived/delete 흐름에서 복구용 스냅샷을 보관한다.

주요 컬럼:
- `id`
- `group_id`
- `backup_type` archive/delete
- `snapshot` json/jsonb
- `created_by`
- `created_at`
- `restored_at` nullable
- `restored_by` nullable

관계:
- `group_backups.group_id → groups.id`
- `created_by → profiles/users.id`

인덱스 후보:
- `group_id`
- `backup_type`
- `created_at`
- `restored_at`

RLS 고려사항:
- 시스템 데이터로 취급하고 리더 개인 소유로 보지 않는다.
- 복원 권한은 그룹 삭제 권한과 연결하되, 백업 조회는 제한한다.

주의사항:
- 그룹 archived 전 snapshot 저장이 우선이다.

## 4. 관계 다이어그램 텍스트

profiles/users
├ group_members
├ group_invites
├ group_role_delegations
└ group_events.created_by

groups
├ parent_group_id → groups.id
├ group_members
├ group_invites
├ group_role_delegations
├ group_events
└ group_backups

## 5. 권한/RLS 설계 방향

SQL 정책은 아직 작성하지 않고 방향만 정리한다.

- 사용자는 자신이 member인 group 조회 가능
- leader는 자신이 leader인 group과 하위 group의 `group_events` 조회 가능
- 형제 group 조회 불가
- 개인 `events`는 공유하지 않음
- delegation은 지정된 기간/권한 안에서만 허용
- archived group은 기본 조회에서 제외

## 6. ERD 리스크

- recursive group tree RLS 복잡도
- 하위 group 조회 성능
- group archive/restore 처리
- `group_events` 반복 일정 확장성
- delegation 권한 해석 복잡도
- profiles/users 확장 위치 결정 필요

## 7. ERD 이후 다음 단계

다음 단계는 SQL이 아니라 아래 순서로 진행한다.

1. ERD 검토
2. RLS 정책 설계 문서
3. SQL 초안
4. Flutter feature module 설계
5. 구현
