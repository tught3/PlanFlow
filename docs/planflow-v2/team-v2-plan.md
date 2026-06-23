# PlanFlow 2차 팀 기능 기획서

## 1. 목표

PlanFlow의 1차 개인 일정 MVP는 그대로 유지하고, 2차에서는 팀 기능을 별도 도메인으로 분리해 확장한다.

핵심 목표는 다음과 같다.

- 개인 일정 구조를 훼손하지 않는다.
- 팀 일정, 팀 업무, 회의록, AI 코칭을 별도 모듈로 설계한다.
- 개인 일정과 팀 일정이 섞이지 않도록 소유권과 권한을 분리한다.
- 1차 배포 안정화에 영향이 없도록 설계 단계에서 경계를 고정한다.

## 2. 현재 구조와 분리 원칙

### 2.1 현재 개인 MVP의 중심

PlanFlow의 현재 구조는 `user_id` 중심이다.

- 일정은 `events` 테이블에 개인 소유로 저장된다.
- 준비 알림/출발 알림/브리핑/음성 로그도 모두 개인 기준이다.
- 설정은 `user_settings` 중심이다.
- 캘린더 연동도 사용자별 연결 상태(`calendar_connections`)를 따른다.

이 구조는 개인 일정 MVP에는 적합하지만, 팀 기능을 억지로 덧붙이면 권한/RLS/공유 규칙이 복잡해진다.

### 2.2 분리 전략

2차에서는 아래 원칙을 유지한다.

1. 개인 일정은 기존 구조를 유지한다.
2. 팀 기능은 별도 도메인으로 분리한다.
3. 팀 기능은 개인 일정과 같은 테이블을 공유하지 않는다.
4. 팀 일정이 필요해도 개인 `events`를 직접 확장하지 않는다.
5. 개인 일정 일부 공유는 “복사”가 아니라 “공유 규칙”으로 처리한다.

## 3. 팀 기능 도메인 초안

### 3.1 팀 개념

팀은 PlanFlow 내에서 일정과 업무를 공유하는 최소 단위다.

- 한 사용자는 여러 팀에 속할 수 있다.
- 한 팀은 여러 멤버를 가진다.
- 팀은 일정, 태스크, 회의록, AI 리포트를 가질 수 있다.

### 3.2 제안 엔티티

#### teams

팀 자체를 나타내는 테이블.

- 팀 이름
- 설명
- 생성자
- 상태
- 기본 타임존
- 생성일/수정일

#### team_members

팀 멤버와 역할을 관리하는 테이블.

- 팀 ID
- 사용자 ID
- 역할
- 초대 상태
- 가입 시각
- 마지막 활성 시각

#### team_invites

초대 링크와 초대 상태를 관리하는 테이블.

- 팀 ID
- 이메일 또는 사용자 식별자
- 초대자
- 초대 토큰
- 만료 시각
- 수락/거절 상태

#### team_events

팀 일정 전용 테이블.

- 팀 ID
- 제목
- 시작/종료 시각
- 장소
- 담당자
- 참여자
- 중요도
- 반복 규칙
- 원본 소스
- 외부 캘린더 연결 정보

#### projects

팀 내 프로젝트 묶음.

- 팀 ID
- 프로젝트 이름
- 설명
- 상태
- 우선순위
- 시작/종료 시각

#### tasks

프로젝트 또는 일정과 연결되는 업무 항목.

- 팀 ID
- 프로젝트 ID
- 제목
- 설명
- 담당자
- 상태
- 진행률
- 마감일
- 완료 시각

#### meeting_notes

회의록과 회의 결과를 저장하는 테이블.

- 팀 ID
- 회의 제목
- 회의 시각
- 회의 요약
- 원문 STT
- 할 일 추출 결과
- 참석자

#### coaching_reports

AI 팀 코칭 리포트 저장용 테이블.

- 팀 ID
- 리포트 범위
- 생성 시각
- KPI 요약
- 반복 패턴
- 리스크 요약
- AI 권장사항

## 4. 추천 데이터 모델 초안

아래는 실제 구현 전 정리용 초안이다.

### teams

