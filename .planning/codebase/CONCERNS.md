# CONCERNS

Generated: 2026-05-03

## 현재 가장 중요한 리스크
- PowerShell 기본 시작 위치가 `C:\AI-automatic-expense-tracker`로 이동하는 현상이 있어, `C:\PlanFlow` 명령은 `Set-Location -LiteralPath C:\PlanFlow`를 명시해야 한다.
- `scripts/gsd-context-hygiene.mjs`가 현재 Flutter repo에는 없다. repo 규칙상 누락을 기록하고 계속해야 한다.
- `.planning/codebase/`는 이번 작업 전 untracked 상태였고, 이번 매핑으로 새로 생성/갱신되었다.

## STT/개인정보 리스크
- `lib/services/stt_service.dart`는 반드시 온디바이스 STT 원칙을 유지해야 한다.
- `SpeechListenOptions(onDevice: true)`가 깨지면 제품의 핵심 개인정보 규칙 위반이다.
- 음성 파일은 저장하거나 외부 전송하지 않는다.
- GPT나 Supabase로 보내도 되는 것은 STT 이후 텍스트와 파싱 JSON뿐이다.

## Supabase/RLS 리스크
- `supabase/schema.sql`은 RLS와 RPC를 포함하므로 DB 변경 시 반드시 함께 검토해야 한다.
- 이벤트/리마인더/선행행동/설정/백업 모두 사용자별 RLS가 핵심 안전장치다.
- repository write는 current user id와 모델 userId 정합성을 유지해야 한다.
- placeholder `.env` 환경에서는 Supabase 초기화가 꺼지는 것이 정상이다.

## 인증/OAuth 리스크
- `lib/core/router.dart`는 Supabase ready/auth/recovery 상태에 따라 redirect한다.
- OAuth callback 처리는 `lib/services/oauth_callback_handler.dart`와 앱 링크 설정에 의존한다.
- 잘못된 `.env` 또는 OAuth client id는 dead host/실패 화면을 만들 수 있다.
- 로그인 화면은 설정 오류를 사용자가 이해할 수 있게 한국어로 안내해야 한다.

## 1차 릴리스 범위 리스크
- Naver Calendar는 현재 unsupported 상태로 유지해야 한다.
- billing, ads, reward ads, TEAM/BUSINESS는 1차 범위가 아니다.
- 카톡/문자/통화 감지는 2차 기능이다.
- 1차에서 허용된 수익 관련 기능은 PRO 얼리버드 이메일 수집뿐이다.

## Native/Android 리스크
- Android STT MethodChannel, 알림, alarm manager, home widget은 실기기 검증 없이는 확신하기 어렵다.
- 권한/Doze/full-screen alarm 관련 동작은 OS 버전별 차이가 있을 수 있다.
- 홈 위젯 클릭 URI(`planflow://voice`)와 router 경로(`/voice`)의 연결을 유지해야 한다.

## AI 파싱 리스크
- `lib/services/gpt_service.dart`는 JSON-only 파싱을 기대한다.
- GPT 실패/불완전 JSON에 대해 ConfirmScreen fallback이 필요하다.
- 날짜/시간/장소/준비물/선행행동이 잘못 파싱될 수 있으므로 저장 전 사용자가 확인할 수 있어야 한다.
- 한국어 음성 문장과 일정 표현은 테스트 케이스를 꾸준히 늘리는 것이 좋다.

## UI/상태 리스크
- `ShellScreen`은 IndexedStack으로 탭 상태를 유지한다. 라우팅과 탭 index가 어긋나지 않게 주의해야 한다.
- `authProvider`는 GoRouter refreshListenable로 쓰이므로 notify 타이밍이 라우팅에 직접 영향을 준다.
- Settings 화면은 secret 값을 노출하면 안 된다.
- 홈 화면은 실제 일정 카드 중심이어야 하며 설명성 랜딩 페이지처럼 변하면 안 된다.

## 테스트 공백
- 많은 서비스 테스트가 있지만 Android 실기기 통합 검증은 별도다.
- Supabase 실제 프로젝트/RLS 검증은 로컬 unit test만으로 충분하지 않다.
- Calendar OAuth는 환경변수와 플랫폼 지원 상태에 따라 달라진다.
- 알림/알람/TTS/home widget은 CI보다 기기 검증이 중요하다.

## 문서/작업 리스크
- 이전에 잘못된 작업트리 내용을 읽을 수 있었으므로, 앞으로는 항상 `Get-Location`과 `git rev-parse --show-toplevel`를 확인한다.
- `.planning/STATE.md`와 `.planning/context/ACTIVE_SUMMARY.md`가 현재 상태의 빠른 복구 기준이다.
- 새 문서나 checkpoint를 만들 때 unrelated source 변경은 stage/commit하지 않는다.
