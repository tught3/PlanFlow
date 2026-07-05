# PlanFlow V2 RLS Policy Design

이 문서는 [09-v2-final-master-design.md](./09-v2-final-master-design.md), [10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md), [11-v2-erd-draft.md](./11-v2-erd-draft.md)를 기준으로 V2 RLS 정책의 방향과 조건을 정리한 문서다.

SQL은 작성하지 않고, 정책 방향만 문서화한다.

## 1. profiles / users invite_code 조회/수정 정책

### 정책 요약

- 사용자는 자신의 프로필을 조회/수정할 수 있다.
- `invite_code`는 본인 프로필에서 확인 가능하다.
- 다른 사용자의 `invite_code`는 초대/조회 경로에서만 제한적으로 사용한다.

### 조건 방향

- 본인 `id` 기준 조회/수정 허용
- 시스템이 초대 수락/중복 방지 검증에 사용하는 조회만 허용
- 공개 프로필 목록에서 invite_code 과노출 금지

### 주요 리스크

- `profiles`와 `users` 중 실제 저장 위치가 확정되기 전까지 정책 문구를 추상화해야 한다.

## 2. groups 조회/생성/수정/archive 정책

### 정책 요약

- 사용자는 자신이 속한 group만 조회할 수 있다.
- leader는 자신이 leader인 group을 생성/수정할 수 있다.
- archived group은 기본 조회에서 제외한다.
- group archive는 삭제가 아니라 숨김/복원 가능한 상태 전환으로 취급한다.

### 조건 방향

- `group_members`로 소속 여부 확인
- leader 여부는 `group_members.role`과 현재 위임 상태를 함께 확인
- `groups.status = archived`는 일반 목록/대시보드/캘린더에서 제외
- 삭제 요청 시 archive 및 backup 생성 흐름을 전제로 한다

### 주요 리스크

- recursive group tree에서 상위/하위/형제 그룹 판정이 복잡하다.
- archive된 부모의 하위 그룹 표시 규칙이 조회 정책과 충돌하지 않게 해야 한다.

## 3. group_members 조회/추가/제거 정책

### 정책 요약

- 사용자는 자신이 속한 group의 membership을 조회할 수 있다.
- leader는 자신이 리더인 group의 membership을 관리할 수 있다.
- member는 일반적으로 조회만 가능하다.

### 조건 방향

- 자신이 속한 group인지 우선 판정
- leader 권한은 해당 group 기준으로만 적용
- 제거는 그룹 소속 변경이 아니라 membership 상태 전환으로 다룬다
- 하위 group membership은 상위 group leader 정책과 분리해서 해석한다

### 주요 리스크

- 상위 group leader가 하위 group member를 직접 제거할 수 있는지 범위가 명확해야 한다.
- 멤버 제거 후 즉시 접근 차단과 이력 보존을 함께 고려해야 한다.

## 4. group_invites 생성/수락/거절/취소/만료 정책

### 정책 요약

- leader만 초대를 생성할 수 있다.
- 대상자는 초대 ID 또는 이메일로 수락할 수 있다.
- 초대 만료 후 수락은 불가하다.
- 같은 group에 `pending` 초대가 있으면 중복 생성 불가다.

### 조건 방향

- 초대 생성 시 대상 사용자/이메일/초대 코드 중 최소 1개를 사용
- 대상자가 이미 member면 초대 생성 금지
- 수락 시 `group_members` 생성
- 거절/취소/만료는 상태 전환으로 처리

### 주요 리스크

- 초대 ID와 이메일 초대가 동시에 존재할 때 우선순위와 중복 판정이 필요하다.
- 초대 수락 시점에 대상 사용자의 현재 membership 상태를 다시 검증해야 한다.

## 5. group_role_delegations 생성/조회/취소/만료 정책

### 정책 요약

