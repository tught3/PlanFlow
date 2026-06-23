# PlanFlow V2 Final Master Design

## 1. 최종 V2 한 줄 정의

PlanFlow V2는 기존 개인 AI 일정관리 앱에 Group Tree 기반 조직 일정 공유 기능을 추가하는 버전이다.

## 2. V2 포함 범위

- Group Tree
- `groups`
- `group_members`
- `group_invites`
- `group_role_delegations`
- `group_events`
- `group_backups`
- 그룹 생성
- 하위 그룹 생성
- 초대 ID/이메일 초대
- 권한 위임
- 그룹 일정
- 개인 일정 + 그룹 일정 오버레이
- 리더용 그룹 대시보드

## 3. V2 제외 범위

- 회의록
- AI 회의록
- 회의록 검색
- Action Item
- Task
- AI 코칭
- 성과 분석
- 음성 녹음 저장

## 4. V2.5 후보

- 회의록 작성
- AI 회의록 요약
- 회의록 검색
- 회의록 태그
- 회의록 즐겨찾기

## 5. V3 후보

- Action Item
- Task
- 업무 상태 추적
- AI 코칭
- 성과 분석
- 조직 지식 검색
- 벡터 검색/RAG

## 6. 기존 문서 충돌 정리

| 기존 문서 | 충돌 내용 | 처리 방향 |
| --- | --- | --- |
| [01-team-erd-draft.md](./01-team-erd-draft.md) | Team 중심 ERD와 `team_events`/`teams` 구조가 현재 Group Tree 방향과 다름 | 최신 기준인 09 문서로 재작성 대상 |
| [02-team-screen-flow.md](./02-team-screen-flow.md) | 팀 홈/팀 캘린더/팀 일정/회의록/Task 흐름이 팀 중심으로 정의됨 | Group 흐름 기준으로 재정리 |
| [03-team-permission-policy.md](./03-team-permission-policy.md) | `owner/admin/member/viewer` 중심 정책이 Group Tree의 `group_members.role` 구조와 충돌 | Group 권한 모델로 재정리 |
| [04-team-v2-mvp-scope.md](./04-team-v2-mvp-scope.md) | 회의록, AI 요약, Action Item, Task를 V2 포함 범위에 둠 | 회의록/업무 기능은 V2.5/V3로 이동 |
| [05-v2-product-structure.md](./05-v2-product-structure.md) | Team 운영 비서 관점으로 설명되어 있고 Group Tree 구조가 아님 | Group Tree 기반 정의로 수정 |
| [06-v2-role-and-visibility-pipeline.md](./06-v2-role-and-visibility-pipeline.md) | `team_leader`/`team_member`, `team_events`, `meeting_action_items` 등 팀 용어와 V2 범위가 현재 최종 방향과 다름 | Group 용어와 제외 범위 기준으로 수정 |
| [07-v2-user-flow-detail.md](./07-v2-user-flow-detail.md) | 현재 저장소에 없음 | 이후 생성 시 09 문서 기준으로 작성 |

## 7. 최종 데이터 원칙

- 기존 `events` 유지
- `group_events` 별도
- `events`와 `group_events`는 DB에서 섞지 않음
- UI에서만 오버레이
- 역할은 user가 아니라 `group_members`에 저장
- 삭제는 archived + backup 우선
- 회의록 관련 테이블은 V2에서 만들지 않음

## 8. 최종 UX 원칙

- 홈은 개인 중심 유지
- 그룹 기능은 조건부 노출
- 현재 선택된 Group 컨텍스트를 명확히 표시
- leader와 member에게 보이는 화면을 다르게 구성
- 다중 그룹 소속을 전제로 설계
- 그룹 일정과 개인 일정은 색상/배지로 구분

## 9. 권한 규칙

- member는 본인이 속한 Group 일정 조회
- leader는 본인이 리더인 Group과 하위 Group 일정 조회
- 형제 Group 조회 금지
- 개인 일정 자동 공유 금지
- delegation은 role 변경이 아니라 별도 위임

## 10. ERD 전 확인사항

ERD 작성 전에 아직 확정해야 할 항목은 다음과 같다.

- group 삭제 시 하위 group 처리
- delegation 위임 범위
- `group_invites` 상태값
- `group_events` 반복 일정 지원 여부
- group dashboard 집계 기준
- group default context 선택 규칙

## 11. 최종 결론

V2는 협업툴 전체가 아니라, 기존 개인 AI 일정관리 앱에 Group Tree 기반 조직 일정 공유 기능을 더한 버전이다.

따라서 이후의 모든 설계와 구현은 이 09 문서를 최신 기준으로 삼아야 한다.
