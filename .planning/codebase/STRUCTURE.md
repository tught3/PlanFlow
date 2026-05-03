# STRUCTURE

Generated: 2026-05-03

## 루트 구조
- `.planning/` - GSD 상태, 활성 요약, codebase map 문서.
- `lib/` - Flutter 앱 소스.
- `test/` - Dart/Flutter 테스트.
- `supabase/schema.sql` - Supabase DB/RLS/RPC source of truth.
- `android/`, `ios/`, `web/`, `windows/`, `macos/`, `linux/` - Flutter 플랫폼 scaffold.
- `docs/` - 세부 agent rule 문서.
- `PlanFlow_Codex_Prompt_v3.md` - 제품/구현 범위 기준 문서.
- `PlanFlow_Design_System.md` - UI 디자인 기준 문서.
- `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml` - Flutter 패키지/분석 설정.

## lib/core
- `lib/core/constants.dart` - 앱 이름, spacing, route 상수.
- `lib/core/env.dart` - `.env`/compile-time 환경변수 접근과 placeholder 감지.
- `lib/core/router.dart` - `GoRouter` route/redirect 설정.
- `lib/core/theme.dart` - Material 3 테마와 PlanFlow 색상 토큰.

## lib/data/models
- `event_model.dart` - 일정 도메인 모델.
- `pre_action_model.dart` - 선행행동 역산 알림 모델과 계산 helper.
- `reminder_model.dart` - 리마인더 모델.
- `user_settings_model.dart` - 사용자 설정 모델.
- `early_bird_email_model.dart` - 얼리버드 이메일 모델.
- `app_feature.dart` - 앱 기능/상태 모델.

## lib/data/repositories
- `event_repository.dart` - 이벤트 Supabase CRUD와 source/external_id upsert.
- `reminder_repository.dart` - 리마인더 저장소.
- `settings_repository.dart` - 사용자 설정 저장소.
- `early_bird_email_repository.dart` - 얼리버드 이메일 제출 저장소.
- `app_repository.dart` - 앱 기능/상태 repository.

## lib/providers
- `app_provider.dart` - 앱 상태 provider.
- `auth_provider.dart` - 인증 상태 provider.
- `event_provider.dart` - 이벤트 목록 provider.
- `settings_provider.dart` - 설정 provider.

## lib/screens
- `lib/screens/splash/splash_screen.dart` - 초기 화면.
- `lib/screens/auth/login_screen.dart` - 로그인/설정 경고 화면.
- `lib/screens/auth/reset_password_screen.dart` - 비밀번호 재설정.
- `lib/screens/shell_screen.dart` - 홈/캘린더/설정 탭 shell.
- `lib/screens/home/home_screen.dart` - 실제 홈 화면.
- `lib/screens/home/widgets/` - 브리핑 배너, 얼리버드 카드, 오늘 일정 카드.
- `lib/screens/calendar/calendar_screen.dart` - 일정 화면.
- `lib/screens/voice/voice_input_screen.dart` - 음성 입력.
- `lib/screens/voice/voice_action_screen.dart` - 음성 action 선택/처리.
- `lib/screens/voice/confirm_screen.dart` - 파싱 결과 확인/저장.
- `lib/screens/event/event_detail_screen.dart` - 일정 상세.
- `lib/screens/event/event_edit_screen.dart` - 일정 편집.
- `lib/screens/settings/settings_screen.dart` - 설정 화면.
- 루트 호환 파일로 `lib/screens/home_screen.dart`, `lib/screens/placeholder_screen.dart`도 존재한다.

## lib/services
- `stt_service.dart` - 온디바이스 STT와 음성 편집 명령.
- `gpt_service.dart` - OpenAI 일정 파싱/브리핑.
- `auth_service.dart` - Supabase auth helper.
- `oauth_callback_handler.dart` - OAuth/app link callback 처리.
- `notification_service.dart` - 로컬 알림.
- `alarm_service.dart` - Android alarm/briefing scaffold.
- `tts_service.dart` - TTS.
- `calendar_sync_service.dart` - Google/Naver calendar sync status/sync.
- `travel_time_buffer_service.dart`, `location_lookup_service.dart`, `map_service.dart` - 이동시간/장소.
- `home_widget_service.dart`와 platform files - 홈 위젯 업데이트.
- `backup_service.dart` - 백업.
- `manual_event_side_effect_service.dart` - 이벤트 저장 후 알림/이력 등 부수효과.
- `event_refresh_bus.dart` - 이벤트 갱신 신호.

## test 구조
- `test/data/models/` - 모델 직렬화/계산 테스트.
- `test/data/repositories/` - repository 테스트.
- `test/providers/` - provider 테스트.
- `test/screens/` - 화면/widget 테스트.
- `test/services/` - STT/GPT/calendar/map/home-widget 등 서비스 테스트.

## 주의할 구조 규칙
- 새 기능은 가능하면 `lib/services`, `lib/data`, `lib/providers`, `lib/screens` 계층을 유지해서 배치한다.
- 1차 릴리스에서 deferred 기능은 UI에서 working feature처럼 보이면 안 된다.
- GSD 문맥 스크립트 `scripts/gsd-context-hygiene.mjs`는 현재 이 Flutter repo에는 없다.
