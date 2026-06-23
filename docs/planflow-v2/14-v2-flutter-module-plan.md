# PlanFlow V2 Flutter Module Plan

이 문서는 V2 구현 전에 Flutter feature module 구조를 확정하기 위한 설계 문서다.

- 기존 개인 일정 기능과 충돌 최소화
- main 머지 리스크 최소화
- 기존 `events` / `reminders` / `pre_actions` / `voice` 기능 직접 수정 최소화
- V2는 별도 feature module로 추가
- 개인 일정 + 그룹 일정은 UI layer에서만 오버레이
- V2 구현 전 main 최신 변경사항을 V2 워킹 트리에 반영해야 한다

## 1. 문서 목적

- V2 구현 전 Flutter 모듈 구조를 확정하기 위한 문서다.
- 기존 개인 일정 기능을 최대한 건드리지 않는다.
- 신규 그룹 기능은 feature 단위로 분리한다.

## 2. 핵심 원칙

- 기존 개인 일정 기능 수정 최소화
- 기존 `events` / `reminders` / `pre_actions` / `voice` 기능 직접 수정 금지
- V2는 별도 feature module로 추가
- 개인 일정 + 그룹 일정은 UI layer에서만 오버레이
- V2 구현 전 main 최신 변경사항을 V2 워킹 트리에 반영해야 함

## 3. 권장 모듈 구조

### `lib/features/groups/`

- `models/`
- `repositories/`
- `services/`
- `providers/`
- `screens/`
- `widgets/`

### `lib/features/group_calendar/`

- `models/`
- `repositories/`
- `services/`
- `providers/`
- `screens/`
- `widgets/`

### `lib/features/group_dashboard/`

- `repositories/`
- `services/`
- `providers/`
- `screens/`
- `widgets/`

### `lib/features/group_invites/`

- `repositories/`
- `services/`
- `providers/`
- `screens/`
- `widgets/`

### `lib/features/group_delegations/`

- `repositories/`
- `services/`
- `providers/`
- `screens/`
- `widgets/`

## 4. groups 모듈 역할

- Group Tree 조회
- 현재 선택 group 관리
- group 생성
- 하위 group 생성
- group archive 요청
- group member 조회

## 5. group_calendar 모듈 역할

- `group_events` 조회
- `group_events` 생성/수정/취소
- recurrence_type 처리
- 기존 개인 calendar 화면과 오버레이 연동 전략
- 개인 `events`와 `group_events` 분리 유지

## 6. group_dashboard 모듈 역할

- leader dashboard
- 오늘 그룹 일정 수
- 이번 주 그룹 일정 수
- 멤버별 일정 수
- 하위 그룹별 일정 수
- KPI / 성과분석 / AI 코칭 제외

## 7. group_invites 모듈 역할

- 내 초대 ID 표시
- 초대 ID 복사
- 초대 ID / 이메일 초대
- 초대 수락 / 거절
- `pending` / `accepted` / `rejected` / `cancelled` / `expired` 상태 표시

## 8. group_delegations 모듈 역할

- 권한 위임 생성
- 위임 목록 조회
- 위임 취소
- 기간 만료 처리 표시
- V2 위임 범위 제한 표시

## 9. 화면 설계 초안

### 화면 후보

- `GroupListScreen`
- `GroupContextPicker`
- `GroupDetailScreen`
- `GroupCreateScreen`
- `GroupMemberScreen`
- `GroupInviteScreen`
- `MyInviteCodeCard`
- `GroupCalendarScreen`
- `GroupEventEditorScreen`
- `GroupEventDetailScreen`
- `GroupDashboardScreen`
- `GroupDelegationScreen`

### 각 화면 공통 항목

- 목적
- 진입 경로
- 표시 데이터
- 권한 조건
- 기존 개인 화면과 연결 여부

## 10. Provider / State 전략

현재 프로젝트의 상태관리 방식을 먼저 확인해서 맞춘다는 전제를 둔다.

구체 구현 전 확인 필요:

- 현재 provider 구조
- 기존 app route 구조
- 기존 calendar 화면 구조

## 11. Routing 전략

- 기존 라우팅 방식 확인 후 맞춤
- V2 route는 group prefix 또는 feature route로 분리
- 기존 개인 route 변경 최소화

## 12. 기존 화면 수정 최소화 전략

### 기존 홈

- group summary card만 조건부 추가 가능
- 직접적인 기존 로직 변경 최소화

### 기존 캘린더

- 개인 `events` 조회 로직 유지
- `group_events` 조회 provider를 별도 추가
- UI에서만 병합 표시

### 설정 화면

- 로그아웃 버튼 위에 내 초대 ID 카드 추가
- 기존 설정 구조 최소 변경

## 13. merge 충돌 최소화 전략

- 새 파일 중심 개발
- 기존 파일 수정 시 수정 이유 문서화
- 기존 개인 기능 수정 전 대체 가능성 검토
- main 변경사항을 V2에 주기적으로 반영
- 실제 구현 전 `git merge origin/main` 필수

## 14. 테스트 전략

- repository unit test
- provider test
- `group_events` overlay test
- invite state test
- delegation permission test
- dashboard aggregation test

## 15. 구현 순서 제안

1. DB schema 적용 후 types/models
2. group repository/service
3. group context provider
4. invite code UI
5. group create/invite flow
6. `group_events` CRUD
7. calendar overlay
8. dashboard
9. delegation

## 16. 실제 코드 구현 전 확인사항

- agents.md 확인
- main 최신 병합
- 기존 calendar 구조 확인
- 기존 settings 화면 확인
- 기존 auth/profile 구조 확인
- Supabase client 구조 확인

## 17. 최종 결론

V2 Flutter 모듈은 기존 개인 일정 기능을 최대한 보존하면서, 그룹 기능만 별도 feature module로 얹는 구조가 적합하다.
