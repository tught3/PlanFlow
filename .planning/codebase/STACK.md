# STACK

Generated: 2026-05-03

## 프로젝트 성격
- PlanFlow는 Flutter 기반 AI 음성 스케줄러 앱이다.
- Android 1차 출시가 우선이며 iOS/web/desktop 플랫폼 폴더도 Flutter scaffold로 존재한다.
- 제품 범위는 `PlanFlow_Codex_Prompt_v3.md`가 기준이며, 현재는 1차 배포용 무료 오픈 + PRO 얼리버드 수집 방향이다.

## 언어와 런타임
- 앱 언어: Dart / Flutter.
- Dart SDK 제약은 `pubspec.yaml`의 `>=3.3.0 <4.0.0`.
- Flutter 앱 진입점은 `lib/main.dart`.
- 앱 루트 위젯은 `lib/app.dart`의 `PlanFlowApp`.
- 라우팅은 `lib/core/router.dart`의 `GoRouter`로 구성된다.

## 주요 Flutter 의존성
- 상태 관리: `flutter_riverpod`, 일부 전역 `ChangeNotifier` 기반 provider.
- 라우팅: `go_router`.
- 환경변수: `flutter_dotenv`.
- 백엔드/Auth: `supabase_flutter`.
- STT: `speech_to_text`.
- TTS: `flutter_tts`.
- 로컬 알림: `flutter_local_notifications`, `timezone`.
- Android 알람: `android_alarm_manager_plus`.
- 홈 위젯: `home_widget`.
- 캘린더: `google_sign_in`, `googleapis`, `googleapis_auth`.
- 네트워크/API: `http`, `url_launcher`.
- 국제화: `intl`, `flutter_localizations`.

## 플랫폼 구조
- `android/`, `ios/`, `web/`, `windows/`, `macos/`, `linux/` 플랫폼 폴더가 있다.
- 1차 릴리스 검증은 Android 중심으로 봐야 한다.
- Android 네이티브 STT 연동은 `lib/services/stt_service.dart`의 `MethodChannel('planflow/native_stt')` 호출 경로가 있다.

## 데이터와 DB
- Supabase SQL source of truth는 `supabase/schema.sql`.
- 핵심 테이블은 `users`, `events`, `pre_actions`, `reminders`, `voice_logs`, `location_history`, `user_settings`, `early_bird_emails`, `user_backups`.
- 모든 사용자 데이터 테이블에 RLS 정책이 정의되어 있다.
- 백업 복원 RPC는 `public.restore_user_backup(uuid)`.
- 얼리버드 이메일 수집 RPC는 `public.submit_early_bird_email(text)`.

## 앱 설정
- 환경 설정 로딩은 `lib/core/env.dart`의 `AppEnv`.
- `.env` asset은 `pubspec.yaml`에 등록되어 있다.
- Supabase placeholder 값은 `AppEnv.hasValidSupabaseConfig`에서 걸러진다.
- Supabase 초기화는 `lib/main.dart`에서 유효한 설정일 때만 수행한다.

## 디자인 시스템
- 테마는 `lib/core/theme.dart`.
- 주요 색상 토큰은 `PlanFlowColors`.
- Material 3 기반이며 `Noto Sans KR`, `Malgun Gothic`, `Roboto` fallback을 사용한다.
- 디자인 참고 문서는 `PlanFlow_Design_System.md`.

## 테스트/품질 도구
- Flutter lint는 `analysis_options.yaml`에서 `package:flutter_lints/flutter.yaml`를 포함한다.
- 주요 검증 명령은 `flutter analyze`와 `flutter test`.
- 테스트는 `test/data`, `test/services`, `test/screens`, `test/providers`로 분리되어 있다.

## GSD 상태
- 현재 `C:\PlanFlow`에는 `scripts/gsd-context-hygiene.mjs`가 없다.
- `.planning/STATE.md`와 `.planning/context/ACTIVE_SUMMARY.md`는 존재한다.
- `.planning/codebase/`는 이번 매핑에서 생성된 코드베이스 구조 문서 위치다.
