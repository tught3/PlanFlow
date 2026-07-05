# PlanFlow V2 Real Device Smoke Test

이 문서는 PlanFlow V2를 실제 기기 기준으로 점검할 때 사용하는 smoke test 가이드다.

## 1. 기기 배치

권장 배치:

| 역할 | 권장 기기 | 비고 |
|---|---|---|
| Leader | 실기기 1대 | 그룹 생성, 초대 발송, 대시보드 확인 |
| Member | 실기기 1대 | 초대 수락, 멤버 표시, 그룹 일정 확인 |
| Outsider | 실기기 1대 또는 에뮬레이터 1대 | 접근 차단 확인 |

운영 팁:

- 가능하면 세 계정은 각기 다른 기기에 로그인해 둔다.
- 한 기기에서 계정을 바꿔가며 테스트해야 한다면, 실수 방지를 위해 계정 전환 전마다 로그아웃 상태를 명확히 확인한다.
- Leader와 Member는 같은 그룹의 흐름을 빠르게 검증할 수 있어야 하고, Outsider는 아무 초대도 받지 않은 상태를 유지한다.

## 2. 계정 준비

필수 계정:

- Leader 계정 1개
- Member 계정 1개
- Outsider 계정 1개

계정 준비 체크:

- `public.users.invite_code`가 Leader와 Member에 대해 확인된다.
- Leader 계정은 그룹 생성 권한이 있다.
- Member 계정은 그룹에 속하지 않은 상태에서 시작한다.
- Outsider 계정은 어떤 그룹에도 속하지 않은 상태에서 시작한다.
- 세 계정 모두 Supabase 세션이 정상적으로 유지된다.

권장 사전 확인:

- 앱 실행 후 로그인 상태가 유지되는지 확인한다.
- 세 계정의 이메일과 표시 이름을 메모해 둔다.
- 테스트 도중 계정 혼동을 막기 위해 기기별 라벨을 붙인다.

## 3. 테스트 순서

### STEP 1. Leader 로그인

목적:

- Leader가 앱에 정상 로그인되는지 확인한다.

예상 결과:

- 개인 홈이 정상 로드된다.
- 그룹 메뉴와 그룹 관련 진입점이 보인다.
- 기존 개인 일정 기능이 그대로 보인다.

실패 시 확인 포인트:

- 세션 복구가 실패했는지 확인한다.
- Supabase 인증 토큰이 만료되었는지 확인한다.
- 네트워크 또는 환경 변수 문제가 있는지 확인한다.

### STEP 2. Group 생성

목적:

- Leader가 새 그룹을 만들 수 있는지 확인한다.

예상 결과:

- 그룹 생성 화면에서 이름 입력이 가능하다.
- 생성 후 새 그룹이 목록에 나타난다.
- 생성한 그룹이 selectedGroup으로 반영된다.

실패 시 확인 포인트:

- 그룹 생성 권한이 Leader로 인식되는지 확인한다.
- 그룹 이름 입력 검증이 과도하게 막고 있지 않은지 확인한다.
- 생성 후 그룹 목록 reload가 되는지 확인한다.

### STEP 3. Invite 발송

목적:

- Leader가 invite_code 또는 email로 Member를 초대할 수 있는지 확인한다.

예상 결과:

- Leader 전용 초대 입력이 보인다.
- invite_code 초대와 email 초대가 모두 동작한다.
- pending invite가 생성된다.
- 중복 초대는 차단된다.

실패 시 확인 포인트:

- Leader가 현재 선택 그룹의 leader인지 확인한다.
- Member가 이미 그룹에 속해 있지 않은지 확인한다.
- invite 대상 email/invite_code가 정확한지 확인한다.

### STEP 4. Member 수락

목적:

- Member가 pending invite를 수락할 수 있는지 확인한다.

예상 결과:

- pending invite 목록이 보인다.
- 수락 후 invite 상태가 accepted로 바뀐다.
- group_members에 Member가 active로 반영된다.
- 그룹 컨텍스트가 Member 계정에서도 인식된다.

실패 시 확인 포인트:

- invite가 만료되었는지 확인한다.
- invite 대상이 Member 본인인지 확인한다.
- RPC `accept_group_invite`가 실패한 메시지를 반환했는지 확인한다.

### STEP 5. Member 표시 확인

목적:

- Leader와 Member 양쪽에서 멤버 목록이 정상 표시되는지 확인한다.

예상 결과:

- leader/member 역할이 구분된다.
- active/removed 상태가 표시된다.
- joined_at 또는 유사한 가입 시간이 확인된다.

실패 시 확인 포인트:

- Group Member 화면이 최신 데이터를 reload했는지 확인한다.
- 목록이 캐시된 예전 상태를 보여주지 않는지 확인한다.

### STEP 6. Outsider 차단 확인

목적:

- 아무 그룹에도 속하지 않은 Outsider가 그룹 데이터에 접근하지 못하는지 확인한다.

예상 결과:

- Outsider는 그룹 목록이나 그룹 상세를 보지 못한다.
- 그룹 일정, 멤버 목록, 대시보드 접근이 막힌다.
- 초대받지 않은 그룹의 invite는 보이지 않는다.

실패 시 확인 포인트:

- Outsider 계정이 잘못된 세션을 사용하고 있지 않은지 확인한다.
- RLS 차단 메시지인지, UI 숨김인지 구분한다.

### STEP 7. Group Event 생성

목적:

- Leader 또는 허용된 권한 보유자가 그룹 일정을 생성할 수 있는지 확인한다.