| 컬럼 | 설명 |
| --- | --- |
| id | 팀 고유 ID |
| owner_user_id | 생성자 |
| name | 팀 이름 |
| description | 팀 설명 |
| timezone | 기본 타임존 |
| status | active / archived |
| created_at | 생성일 |
| updated_at | 수정일 |

### team_members

| 컬럼 | 설명 |
| --- | --- |
| id | 멤버십 고유 ID |
| team_id | 팀 ID |
| user_id | 사용자 ID |
| role | owner / admin / member / viewer |
| invitation_status | invited / accepted / rejected |
| joined_at | 가입일 |
| last_seen_at | 마지막 활동일 |

### team_invites

| 컬럼 | 설명 |
| --- | --- |
| id | 초대 고유 ID |
| team_id | 팀 ID |
| invited_email | 초대 대상 이메일 |
| invited_by_user_id | 초대한 사람 |
| token | 초대 토큰 |
| status | pending / accepted / expired / revoked |
| expires_at | 만료 시각 |
| created_at | 생성일 |

### team_events

| 컬럼 | 설명 |
| --- | --- |
| id | 팀 일정 ID |
| team_id | 팀 ID |
| title | 일정 제목 |
| start_at | 시작 시각 |
| end_at | 종료 시각 |
| location | 장소 |
| location_lat / location_lng | 좌표 |
| memo | 메모 |
| participants | 참여자 목록 |
| assignee_user_id | 담당자 |
| is_critical | 중요 일정 여부 |
| recurrence_rule | 반복 규칙 |
| source | manual / voice / sync |
| external_id | 외부 일정 ID |
| external_calendar_id | 외부 캘린더 ID |
| created_by_user_id | 생성자 |
| created_at | 생성일 |
| updated_at | 수정일 |

### projects

| 컬럼 | 설명 |
| --- | --- |
| id | 프로젝트 ID |
| team_id | 팀 ID |
| name | 프로젝트명 |
| description | 설명 |
| status | active / paused / done |
| priority | 우선순위 |
| start_date | 시작일 |
| due_date | 마감일 |
| created_at | 생성일 |
| updated_at | 수정일 |

### tasks

| 컬럼 | 설명 |
| --- | --- |
| id | 업무 ID |
| team_id | 팀 ID |
| project_id | 프로젝트 ID |
| title | 업무 제목 |
| description | 상세 설명 |
| assignee_user_id | 담당자 |
| status | todo / doing / blocked / done |
| progress | 진행률 |
| due_at | 마감 시각 |
| completed_at | 완료 시각 |
| created_at | 생성일 |
| updated_at | 수정일 |

### meeting_notes

| 컬럼 | 설명 |
| --- | --- |
| id | 회의록 ID |
| team_id | 팀 ID |
| title | 회의 제목 |
| meeting_at | 회의 시각 |
| transcript_raw | 원문 STT |
| summary | 요약 |
| action_items_json | 할 일 추출 결과 |
| attendees | 참석자 |
| created_by_user_id | 작성자 |
| created_at | 생성일 |

### coaching_reports

| 컬럼 | 설명 |
| --- | --- |
| id | 리포트 ID |
| team_id | 팀 ID |
| report_type | weekly / monthly / custom |
| period_start | 시작일 |
| period_end | 종료일 |
| summary_json | 요약 데이터 |
| recommendations_json | 권장사항 |
| created_at | 생성일 |

## 5. 개인 일정과 팀 일정 분리 전략

### 5.1 절대 분리 대상

아래 항목은 개인과 팀이 같은 테이블을 공유하지 않는 방향이 안전하다.

- 일정 본문
- 업무/태스크
- 회의록
- AI 요약/코칭 결과
- 알림 상태
- 초대 상태
- 공유 상태

### 5.2 권장 구조

#### 옵션 A. 완전 분리

- `events`는 개인 일정 전용
- `team_events`는 팀 일정 전용
- `tasks`, `projects`, `meeting_notes`, `coaching_reports`는 팀 전용

장점:

- RLS가 단순하다.
- 개인 MVP와 충돌이 적다.
- 나중에 팀 기능만 따로 버전업하기 쉽다.

단점:

- 화면/검색/캘린더 통합 시 집계 로직이 더 필요하다.

