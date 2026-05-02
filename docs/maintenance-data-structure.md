# PlanFlow 유지보수용 데이터 구조 가이드

PlanFlow는 앞으로 기능이 계속 늘어날 수 있으므로 화면 코드가 Supabase, 알림, OAuth, GPT 파싱을 직접 섞어 갖지 않도록 계층을 나눠 관리한다.

## 현재 기준 계층

- `lib/data/models`: 앱에서 쓰는 데이터 타입. Supabase 컬럼명과 Dart 필드 변환은 여기에서 담당한다.
- `lib/data/repositories`: Supabase 테이블/RPC 접근 담당. 화면은 가능하면 repository만 호출한다.
- `lib/services`: 외부 기능 담당. OAuth, GPT, STT, 알림, 백업, 홈 위젯처럼 앱 외부 또는 플랫폼 기능과 맞닿은 코드를 둔다.
- `lib/screens`: 사용자 화면. 화면 상태와 사용자 입력만 다루고, 저장/동기화 세부 구현은 repository/service에 맡긴다.
- `lib/core`: 라우팅, 테마, 환경값, 상수처럼 앱 전역에서 공유하는 코드.
- `supabase/schema.sql`: 데이터베이스 구조의 기준 파일. Supabase SQL Editor에 적용한 내용과 이 파일을 맞춘다.

## 주요 데이터 흐름

1. 사용자가 음성 또는 직접 입력으로 일정을 만든다.
2. `GptService`가 자연어를 일정 구조로 변환한다.
3. 확인 화면에서 `EventModel`을 만든다.
4. `EventRepository`가 `events` 테이블에 저장한다.
5. 관련 준비/알림/위치/음성 로그는 별도 테이블에 저장한다.
6. `NotificationService`와 `HomeWidgetService`가 기기 알림/위젯을 갱신한다.

## 유지보수 원칙

- 새 테이블을 만들면 `supabase/schema.sql`, model, repository, 테스트를 함께 갱신한다.
- 화면에서 Supabase `.from(...)`을 직접 호출하지 않는다. 먼저 repository/service로 빼는 것을 기본값으로 한다.
- 사용자별 데이터는 항상 `user_id`를 기준으로 분리한다.
- OAuth provider나 외부 API가 검수 전이면 화면에서 숨기고 service 코드만 보존할 수 있다.
- 출시 전 기능과 2차 기능은 문서/설정에는 남기되, 사용자 화면에는 노출하지 않는다.

## 다음 정리 후보

- Home 화면의 오늘 일정 조회를 `HomeScheduleRepository` 또는 `EventRepository.listTodayEvents()`로 분리한다.
- 로그인 provider 표시 여부를 환경값 또는 feature flag로 분리한다.
- 앱 내 설정값을 `user_settings` 저장소와 연결한다.
- 백업/복원 상태를 별도 화면 또는 설정 섹션으로 정리한다.
