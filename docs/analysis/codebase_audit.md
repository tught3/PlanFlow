# 코드베이스 구조 감사 및 빌드 상태 점검

- **작성일시:** 2026-07-05
- **대상:** PlanFlow Flutter 앱 (`pubspec.yaml` name=`planflow`, version=`1.1.1+75`)
- **SDK 제약:** `>=3.3.0 <4.0.0`
- **감사자:** GLM Worker W02

---

## 1. 빌드 / 분석 상태

| 항목 | 결과 |
| --- | --- |
| `flutter pub get` | ✅ 성공 (의존성 해결 완료) |
| `flutter analyze --no-pub` | ✅ **No issues found!** (return code 0, 약 16.5s) |
| 컴파일 에러 | 없음 |
| 분석 설정 | `analysis_options.yaml` → `package:flutter_lints/flutter.yaml`, `build/**` 제외, `public_member_api_docs: false` |

> 참고: 워크트리 최초에는 패키지가 미설치되어 `uri_does_not_exist` 에러가 발생하지만, `flutter pub get`
> 이후에는 정상 분석된다. 신규 워크트리/CI 환경에서는 반드시 `flutter pub get`을 먼저 실행해야 한다.

---

## 2. lib/ 디렉토리 트리 (Dart 파일 기준)

전체 **181개** Dart 파일 / 약 **88,326 줄** (lib/ 기준). 테스트 파일은 **111개** (`test/`).

```
lib/
├── main.dart                     # 앱 진입점
├── app.dart                      # MaterialApp / 라우터 연결 / 라이프사이클
├── firebase_options.dart         # FlutterFire 생성 파일
├── core/                         # 코어 인프라 (17)
│   ├── analytics_service.dart
│   ├── constants.dart            # AppRoutes 등 라우트 상수
│   ├── diag_logger.dart
│   ├── env.dart                  # AppEnv: Supabase/Naver/Firebase 환경값
│   ├── event_metadata.dart
│   ├── local_time.dart
│   ├── log_text.dart
│   ├── region_settings.dart
│   ├── responsive.dart
│   ├── router.dart               # GoRouter(appRouter) 전역 라우터
│   ├── runtime_error_filter.dart # Crashlytics 노이즈 필터
│   ├── safe_prefs.dart
│   ├── startup_route_gate.dart   # 위젯/딥링크 시작 라우트 게이트
│   ├── supabase_auth_options.dart
│   ├── theme.dart
│   └── time_format_controller.dart
├── data/                         # 데이터 계층 (13)
│   ├── models/                   # EventModel, UserSettingsModel, CalendarConnectionModel 등 (7)
│   └── repositories/             # Supabase 기반 리포지토리 (6)
├── features/                     # 피처 단위 모듈 (46) — 현재 groups 1종
│   └── groups/
│       ├── models/       (10)
│       ├── providers/    (12)   # Riverpod/ChangeNotifier 상태
│       ├── repositories/ (7)
│       ├── screens/      (10)
│       ├── services/     (3)
│       └── widgets/      (4)
├── l10n/                         # 다국어 (4): app_l10n, app_localizations{,_en,_ko}
├── providers/                    # 전역 ChangeNotifier (2): auth_provider, settings_provider
├── screens/                      # UI 화면 (26)
│   ├── auth/         (login, reset_password)
│   ├── briefing/     (briefing_launch)
│   ├── calendar/     (calendar, calendar_widgets)
│   ├── event/        (event_detail, event_edit)
│   ├── home/         (home, home_widgets)
│   ├── location/     (location_pick_flow, location_picker)
│   ├── onboarding/   (permission_onboarding)
│   ├── settings/     (settings, beta_survey, feedback_report, naver_ics_import ...)
│   ├── splash/       (splash)
│   ├── voice/        (voice_input, voice_action, voice_conversation, confirm ...)
│   ├── shell_screen.dart        # 바텀탭 쉘
│   └── placeholder_screen.dart
├── services/                     # 비즈니스/플랫폼 서비스 (57)
│   ├── 알림/알람: alarm_service, notification_service, briefing_scheduler_service,
│   │            departure_alarm_service, smart_preparation_alarm_service ...
│   ├── 음성: stt_service, tts_service, gpt_service, voice_command_pipeline,
│   │         voice_command_router, voice_correction_learning_service ...
│   ├── 캘린더 동기화: calendar_auto_sync_service, calendar_sync_service,
│   │               device_calendar_service, naver_caldav_service, naver_open_api_calendar_service ...
│   ├── 마이그레이션: *_migration_service (event_reminder / smart_preparation / critical_alarm 채널)
│   ├── 플랫폼: home_widget_service(+ io/stub), app_permission_service, background_task_service,
│   │          battery_optimization_service, update_service, oauth_callback_handler ...
│   └── 기타: auth_service, backup_service, review_service, remote_config_service ...
├── shared/                       # 범용 공용 코드 (4): constants/extensions/utils/widgets (barrel)
└── widgets/                      # 재사용 위젯 (9): planflow_action_buttons, planflow_logo,
                                  # planflow_voice_fab, recurrence_selector, reminder_offset_selector ...
```

