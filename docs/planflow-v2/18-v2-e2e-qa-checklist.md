# PlanFlow V2 End-to-End QA Checklist

이 문서는 PlanFlow V2의 실제 사용자 흐름, 개인 기능 회귀, DB/RLS/RPC 안정성, 그리고 `main` 병합 전 위험 요소를 한 번에 점검하기 위한 통합 QA 체크리스트다.

이 문서는 검토/테스트용이며, 구현이나 `supabase/schema.sql` / Flutter 코드 변경은 하지 않는다.

## 1. QA 목적

- V2 핵심 흐름이 실제 사용자 기준으로 끊기지 않고 연결되는지 확인한다.
- 기존 개인 PlanFlow 기능이 깨지지 않았는지 확인한다.
- `main`과 병합하기 전에 남은 위험 요소와 수동 검증 항목을 정리한다.

## 2. 핵심 사용자 시나리오

### 시나리오 A. 개인 사용자

- 흐름
  - 앱 실행
  - 개인 일정 확인
  - 개인 일정 생성/수정/삭제
  - 그룹이 없어도 기존 기능 정상
  - 캘린더에서 개인 일정만 표시
- 확인 포인트
  - personal mode에서 그룹 메뉴가 노출되지 않거나 읽기 전용으로 동작하는지 확인
  - 개인 일정 생성/수정/삭제가 group 기능과 충돌하지 않는지 확인
- 현재 QA 상태
  - `PASS` for automated regression
  - `NEEDS MANUAL TEST` for 실제 기기 확인

### 시나리오 B. 리더가 그룹 생성

- 흐름
  - 그룹 관리 진입
  - 그룹 생성
  - 생성한 그룹이 `selectedGroup`으로 설정
  - GroupList 표시
  - Dashboard 표시
- 확인 포인트
  - 생성 직후 selected group이 바뀌는지
  - leader role이 정상 반영되는지
  - GroupList와 Dashboard가 같은 context를 보는지
- 현재 QA 상태
  - `PASS` for provider/screen tests
  - `NEEDS MANUAL TEST` for end-to-end 흐름

### 시나리오 C. 리더가 멤버 초대

- 흐름
  - 내 invite_code 확인
  - 초대 ID로 초대
  - 이메일로 초대
  - pending invite 생성
  - 중복 초대 방지
- 확인 포인트
  - invite_code가 실제 사용자 식별 키로 보이는지
  - email / invite_code / user_id 경로가 중복되지 않는지
  - pending invite partial unique index가 작동하는지
- 현재 QA 상태
  - `PASS` for repository and provider tests
  - `NEEDS MANUAL TEST` for user-visible invite flow

### 시나리오 D. 멤버가 초대 수락

- 흐름
  - pending invite 조회
  - accept
  - `accept_group_invite` RPC 동작
  - `group_members` 생성
  - `GroupContextProvider`에 그룹 반영
- 확인 포인트
  - invite accept가 원자적으로 처리되는지
  - accept 후 그룹 context가 바로 갱신되는지
  - 수락 직후 selected group이 personal mode에서 벗어나는지
- 현재 QA 상태
  - `PASS` for RPC/repository tests
  - `NEEDS MANUAL TEST` for context refresh

### 시나리오 E. 멤버 관리

- 흐름
  - 멤버 목록 조회
  - leader/member 표시
  - 자기 자신 제거 방지
  - 마지막 leader 제거 방지
  - 멤버 제거 시 `status removed`
- 확인 포인트
  - UI와 RPC/RLS가 같은 규칙을 쓰는지
  - soft remove가 실제 delete가 아닌지
  - leader가 아닌 사용자는 제거 버튼이 없거나 실패하는지
- 현재 QA 상태
  - `PASS` for RPC/provider tests
  - `NEEDS MANUAL TEST` for final leader edge cases

### 시나리오 F. 그룹 일정

- 흐름
  - 그룹 일정 생성
  - 그룹 일정 조회
  - 그룹 일정 상세
  - 그룹 일정 취소/보관
  - delegation 권한 적용 확인
- 확인 포인트
  - `group_events`가 개인 `events`와 섞이지 않는지
  - delegation permission이 `create/update/cancel`에만 적용되는지
  - 반복 일정 `none/daily/weekly/monthly` 범위가 UI에 맞는지
- 현재 QA 상태
  - `PASS` for model/repository/screen tests
  - `RISK` for recurrence expansion and tree-based permission depth

### 시나리오 G. 캘린더 오버레이

- 흐름
  - 개인 일정 표시 유지
  - 그룹 일정 추가 표시
  - `selectedGroup` 없을 때 개인 모드
  - 그룹 일정 클릭 시 `GroupEventDetail` 이동
  - 개인 일정 클릭 시 기존 상세 이동