예상 결과:

- 그룹 일정 생성 화면이 열린다.
- title, start/end, recurrence 입력이 가능하다.
- 생성 후 그룹 일정 목록에 반영된다.

실패 시 확인 포인트:

- selectedGroup이 활성 상태인지 확인한다.
- delegation 권한이 필요한 케이스인지 확인한다.
- end_at이 start_at보다 앞서지 않는지 확인한다.

### STEP 8. Calendar Overlay 확인

목적:

- 개인 일정과 그룹 일정이 같은 캘린더 화면에서 UI 레벨로만 함께 보이는지 확인한다.

예상 결과:

- 개인 일정은 기존처럼 유지된다.
- 그룹 일정은 배지/아이콘/색상으로 구분된다.
- selectedGroup이 없으면 개인 일정만 보인다.
- 그룹 일정 클릭 시 GroupEventDetail로 이동한다.
- 개인 일정 클릭 시 기존 개인 상세 흐름이 유지된다.

실패 시 확인 포인트:

- overlay가 DB를 섞는 방식으로 구현되지 않았는지 확인한다.
- 범위가 현재 visible range와 맞는지 확인한다.

### STEP 9. Dashboard 확인

목적:

- Leader용 대시보드가 최소 지표를 보여주는지 확인한다.

예상 결과:

- 오늘 그룹 일정 수가 보인다.
- 이번 주 그룹 일정 수가 보인다.
- 멤버 수가 보인다.
- 다가오는 일정이 보인다.
- AI 코칭/성과분석/KPI는 보이지 않는다.

실패 시 확인 포인트:

- 현재 선택 그룹이 맞는지 확인한다.
- 그룹이 archived 상태인지 확인한다.
- dashboard reload가 필요한지 확인한다.

### STEP 10. Member 제거

목적:

- Leader가 Member를 제거할 수 있는지 확인한다.

예상 결과:

- leader만 제거 버튼을 볼 수 있다.
- 제거 후 status가 removed로 바뀐다.
- removed_at / removed_by가 기록된다.

실패 시 확인 포인트:

- 자기 자신 제거인지 확인한다.
- 마지막 leader 제거 시도인지 확인한다.
- RPC `remove_group_member` 실패 메시지를 확인한다.

### STEP 11. 권한 차단 확인

목적:

- Member/Outsider가 Leader 전용 작업을 수행하지 못하는지 확인한다.

예상 결과:

- Member는 그룹 생성/초대/리더 전용 멤버 제거가 차단된다.
- Outsider는 그룹 조회/일정 조회/대시보드 조회가 차단된다.
- delegation이 없는 Member는 Leader 전용 그룹 일정 작업이 차단된다.

실패 시 확인 포인트:

- 버튼 비활성화인지, 서버 RLS 차단인지 구분한다.
- 위임 권한이 실제로 부여된 계정인지 확인한다.

## 4. 단계별 예상 결과와 실패 시 확인 포인트

| 단계 | 예상 결과 | 실패 시 확인 포인트 |
|---|---|---|
| Leader 로그인 | 개인 홈과 그룹 메뉴가 정상 표시 | 세션/인증/네트워크 |
| Group 생성 | 새 그룹이 selectedGroup으로 설정 | 생성 권한, reload |
| Invite 발송 | pending invite 생성 | leader 여부, 대상 값, 중복 여부 |
| Member 수락 | invite accepted, membership active | 만료, 대상 일치, RPC 실패 |
| Member 표시 | role/status/joined_at 표시 | reload, 캐시, 권한 |
| Outsider 차단 | 그룹 데이터 미노출 | 잘못된 세션, RLS 차단 여부 |
| Group Event 생성 | 일정 생성 성공 | group context, delegation, 시간 검증 |
| Calendar Overlay | 개인/그룹 일정 함께 표시 | visible range, 배지, detail route |
| Dashboard | 오늘/이번 주/멤버/다가오는 일정 표시 | selectedGroup, archived 여부 |
| Member 제거 | removed 상태 반영 | self removal, last leader, RPC 실패 |
| 권한 차단 | member/outsider의 제한 동작 확인 | UI 숨김과 서버 차단 구분 |

## 5. 버그 기록 양식

| 항목 | 내용 |
|---|---|
| 날짜 |  |
| 기기 |  |
| 계정 역할 | Leader / Member / Outsider |
| 화면 |  |
| 단계 | STEP 1 ~ STEP 11 |
| 기대 결과 |  |
| 실제 결과 |  |
| 재현율 |  |
| 로그/에러 |  |
| 스크린샷 |  |
| 비고 |  |

## 6. PASS 기준

PASS 기준:

- Leader, Member, Outsider 세 계정이 각각 의도한 역할로 동작한다.
- 그룹 생성, 초대, 수락, 멤버 표시, 멤버 제거가 모두 연결된다.
- outsider는 그룹 데이터에 접근하지 못한다.
- 그룹 일정이 개인 캘린더와 UI에서만 병합되어 보인다.
- Dashboard는 leader 기준 최소 정보만 보여준다.
- 개인 일정 생성/수정/삭제는 기존처럼 정상 동작한다.
- 특정 단계 실패 시 원인이 계정, 권한, RLS, RPC, UI 중 어디인지 바로 분리할 수 있다.

최종 판단:

- 위 항목이 모두 충족되면 smoke test PASS로 기록한다.
- 하나라도 실패하면 FAIL 또는 NEEDS FOLLOW-UP으로 기록하고, 문제를 재현 가능한 단계 번호와 함께 남긴다.
