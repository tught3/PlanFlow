# PlanFlow V2 Supabase Deployment Plan

이 문서는 PlanFlow V2의 Supabase 실제 적용 전 검증 계획서다.

대상은 `public.users invite_code`, `groups`, `group_members`, `group_invites`, `group_role_delegations`, `group_events`, `group_backups`와 관련 RPC / RLS 정책이다.

이 문서는 실행 계획이며, 실제 운영 Supabase 적용은 하지 않는다.

## 1. 목적

- V2 스키마가 실제 Supabase 환경에서 안전하게 적용될 수 있는지 검증한다.
- RPC와 RLS가 설계 문서와 실제 구현 기대를 충족하는지 확인한다.
- 실패 시 롤백 경로를 미리 정해 적용 사고를 막는다.

## 2. 적용 전 전제

- 현재 로컬 V2 워킹트리는 main 반영 이후 기준으로 동작한다.
- 실제 운영 Supabase에는 아직 적용하지 않는다.
- `supabase/schema.sql`은 이 문서 작성 시점까지 기준 문서일 뿐, 추가 수정은 별도 승인 후 진행한다.
- `flutter analyze --no-pub`는 통과 상태를 유지해야 한다.
- `git diff --check`는 clean 상태를 유지해야 한다.

## 3. Schema 검증 계획

### 3.1 검증 대상 테이블

- `public.users`
- `groups`
- `group_members`
- `group_invites`
- `group_role_delegations`
- `group_events`
- `group_backups`

### 3.2 공통 검증 항목

- FK가 실제 사용자 테이블을 올바르게 가리키는지 확인한다.
- 인덱스가 조회/중복 방지 목적에 맞게 배치되었는지 확인한다.
- `check` constraint가 enum/상태값 범위를 충분히 막는지 확인한다.
- partial unique index가 필요한 곳에 정확히 들어갔는지 확인한다.
- immutable trigger가 너무 넓어서 업데이트를 막지 않는지 확인한다.
- migration 순서가 선후 관계를 깨지 않는지 확인한다.

### 3.3 테이블별 위험 포인트

#### public.users

- `invite_code` unique 여부 확인
- invite code 조회를 위한 인덱스 존재 확인
- 기존 `auth.users`를 건드리지 않는 구조인지 확인

#### groups

- `parent_group_id` self reference FK 확인
- status `active / archived / deleted_pending` 체크 확인
- `archived_at`와 archive 흐름이 일치하는지 확인
- `restored_at / restored_by`가 없다는 규칙이 유지되는지 확인

#### group_members

- `(group_id, user_id)` unique 확인
- `role leader/member` 체크 확인
- `status active/removed` 체크 확인
- `removed_at / removed_by`가 soft remove 흐름과 맞는지 확인
- 마지막 leader 제거를 DB/RPC 차원에서 차단하는지 확인

#### group_invites

- `pending / accepted / rejected / cancelled / expired` 상태값이 완전한지 확인
- `pending` 중복 방지 partial unique index가 실제로 있는지 확인
- `invited_user_id / invited_email / invited_invite_code` 셋이 중복 규칙과 충돌하지 않는지 확인
- 만료 시 `expired_at`이 사용되는지 확인

#### group_role_delegations

- `permissions jsonb`가 허용 목록만 담도록 방어되는지 확인
- `starts_at < ends_at` 조건이 적용되는지 확인
- `active / expired / cancelled` 상태 전환이 명확한지 확인

#### group_events

- `recurrence_type none/daily/weekly/monthly`만 허용되는지 확인
- `status active/cancelled/archived` 체크 확인
- `group_id + start_at` 인덱스가 있는지 확인
- 개인 `events`와 섞이지 않는지 확인

#### group_backups

- `backup_type archive/delete` 체크 확인
- `snapshot jsonb` 구조가 restore 검증에 충분한지 확인
- `restored_at / restored_by`가 복원 이력을 보존하는지 확인
- leader만 조회/복원할 수 있는지 확인

### 3.4 Schema 검증 결과 요약 방식

실DB 적용 전 아래 형식으로 점검한다.