#### 옵션 B. 공통 캘린더 레이어

- 개인 일정과 팀 일정을 상위 캘린더 조회 레이어에서 합쳐 보여준다.
- 저장소는 분리하고, 읽기 경로만 통합한다.

장점:

- UI는 한 화면에서 보기 쉽다.

단점:

- 내부 복잡도가 올라간다.
- 권한/필터 버그가 생기기 쉽다.

### 5.3 권장 결론

2차 초기에는 **완전 분리 + 읽기 통합 레이어**가 가장 안전하다.

- 저장은 분리
- 조회는 통합 가능
- 권한은 각 테이블별 RLS로 분리

## 6. API / 동기화 / AI 흐름 초안

### 6.1 팀 일정 생성 흐름

1. 사용자가 팀 일정/업무를 입력한다.
2. AI 파싱이 제목, 시간, 장소, 담당자, 반복, 메모를 분리한다.
3. 저장 시 팀 전용 테이블에 기록한다.
4. 필요하면 알림과 브리핑은 팀 규칙에 따라 별도 생성한다.

### 6.2 회의록 흐름

1. STT 원문을 저장한다.
2. GPT 요약으로 회의록을 생성한다.
3. 할 일 추출 결과를 tasks로 분리한다.
4. 코칭 리포트는 주간/월간 배치에서 생성한다.

### 6.3 AI 코칭 흐름

AI 코칭은 아래만 사용한다.

- 일정 밀도
- 지연 반복
- 담당자 편중
- 회의 후 할 일 미완료율
- 반복 업무 패턴

개인 브리핑과 분리된 팀 리포트로 운영한다.

## 7. 권한과 RLS 설계 방향

### 기본 원칙

- 개인 데이터는 기존처럼 `auth.uid()` 소유권 중심으로 유지한다.
- 팀 데이터는 `team_members` 기반 권한으로 제어한다.
- 초대는 `team_invites`에서 별도 관리한다.
- 관리자/소유자/멤버/조회자 역할을 분리한다.

### 권장 RLS 방향

- `teams`: owner/member 기준 정책
- `team_members`: 같은 팀 멤버만 조회, owner/admin만 수정
- `team_invites`: 초대자와 소유자만 관리
- `team_events`: team_members 기반 조회/쓰기
- `projects` / `tasks`: team_members 기반
- `meeting_notes`: 작성자 또는 멤버 조회
- `coaching_reports`: 멤버 조회, admin/owner 생성 우선

## 8. 1차 배포 영향 차단 전략

2차 설계는 1차 안정화를 건드리지 않기 위해 아래 기준을 지킨다.

1. 현재 `lib/`, `android/`, `supabase/schema.sql`의 개인 MVP 경로는 유지한다.
2. 팀 기능은 별도 모듈/도메인으로만 설계한다.
3. 개인 앱 화면에 팀 메뉴를 섣불리 추가하지 않는다.
4. 기존 알림/브리핑/STT/캘린더 동기화는 개인 MVP의 안정성을 우선한다.
5. 팀 기능은 별도 브랜치에서 단계적으로 구현한다.

## 9. 2차 작업 순서 제안

### Phase 1

- 팀 도메인 스키마 초안 확정
- 권한/초대/멤버십 모델 설계
- 개인/팀 분리 범위 확정

### Phase 2

- 팀 일정/프로젝트/태스크 기본 CRUD
- 회의록 STT/요약 저장
- 팀 캘린더 통합 뷰

### Phase 3

- AI 코칭 리포트
- 자동 할 일 추출
- 팀 단위 통계/분석

## 10. 현재 기준 최종 판단

PlanFlow는 지금 상태에서 개인 일정 MVP로는 충분히 의미가 있지만, 팀 기능은 같은 테이블에 억지로 붙이는 방식이 아니라 **별도 모듈로 분리하는 것이 맞다**.

특히 `events`, `pre_actions`, `reminders`, `voice_logs`, `location_history`, `user_settings`가 모두 개인 소유 모델이므로, 팀 기능을 바로 얹으면 유지보수성이 크게 떨어진다.

따라서 2차는 **개인 MVP 유지 + 팀 모듈 별도 설계**가 정답이다.
