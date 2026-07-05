# PlanFlow 2차 팀 모듈 ERD 초안

이 문서는 PlanFlow 2차 팀 모듈의 DB/ERD 방향을 정리한 초안이다.

## 1. 기본 원칙

- 개인 MVP의 기존 테이블은 유지한다.
- 팀 기능은 개인 MVP와 분리된 별도 테이블 집합으로 설계한다.
- 팀 기능을 이유로 기존 `events`, `pre_actions`, `reminders`, `voice_logs`, `location_history`, `user_settings` 구조를 직접 확장하지 않는다.
- 개인 데이터와 팀 데이터를 한 테이블에 섞지 않는다.
- 이 문서는 설계 초안이며, 아직 실제 `supabase/schema.sql`에는 반영하지 않는다.

## 2. 테이블 초안

### teams

팀 자체를 나타내는 최상위 테이블이다.

주요 목적:

- 팀의 이름과 상태를 관리한다.
- 팀의 소유자와 기본 설정을 보관한다.
- 이후 팀 모듈의 모든 하위 엔티티가 참조하는 루트가 된다.

주요 컬럼 초안:

- `id`
- `owner_user_id`
- `name`
- `description`
- `timezone`
- `status`
- `created_at`
- `updated_at`

### team_members

팀 소속 멤버와 역할을 관리하는 테이블이다.

주요 목적:

- 한 사용자가 어떤 팀에 속하는지 관리한다.
- 역할별 권한 판단의 기준이 된다.
- 초대 수락 상태와 가입 시점을 추적한다.

주요 컬럼 초안:

- `id`
- `team_id`
- `user_id`
- `role`
- `membership_status`
- `joined_at`
- `last_seen_at`
- `created_at`
- `updated_at`

### team_invites

팀 초대 요청과 만료 상태를 관리하는 테이블이다.

주요 목적:

- 초대 링크 또는 초대 대상자를 추적한다.
- 초대 수락 전/후 상태를 분리한다.
- 만료, 취소, 거절 상태를 기록한다.

주요 컬럼 초안:

- `id`
- `team_id`
- `invited_email`
- `invited_user_id`
- `invited_by_user_id`
- `token`
- `status`
- `expires_at`
- `accepted_at`
- `created_at`

### team_events

팀 일정 전용 테이블이다.

주요 목적:

- 팀 단위 일정을 저장한다.
- 팀 캘린더의 기본 소스로 사용한다.
- 담당자, 참가자, 일정 속성을 팀 문맥에서 관리한다.

주요 컬럼 초안:

- `id`
- `team_id`
- `title`
- `description`
- `start_at`
- `end_at`
- `timezone`
- `location_name`
- `location_lat`
- `location_lng`
- `assignee_user_id`
- `created_by_user_id`
- `importance`
- `recurrence_rule`
- `source`
- `external_calendar_id`
- `external_event_id`
- `created_at`
- `updated_at`

### projects

팀 내 프로젝트 단위를 관리하는 테이블이다.

주요 목적:

- 팀 업무를 묶음 단위로 관리한다.
- 태스크와 회의록을 프로젝트 단위로 연결할 수 있게 한다.
- 팀의 진행 상황을 상위 레벨에서 파악하게 한다.

주요 컬럼 초안:

- `id`
- `team_id`
- `name`
- `description`
- `status`
- `priority`
- `start_date`
- `due_date`
- `owner_user_id`
- `created_at`
- `updated_at`

### tasks

팀의 실행 단위를 관리하는 테이블이다.

주요 목적:

- 프로젝트나 일정과 연결되는 태스크를 저장한다.
- 담당자와 상태를 관리한다.
- 회의 후 후속 조치와 연결할 수 있게 한다.

주요 컬럼 초안:

- `id`
- `team_id`
- `project_id`
- `title`
- `description`
- `status`
- `priority`
- `assignee_user_id`
- `reporter_user_id`
- `due_at`
- `completed_at`
- `created_at`
- `updated_at`

### task_comments

태스크에 달리는 코멘트와 진행 메모를 저장하는 테이블이다.

주요 목적:

- 태스크 단위의 대화를 분리해서 관리한다.
- 변경 사유와 추가 맥락을 남긴다.
- 회의록과 태스크가 뒤섞이지 않도록 한다.

주요 컬럼 초안:

- `id`
- `task_id`
- `team_id`
- `author_user_id`
- `comment_body`
- `created_at`
- `updated_at`

### meeting_notes

회의록 원문과 요약을 저장하는 테이블이다.

주요 목적:

- 회의의 원문, 요약, 메타데이터를 관리한다.
- 회의록에서 추출된 액션아이템과 연결된다.
- 팀 단위 회의 기록의 중심이 된다.