| 테이블 | FK | index | check | partial unique | 위험도 | 비고 |
|---|---|---|---|---|---|---|
| public.users | PASS/FAIL | PASS/FAIL | PASS/FAIL | N/A | 낮음/중간/높음 | invite_code |
| groups | PASS/FAIL | PASS/FAIL | PASS/FAIL | N/A | 낮음/중간/높음 | tree 구조 |
| group_members | PASS/FAIL | PASS/FAIL | PASS/FAIL | PASS/FAIL | 낮음/중간/높음 | soft remove |
| group_invites | PASS/FAIL | PASS/FAIL | PASS/FAIL | PASS/FAIL | 낮음/중간/높음 | pending 중복 |
| group_role_delegations | PASS/FAIL | PASS/FAIL | PASS/FAIL | PASS/FAIL | 낮음/중간/높음 | permission jsonb |
| group_events | PASS/FAIL | PASS/FAIL | PASS/FAIL | N/A | 낮음/중간/높음 | recurrence |
| group_backups | PASS/FAIL | PASS/FAIL | PASS/FAIL | N/A | 낮음/중간/높음 | archive snapshot |

## 4. RPC 검증 계획

### 4.1 `accept_group_invite`

#### 성공 시나리오

- pending invite가 존재한다.
- 만료되지 않았다.
- 대상 사용자가 invite 대상과 일치한다.
- `group_members`가 생성된다.
- invite가 accepted로 바뀐다.

#### 실패 시나리오

- 인증되지 않은 사용자
- pending invite가 아님
- 이미 accepted/rejected/cancelled/expired 상태
- target mismatch
- group_members 중복

#### 동시 요청 시나리오

- 같은 invite에 대해 동시에 accept 요청이 들어와도 membership과 invite 상태가 1회만 반영되어야 한다.
- 한 요청 실패 시 전체 rollback 되어야 한다.

### 4.2 `archive_group_with_backup`

#### 성공 시나리오

- 요청자가 leader다.
- 그룹이 active 상태다.
- backup row가 먼저 또는 같은 트랜잭션 안에서 생성된다.
- groups.status가 archived로 바뀐다.
- archived_at이 기록된다.

#### 실패 시나리오

- 인증되지 않은 사용자
- leader가 아닌 사용자
- 이미 archived/deleted_pending 상태
- snapshot 생성 실패
- backup insert 실패

#### 동시 요청 시나리오

- 동시에 archive 요청이 들어오면 하나만 성공해야 한다.
- 중복 backup이나 이중 archived 상태가 생기지 않아야 한다.

### 4.3 `remove_group_member`

#### 성공 시나리오

- 요청자가 active leader다.
- 대상이 active member다.
- `status = removed`, `removed_at`, `removed_by`가 기록된다.

#### 실패 시나리오

- 인증되지 않은 사용자
- leader가 아닌 사용자
- 자기 자신 제거
- 마지막 active leader 제거
- 이미 removed 상태

#### 동시 요청 시나리오

- 동일 member에 대한 중복 remove 요청은 하나만 반영되어야 한다.
- leader 제거와 member 제거가 섞여도 마지막 leader 규칙이 깨지지 않아야 한다.

## 5. RLS 검증 계획

### 5.1 역할 구분

- member
- leader
- delegation

### 5.2 권한 매트릭스

| 객체 / 동작 | member | leader | delegation | 비고 |
|---|---|---|---|---|
| groups 조회 | 허용: 소속 group | 허용: 리더 group | 허용 범위 내 | 형제 group 차단 |
| groups 생성 | 차단 | 허용 | 차단 | leader만 |
| groups 수정 | 차단 | 허용 | 차단 | archive 포함 |
| groups archive | 차단 | 허용 | 차단 | backup 필수 |
| group_members 조회 | 허용: 소속 group | 허용 | 허용 범위 내 | removed 제외 정책 확인 |
| group_members 추가 | 차단 | 허용 | 차단 | invite flow와 분리 |
| group_members 제거 | 차단 | 허용 | 차단 | RPC 중심 |
| group_invites 생성 | 차단 | 허용 | 차단 | leader만 |
| group_invites 수락 | 본인 대상만 허용 | leader는 조회/취소 | 허용 없음 | 대상자만 |
| group_invites 취소 | 차단 | 허용 | 차단 | pending만 |
| group_role_delegations 생성 | 차단 | 허용 | 차단 | permission 제한 |
| group_role_delegations 조회 | 본인 대상/leader | 허용 | 본인 대상 | 기간 확인 |
| group_role_delegations 취소 | 차단 | 허용 | 제한적 허용 | rule 확인 |
| group_events 조회 | 허용: 소속 group | 허용 | 허용 범위 내 | active only |
| group_events 생성 | 차단 | 허용 | 허용 범위 내 | delegated permission |
| group_events 수정 | 차단 | 허용 | 허용 범위 내 | delegated permission |
| group_events 취소 | 차단 | 허용 | 허용 범위 내 | delegated permission |
| group_events 보관 | 차단 | 허용 | 제한적/차단 | 설계 확인 |
| group_backups 조회 | 차단 | 허용 | 차단 | leader only |
| group_backups 복원 | 차단 | 허용 | 차단 | 실DB 확인 필수 |