- 확인 포인트
  - 개인 일정과 그룹 일정이 UI에서만 병합되는지
  - overlay가 없을 때 기존 캘린더가 그대로 동작하는지
  - selected group 변경 후 overlay가 refresh되는지
- 현재 QA 상태
  - `PASS` for automated widget tests
  - `NEEDS MANUAL TEST` for 실제 화면/스크롤 체감

### 시나리오 H. 대시보드

- 흐름
  - 오늘 일정 수
  - 이번 주 일정 수
  - 멤버 수
  - 다가오는 일정
  - leader/member 표시
- 확인 포인트
  - KPI/성과분석/AI 코칭이 섞이지 않는지
  - leader 전용 정보와 member 정보가 분리되는지
- 현재 QA 상태
  - `PASS` for screen/provider tests
  - `NEEDS MANUAL TEST` for 숫자/빈 상태 시각 확인

## 3. 기존 개인 기능 회귀 체크

| 영역 | 영향 있음/없음 | 확인 방법 | 위험도 | 비고 |
|---|---|---|---|---|
| 홈 | 영향 없음 | 홈 첫 진입, 위젯/카드 렌더 확인 | 낮음 | group overlay가 홈으로 확장되지 않았는지 확인 |
| 개인 캘린더 | 영향 없음 | 일정 목록, 월간 그리드, day sheet 확인 | 낮음 | personal events 흐름 유지 |
| 개인 일정 생성/수정/삭제 | 영향 없음 | event edit/detail flow 수행 | 낮음 | 기존 route 유지 |
| 알림 | 영향 없음 | reminder/pre-action 알림 생성 확인 | 낮음 | group 기능과 분리 |
| 브리핑 | 영향 없음 | morning/evening briefing 실행 | 낮음 | 그룹 데이터가 브리핑에 섞이지 않는지 확인 |
| 음성 입력 | 영향 없음 | STT -> confirm -> save 흐름 확인 | 낮음 | 음성 데이터는 기존 계약 유지 |
| 준비물/장소 | 영향 없음 | event edit editor의 location/supplies 입력 확인 | 낮음 | group 일정이 개인 editor를 건드리지 않는지 확인 |
| 설정 | 영향 없음 | settings route와 그룹 진입점 확인 | 낮음 | group 메뉴 추가가 기존 설정을 덮지 않는지 확인 |
| 인증 | 영향 없음 | login / session restore / logout 확인 | 중간 | Supabase 초기화/세션 복구 회귀 가능성만 점검 |

## 4. DB/RLS/RPC 체크

| 항목 | 현재 판단 | 확인 방법 | 위험도 | 비고 |
|---|---|---|---|---|
| invite accept 원자성 | PASS but verify live | RPC로 invite accept 후 membership 생성 확인 | 중간 | `accept_group_invite`가 핵심 |
| archive group with backup 원자성 | PASS but verify live | archive RPC 후 backup row 생성 및 archived status 확인 | 중간 | `group_backups`와 그룹 상태 동시 반영 확인 |
| remove group member RPC | PASS | 자기 자신 제거/마지막 leader 제거 차단 확인 | 중간 | 서버측 방어 필수 |
| group_events 권한 | PASS but verify live | member/leader/delegation 조회·수정 범위 확인 | 중간 | recursive tree는 추가 점검 필요 |
| delegation permission | PASS | `create/update/cancel` 범위만 허용되는지 확인 | 중간 | delete/group create-child는 제외 |
| group_backups 조회 제한 | PASS | member 조회 차단, leader만 조회 확인 | 낮음 | restore 권한도 함께 확인 |
| 형제 그룹 접근 차단 | PASS but verify live | sibling group select / update 차단 확인 | 중간 | recursive helper 보강 여부 확인 |
| public.users invite_code 구조 | PASS | unique/lookup/copy 동작 확인 | 낮음 | profiles가 아닌 public.users 사용 전제 |

## 5. main 병합 리스크

| 파일 | 위험도 | 대응 방법 | 비고 |
|---|---|---|---|
| `lib/core/router.dart` | 중간 | group route 추가/변경이 개인 route와 충돌하는지 확인 | 경로 중복 여부 점검 |
| `lib/screens/settings/settings_screen.dart` | 중간 | 그룹 메뉴 추가가 기존 설정 카드/버튼과 충돌하지 않는지 확인 | 진입점만 최소화 |
| `lib/screens/calendar/calendar_screen.dart` | 높음 | overlay, personal event, day sheet, test fixture 모두 회귀 점검 | 가장 자주 충돌할 가능성 큼 |
| `pubspec.yaml` | 낮음 | 버전/의존성 변경 여부만 확인 | 배포 시 영향 가능 |
| `supabase/schema.sql` | 높음 | 실제 DB 적용 전 diff / RLS / RPC 검증 필수 | merge 직전 가장 중요 |
| `.planning/context/ACTIVE_SUMMARY.md` | 중간 | 충돌 마커 재발 여부 확인 | append 구간 충돌 주의 |