주요 컬럼 초안:

- `id`
- `team_id`
- `project_id`
- `title`
- `meeting_at`
- `transcript_raw`
- `summary`
- `attendees_json`
- `created_by_user_id`
- `created_at`
- `updated_at`

### meeting_action_items

회의록에서 추출된 실행 항목을 저장하는 테이블이다.

주요 목적:

- 회의 결과를 태스크로 연결하거나 후속 조치로 전환한다.
- 회의록과 실행 업무를 느슨하게 분리한다.
- AI 추출 결과를 별도 항목으로 감사 가능하게 남긴다.

주요 컬럼 초안:

- `id`
- `meeting_note_id`
- `team_id`
- `task_id`
- `title`
- `description`
- `assignee_user_id`
- `due_at`
- `source`
- `confidence_score`
- `created_at`

### coaching_reports

AI 팀 코칭 리포트를 저장하는 테이블이다.

주요 목적:

- 팀 운영 패턴, 병목, 후속 권장사항을 축적한다.
- 주간/월간 코칭 리포트를 보관한다.
- 개인 브리핑과 분리된 팀 분석 레이어를 제공한다.

주요 컬럼 초안:

- `id`
- `team_id`
- `report_type`
- `period_start`
- `period_end`
- `summary_json`
- `insights_json`
- `recommendations_json`
- `created_by_user_id`
- `created_at`

## 3. 관계 초안

- `teams 1:N team_members`
- `teams 1:N team_invites`
- `teams 1:N team_events`
- `teams 1:N projects`
- `teams 1:N tasks`
- `teams 1:N meeting_notes`
- `teams 1:N coaching_reports`
- `projects 1:N tasks`
- `tasks 1:N task_comments`
- `meeting_notes 1:N meeting_action_items`
- `meeting_action_items N:1 tasks`는 선택적 연결로 둔다
- `team_members.user_id`는 같은 사용자가 여러 팀에 참여할 수 있다는 전제를 가진다

## 4. 개인 events와 team_events를 분리하는 이유

개인 `events`와 팀 `team_events`를 분리하는 이유는 다음과 같다.

- 개인 일정은 단일 소유자 기준이고, 팀 일정은 다중 멤버 기준이기 때문이다.
- 개인 일정에는 개인용 알림, 브리핑, 출발 준비 알림이 얽혀 있다.
- 팀 일정은 담당자, 참여자, 회의 맥락, 프로젝트 연결이 추가된다.
- 같은 테이블에 섞으면 RLS 정책과 조회 조건이 복잡해진다.
- 개인 MVP 안정성을 지키기 위해 저장 경로부터 분리하는 편이 안전하다.

즉, 읽기 화면에서 통합해서 보여줄 수는 있어도 저장 계층은 분리하는 방향이 맞다.

## 5. event_shares 개념 메모

나중에 개인 일정을 팀에 공유해야 한다면, 개인 `events`를 직접 복제하기보다 `event_shares` 같은 개념을 두는 것이 안전하다.

개념 메모:

- 원본 개인 일정은 `events`에 남긴다.
- 공유 대상 팀, 공유 범위, 편집 가능 여부를 별도로 기록한다.
- 공유는 복제가 아니라 접근 권한 부여에 가깝게 설계한다.
- 개인 일정의 메모, 위치, 알림 정보는 공유 범위를 더 세밀하게 조절해야 한다.

이 개념은 향후 확장 포인트로만 둔다.

## 6. RLS 설계 시 주의점

- 모든 팀 테이블은 `team_id` 기반 필터를 기본으로 둔다.
- `team_members` 존재 여부와 역할을 먼저 확인한 뒤 나머지 테이블 접근을 허용한다.
- 초대 테이블은 팀 멤버가 아니어도 제한적으로 접근할 수 있는 경로가 필요할 수 있다.
- `owner`, `admin`, `member`, `viewer`의 쓰기 범위를 분리해야 한다.
- AI 리포트와 회의록은 읽기 범위가 넓더라도 수정 범위는 좁게 둔다.
- 개인 `events`와 팀 `team_events`는 서로 다른 정책 세트를 가져야 한다.
- 공유 개념을 넣더라도 원본 개인 일정의 읽기/쓰기 권한은 별도로 지켜야 한다.
- 운영자나 관리자 계정이 있다고 해도 팀 데이터에 대한 무제한 접근으로 이어지지 않게 해야 한다.

## 7. 주의 문구

이 문서는 팀 모듈의 설계 초안이다.

- 실제 `supabase/schema.sql` 반영 전 문서다.
- 아직 마이그레이션이나 RLS 적용을 의미하지 않는다.
- 구현 전에 역할, 공유 범위, 일정 통합 방식이 추가로 확정될 수 있다.
