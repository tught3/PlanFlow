# PlanFlow V2 DB Implementation Review

이 문서는 [09-v2-final-master-design.md](./09-v2-final-master-design.md)부터 [16-v2-schema-sql-final-draft.md](./16-v2-schema-sql-final-draft.md)까지의 설계 문서와, 현재 `supabase/schema.sql` 및 `lib/features/groups/` 구현 상태를 대조한 리뷰 문서다.

이 문서는 리뷰용이며, 구현이나 SQL 반영은 하지 않는다.

## 1. 리뷰 범위

- `supabase/schema.sql`
- `lib/features/groups/models/`
- `lib/features/groups/repositories/`
- `test/features/groups/`
- `docs/planflow-v2/09~16` 설계 문서와 실제 구현 일치 여부

## 2. 주요 리뷰 결론

- V2 DB 1차 구현의 기본 테이블 묶음은 큰 틀에서 설계와 일치한다.
- `public.users invite_code`, `groups`, `group_members`, `group_invites`, `group_role_delegations`, `group_events`, `group_backups` 모두 실제 schema에 들어갔다.
- 그룹별 모델/레포도 최소 범위는 갖췄다.
- 다만 UI/Provider로 넘어가기 전에 반드시 막아야 할 위험이 몇 가지 있다.
- 가장 큰 위험은 `recursive group tree` 권한, `invite accept` 원자성, `archive + backup` 원자성, `invite expiration` 강제, 그리고 일부 업데이트 경로가 너무 넓다는 점이다.

## 3. Schema 일관성 검토

### 3.1 설계와 실제 schema.sql의 일치 여부

- `groups`, `group_members`, `group_invites`, `group_role_delegations`, `group_events`, `group_backups`는 설계 문서의 핵심 컬럼을 대부분 반영했다.
- `public.users`에 `invite_code`를 둔 점은 실제 프로젝트 구조와 맞다.
- 설계 문서에는 `profiles/users` 표현이 섞여 있지만, 현재 구현 기준으로는 `public.users`를 앱 사용자 테이블로 쓰는 것이 일관된다.
- `invite_code` unique, 주요 인덱스, partial unique index, 반복 일정 제한, delegation permission 제한은 반영되어 있다.

### 3.2 누락 또는 과도한 제약

- `group_members`에는 `joined_at`, `removed_at`, `removed_by`가 들어갔지만, 별도의 immutable trigger는 없다.
- `group_members`는 leader update 정책이 넓어서, 현재 구현만 놓고 보면 role/상태 전환 외의 수정이 열릴 가능성이 있다.
- `group_invites`는 `expires_at`을 갖지만, 만료를 강제하는 DB 레벨 자동 전환은 없다.
- `group_backups`는 복원 이력을 담지만, restore 동작이 한 번만 가능하도록 강제하지는 않는다.
- `group_events`의 immutable trigger는 `group_id`, `created_by`, `created_at`만 막고 있고, 나머지 열은 정책과 레포에서 관리한다.

## 4. RLS 정책 검토

### 4.1 잘 맞는 부분

- `group_events`는 active group 기준의 member/leader/delegation 조회 정책이 들어가 있다.
- `group_backups`는 member에게 보이지 않고 leader만 select/update 가능하다.
- `group_invites`는 leader 생성, 대상자 수락/거절, leader 취소 흐름이 분리되어 있다.
- delegation의 `group_events` 권한 연결은 `has_group_delegated_permission` helper로 이어졌다.

### 4.2 위험 또는 누락

- `groups` / `group_events` / `group_backups` 모두 `recursive group tree`를 실제로 계산하는 helper는 아직 없다.
- 문서에서는 leader가 하위 group까지 볼 수 있어야 한다고 정리했지만, 실제 RLS는 direct membership / direct leader 기준에 가깝다.
- 형제 group 차단은 의도와 맞지만, parent -> child 접근까지 포함한 tree 권한은 아직 구현되지 않았다.
- `group_invites`는 RLS상 pending 상태만 대상으로 작동하지만, `expires_at`이 지났는지에 대한 강제는 없다.
- `group_invites` 수락 후 `group_members` insert는 별도 쿼리라서, invite accepted 상태와 membership 생성이 원자적으로 묶이지 않는다.

## 5. Repository 일관성 검토

### 5.1 `GroupRepository`

- 기본 그룹 생성/수정/멤버 추가/수정은 최소 범위로 정리돼 있다.
- 다만 `archive + backup`을 단일 진입점으로 다루는 메서드는 없다.
- 그룹 아카이브는 현재 `GroupBackupRepository.archiveGroupWithBackup()` 쪽에 분산되어 있어, UI가 붙을 때 진입점이 흩어질 수 있다.

### 5.2 `GroupInviteRepository`

- 이메일/초대코드 초대, 내 pending invite 조회, accept/reject/cancel 메서드가 있다.
- 초대 대상 매칭을 `invite_code / email / user_id`로 나눠 처리하는 점은 설계와 맞는다.
- 하지만 `acceptInvite()`는 `group_invites` 업데이트와 `group_members` insert가 분리되어 있어 원자성이 없다.
- `getPendingInvitesForMe()`는 여러 컬럼을 따로 조회한 뒤 앱에서 합치는 방식이라, 중복 방지용 unique index와 함께 쓰는 구조다.

### 5.3 `GroupDelegationRepository`

