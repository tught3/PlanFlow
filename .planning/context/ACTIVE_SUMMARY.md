# ACTIVE SUMMARY

- generated_at: 2026-05-09T23:29:51.354Z
- latest_commit: c16b38a 2026-05-09 Add Naver CalDAV credential syncing
- snapshot_keep: 12

## Stable Context
### Project
- 거래를 직접 입력하지 않고도 자동으로 가계부를 채울 수 있어야 한다.
- 카드대금납부, 계좌간이체, 취소거래, 애매한 거래 같은 예외가 안정적으로 처리되어야 한다.
- 사용자는 거래내역, 계좌/카드, 통계 화면에서 실제 저장 결과를 신뢰할 수 있어야 한다.
- 디버깅 시 핵심 기능이 어떤 단계로 동작했는지 로그로 빠르게 추적할 수 있어야 한다.

### Engineering Rules
- 기능/로직 수정 후에는 연결 경로 전수 점검을 먼저 수행한다.
- 금융 파이프라인 수정 시 `npm run test:financial-regression`을 기준 검증으로 사용한다.
- 타입 안정성은 `npm run check`로 유지한다.
- 3개 이상 지시가 함께 오면 먼저 계획을 만든다.
- 가능한 경우 좁은 범위부터 수정하고 인접 영향만 점진적으로 넓힌다.
- 장시간 탐색은 피하고, 근거가 나오는 범위만 단계적으로 확장한다.

