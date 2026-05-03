# CONVENTIONS

Generated: 2026-05-03

## 언어
- 기본 응답과 문서는 한국어를 우선한다.
- 사용자-facing UI 텍스트도 한국어를 유지한다.
- provider/platform 이름이나 API 브랜드는 원문 표기를 허용한다.

## Dart/Flutter 스타일
- `analysis_options.yaml`는 `flutter_lints`를 사용한다.
- `public_member_api_docs`는 비활성화되어 있다.
- Flutter formatting은 `dart format`을 사용한다.
- Material 3 패턴을 사용하며 테마 토큰은 `lib/core/theme.dart`를 따른다.
- route 상수는 `lib/core/constants.dart`의 `AppRoutes`를 우선 사용한다.

## 아키텍처 관례
- 앱 시작/전역 설정은 `lib/main.dart`와 `lib/app.dart`.
- route/redirect는 `lib/core/router.dart`.
- 화면은 `lib/screens/**`.
- 재사용 위젯은 `lib/widgets/**` 또는 feature screen 하위 `widgets/`.
- 도메인 모델은 `lib/data/models/**`.
- Supabase 접근은 `lib/data/repositories/**`.
- 외부 API/플랫폼 기능은 `lib/services/**`.
- 상태는 `lib/providers/**`에 둔다.

## Supabase 관례
- `.env` 값은 `AppEnv`를 통해 접근한다.
- Supabase 설정이 placeholder이면 초기화하지 않는다.
- 사용자 데이터 write는 현재 로그인한 user id와 모델의 `userId`가 일치해야 한다.
- DB 변경은 `supabase/schema.sql`을 기준으로 한다.
- RLS 정책은 유지해야 하며, table 추가 시 정책도 함께 추가한다.

## 음성/AI 보안 관례
- STT는 온디바이스가 기본이며 `SpeechListenOptions(onDevice: true)`를 유지한다.
- 음성 파일은 외부 서버로 보내지 않는다.
- GPT에는 STT 변환 텍스트만 전달한다.
- `voice_logs`에는 raw text와 parsed JSON만 저장한다.
- 파싱 실패 시 사용자가 확인/수정할 수 있는 fallback UI를 유지한다.

## 캘린더/지도 관례
- Google Calendar는 지원 경로가 있으나 OAuth 설정이 없으면 notConfigured/signedOut 상태를 반환한다.
- Naver Calendar는 1차 배포에서 unsupported로 유지한다.
- 이동시간/지도 API 키는 `AppEnv`에서 읽고, secrets를 코드/문서에 쓰지 않는다.

## UI 관례
- 1차 홈은 일정 카드 중심의 실사용 화면이어야 한다.
- 설정 화면은 실제 로컬 상태/환경 상태를 보여주되 secret 값은 노출하지 않는다.
- 얼리버드 이메일 수집은 1차 배포에서 허용된 수익 관련 유일한 기능이다.
- 광고/구독 제한/TEAM/BUSINESS는 1차 구현 범위가 아니다.

## 테스트 관례
- 모델 로직은 `test/data/models`.
- 서비스 로직은 `test/services`.
- 화면은 `test/screens`.
- 변경 범위에 맞는 focused test를 우선 실행하고, 넓은 변경은 `flutter analyze`와 전체/관련 테스트를 실행한다.

## 작업 관례
- 시작 시 `.planning/STATE.md`와 `.planning/context/ACTIVE_SUMMARY.md`를 확인한다.
- `scripts/gsd-context-hygiene.mjs`가 현재 없으므로 실행 불가를 기록하고 계속한다.
- 완료 시 planning context checkpoint와 검증 결과를 남긴다.
- unrelated dirty/untracked 파일은 건드리지 않는다.
