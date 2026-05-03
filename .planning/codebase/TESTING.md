# TESTING

Generated: 2026-05-03

## 기본 검증 명령
- 분석: `C:\src\flutter\bin\flutter.bat analyze`
- 전체 테스트: `C:\src\flutter\bin\flutter.bat test`
- 특정 테스트: `C:\src\flutter\bin\flutter.bat test test/services/stt_service_test.dart`
- 포맷: `C:\src\flutter\bin\dart.bat format <paths>`
- 패키지 갱신: `C:\src\flutter\bin\flutter.bat pub get`

## 현재 문맥의 최근 검증
- `.planning/context/ACTIVE_SUMMARY.md`에 따르면 최근 여러 checklist 작업 후 `flutter analyze`가 통과했다.
- 서비스 테스트도 여러 차례 focused로 통과했다.
- Windows developer mode가 plugin symlink 이슈 해결에 필요했던 이력이 있다.

## 테스트 분포
- 모델 테스트:
  - `test/data/models/event_model_test.dart`
  - `test/data/models/pre_action_model_test.dart`
  - `test/data/models/reminder_model_test.dart`
  - `test/data/models/user_settings_model_test.dart`
  - `test/data/models/early_bird_email_model_test.dart`
- repository 테스트:
  - `test/data/repositories/settings_repository_test.dart`
  - `test/data/repositories/early_bird_email_repository_test.dart`
- provider 테스트:
  - `test/providers/settings_provider_test.dart`
- screen/widget 테스트:
  - `test/screens/confirm_screen_test.dart`
  - `test/screens/voice_action_screen_test.dart`
  - `test/screens/settings_screen_test.dart`
  - `test/screens/early_bird_signup_card_test.dart`
- service 테스트:
  - `test/services/stt_service_test.dart`
  - `test/services/gpt_service_test.dart`
  - `test/services/calendar_sync_service_test.dart`
  - `test/services/map_service_test.dart`
  - `test/services/travel_time_buffer_service_test.dart`
  - `test/services/home_widget_service_test.dart`
  - `test/services/manual_event_side_effect_service_test.dart`

## 변경별 권장 검증
- 모델 JSON/계산 변경: 관련 `test/data/models/*` + `flutter analyze`.
- Supabase repository 변경: 관련 repository test + `flutter analyze`.
- STT 변경: `test/services/stt_service_test.dart` + Android 실기기 확인.
- GPT prompt/parser 변경: `test/services/gpt_service_test.dart` + representative Korean input 수동 확인.
- 알림/알람 변경: `flutter analyze` + Android 실기기 알림/정확한 알람 검증.
- 캘린더 변경: `test/services/calendar_sync_service_test.dart` + OAuth 설정 환경에서 수동 검증.
- 홈 위젯 변경: `test/services/home_widget_service_test.dart` + Android launcher widget 실기기 검증.
- UI 변경: 해당 widget test + Android/mobile viewport 수동 확인.

## Android 검증 주의
- Android 우선 릴리스이므로 native 기능은 emulator/browser만으로 충분하지 않다.
- STT, 알림, exact alarm, TTS, home widget, OAuth deep link는 실기기 검증이 필요하다.
- 스크린샷/미러링이 검은 화면이면 사용자에게 휴대폰 화면을 켜 달라고 요청한다.

## 문서 매핑 검증
- `.planning/codebase/*.md` 7개가 모두 존재해야 한다.
- 각 문서는 20줄 이상이어야 한다.
- secret 패턴이 없어야 한다.
- 문서만 바꾼 경우 기능 테스트 대신 line count, secret scan, `git diff --check -- .planning/codebase`를 우선한다.

## 알려진 도구 상태
- 현재 `C:\PlanFlow`에는 `scripts/gsd-context-hygiene.mjs`가 없어 위생 스크립트 실행은 불가하다.
- PowerShell 프로필이 다른 작업트리로 이동시키는 현상이 있어, 명령은 `Set-Location -LiteralPath C:\PlanFlow; ...` 형태로 강제하는 것이 안전하다.