---

## 3. 주요 진입점

### 3.1 `lib/main.dart`
- `WidgetsFlutterBinding.ensureInitialized()` → 타임존 초기화(`ensureTimeZonesInitialized`) → 세로 고정 →
  `runApp(ProviderScope(child: PlanFlowApp()))`.
- 이후 비동기로 `_initializePlatformServices()` 실행:
  - Firebase (Crashlytics + RemoteConfig, 오프라인/일시 오류는 non-fatal/드롭 필터링)
  - Naver Map (`FlutterNaverMap().init()`)
  - Supabase (`Supabase.initialize`) → `authProvider.start()` + 이벤트 프리페치/일일 캘린더 동기화 스케줄
- 각 플랫폼 서비스 초기화는 타임아웃(`8~10s`)과 try/catch로 보호되어 초기화 실패 시에도 앱 부팅은 진행된다.

### 3.2 `lib/app.dart` — `PlanFlowApp`
- `MaterialApp.router(routerConfig: appRouter)` 로 `go_router` 연결.
- 담당: 홈위젯 클릭 스트림, 딥링크(app_links), 공유 ICS 수신(receive_sharing_intent), 전경 브리핑 폴링(2s),
  캘린더 백그라운드 동기화, OAuth 콜백, 채널/스마트준비 마이그레이션, 업데이트 검사 지연 실행.
- 라이프사이클(`AppLifecycleListener`)에서 onResume/onPause 트리거로 세션/캘린더 동기화.

### 3.3 `lib/core/router.dart` — `appRouter` (GoRouter)
- `initialLocation: AppRoutes.root`, `refreshListenable` = `authProvider` + `startupRouteGate`.
- `redirect` 로직이 세션 상태(`AuthSessionStatus`)에 따라 login/root/home 전환을 결정:
  - `recovering`, `reauthRequired + account snapshot`, `!hasAttemptedStartupSync` → 리다이렉트 보류.
  - 비밀번호 복구 모드 → reset_password 강제.
  - Supabase 미구성 → login 강제.
- 라우트: root, login, permissionOnboarding, resetPassword, home, calendar, settings, briefing,
  naverIcsImport, voice, voiceLauncher(redirect), voiceConversation, voiceAction, confirm, eventDetail,
  그리고 `features/groups/*` 화면(그룹 대시보드/상세/생성/이벤트 생성/상세/목록/초대/멤버 등).
- `ShellScreen(initialIndex)` 로 홈(0)/캘린더(1)/설정(2) 바텀탭 구성.

---

## 4. 핵심 모듈 식별

### 4.1 `lib/core/` — 코어 인프라 (17)
라우터, 테마, 환경(`AppEnv`), 상수(`AppRoutes`), 진단 로거, 런타임 에러 필터(Crashlytics 노이즈 제거),
시작 라우트 게이트(위젯/딥링크 warm-start 복구), 타임존/시간 포맷, 반응형 유틸.

### 4.2 `lib/providers/` — 전역 상태 (2)
- `auth_provider.dart` — `AuthProvider(ChangeNotifier)` 싱글톤(`final authProvider`).
  세션 상태 머신(`AuthSessionStatus`: unresolved/recovering/active/reauthRequired/signedOut),
  부트스트랩/세션 복구/명시적 로그아웃 처리, 프로필 동기화.
- `settings_provider.dart` — 사용자 설정 상태.

### 4.3 `lib/data/` — 데이터 계층 (13)
- `models/`: EventModel, UserSettingsModel, CalendarConnectionModel, EarlyBirdEmailModel,
  FeedbackReportModel, PreActionModel, VoiceCorrectionRule.
- `repositories/`: 각 모델별 Supabase 리포지토리 (event, settings, calendar_connection, early_bird_email,
  feedback, voice_correction_rule).

### 4.4 `lib/features/` — 피처 모듈 (46)
현재 **groups** 피처 단독. 모델(10)/프로바이더(12)/리포지토리(7)/화면(10)/서비스(3)/위젯(4)로
내부에 feature-first 레이어드 구조를 갖춤. 다른 도메인은 아직 `screens/` + `services/` 구형 구조.

### 4.5 `lib/services/` — 서비스 계층 (57)
알림/알람, 음성(STT/TTS/GPT/파이프라인), 캘린더 동기화(Naver CalDAV/OpenAPI/ICS),
마이그레이션(채널/스마트준비 페이로드), 플랫폼(홈위젯/권한/백그라운드/배터리/업데이트/OAuth) 등.

### 4.6 `lib/shared/` — 공용 코드 (4)
`widgets/`, `utils/`, `constants/`, `extensions/` barrel 구조. `README.md` 규칙에 따라
feature 종속 코드 금지, core 인프라는 `lib/core/` 유지.