## Current State
- 2026-05-10: 반응형 레이아웃 공용 helper를 추가하고 shell/home/calendar/event/settings/voice 흐름을 폭 제한 중심으로 적응형화했다. 겉화면/잠금화면 알림 문구도 갱신했다. `dart analyze`, `flutter test`, `flutter build apk --debug`는 통과했고, `flutter build apk --release`는 release signing `storeFile` 누락으로 실패했다. 연결된 `adb` device는 없다.
- GSD 초기화가 없던 저장소에 2026-04-01 기준 기본 `.planning` 문맥을 생성했다.
- 메인 앱과 `lite-app` 모두 금융 파이프라인 구조 로그를 일부 도입한 상태다.
- `npm run check`와 `npm run test:financial-regression`은 최근 작업 기준 통과 상태다.
- 환경 제약 때문에 이 세션에서는 `npm run build`가 `vite/esbuild spawn EPERM`으로 막힐 수 있다.
- Phase 6으로 GSD 컨텍스트 위생 자동화를 추가해 장기 세션 품질 저하를 줄이는 작업을 시작했다.
- 사용자가 별도로 중지하지 않는 한 항상 GSD 우선 모드로 작업한다.
- 새 세션에서는 `.planning/STATE.md` 확인 후 `gsd-progress` 성격으로 현재 상태를 먼저 정리한다.
- 새 세션 시작 직후와 최종 완료 보고 직전에는 `node scripts/gsd-context-hygiene.mjs`를 자동 실행해 활성 요약을 갱신한다.
- **Firebase Advanced 재검증 완료 (2026-05-10):** OAuth 로그인 analytics를 callback/session sync 뒤로 이동했고, `schedule_parse_failed` fallback 기록과 `schedule_parsed` double-counting 분리, `briefing_enabled`/`max_voice_duration_seconds`/early bird 리모트 설정 실제 반영까지 완료. `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, `adb install`, `adb launch`, `adb pidof` 통과.
- 2026-05-10: Wave 1 Task 1C로 `lib/services/remote_config_service.dart` 신규 생성. 기본값 우선 적용과 네트워크 실패 무시를 포함한 안전한 Remote Config 래퍼를 추가했다.


- 2026-05-09~10: `CODEX_FIREBASE_SETUP.md` 기준으로 Firebase Step 1~5를 순서대로 진행했다. `pubspec.yaml`에 `firebase_core`, `firebase_crashlytics`, `firebase_analytics`를 추가했고, `android/settings.gradle.kts`와 `android/app/build.gradle.kts`에 Google Services/Crashlytics 플러그인을 연결했다. `lib/main.dart`에서 `Firebase.initializeApp()`과 Crashlytics 전역 오류 핸들러를 붙였고, `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, 실기기 설치/실행까지 통과했다. `flutter pub get`은 Windows symlink 지원 경고가 있었지만 이후 검증은 정상 통과했다.
- 2026-05-10: Supabase `calendar_sync_patch.sql` / `schema.sql`에서 `upsert_naver_caldav_credentials` 함수 생성보다 앞서 있던 `REVOKE/GRANT`를 함수 뒤로 이동시켜 SQL Editor의 `42883 function ... does not exist` 실패를 정리했다. 다음 적용 때는 함수 생성 후 권한 부여 순서로 실행된다.
- 2026-05-10: `CODEX_FIREBASE_ADVANCED.md` Wave 1를 진행해 `pubspec.yaml`에 `firebase_remote_config`와 `firebase_performance`를 추가하고, `lib/main.dart`에서 `RemoteConfigService.initialize()`를 Firebase 초기화 직후 호출하도록 연결했다. `lib/core/analytics_service.dart`와 `lib/services/remote_config_service.dart`를 추가했고, `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, 실기기 설치/실행까지 통과했다.
- 2026-05-10: `CODEX_FIREBASE_ADVANCED.md` Wave 2를 진행해 `lib/services/gpt_service.dart`의 GPT 모델을 Remote Config 기반으로 바꾸고, 음성 입력/일정 확인/로그인/설정 화면에 Analytics 이벤트와 브리핑 Remote Config 가드를 연결했다. Firebase 미초기화 테스트는 Analytics/Remote Config 헬퍼가 no-app 환경에서 기본값/무동작으로 돌아가도록 보정해서 해결했다. `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, 실기기 설치/실행까지 통과했다.
- 2026-05-10: `CODEX_FINAL_POLISH.md` Wave 1~2를 반영해 개인정보처리방침 HTML, 인앱 리뷰/업데이트 서비스, ProGuard 릴리즈 난독화, 리뷰/업데이트 연결, 앱 resume 업데이트 체크를 추가했다. Android JVM target 불일치는 `android/build.gradle.kts`에서 `in_app_review`는 11, `in_app_update`는 1.8로 예외 처리해 해소했고, `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, ADB install/launch/pidof까지 다시 통과했다.
- 2026-05-10: 공식 이메일을 `officialfluxstudio.kr@gmail.com`으로 통일했다. `docs/privacy-policy.html`과 `docs/privacy-policy.md`, 그리고 final polish 기록의 문의/Play Store 안내를 같은 공식 연락처로 갱신했다.
- 2026-05-10: `CODEX_ONBOARDING_CRO.md`를 반영해 온보딩 AppBar/IntroCard/선택 사항 배지/완료 후 이동 경로를 정리하고, 홈 empty state CTA와 FAB pulse 강조를 추가했다. `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, ADB install/launch/pidof까지 통과했다.
- 2026-05-10: 스마트 업데이트 로직을 `lib/services/remote_config_service.dart`와 `lib/services/update_service.dart`에 반영했다. `min_required_version` 기본값, `getInt` 헬퍼, `package_info_plus` 기반 versionCode 비교, 디버그 조기 반환, 10초 타임아웃, immediate/flexible 분기, 실패 debugPrint 처리를 추가했고 `flutter analyze`는 통과했다. `flutter build apk --debug`는 이 환경에서 시간 초과로 끝났다.
- 2026-05-10: `CODEX_SMART_UPDATE_SETUP.md`와 `CODEX_RELEASE.md` 기준으로 릴리스 메타데이터를 정리했다. `pubspec.yaml` 버전을 `1.1.0+2`로 올리고 `docs/whats-new-1.1.0.md`를 추가했으며, `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, ADB install/launch/pidof까지 통과했다.

## 2026-05-10 Responsive Layout Checkpoint
- 공용 반응형 helper를 추가하고 shell/home/calendar/event/settings/voice 흐름을 폭 제한 중심으로 적응형화했다.
- 겉화면/잠금화면 알림 안내 문구를 갱신했다.
- `dart analyze`, `flutter test`, `flutter build apk --debug`는 통과했고, `flutter build apk --release`는 release signing `storeFile` 누락으로 실패했다.

## Roadmap Focus
- Phase 5: 데이터 정합성 정리
- Phase 6: GSD 컨텍스트 위생 자동화
- Phase 7: 통계 제외 + 자동 학습 기능

## Active Phase Detail
- active_phase: 07-stats-exclusion-learning
- active_phase_title: stats exclusion learning

### Phase Context
- 활성 phase CONTEXT.md를 찾지 못했다.

### Phase Plan
- 활성 phase PLAN.md를 찾지 못했다.

## Recent Issue Notes
- 2026-04-19-self-transfer-misread-as-salary
- 2026-04-19-raw-archive-upload-and-corrected-fields-gap
- 2026-04-19-hana-autopay-liivm-merchant-fix
- 2026-04-18-naver-membership-card-cancel-bridge
- 2026-04-18-ibk-bc-card-unification-and-food-category

## Dirty Worktree Surface
- .planning: 25개
- server: 3개
- planning: 1개
- android: 1개
- client: 1개
- "FinFlow_NLS_Migration_Codex (1).md": 1개
- "FinFlow_: 1개
- scripts: 1개

## Changed Files Sample
- M .planning/context/ACTIVE_SUMMARY.md
-  M .planning/context/MANIFEST.json
-  D .planning/context/snapshots/2026-05-06T00-54-44Z.md
-  D .planning/context/snapshots/2026-05-06T00-58-16Z.md
-  D .planning/context/snapshots/2026-05-06T01-10-01Z.md
-  D .planning/context/snapshots/2026-05-06T01-23-58Z.md
-  D .planning/context/snapshots/2026-05-06T01-38-34Z.md
-  D .planning/context/snapshots/2026-05-06T01-43-35Z.md
-  D .planning/context/snapshots/2026-05-06T01-48-16Z.md
-  D .planning/context/snapshots/2026-05-06T03-26-34Z.md
-  D .planning/context/snapshots/2026-05-06T03-27-44Z.md
-  D .planning/context/snapshots/2026-05-06T03-37-06Z.md
-  D .planning/context/snapshots/2026-05-06T03-52-26Z.md
-  D .planning/context/snapshots/2026-05-06T03-53-43Z.md
-  M android/app/capacitor.build.gradle
-  M client/src/pages/login.tsx
-  M server/routes.ts
- ?? .planning/context/snapshots/2026-05-09T12-48-28Z.md
- ?? .planning/context/snapshots/2026-05-09T12-48-29Z.md
- ?? .planning/context/snapshots/2026-05-09T13-00-43Z.md

## Next Session Start
- `.planning/STATE.md`를 먼저 읽는다.
- `.planning/context/ACTIVE_SUMMARY.md`로 안정 문맥을 빠르게 복구한다.
- 현재 작업이 phase면 해당 `.planning/phases/*` 문서를 읽고 시작한다.
- 금융거래감지 수정이면 이슈 기록, 전수 점검, 회귀 테스트 순서를 유지한다.

## Safe To Drop From Prompt
- 오래된 장문 탐색 로그
- 이미 문서에 승격된 의사결정의 반복 설명
- 오래된 자동 생성 스냅샷 세부 내용

## 2026-05-10 Responsive Layout Checkpoint
- 공용 반응형 helper를 추가하고 shell/home/calendar/event/settings/voice 흐름을 폭 제한 중심으로 적응형화했다.
- 겉화면/잠금화면 알림 안내 문구를 갱신했다.
- `dart analyze`, `flutter test`, `flutter build apk --debug`는 통과했고, `flutter build apk --release`는 release signing `storeFile` 누락으로 실패했다.

## 2026-05-10 Dart Define Env Checkpoint
- 앱 런타임과 백그라운드 isolate의 `.env`/`flutter_dotenv` 의존을 제거하고 `String.fromEnvironment` 기반 `--dart-define` 주입으로 통일했다.
- Supabase URL/anon key 안내 문구와 문서를 빌드 설정값 기준으로 갱신했고, `env/local.example.json` 예시를 추가했다.
- `NAVER_MAP_CLIENT_SECRET`, OpenAI 원본 키, provider secret은 앱 define/APK asset에 넣지 않도록 AppEnv와 문서 경로를 정리했다.
- `dart analyze`, `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build apk --debug --no-pub`, define 포함 debug build를 통과했다. `flutter build apk --release --no-pub`는 기존 release signing `storeFile` 누락으로 실패했다.
- ADB 실기기 설치/실행은 변경 중 한 차례 통과했고, 마지막 재설치 시점에는 Wi-Fi ADB가 `device offline`으로 떨어져 추가 설치 확인을 보류했다.

## 2026-05-10 Onboarding Compact Checkpoint
- Permission onboarding copy and spacing were tightened so the top explanation is shorter, prep-time chips are shorter, the microphone hint is one line, and the bottom app settings button was removed.
- The main request-all-permissions action is pinned to the bottom bar and is visible on compact heights without scrolling.
- Verification passed: `dart analyze`, `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build apk --debug --no-pub`, APK install, and launcher PID check on `com.planflow.app`.

## 2026-05-10 VS Code Define Auto-Run Checkpoint
- Added `.vscode/launch.json` and `.vscode/settings.json` so Flutter Run/Debug in VS Code automatically passes `--dart-define-from-file=env/local.json`.
- Created local `env/local.json` from the existing `.env` values in the workspace; the file stays ignored by git.
- Updated the env setup doc to explain that Run/Debug now follows the local define file automatically.

## 2026-05-10 Flutter Local Wrapper Checkpoint
- Added `scripts/flutter-local.ps1` so command-line Flutter run/build/test invocations can automatically inject `--dart-define-from-file=env/local.json`.
- Verified the wrapper with `./scripts/flutter-local.ps1 test --no-pub test/screens/permission_onboarding_screen_test.dart`.
- Updated the env setup doc to point command-line runs at the wrapper.

## 2026-05-10 AGENTS Auto-Run Checkpoint
- Updated `AGENTS.md` so Flutter run/build/test commands in this repo should prefer `scripts/flutter-local.ps1` and automatically inject `env/local.json` defines.

## 2026-05-10 Flutter Local Wrapper Fix Checkpoint
- Fixed `scripts/flutter-local.ps1` so it injects local defines as individual `--dart-define=KEY=VALUE` flags, with `build apk` argument order handled correctly.
- Verified `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell pidof com.planflow.app`.

## 2026-05-10 Onboarding Balance Checkpoint
- Slightly expanded the onboarding spacing again so the bottom request button stays fixed while the cards and permission rows fill more of the available height.
- Widened the permission descriptions on the longer rows to allow more natural wrapping on compact screens.
- Verified with `./scripts/flutter-local.ps1 test --no-pub test/screens/permission_onboarding_screen_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell pidof com.planflow.app`.

## 2026-05-10 Login Naver Visibility Checkpoint
- Restored the Naver social login entry on `lib/screens/auth/login_screen.dart` and moved the social login block above the email form in login mode so it appears earlier on compact screens.
- Kept the Google/Kakao/Naver buttons together and slightly reduced login-screen vertical spacing so the Naver action is easier to reach without scrolling.
- Verified with `./scripts/flutter-local.ps1 test --no-pub test/screens/login_screen_test.dart`, `flutter analyze --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` plus `adb shell pidof com.planflow.app`.

## 2026-05-10 Exact Alarm Onboarding Checkpoint
- Split the exact alarm permission out into its own onboarding request step so the request-all flow now explicitly requests it instead of relying on the notification bundle alone.
- Added a direct exact-alarm request path in `AppPermissionService` / `NotificationService`, and wired the exact-alarm tile to that dedicated request.
- Added a regression test that proves request-all flips the exact-alarm tile to the checked state.
- Verified with `./scripts/flutter-local.ps1 test --no-pub test/screens/permission_onboarding_screen_test.dart`, `flutter analyze --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` plus `adb shell pidof com.planflow.app`.

## 2026-05-10 Full Flutter Test Stability Checkpoint
- Fixed full `flutter test --no-pub` failures caused by local dart-define map/proxy settings leaking into map and location service tests.
- Added an in-app map availability override to `LocationPickerScreen` for deterministic fallback UI tests.
- Updated map/location service tests to explicitly disable providers/proxy paths outside the scenario under test.
- Verified with `flutter analyze --no-pub`, `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` plus `adb shell pidof com.planflow.app`.

## 2026-05-10 Login And Voice Compact UI Checkpoint
- Moved the Google/Kakao/Naver social login card below the email login card on the login screen.
- Shortened the voice input guide above the raw text field and tightened vertical spacing to reduce compact-screen scrolling.
- Made the lower voice action buttons use compact labels while listening and scale text down to stay on one line when the close button appears.
- Verified with related screen tests, `flutter analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` plus `adb shell pidof com.planflow.app`.

## 2026-05-10 Voice Bottom Controls And ADB Package Safety Checkpoint
- Moved the voice action row (`전체삭제`, `마지막삭제`, `직접입력`, and the listening close button) out of the scroll body and pinned it above the bottom navigation bar.
- Restored a little more voice guide content while keeping the compact screen flow stable.
- Added an AGENTS safety rule that destructive ADB package commands in this repo must target only `com.planflow.app` and must not touch FinFlow or other app packages.
- ADB event logs showed `com.aiexpense.tracker` and `com.planflow.app` were both fully removed around 2026-05-10 21:05 by shell-driven package operations, confirming the disappearance was external ADB package removal rather than app code.
- Verified with `flutter analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` plus `adb shell pidof com.planflow.app`.

## 2026-05-10 Voice Fixed Stack Checkpoint
- Reordered the voice input screen into a fixed non-scroll stack: command guide, listening guide, transcript input, primary voice button, action row, status banner, and bottom navigation.
- Made only the `이렇게 말해보세요` guide expand to fill remaining space, with scale-down protection for very short test heights.
- Moved the voice status banner into the bottom controls below the action row and above the navigation bar.
- Verified with `flutter analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` plus `adb shell pidof com.planflow.app`.

## 2026-05-10 Voice Guide Content Fill Checkpoint
- Filled the expanded `이렇게 말해보세요` voice guide with richer examples again instead of leaving the enlarged guide card visually empty.
- Kept the fixed non-scroll voice layout, while using a compact two-line guide only on very short heights to prevent overflow.
- Verified with `flutter analyze --no-pub`, `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_input_screen_test.dart`, full `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` plus `adb shell pidof com.planflow.app`.

## 2026-05-10 Settings Calendar Sync Cleanup Checkpoint
- Removed the Settings tab's calendar auto-sync status summary card so only the actual Google/Naver/device calendar action rows and right-side status check icons remain visible.
- Hardened Google OAuth env handling so an explicit non-placeholder `GOOGLE_SERVER_CLIENT_ID` can override the web client fallback, and documented the current debug SHA values for Google Cloud OAuth setup.
- ADB logcat confirmed the current Google Calendar failure is `PlatformException(sign_in_failed, ApiException: 10)`, which points to Google Cloud OAuth package/SHA/client setup rather than a Flutter flow crash.
- Verified with `flutter analyze --no-pub`, `./scripts/flutter-local.ps1 test --no-pub test/screens/settings_screen_test.dart`, `./scripts/flutter-local.ps1 test --no-pub test/services/calendar_sync_service_test.dart`, full `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell pidof com.planflow.app` plus resumed activity check.

## 2026-05-10 Event Edit Date Time Picker Checkpoint
- Replaced the event edit screen's sequential date picker then time picker flow with a single bottom sheet that shows the calendar and time controls together.
- Added hour/minute dropdowns and quick 10/30 minute adjustment chips so start/end times can be changed without reopening a second dialog.
- Verified with `flutter analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell pidof com.planflow.app`.

## 2026-05-10 Google Auto Sync Reauth Preservation Checkpoint
- Fixed Google Calendar automatic sync so a non-interactive silent token miss no longer overwrites an existing connected calendar connection with `reauthRequired`.
- Kept manual Google Calendar sync behavior strict: when the user taps sync and token/consent is missing, the app can still ask for reauthentication.
- Added a regression test that proves non-interactive Google sync preserves the connected state when the access token is unavailable.
- Verified with `flutter analyze --no-pub`, `./scripts/flutter-local.ps1 test --no-pub test/services/calendar_sync_service_test.dart`, full `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell pidof com.planflow.app` plus resumed activity check.

## 2026-05-11 Region Timezone And Settings Cleanup Checkpoint
- Removed the Settings calendar-sync subtitle and normalized the calendar-to-backup section spacing.
- Added a compact country/time setting with Korea as default and v1 region presets for Korea, US, Japan, UK, Germany, France, and Australia.
- Centralized event wall-time conversion so event edit and voice-confirm saves write UTC instants, while display/pickers use the selected app region; `EventModel` now serializes event timestamps as UTC.
- Added Supabase schema fields for region settings and a legacy settings fallback so existing remote schemas keep working until the new columns are applied.
- Verified with `dart analyze`, `flutter analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub`, and `./scripts/flutter-local.ps1 build apk --debug --no-pub`. `flutter build apk --release --no-pub` still fails on the known missing release signing `storeFile`. ADB install was blocked because the Wi-Fi device went offline/timeouts after the build.

## 2026-05-11 Voice Confirm Map Timezone Cleanup Checkpoint
- Fixed voice add flow so manually edited transcript text enters ConfirmScreen as confirmed user text and no longer triggers GPT re-parse overwrite.
- Added ConfirmScreen dirty-field guards so GPT hydration cannot replace user-edited title, location, memo, start time, or end time.
- Changed location lookup so the map picker opens even with an empty location, and search/auth/timeout failures now land on the picker with fallback guidance instead of leaving an empty body.
- Removed the visible single/all-day/multi-day segmented control from ConfirmScreen; multi-day is now derived from Korean local start/end dates at save time while internal all-day compatibility remains.
- Changed recurrence and reminder UI to one current-value button each, with bottom-sheet choices for repeat frequency and notification timing.
- Shortened the strong alarm explanation to clarify exact alarm/vibration/full-screen attempts while noting Android cannot guarantee DND or silent-mode bypass.
- Added regression tests for empty-location map opening, manual text hydration protection, and KST wall-time UTC roundtrip/multi-day calculation.
- Verification passed: `flutter analyze --no-pub`, full `flutter test --no-pub`, focused post-format screen/widget tests, and `flutter build apk --debug --no-pub`. ADB install/launch could not run because `adb devices` returned no connected device.
- Follow-up ADB verification passed after the device reconnected at `192.168.0.9:5555`: `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk` timed out at the shell level but the app package was installed, `adb shell am start -n com.planflow.app/.MainActivity` launched the app, and `adb shell pidof com.planflow.app` returned PID `29385`.

## 2026-05-11 Naver-Style Event Editor Checkpoint
- Added a shared Naver Calendar-style event editor with title/calendar header, all-day toggle, two-column start/end summaries, inline year/month/day/AM-PM/hour/minute wheels, today shortcut, timezone row, category, recurrence, location, description, reminder, and strong-alarm controls.
- Wired the shared editor into both ConfirmScreen and EventEditScreen so new schedule confirmation and existing event editing use the same inline date/time flow.
- Removed EventEditScreen's visible single/all-day/multi-day segmented control; multi-day is now derived from start/end local dates on save. EventEdit map picking now opens even when the location field is empty.
- Kept ConfirmScreen's manual text protection and smart prep/supplies flow while moving them into the new editor frame.
- Added regression coverage for hidden-by-default inline wheels, start wheel activation, all-day time-column hiding, and EventEditScreen's new editor shape.
- Verification passed: `flutter analyze --no-pub`, full `flutter test --no-pub` (215 tests), `flutter build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `24308`.

## 2026-05-11 Built-In Supabase Client Config Checkpoint
- Moved the PlanFlow Supabase public client URL and anon key into `AppEnv` fallback defaults so raw Flutter builds no longer lose login/DB setup when `env/local.json` or dart-defines are omitted.
- Kept compile-time `--dart-define` values as explicit overrides for one-off environments, while documenting that Supabase public config is built in and external provider values still use dart-defines.
- Added a regression test proving `AppEnv.hasValidSupabaseConfig` remains true without local defines.
- Verification passed: `flutter analyze --no-pub lib/core/env.dart test/core/app_env_test.dart`, `flutter test --no-pub test/core/app_env_test.dart`, full `flutter analyze --no-pub`, full `flutter test --no-pub` (216 tests), raw `flutter build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `30348`.

## 2026-05-11 Voice Recognition And Edit Intent Checkpoint
- Hardened STT transcript cleanup so adjacent repeated phrases such as a full sentence recognized twice collapse before routing or saving.
- Expanded local Korean time inference to understand common spoken time forms such as `열두시반`, `오후 두시 반`, `저녁 일곱시 삼십분`, and numeric `12시 반`; the GPT parsing prompt now names these forms explicitly.
- Broadened voice edit intent routing so schedule-change phrases like `미뤄줘`, `옮겨줘`, `앞당겨줘`, `늦춰줘`, and time/place-change wording go to the voice schedule management/edit flow instead of the add confirmation flow.
- Clarified current edit architecture during investigation: voice input detects edit intent, `VoiceActionScreen` loads candidate events, and selecting a candidate opens `EventEditScreen`.
- Verification passed: `flutter analyze --no-pub`, focused `flutter test --no-pub test/services/stt_service_test.dart test/services/gpt_service_test.dart test/screens/voice_input_screen_test.dart`, full `flutter test --no-pub` (219 tests), `flutter build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `11910`.

## 2026-05-11 Voice Edit Candidate Recovery Checkpoint
- Normalized common Korean STT phrase errors before voice management and GPT fallback parsing, including `강릉에서 아산에서` -> `강릉아산에서`.
- Hardened voice edit/delete candidate ranking so new target date/time phrases such as `이번주 목요일 오전9시로 변경` are removed from the search text, Korean particles are stripped, and tokens like `전달일정` also match saved titles containing `전달`.
- Voice management now shows and logs the normalized command text, so the user reviews the corrected wording before opening candidates or sending an add confirmation.
- Added regression coverage for the user's example phrase finding `강릉아산 아이스크림 전달` ahead of unrelated date/time matches.
- Verification passed: `flutter analyze --no-pub`, focused `flutter test --no-pub test/screens/voice_action_screen_test.dart`, focused `flutter test --no-pub test/services/stt_service_test.dart test/services/gpt_service_test.dart`, full `flutter test --no-pub` (220 tests), `flutter build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `17882`.

## 2026-05-11 Voice Text AI Cleanup Generalization Checkpoint
- Removed the previous one-off Korean STT phrase replacement and added a shared `VoiceTextCleanupService` for basic cleanup, candidate-aware particle repair, and AI escalation detection.
- Added `GptService.cleanupVoiceText()` so suspicious recognized schedule commands can be cleaned through the OpenAI proxy with conservative JSON output, confidence gating, and candidate event context for edit/delete/query flows.
- Wired voice input and voice schedule management to use the cleaned command text for routing, schedule confirmation, and target event ranking while preserving manually edited transcript text.
- Updated regression tests to prove local cleanup is generic, natural route expressions stay unchanged, high-confidence AI cleanup is accepted, low-confidence cleanup is ignored, and voice edit candidates rank correctly without hardcoded place names.
- Verification passed: `flutter analyze --no-pub`, focused voice/GPT/STT cleanup tests, full `./scripts/flutter-local.ps1 test --no-pub` (225 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `16345`.

## 2026-05-12 Calendar Connection Persistence Checkpoint
- Changed app startup/resume calendar sync from Google-only `GoogleCalendarAutoSyncService` to the unified `CalendarAutoSyncService`, so Google, Naver API, Naver CalDAV, and device calendar sync share the same lifecycle entry point.
- Updated the composite Naver CalDAV credential store to refresh the local secure cache whenever Supabase returns remote credentials, improving update/restart recovery after local cache loss.
- Added regression coverage proving lifecycle auto sync imports Naver CalDAV when credentials exist and remote CalDAV credentials are copied back into the local cache.
- Verification passed: raw `flutter analyze --no-pub` (wrapper analyze still passes `--dart-define` incorrectly), focused calendar credential/auto-sync tests, full `./scripts/flutter-local.ps1 test --no-pub` (226 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `21386`.
