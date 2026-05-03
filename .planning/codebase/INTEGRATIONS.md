# INTEGRATIONS

Generated: 2026-05-03

## Supabase
- 클라이언트 초기화는 `lib/main.dart`에서 `Supabase.initialize()`로 수행한다.
- 설정값은 `lib/core/env.dart`의 `SUPABASE_URL`, `SUPABASE_ANON_KEY`에서 읽는다.
- 설정이 placeholder이면 초기화를 건너뛰고 로그인 화면에서 한국어 경고를 보여주는 흐름이 있다.
- 이벤트 CRUD는 `lib/data/repositories/event_repository.dart`의 `SupabaseEventRepository`.
- 설정/리마인더/얼리버드/백업 저장소는 `lib/data/repositories/` 아래에 있다.
- SQL 기준 파일은 `supabase/schema.sql`.

## Supabase Auth
- 인증 상태 provider는 `lib/providers/auth_provider.dart`.
- 인증 서비스는 `lib/services/auth_service.dart`.
- 로그인 화면은 `lib/screens/auth/login_screen.dart`.
- 비밀번호 재설정 화면은 `lib/screens/auth/reset_password_screen.dart`.
- OAuth/딥링크 콜백 처리는 `lib/services/oauth_callback_handler.dart`.
- 앱 라우터는 Supabase 준비 상태와 로그인 상태에 따라 `/login`, `/home`, `/reset-password`로 redirect한다.

## OpenAI
- 자연어 일정 파싱과 브리핑 생성은 `lib/services/gpt_service.dart`.
- API 키는 `AppEnv.openAiApiKey`에서 읽는다.
- 파싱 프롬프트는 한국어 일정 JSON을 요구하며, 음성 파일이 아니라 STT 결과 텍스트만 사용한다.
- 브리핑 프롬프트는 모닝/이브닝 한국어 문장 생성 용도다.

## STT
- STT 서비스는 `lib/services/stt_service.dart`.
- `speech_to_text` 경로에서 `SpeechListenOptions(onDevice: true)`를 사용한다.
- Android에서는 우선 `MethodChannel('planflow/native_stt')` 기반 네이티브 STT를 시도하고, 실패 시 `speech_to_text` 경로로 fallback한다.
- 음성 명령 정규화, 마지막 단어/세그먼트 삭제, 전체 초기화 같은 음성 편집 보조 로직이 있다.
- 보안 규칙상 음성 파일은 외부 서버로 보내지 않는다.

## TTS와 알람
- TTS 서비스는 `lib/services/tts_service.dart`.
- 브리핑/알람 스케줄 scaffold는 `lib/services/alarm_service.dart`와 `lib/services/briefing_scheduler_service.dart`.
- 로컬 알림은 `lib/services/notification_service.dart`.
- 리마인더 설정 계산은 `lib/services/reminder_settings_service.dart`.

## Calendar
- 캘린더 동기화는 `lib/services/calendar_sync_service.dart`.
- Google Calendar는 `google_sign_in`, `googleapis`, `googleapis_auth`를 사용한다.
- Google 이벤트는 `EventRepository.upsertEventBySourceExternalId()`로 Supabase events에 반영한다.
- Naver Calendar는 1차 배포에서 unsupported 결과를 반환하도록 명시되어 있다.

## 지도/이동시간
- 이동시간 버퍼 계산은 `lib/services/travel_time_buffer_service.dart`.
- 위치 조회와 지도 관련 서비스는 `lib/services/location_lookup_service.dart`, `lib/services/map_service.dart`.
- 환경변수로 `GOOGLE_MAPS_API_KEY`, `TMAP_API_KEY`, `NAVER_MAP_CLIENT_ID`, `NAVER_MAP_CLIENT_SECRET`를 읽는 구조가 있다.

## 홈 위젯
- 앱 루트는 `home_widget` 클릭 스트림을 구독한다.
- `lib/app.dart`는 `planflow://voice` 홈 위젯 클릭을 `/voice`로 라우팅한다.
- 홈 위젯 서비스는 `lib/services/home_widget_service.dart`.
- 플랫폼 분기는 `home_widget_platform.dart`, `home_widget_platform_io.dart`, `home_widget_platform_stub.dart`.

## 외부로 아직 노출하면 안 되는 범위
- Naver Calendar는 1차 배포에서 working feature로 노출하지 않는다.
- billing, ads, reward ads, TEAM/BUSINESS 기능은 1차 릴리스 범위가 아니다.
- 카톡/문자/통화 감지는 2차 기능이며 1차에서 구현/노출하지 않는다.