### 4.7 `lib/screens/` — UI 화면 (26)
auth/briefing/calendar/event/home/location/onboarding/settings/splash/voice 도메인 + shell/placeholder.

---

## 5. 의존성 목록

### 5.1 dependencies
| 패키지 | 버전 | 용도 |
| --- | --- | --- |
| flutter / flutter_localizations | sdk | 코어 |
| android_alarm_manager_plus | ^5.0.0 | 정확 알람 |
| app_links | ^7.0.0 | 딥링크 |
| crypto | ^3.0.6 | 해시 |
| flutter_local_notifications | ^21.0.0 | 로컬 알림 |
| flutter_riverpod | ^2.4.9 | 상태관리 |
| flutter_tts | ^3.8.5 | TTS |
| flutter_naver_map | ^1.4.4 | 네이버 지도 |
| google_maps_flutter | ^2.10.1 | 구글 지도 |
| firebase_core | ^3.6.0 | Firebase |
| firebase_crashlytics | ^4.1.3 | 크래시 리포트 |
| firebase_remote_config | ^5.1.0 | 원격 설정 |
| in_app_review | ^2.0.9 | 리뷰 유도 |
| in_app_update | ^4.2.3 | 인앱 업데이트 |
| package_info_plus | ^8.0.0 | 패키지 정보 |
| qr_flutter | ^4.1.0 | QR 코드 |
| flutter_secure_storage | ^9.2.4 | 보안 저장소 |
| go_router | ^13.2.0 | 라우팅 |
| google_sign_in | ^6.2.1 | 구글 로그인 |
| googleapis / googleapis_auth | ^12.0.0 / ^1.4.1 | Google Calendar API |
| home_widget | ^0.9.1 | 홈위젯 |
| http | ^1.2.0 | HTTP |
| intl | ^0.20.2 | 다국어/포맷 |
| speech_to_text | ^7.3.0 | STT |
| shared_preferences | ^2.3.3 | 로컬 저장소 |
| supabase_flutter | ^2.0.0 | 백엔드(BaaS) |
| timezone | ^0.11.0 | 타임존 |
| url_launcher | ^6.3.1 | 외부 앱 실행 |
| xml | ^6.5.0 | ICS/XML 파싱 |
| android_intent_plus | ^6.0.0 | Android 인텐트 |
| receive_sharing_intent | ^1.8.1 | 공유 수신 |
| file_picker | ^11.0.2 | 파일 선택 |
| ical_parser | ^1.2.0 | iCalendar 파싱 |

### 5.2 dev_dependencies
| 패키지 | 버전 | 용도 |
| --- | --- | --- |
| flutter_test | sdk | 테스트 |
| flutter_lints | ^5.0.0 | 린트 규칙 |
| flutter_local_notifications_platform_interface | ^11.0.0 | 알림 플랫폼 인터페이스 |
| shared_preferences_platform_interface | ^2.4.2 | 저장소 플랫폼 인터페이스 |

> `flutter pub outdated`: 81개 패키지가 제약 내 최신이 아님(주요 breaking: go_router 13→17,
> firebase_* 3→4/5→6, supabase_flutter 2.12→2.15, riverpod 2.6→3.3). 현재 버전 고정으로 안정 동작 중.

---

## 6. 관찰 및 권장사항

1. **정적 분석 통과** — `flutter analyze` 이슈 0건. 코드 품질 기준 양호.
2. **테스트 커버리지** — `test/`에 111개 테스트 파일. core/data/features(groups)/providers/screens/services
   전 영역에 테스트 존재. 신규 워크트리에서는 `flutter pub get` 후 `flutter test` 권장.
3. **아키텍처 혼재** — `features/groups/`만 feature-first 구조이고, 나머지 도메인(음성/캘린더/홈 등)은
   `screens/`+`services/` 평면 구조. 점진적 feature-first 마이그레이션 시 `shared/README.md` 규칙 준수 권장.
4. **신규 워크트리 가드** — 의존성 미설치 시 `uri_does_not_exist` 가짜 에러가 다수 발생하므로,
   CI/워크트리 부팅 시 항상 `flutter pub get`을 선행해야 한다(본 감사의 사전 확인 단계에서 재현됨).
5. **의존성 업그레이드 여지** — go_router/firebase/riverpod 등 대규모 breaking 업그레이드 가능하나,
   현재 제약 범위 내에서 안정 동작 중이므로 별도 일정에서 평가할 것.

---

## 7. 결론

- 코드베이스는 **181개 소스 파일 / ~88K 줄 / 111개 테스트** 규모이며,
  `main.dart` → `app.dart`(PlanFlowApp) → `core/router.dart`(appRouter) 진입 체계가 명확하다.
- `flutter pub get` 후 `flutter analyze`는 **이슈 0건, 컴파일 에러 없음**으로 빌드 가능 상태다.
- 핵심 모듈: `core/`(인프라), `providers/`(전역 상태), `data/`(모델/리포지토리),
  `features/groups/`(feature-first), `services/`(57개 비즈니스/플랫폼 서비스), `shared/`(공용).