- delegation은 role 변경이 아니다.
- leader가 지정한 기간 동안 일부 권한만 위임할 수 있다.
- 만료 시 자동으로 무효화된다.

### 조건 방향

- `starts_at` / `ends_at` 범위 내에서만 유효
- `permissions`에 명시된 권한만 허용
- 생성/조회/취소는 delegator와 대상자, 그리고 관련 group 기준으로 제한

### V2 허용 범위

- 그룹 일정 생성
- 그룹 일정 수정
- 그룹 일정 삭제 또는 취소
- 그룹 대시보드 조회

### V2 금지 범위

- 그룹 삭제
- 하위 그룹 생성
- 멤버 제거
- 다른 사람에게 재위임
- 영구 삭제
- 결제/운영자 권한

### 주요 리스크

- permission json 해석 규칙이 불명확하면 정책 복잡도가 급증한다.
- 위임과 leader 권한이 동시에 있는 경우 우선순위를 명확히 해야 한다.

## 6. group_events 조회/생성/수정/취소/archive 정책

### 정책 요약

- member는 자신이 속한 group의 일정만 조회할 수 있다.
- leader는 자신이 리더인 group과 하위 group의 일정까지 조회할 수 있다.
- 형제 group 일정은 조회 불가다.
- 개인 `events`는 공유하지 않는다.

### 조건 방향

- `group_members` 소속 여부 확인
- recursive group tree를 통해 하위 group 범위 계산
- `status = archived`인 group의 이벤트는 기본 조회 제외
- `status = cancelled`인 일정은 필요 시 이력 조회만 허용

### 반복 일정 방향

- V2는 `none / daily / weekly / monthly`만 지원
- 복잡한 RRULE은 제외
- `recurrence_until`은 선택적으로 종료일을 지정하는 데만 사용

### 주요 리스크

- recursive tree 조회가 느려질 수 있다.
- 반복 일정 확장 시 event 발생 규칙과 archive 규칙의 충돌을 막아야 한다.

## 7. group_backups 생성/조회/복원 정책

### 정책 요약

- group archive/delete 전 백업을 생성한다.
- 백업은 시스템 데이터로 취급한다.
- 복원은 권한이 있는 leader만 가능하다.

### 조건 방향

- backup 생성 시점은 archive/delete 직전 또는 직후로 정의한다.
- snapshot은 group 본문, 멤버십, 초대 상태, 이벤트 참조를 복구 가능한 형태로 보관한다.
- restored_at / restored_by로 복원 이력 관리

### 주요 리스크

- snapshot 범위가 커질수록 저장 비용과 복원 복잡도가 커진다.
- 하위 group을 포함한 복원 범위를 명확히 하지 않으면 일관성이 깨질 수 있다.

## 8. 공통 RLS 원칙

- 사용자는 자신이 member인 group 조회 가능
- leader는 자신이 leader인 group과 하위 group 일정 조회 가능
- 형제 group 조회 불가
- 개인 `events`는 공유하지 않음
- delegation은 지정된 기간/권한 안에서만 허용
- archived group은 기본 조회에서 제외
- recursive group tree 판정은 항상 하위 범위를 포함해 계산한다

## 9. 정책 설계 시 주의점

- RLS는 group membership, role, delegation, archive 상태를 동시에 고려해야 한다.
- 조회 정책과 수정 정책을 같은 규칙으로 묶지 않는다.
- archived group의 백업/복원 권한은 일반 조회 권한과 분리해야 한다.
- profiles/users의 invite_code는 초대용 식별자로만 다룬다.

## 10. 주요 리스크

- recursive group tree RLS 복잡도
- 하위 group 조회 성능
- group archive/restore 처리
- delegation 권한 해석 복잡도
- group invite 수락 시 membership 재검증 필요
- profiles/users 확장 위치 결정 필요

## 11. 다음 단계

1. RLS 설계 검토
2. SQL 정책 초안
3. Flutter feature module 설계
4. 구현
