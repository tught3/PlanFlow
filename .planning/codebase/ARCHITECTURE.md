# ARCHITECTURE

Generated: 2026-05-03

## 전체 구조
- PlanFlow는 Flutter 단일 앱 구조다.
- UI, 상태, 데이터 모델, Supabase repository, 음성/AI/알림/캘린더 서비스가 `lib/` 아래에 계층화되어 있다.
- Supabase는 Auth, PostgreSQL, RLS, 백업/복원 RPC의 백엔드 역할을 한다.
- 음성 처리 원칙은 온디바이스 STT -> 텍스트 -> GPT 일정 파싱 -> 사용자 확인 -> Supabase 저장이다.

## 부팅 흐름
- `lib/main.dart`가 Flutter binding을 초기화한다.
- `.env`를 `flutter_dotenv`로 로드한다.
- `AppEnv.hasValidSupabaseConfig`가 true일 때만 Supabase를 초기화한다.
- Supabase 초기화 성공 후 `authProvider.start()`를 호출한다.
- 앱은 `ProviderScope(child: PlanFlowApp())`로 시작한다.

## 앱 루트와 라우팅
- `lib/app.dart`는 `MaterialApp.router`를 생성한다.
- locale은 `ko_KR`이며 `en_US`도 supportedLocales에 포함된다.
- 앱 resume 시 `authProvider.syncCurrentSession()`을 호출한다.
- 홈 위젯 초기 실행/클릭 URI를 받아 `planflow://voice`를 음성 화면으로 보낸다.
- `lib/core/router.dart`의 `GoRouter`가 인증 상태와 Supabase 준비 상태에 따라 redirect한다.

## 주요 라우트
- `/` -> `SplashScreen`.
- `/login` -> `LoginScreen`.
- `/reset-password` -> `ResetPasswordScreen`.
- `/home` -> `ShellScreen(initialIndex: 0)`.
- `/calendar` -> `ShellScreen(initialIndex: 1)`.
- `/settings` -> `ShellScreen(initialIndex: 2)`.
- `/voice` -> `VoiceInputScreen`.
- `/voice/action` -> `VoiceActionScreen`.
- `/voice/confirm` -> `ConfirmScreen`.
- `/event/detail`, `/event/detail/:eventId` -> `EventDetailScreen`.
- `/event/edit`, `/event/edit/:eventId` -> `EventEditScreen`.

## UI Shell
- `lib/screens/shell_screen.dart`는 `IndexedStack`으로 홈/캘린더/설정 탭을 유지한다.
- 하단 내비게이션은 홈, 일정, 설정 3개 destination이다.
- Android back 동작은 홈 탭 복귀 후 앱 종료로 처리한다.
- 전역 음성 FAB는 `lib/widgets/planflow_voice_fab.dart`.

## 데이터 계층
- 모델은 `lib/data/models/`에 있다.
- repository는 `lib/data/repositories/`에 있다.
- `EventRepository`는 abstract + Supabase 구현체 패턴을 사용한다.
- `EventModel`은 Supabase row JSON 변환과 앱 내부 도메인 모델 역할을 겸한다.
- settings, reminders, app feature, early bird email repository도 같은 data 계층에 배치되어 있다.

## 상태 계층
- `lib/providers/auth_provider.dart`는 인증 상태와 password recovery 상태를 라우터에 제공한다.
- `lib/providers/event_provider.dart`는 이벤트 목록 로딩 상태를 관리한다.
- `lib/providers/settings_provider.dart`는 설정 상태를 관리한다.
- `flutter_riverpod`이 앱 루트에 주입되어 있고, 일부 provider는 기존 `ChangeNotifier` 패턴을 유지한다.

## 서비스 계층
- 음성 입력: `lib/services/stt_service.dart`.
- GPT 파싱/브리핑: `lib/services/gpt_service.dart`.
- Supabase auth: `lib/services/auth_service.dart`.
- 알림: `lib/services/notification_service.dart`.
- Android 알람/브리핑: `lib/services/alarm_service.dart`, `lib/services/briefing_scheduler_service.dart`.
- 캘린더 동기화: `lib/services/calendar_sync_service.dart`.
- 백업: `lib/services/backup_service.dart`.
- 홈 위젯: `lib/services/home_widget_service.dart`.
- 이벤트 저장 후 부수효과: `lib/services/manual_event_side_effect_service.dart`.

## 저장 흐름
- 사용자는 `VoiceInputScreen`에서 STT를 시작한다.
- 텍스트는 `GptService`로 파싱된다.
- `ConfirmScreen`에서 사용자가 결과를 확인/수정한다.
- 저장 시 이벤트, 선행행동, 리마인더, 위치 이력, voice log, 알림 스케줄링 흐름이 연결되어야 한다.
- 수동 이벤트 부수효과는 `ManualEventSideEffectService`에 분리되어 있다.

## DB/RLS 구조
- `supabase/schema.sql`은 재실행 가능한 `create table if not exists`, `alter table add column if not exists`, RLS policy, RPC를 포함한다.
- 모든 사용자 소유 테이블은 `auth.uid()` 기반 RLS를 가진다.
- `early_bird_emails`는 anon/authenticated에서 RPC로 제출할 수 있게 설계되어 있다.
- `user_backups`와 `restore_user_backup`은 사용자별 백업/복원 경로다.
