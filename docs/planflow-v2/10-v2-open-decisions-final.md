# PlanFlow V2 Open Decisions Final

이 문서는 [09-v2-final-master-design.md](./09-v2-final-master-design.md)를 기준으로, ERD 작성 전에 남아 있던 미결정사항 6개를 최종 확정한 문서다.

## 1. Group 삭제 정책

- 즉시 영구 삭제는 금지한다.
- 삭제 요청 시 `group_backups`를 생성한다.
- 삭제 대상 `group.status`는 `archived`로 전환한다.
- archived group은 기본 화면, 대시보드, 캘린더에서 숨긴다.
- archived group은 복원 가능해야 한다.
- 영구 삭제는 별도 단계로 둔다.
- 부모 group이 archived 되면 하위 group도 함께 archived 상태로 간주한다.
- 복원 시 하위 group 복원 여부는 선택 가능하게 설계한다.

## 2. Delegation 위임 범위

V2에서 위임 가능하다.

- 그룹 일정 생성
- 그룹 일정 수정
- 그룹 일정 삭제 또는 취소
- 그룹 대시보드 조회

V2에서 위임 금지한다.

- 그룹 삭제
- 하위 그룹 생성
- 멤버 제거
- 다른 사람에게 재위임
- 영구 삭제
- 결제/운영자 권한

위임은 role 변경이 아니라 `group_role_delegations`로 관리한다.

- `starts_at` / `ends_at` 기준으로 기간 만료 시 자동 무효화된다.
- 위임 범위는 고정된 권한 집합으로 관리한다.

## 3. `group_invites` 상태값

상태값은 다음과 같다.

- `pending`
- `accepted`
- `rejected`
- `cancelled`
- `expired`

규칙은 다음과 같다.

- 이미 member인 사용자는 초대할 수 없다.
- 같은 group에 `pending` 초대가 있으면 중복 초대할 수 없다.
- 초대 ID 또는 이메일 둘 다 허용한다.
- 초대 수락 시 `group_members`가 생성된다.
- 초대 만료 시 수락할 수 없다.

## 4. `group_events` 반복 일정

V2에서는 반복 일정을 지원한다.

지원 범위는 다음과 같다.

- `none`
- `daily`
- `weekly`
- `monthly`

V2에서는 복잡한 RRULE 전체를 지원하지 않는다.

반복 종료 조건은 다음 중 하나로 제한한다.

- 종료일 없음
- 특정 날짜까지

## 5. Group dashboard 집계 기준

leader 대시보드 표시 항목은 다음으로 제한한다.

- 오늘 그룹 일정 수
- 이번 주 그룹 일정 수
- 다가오는 그룹 일정
- 멤버별 그룹 일정 수
- 하위 그룹별 일정 수

표시하지 않는다.

- KPI
- 성과 분석
- 생산성 점수
- AI 코칭
- Action Item 통계

## 6. Group default context 선택 규칙

앱 실행 시 기본 group 선택 순서는 다음과 같다.

1. 사용자가 마지막으로 선택한 group
2. 사용자가 leader인 group
3. 사용자가 member인 group
4. 없으면 개인 모드

다중 group 소속 사용자는 현재 선택된 group context를 명확히 볼 수 있어야 한다.

## 7. ERD 준비 판단

이 6개 결정사항이 확정되면 V2 ERD 작성이 가능하다.

ERD 범위는 다음 테이블로 제한한다.

- `profiles` / `users`의 `invite_code`
- `groups`
- `group_members`
- `group_invites`
- `group_role_delegations`
- `group_events`
- `group_backups`

V2.5 / V3 예약 테이블은 다음과 같다.

- `meeting_notes`
- `action_items`
- `tasks`
- `coaching_reports`

## 8. 최종 결론

V2 ERD는 지금 당장 작성하지 않고, 이 문서의 6개 결정사항이 확정된 상태에서만 진행한다.

이후 설계와 구현은 [09-v2-final-master-design.md](./09-v2-final-master-design.md)와 이 문서를 최신 기준으로 삼는다.