### 5.3 반드시 확인할 RLS 포인트

- member는 자신이 속한 group만 조회 가능한지 확인한다.
- leader는 자신이 leader인 group과 그 범위 안에서만 보이는지 확인한다.
- delegation은 기간과 permission 범위 밖에서는 무시되는지 확인한다.
- archived group은 기본 조회에서 빠지는지 확인한다.
- 형제 group 접근이 차단되는지 확인한다.
- `group_backups`는 member에게 노출되지 않는지 확인한다.

## 6. 실DB 적용 순서

실제 적용은 아래 순서로 진행한다.

1. `public.users.invite_code`
2. `groups`
3. `group_members`
4. `group_invites`
5. `group_role_delegations`
6. `group_events`
7. `group_backups`
8. RPC 함수
9. RLS 정책
10. 마지막 검증 쿼리

### 적용 순서 이유

- 사용자 식별 키가 먼저 있어야 초대와 멤버십 검증이 가능하다.
- `groups`와 `group_members`가 먼저 있어야 나머지 테이블의 FK를 안전하게 만든다.
- `group_invites`와 `group_role_delegations`는 group/member 기초 위에서 만들어야 한다.
- `group_events`와 `group_backups`는 권한/이력 구조가 준비된 뒤 붙이는 편이 안전하다.
- RPC와 RLS는 테이블이 모두 존재한 뒤 최종 단계에서 연결한다.

## 7. 롤백 계획

### 7.1 schema 실패 시

- 가장 마지막에 적용한 DDL부터 역순으로 되돌린다.
- FK / index / trigger / policy 순서로 제거한다.
- 실제 데이터가 들어간 상태라면 먼저 영향 범위를 확인한 뒤 되돌린다.

### 7.2 RPC 실패 시

- 함수 정의만 롤백한다.
- 함수가 사용하던 정책/헬퍼가 RPC 전용이면 함께 제거 여부를 검토한다.
- UI는 RPC 실패 메시지만 보여주고 데이터 변경은 하지 않는다.

### 7.3 RLS 실패 시

- 정책을 즉시 비활성화하거나 임시 완화하지 말고, 실패 원인을 확인한다.
- 잘못된 정책은 해당 table policy만 되돌린다.
- 다른 테이블의 정책에는 영향이 없도록 분리한다.

### 7.4 운영 반영 전 안전장치

- 적용 전 스냅샷 또는 SQL export를 확보한다.
- 단계별로 적용하고, 각 단계마다 검증 쿼리를 실행한다.
- 실패 시 다음 단계로 넘어가지 않는다.

## 8. 실DB 체크리스트

| 체크 항목 | 상태 | 위험도 | 비고 |
|---|---|---|---|
| schema export와 로컬 `supabase/schema.sql` 비교 | NEEDS MANUAL TEST | 중간 | diff 확인 |
| invite_code unique / lookup 확인 | NEEDS MANUAL TEST | 중간 | `public.users` |
| pending invite 중복 차단 | NEEDS MANUAL TEST | 높음 | partial unique index |
| invite accept 원자성 | NEEDS MANUAL TEST | 높음 | RPC 필수 |
| archive + backup 원자성 | NEEDS MANUAL TEST | 높음 | RPC 필수 |
| remove member RPC | NEEDS MANUAL TEST | 높음 | 자기 자신/마지막 leader 차단 |
| delegation 기간 만료 검증 | NEEDS MANUAL TEST | 중간 | active만 허용 |
| group_events 권한 검증 | NEEDS MANUAL TEST | 높음 | leader/delegation |
| group_backups leader only | NEEDS MANUAL TEST | 중간 | 조회/복원 차단 |
| 형제 group 접근 차단 | NEEDS MANUAL TEST | 높음 | recursive tree 확인 |

## 9. 최종 결론

V2의 실제 Supabase 적용은 schema / RPC / RLS / 롤백 계획이 모두 준비된 다음에만 진행한다.

현재는 문서상 준비 단계이며, 적용 직전에는 반드시 다음을 만족해야 한다.

- schema 검증 결과가 PASS일 것
- RPC 검증 시나리오가 모두 정리될 것
- RLS 허용/차단 매트릭스가 명확할 것
- rollback 계획이 실제 운영 순서와 일치할 것

이 문서가 확정되면 실제 운영 Supabase 적용은 단계별로 진행할 수 있다.