## 6. Must Fix Before Merge

- 실제 Supabase DB 적용 검증
- RLS를 실제 DB에 적용한 뒤 member/leader/delegation 차단 확인
- `invite accept` 원자성과 `archive group with backup` 원자성 실DB 검증
- `selectedGroup` 전환 후 calendar overlay refresh 확인
- 전체 `flutter test --no-pub` timeout이 재발하지 않는지 확인
- `env/local.json`이 없는 워크트리에서도 최소 회귀 테스트가 돌아가는지 확인

## 7. Can Fix After Merge

- 반복 일정 UX 개선
- 권한 위임 UI 정밀화
- 멤버 이름 / 프로필 표시 개선
- 초대 만료 UX
- 대시보드 필터와 요약 카드 정리
- 캘린더 overlay 표시 밀도 조정

## 8. V2.5 / V3로 넘길 것

### V2.5

- 회의록
- AI 회의록 요약
- 회의록 검색

### V3

- Action Item
- Task
- AI 코칭
- 성과 분석
- 조직 지식 검색

## 9. 최종 QA 체크리스트 표

| 영역 | 체크 항목 | 상태 | 위험도 | 비고 |
|---|---|---|---|---|
| 개인 사용 | 개인 일정만 있는 경우 기존 캘린더 동작 유지 | PASS | 낮음 | 자동 테스트 존재 |
| 개인 사용 | 그룹이 없어도 앱이 personal mode로 정상 동작 | PASS | 낮음 | ContextProvider 검증 필요 |
| 그룹 생성 | 그룹 생성 후 selectedGroup 반영 | NEEDS MANUAL TEST | 중간 | UI 흐름 확인 필요 |
| 그룹 초대 | invite_code / email 초대 생성 | PASS | 중간 | 중복 초대 규칙 포함 |
| 초대 수락 | `accept_group_invite` RPC로 원자 처리 | PASS | 중간 | 실DB 검증 필요 |
| 멤버 관리 | 자기 자신 제거 방지 | PASS | 중간 | 서버측 RPC 포함 |
| 멤버 관리 | 마지막 leader 제거 방지 | PASS | 높음 | edge case 필수 |
| 그룹 일정 | leader/delegation 권한으로 생성/수정/취소 | PASS | 중간 | 반복 일정 포함 |
| 캘린더 | personal + group overlay 동시 표시 | PASS | 중간 | widget test 통과 |
| 캘린더 | selectedGroup 없으면 personal mode 유지 | PASS | 낮음 | provider test 통과 |
| 대시보드 | 오늘/이번 주/멤버/다가오는 일정 표시 | PASS | 낮음 | group dashboard baseline |
| DB/RLS | group_backups 조회 제한 | PASS | 낮음 | leader only |
| DB/RLS | 형제 그룹 접근 차단 | PASS | 중간 | recursive tree는 추가 검증 |
| 병합 | `calendar_screen.dart` 충돌 가능성 | RISK | 높음 | 자주 수정되는 파일 |
| 병합 | `schema.sql` 충돌 가능성 | RISK | 높음 | schema 변경 세션 분리 필요 |
| 병합 | `ACTIVE_SUMMARY.md` 반복 충돌 | RISK | 중간 | append 구간 충돌 주의 |
| 병합 | `router.dart` / `settings_screen.dart` 충돌 | NEEDS MANUAL TEST | 중간 | 진입점 추가 확인 |
| 배포 | 전체 test timeout 재발 여부 | NEEDS MANUAL TEST | 중간 | 환경 의존성 확인 |

## 10. 다음 단계 추천

- 지금 바로 `main` 병합은 조건부 가능하다.
- 다만 병합 전에 반드시 실제 Supabase 적용 검증과 RLS 실DB 테스트를 먼저 해야 한다.
- 수동 테스트는 아래 순서가 좋다.
  1. 개인 캘린더 회귀
  2. 그룹 생성
  3. 초대 발송
  4. 초대 수락
  5. 멤버 제거
  6. 그룹 일정 생성
  7. 캘린더 오버레이 확인
  8. 대시보드 확인
- 현재 QA 결론은 `main merge candidate`이지만, 실DB 검증 전에는 `final merge ready`로 보지 않는다.