- 허용 권한 목록을 코드와 SQL 양쪽에서 제한한 점은 좋다.
- `status = active`, `starts_at/ends_at`, `cancelled_at/cancelled_by` 흐름도 설계와 맞는다.
- 다만 expired로 자동 전환하는 작업은 아직 없다.
- `group_events` 권한 연결은 구현됐지만, subtree 기준 확장은 아직 없다.

### 5.4 `GroupEventRepository`

- `none/daily/weekly/monthly` 제한과 active 조회 필터는 설계와 일치한다.
- `created_by / updated_by / cancelled_by`가 모델과 레포에 반영돼 있다.
- 하지만 실제 recurrence expansion은 아직 없다.
- `cancel` / `archive`는 별도 update 호출이며, UI에서 한 화면으로 노출할 때 상태 전환 규칙을 더 명확히 해야 한다.

### 5.5 `GroupBackupRepository`

- 백업 생성, 백업 조회, 복원 마킹, `archiveGroupWithBackup()`까지 준비돼 있다.
- 백업 생성과 그룹 archived 변경은 분리 쿼리라 원자성이 없다.
- 복원 마킹도 한 번만 허용되도록 강하게 고정돼 있지 않다.
- parent/child group archive 복원 정책은 아직 제품 규칙 수준에서만 남아 있다.

## 6. 기존 개인 기능 영향

- `events`, `reminders`, `pre_actions`, `voice` 관련 코드는 수정되지 않았다.
- `group_events`는 별도 테이블/레포로 분리되어 개인 일정과 섞이지 않는다.
- 캘린더 오버레이가 아직 없기 때문에, 기존 화면의 개인 일정 렌더링에는 직접적인 영향이 없다.

## 7. 테스트 현황

- 현재 그룹 관련 테스트는 `test/features/groups/group_backup_model_test.dart` 1개가 추가돼 있다.
- 아직 repository 레벨 테스트는 부족하다.
- 이번 리뷰 시점의 전체 `flutter test --no-pub`는 통과했다.
- 이전 세션에서 보이던 `MissingPluginException` / `Supabase.instance` 초기화 실패는 이번 리뷰 실행에서는 재현되지 않았다.
- 다음 단계에서 추가해야 할 테스트는 아래와 같다.
  - `GroupInviteRepository` accept/reject/cancel 테스트
  - `GroupBackupRepository` archive / restore 테스트
  - `GroupEventRepository` create/update/cancel/archive 테스트
  - `group_invites` 만료/중복 초대 규칙 테스트
  - group tree 상위/하위 접근 테스트

## 8. UI/Provider 구현 전 필수 보완사항

### Must fix before UI

- `group_invites` 수락과 `group_members` 생성의 원자성 확보
- `group_backups` 생성과 그룹 archive 변경의 원자성 확보
- `group_invites` 만료 강제 로직 추가
- `recursive group tree` 기반 상위/하위 group 권한 helper 정리
- `group_members`의 업데이트 범위를 더 좁혀서 role/필수 필드 수정이 의도치 않게 열리지 않도록 정리

### Can fix during UI

- `group_events` recurrence 확장 표시 로직
- `GroupRepository`에 archive 진입점 통합
- repository 예외 메시지와 빈 상태 UX 정리
- 그룹 초대 목록/대상자 표시를 위한 조회 보강
- repository 테스트 추가

### Later improvement

- invite expiration 자동 배치 작업 또는 RPC
- parent/child group archive 복원 범위 선택 UI
- group tree 성능 최적화 helper
- bulk restore / bulk archive RPC
- delegation expired 자동 전환 잡

## 9. 다음 구현 추천 순서

1. `GroupContextProvider`
   - 현재 선택 group, 마지막 선택 group, leader/member 구분을 한 곳에서 관리해야 이후 UI가 꼬이지 않는다.
2. `GroupList` / `GroupCreate` 기본 UI
   - 그룹 전환과 생성이 먼저 열려야 초대/일정 UI가 정상적으로 붙는다.
3. `InviteCode` 표시
   - 초대 경로의 핵심 키를 사용자가 확인할 수 있어야 한다.
4. `GroupInvite` UI
   - accept/reject/cancel 흐름을 먼저 제품으로 검증할 수 있다.
5. `GroupEvent` UI
   - `group_events`의 일정 CRUD를 노출한다.
6. `Calendar overlay`
   - 개인 일정과 group_events 병합 표시를 붙인다.
7. `Dashboard`
   - leader 전용 대시보드는 마지막에 붙이는 편이 범위 관리에 안전하다.

### 추천 이유

- 먼저 `GroupContextProvider`가 있어야 선택된 group 기준으로 나머지 화면과 레포가 일관되게 움직인다.
- `GroupList`와 `GroupCreate`가 있어야 초대와 일정 생성이 실제로 닿는 진입점이 생긴다.
- `InviteCode`와 `GroupInvite`를 먼저 두면 가장 중요한 팀 합류 흐름을 빨리 검증할 수 있다.
- `GroupEvent`는 실제 일정 데이터가 안정화된 뒤에 붙여야 오버레이와 충돌이 적다.
- `Calendar overlay`와 `Dashboard`는 데이터가 안정화된 뒤가 맞다.

## 10. 최종 판단

V2 DB 1차 구현은 설계 문서와 대체로 일치한다.

하지만 UI/Provider 구현으로 넘어가기 전에는 최소한 다음을 먼저 정리해야 한다.

- invite accept / backup archive의 원자성
- invite expiration 강제
- recursive group tree 권한 처리
- member update 범위 축소

이 4개가 정리되면, 그룹 리스트와 초대 UI부터 올려도 안정성이 크게 떨어지지 않는다.

