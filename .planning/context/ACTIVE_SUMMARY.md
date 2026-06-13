# ACTIVE SUMMARY
## 2026-06-13 V2 E2E QA checklist draft
- Added docs/planflow-v2/18-v2-e2e-qa-checklist.md to consolidate V2 end-to-end QA coverage across personal flow, group flow, DB/RLS/RPC, and main-merge risks.
- The checklist marks merge blockers as real DB/RLS validation, atomic RPC verification, and manual overlay/context refresh checks rather than further code changes.
- Verification in this turn: git fetch origin, git merge origin/main (Already up to date.), flutter analyze --no-pub before docs write, and flutter test --no-pub remains passing from the current branch state.

## 2026-06-13 Play versionCode 23 collision recovery
- Play Console에서 `versionCode=23`이 이미 사용되었다는 오류가 나서 `pubspec.yaml` 버전을 `1.1.0+24`로 올려 재시도했다.
- release AAB는 이미 재생성된 상태였고, `android/gradlew.bat :app:publishReleaseBundle --track alpha --artifact-dir ..\build\app\outputs\bundle\release -PplanflowPlayServiceAccountJson=E:\FluxStudio\secrets\planflow-495007-dbe93d413189.json` 실행이 `BUILD SUCCESSFUL`로 끝나 Play 전송 단계가 완료되었다.
- 남은 확인은 Play Console에서 새 릴리스를 열어 `versionCode=24` 반영과 테스터 배포 상태를 보는 것이다.

## 2026-06-11 PlanFlow V2 group_backups implementation
- Added `public.group_backups` and its RLS/helper layer to `supabase/schema.sql`, including archive backup creation, restore marking, and a convenience archive-with-backup flow.
- Added `GroupBackupModel`, `GroupBackupRepository`, and a focused group backup model regression test under `test/features/groups/`.
- Verification: `flutter analyze --no-pub`, `flutter test test/features/groups/group_backup_model_test.dart --no-pub`, `flutter test --no-pub`, and `git diff --check` all passed.

## 2026-06-11 PlanFlow V2 group_events implementation
- Added `public.has_group_delegated_permission` and the `public.group_events` table/RLS slice to `supabase/schema.sql` for the V2 team-event layer.
- Added `GroupEventModel` and `GroupEventRepository` under `lib/features/groups/` to match the new group event schema.
- Verification: `flutter analyze --no-pub` passed; full `flutter test --no-pub` still hits unrelated existing plugin/initialization failures in manual-event and settings-related tests.

## 2026-06-07 PlanFlow v2 planning docs
- Created `docs/planflow-v2/README.md` and `docs/planflow-v2/team-v2-plan.md` on branch `feature/team-v2-planning` to keep team-function planning separate from the 1st-release stabilization line.
- The new docs keep the personal MVP structure intact and outline a separate team-module direction for `teams`, `team_members`, `team_invites`, `team_events`, `projects`, `tasks`, `meeting_notes`, and `coaching_reports`.

## 2026-06-11 PlanFlow deploy-by-default rule confirmed
- `AGENTS.md`에 Flutter/Android 코드 변경 후 별도 금지 문구가 없으면 `analyze -> tests -> versionCode bump -> Play internal upload -> Telegram`까지 자동으로 이어가도록 규칙을 반영했다.
- 예외는 `배포하지 마`, `SkipUpload`, `코드만 수정`으로 정리했고, 최종 보고 형식도 `[PlanFlow 배포 완료]` 블록으로 통일하도록 적었다.

## 2026-06-11 PlanFlow deploy failure alert quality follow-up
- `scripts/build-internal-aab.ps1`에서 analyze/build 로그를 `.deploy-logs\`에 저장하도록 바꾸고, analyze는 실제 analyzer issue 라인, build는 `FAILURE:`/`What went wrong`/`Execution failed` 같은 실제 실패 문맥만 추려서 던지게 보강했다.
- `scripts/deploy-play-internal.ps1`는 analyze/build 실패 시 Telegram과 콘솔에 로그 경로, 실제 issue 라인, 그리고 필요 시 짧은 excerpt를 함께 보여주도록 개선했다.
- `deploy-play.bat planflow -SkipUpload` 재검증이 성공했고, 버전은 `1.1.0+16`으로 증가했다. analyze는 재확인 시 `No issues found!`로 통과했고, build 로그는 `.deploy-logs\build-*.log`, analyze 로그는 `.deploy-logs\analyze-*.log`로 남았다.

## 2026-06-11 PlanFlow deploy logging and Play upload follow-up
- `scripts/build-internal-aab.ps1`에 analyze 로그 파일과 오류 excerpt를 남기는 경로를 추가해, 실패 시 `build/logs/analyze-*.log`와 실제 오류 줄이 콘솔과 Telegram에 함께 보이도록 보강했다.
- `scripts/deploy-play-internal.ps1`는 analyze 실패 시 로그 경로와 excerpt를 읽어 Telegram 실패 메시지에 넣고, `bump-version-code.ps1`의 `NewVersion` 반환값이 없어도 `pubspec.yaml` 버전을 fallback으로 읽도록 안전하게 처리했다.
- `flutter_local_notifications_platform_interface`를 dev dependency로 추가해 `test/screens/shell_swipe_gesture_test.dart`의 analyzer 경고를 해소했다.
- 검증: `scripts/flutter-local.ps1 analyze --no-pub` 통과, `E:\FluxStudio\tools\deploy-play.bat planflow` 실행 성공, `pubspec.yaml` 버전은 `1.1.0+15`로 증가했다. 실제 Play Console 반영/텔레그램 수신 여부는 이후 장치와 콘솔에서 추가 확인이 필요하다.

## 2026-06-11 TASK_20260608_030311 로그인 startup redirect 복구
- AuthProvider startup bootstrap과 Supabase 미준비 경로에서 `_hasAttemptedStartupSync`를 true로 표시해, 세션 복구 결과가 signedOut일 때 라우터가 로그인 redirect를 계속 막지 않도록 보정했다.
- `test/providers/auth_provider_test.dart`에 세션이 없는 startup recovery 이후 로그인 redirect가 가능해야 하는 회귀 테스트를 추가했다.
- 검증: `dart format lib/providers/auth_provider.dart test/providers/auth_provider_test.dart`, `dart analyze lib/providers/auth_provider.dart test/providers/auth_provider_test.dart`, `git diff --check` 통과. `scripts/flutter-local.ps1`와 FluxOS preflight/claim은 Python launcher/daemon 권한 문제로 실패했고, 원시 `flutter test/analyze`는 출력 없이 타임아웃되어 완료하지 못했다.

## 2026-06-11 PlanFlow deploy-by-default rule update
- `AGENTS.md`에 Flutter/Android 코드 수정 후 별도 금지 지시가 없으면 자동으로 배포 파이프라인을 이어서 수행하도록 규칙을 추가했다.
- 배포 파이프라인 순서(`flutter analyze` -> 관련 테스트 -> versionCode 증가 -> AAB 생성 -> Play internal 업로드 -> Telegram 알림 -> 결과 보고)와 예외 문구(`배포하지 마`, `코드만 수정해`, `검증만 해`, `SkipUpload`)를 명시했다.
- 최종 완료 보고 형식을 `[PlanFlow 배포 완료]` 블록으로 통일하도록 적었다.

## 2026-06-11 Telegram UTF-8 fix
- `scripts/deploy-play-internal.ps1`와 `scripts/send-telegram.ps1`를 UTF-8 BOM으로 다시 저장하고, Telegram 전송은 `HttpClient + UTF-8 StringContent`로 바꿔 Windows PowerShell 5.x/7.x에서 한글이 깨지지 않도록 수정했다.
- Telegram 전송 테스트를 실제로 한 번 보내서 helper가 `Ok=True`로 응답하는지 확인했다.

## 2026-06-11 PlanFlow deploy Telegram notification hookup
- `scripts/deploy-play-internal.ps1`에 성공/실패 Telegram 알림 후크를 추가하고, `scripts/build-internal-aab.ps1`는 단계 상태를 임시 파일로 남겨 실패 단계 식별이 가능하도록 보강했다.
- 새 공용 헬퍼 `scripts/send-telegram.ps1`를 추가해 `E:\FluxStudio\.env`의 `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`를 읽어 sendMessage를 보내게 했다.
- 파서는 세 파일 모두 통과했고, 아직 실제 Play 업로드/Telegram 발송은 실행하지 않았다.
## 2026-06-09 TASK_20260608_141130 브리핑 foreground 알림 억제
- 앱 lifecycle이 foreground/resumed일 때 브리핑 실행 알림과 예약 브리핑 시작 알림을 보내지 않도록 `BriefingSchedulerService`에 foreground suppress 경로를 추가했다.
- `PlanFlowApp`이 resume/pause/dispose 시 foreground 상태를 SharedPreferences에 기록해 Android alarm callback isolate에서도 같은 상태를 참조할 수 있게 했다.
- 회귀 테스트를 추가해 foreground 브리핑 실행은 TTS만 수행하고, foreground 시작 알림은 스케줄되지 않는지 확인하도록 했다.
- 검증: `dart format` 통과, `dart analyze lib/services/briefing_scheduler_service.dart lib/app.dart test/services/briefing_scheduler_service_test.dart` 통과, `git diff --check` 통과. `scripts/flutter-local.ps1 test/analyze`는 FluxOS session lock 권한 문제로 실패했고, 원시 `flutter test`는 출력 없는 타임아웃으로 완료하지 못했다.

## 2026-06-08 TASK_20260607_030411 리뷰 반영
- AI 일정 대화의 제목/이름 검색에서 `김태형 PM 일정 찾아줘` 같은 다중 토큰 검색이 OR 매칭으로 넓어지던 위험을 줄여, 제목/참석자/대상 필드 전체에 모든 검색 토큰이 있을 때만 매칭되도록 수정했다.
- `test/services/voice_conversation_controller_test.dart`에 이름만 맞는 일정과 직책만 맞는 일정이 섞이지 않는 회귀 테스트를 추가했다.
- 검증: `dart format` 통과, `dart analyze lib/services/voice_conversation_controller.dart test/services/voice_conversation_controller_test.dart` 통과, `git diff --check` 통과. `scripts/flutter-local.ps1 test`는 FluxOS lock 권한 문제, 원시 `flutter test`는 출력 없는 타임아웃으로 완료하지 못했다.

## 2026-06-07 TASK_20260607_030411 Widget And Voice Parsing Follow-up
- 주간 리스트 홈 위젯이 XML의 4번째 이벤트 슬롯을 실제 일정으로 채우도록 Kotlin raw/SharedPreferences 렌더 경로를 4행 기준으로 맞췄고, 5번째부터만 overflow 라벨이 나오도록 계산을 보정했다.
- AI 일정 대화는 `이 일정`/`이거`를 현재 focus 참조로 처리하고, 제목/참석자/대상 이름 검색을 오늘 기준 전후 1개월 범위에서 수행하도록 보강했다. 다중 후보에서는 첫 번째를 임의 선택하지 않고 번호 선택을 요구하며, 전후 1개월 밖에만 후보가 있으면 기간 확장 질문을 반환한다.
- 음성 일정 구조 파서는 `오늘부터 2주간 ...` 같은 상대 시작일+기간 표현을 all-day multi-day 범위로 해석하고 제목에서 해당 기간 표현을 제거한다. 월말 기준 1개월 검색/기간 계산은 대상 월 마지막 날로 clamp한다.
- 검증: `C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe format ...`, `C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe analyze <changed files>`, `C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe analyze`, `git diff --check` 통과. Flutter test/build는 이 세션의 SDK cache/FluxOS lock 권한 문제와 Gradle wrapper 네트워크 차단으로 실행하지 못했다.

## 2026-06-06 Internal Test AAB Automation
- Added `scripts/bump-version-code.ps1`, `scripts/build-internal-aab.ps1`, and root `deploy-planflow.bat` so one command can bump `pubspec.yaml` build number, run `flutter analyze`, run the focused smoke tests, build the release AAB, and print the upload path.
- Added a short internal-test automation note to `docs/play-console-submission.md`, and aligned the Play submission/listing docs to the current `1.1.0+5` internal build metadata after verification.
- Verification passed: `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\build-internal-aab.ps1`, which completed `analyze`, the six focused tests, and `build/app/outputs/bundle/release/app-release.aab` generation at `E:\FluxStudio\PlanFlow\build\app\outputs\bundle\release\app-release.aab`.

## 2026-05-31 STT Silence And Widget Offset Cleanup
- Conversation-mode STT silence is now 30 seconds in both the Flutter service layer and the Android fallback, so the listen loop no longer retriggers every couple of seconds during a spoken sentence.
- Home widgets now keep raw event payloads alongside the existing summarized payload, which lets the Kotlin providers render month/week/day widgets from the actual event list and move previous/next controls without a +/-1 clamp.
- The monthly widget date-number tap is the only deep-link target now; blank month-cell space no longer opens the app.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart test/screens/confirm_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, and install/launch on `192.168.0.102:36273`.

## 2026-05-29 Firebase Android Package Cleanup Follow-up
- Removed the stale `com.planflow.app` client entry from `android/app/google-services.json` so the Firebase Android config now matches the current `com.fluxstudio.planflow` package only.
- Re-verified the current location picker flow after the Naver-first preference change: focused `location_picker_screen_test.dart`, `flutter analyze`, debug APK build, and update/install/launch on `192.168.0.102:5555` all passed.

## 2026-05-29 Naver-First Map Preference Follow-up
- Location pick flow now prefers Naver when `NAVER_MAP_CLIENT_ID` is present, and the in-app map view falls back to Google only if Naver has not finished initializing or cannot be used.
- The location picker guidance remains on the candidate list when map tiles are unavailable, so users can still choose a place even if the current map provider fails.
- Verification passed: focused `test/screens/location_picker_screen_test.dart` and runtime config checks confirming `NAVER_MAP_CLIENT_ID` is present and Naver map initialization is wired in `main.dart`.

## 2026-05-28 Voice Title Preservation And Editor Cleanup
- Voice schedule parsing now preserves people/job-title phrases in titles, so inputs like `김태형pm한테 날짜 괜찮냐고 물어보기` keep the recipient in the saved title instead of moving/removing it through people fields.
- Confirm and edit screens no longer expose category/visit-goal choice UI for new schedules; recurrence stays as its own section, and critical alarm is separated from reminder options.
- Android all-day device calendar imports normalize holiday dates locally so `현충일` and `광복절` do not shift by one day, and Android 12+ launch splash now uses the PlanFlow-toned background/icon instead of a blank white launch frame.
- Verification passed: focused voice/GPT/analysis, device calendar, editor widget, event edit, and confirm screen tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-25 Email Verification UX And Account Deletion URL
- Email sign-up now records a pending email-confirmation callback state, so confirmation-link failures no longer fall through to the social OAuth consent-cancel message.
- Updated the sign-up success message to explain that already-registered emails may not receive another email and should use login or password reset.
- Added `docs/account-deletion.html` and recorded the Play Console account deletion / partial data deletion URLs in the submission draft.
- Verification passed: focused OAuth callback and login screen tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-25 Voice Input STT Exit And Korean Parsing Guard
- VoiceInputScreen now routes app-bar back, system back, and bottom-tab navigation through a single exit path that cancels active STT, clears transcript/session guards, and prevents late partial callbacks from leaking into the next voice entry.
- SttService now force-cleans stale native/speech sessions before new listens, uses a listen-generation guard for late callbacks, and can clear native state even when Android never sends a cancel callback.
- Korean voice parsing now preserves `경조사` instead of reducing it to `조사`, rejects time-only words such as `오전` as schedule locations, and normalizes AI-provided location fields through the same structured location guard.
- Verification passed: focused VoiceInput, STT, VoiceScheduleStructure, GPT, and VoiceCommandAnalysis tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-25 Release Risk Cleanup
- Bumped the internal-test build number to `1.1.0+3` so the next Play Console upload can avoid the already-installed `versionCode=2` collision risk.
- Fixed the `location_picker_screen_test.dart` harness timeout by fully faking location permission checks and letting `pickLocationFromQuery` disable in-app platform maps for widget tests without changing production defaults.
- Updated the Play Console submission draft to match the actual 1st-release scope, including Naver CalDAV wording, versionCode 3, and a note that KakaoTalk/SMS automatic detection is not included in this internal test.
- Changed the Settings backup restore button to the same light purple briefing-style color while keeping other Settings button color roles intact.
- Verification passed: location picker screen tests; full `scripts/flutter-local.ps1 test --no-pub` suite; focused settings screen tests after the restore-button color change; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; release AAB build without the previous Kotlin daemon crash log; debug APK build; update install/launch/PID check on `192.168.0.102:5555` with installed `versionCode=3`, `versionName=1.1.0`, `targetSdk=36`.

## 2026-05-25 Release Readiness Sweep And Location Diagnostics
- Treated placeholder `NAVER_MAP_PROXY_URL` values as unset so place lookup falls back to the direct Naver geocoding path and surfaces real auth failures instead of silently returning empty results.
- Passed the injected `AppPermissionService` from `ConfirmScreen` into the location picker flow, keeping tests and future callers from bypassing the configured permission path.
- Refreshed ConfirmScreen tests for the current collapsed editor UI and future-date fixtures.
- Verification passed: focused auth, voice, calendar sync, Naver CalDAV/ICS, device calendar, location lookup, travel time, side effect, notification, widget, backup, feedback, briefing, settings, confirm, event edit, calendar editor, home widget route tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; release AAB build; APK signature verification; update install/launch/PID check on `192.168.0.102:5555`.
- Note: `test/screens/location_picker_screen_test.dart` still times out before emitting test output in this environment and needs a separate harness-level cleanup pass; the confirm-screen picker path is covered with injected permissions.

## 2026-05-25 Muted Cobalt Voice CTA
- Lowered the shared tertiary/cobalt accent from `#1A4FD6` to a softer `#2D5CA8` with a matching faint tone, so all buttons using that accent are less glaring while staying in the PlanFlow blue family.
- Changed the Home empty-state voice CTA label from `새 일정 음성으로 추가하기` to `음성으로 새 일정 추가하기`.
- Verification passed: focused home, voice input, and settings tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-25 Voice Conversation Delete Session Isolation
- AI schedule conversation now trims repeated pending-delete request text from follow-up confirmations, so `5번 일정 삭제해 줘 응 삭제해줘` is handled and displayed as `응 삭제해줘` inside the conversation.
- Added a guarded exit sheet for AI conversation back navigation; leaving cancels STT, clears pending delete/session state, and returns an explicit `voiceConversationClosed` result to the parent voice input page.
- VoiceInputScreen now treats that explicit close result as a fresh idle state, clearing stale transcript/guards so confirmation phrases do not leak into the old delete flow.
- Verification passed: focused voice conversation and voice input tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and update install/launch/PID check on `192.168.0.102:5555`.

- generated_at: 2026-05-09T23:29:51.354Z
- latest_commit: c16b38a 2026-05-09 Add Naver CalDAV credential syncing
- snapshot_keep: 12

## 2026-05-25 Briefing Movement Context Guard
- Local briefing fallback no longer says `이동을 서둘러` for schedules that have no usable location; very tight no-location schedules now use a non-movement wording about checking the previous schedule's wrap-up time.
- GPT briefing prompts now explicitly say to include place/movement guidance only when event data contains a place and never invent location, departure, or movement advice without evidence.
- Verification passed: focused briefing scheduler tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-25 Voice Conversation Card Actions
- AI schedule conversation result cards are now tappable and open a PlanFlow-styled action sheet with edit/delete/close choices; delete requires a second confirmation and removed events are filtered from visible result cards.
- Replaced the old `계속 듣기` switch with a single voice control: hearing icon plus `듣는 중...` while active, a `정지` action, and a restart mic button plus stopped guidance when paused.
- Voice query routing now opens the conversation route with `autoStart=1` so schedule query results can continue into follow-up voice commands.
- Verification passed: focused voice conversation tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build. `192.168.0.102:5555` was offline/not reachable during install/run verification.

## 2026-05-24 Early Bird Storage Path Alignment
- Aligned PRO early-bird storage around `planflow.early_bird_emails` while keeping `public.submit_early_bird_email` as the app-facing RPC gateway.
- Applied the production DB patch: legacy `public.early_bird_emails` and `public.product_early_birds` PlanFlow rows were preserved/merged, direct anon/authenticated grants on `planflow.early_bird_emails` were revoked, and backup table lists now include both current and legacy early-bird tables.
- Updated local schema, backup SQL, docs, and repository comments so future checks look at the correct product schema without changing NexusFlow/shared tables.
- Verification passed: Supabase RPC/storage/grant/backup queries, focused early-bird repository and widget tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and update install/launch on `192.168.0.102:5555`.

## 2026-05-24 Apricot Accent And Voice STT Exit Cleanup
- Updated the third accent token to `#D08C60` and applied it to the Home empty-state `새 일정 음성으로 추가하기` button and the Voice Input `음성으로 다시 입력하기` button only.
- Hardened `VoiceInputScreen` disposal so active STT is cancelled on route exit, stale partial/final callbacks are ignored, and re-entering voice input starts a fresh listen session after manual edit or back navigation.
- Verification passed: focused voice input, home screen, and settings screen tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build. No ADB device was connected for install/run verification.

## 2026-05-24 Third Accent Color Exploration
- Added a new muted third accent color (`PlanFlowColors.tertiaryAccent`) and applied it to the Settings `중요 알림 소리 바꾸기` button so the UI has a non-blue, non-purple primary option.
- The current palette now keeps the existing navy/blue and lavender accents, while introducing a calmer sage/earth tone for a third button family.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/settings_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, and `dart format lib/core/theme.dart lib/screens/settings/settings_screen.dart`.

## 2026-05-24 Settings Tab Runtime Status Cleanup
- Removed the visible briefing reservation status card and smart departure alarm status card from Settings, while keeping the underlying briefing and alarm features intact.
- Switched the `중요 알림 소리 바꾸기` control to a filled primary-colored button to match the Morning Briefing accent style.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/settings_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and `scripts/flutter-local.ps1 build apk --debug`. No Android device was connected for an install/run check.

## 2026-05-24 Remove Critical Alarm Difference Test
- Removed the Settings test-only `일반/중요 알림 차이 테스트` button, explanatory text, and scheduling helper/state.
- Kept the actual normal/critical notification scheduling APIs, `critical_alarms_v5_distinct` channel, future critical alarm migration, and `중요 알림 소리 바꾸기` channel-settings entry intact.
- Verification passed: no remaining test-button references by `rg`, `scripts/flutter-local.ps1 test test/services/notification_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-23 Auth Persistence And Voice Date-Range Normalization
- Auth bootstrap now waits briefly for restored Supabase auth state, then attempts a session refresh before resolving startup; transient refresh errors keep the restored user instead of dropping directly to the login screen.
- Korean STT cleanup now removes unnatural repeated/overlapped tokens such as `경탁이 탁이한테`, `전화 전화해서`, and `확인 확인해줘` while preserving person names for targets/participants.
- Voice schedule parsing now gives local all-day date ranges priority over GPT output, so `5월 26일부터 6월 1일까지 원주집 임대` becomes title `원주집 임대` with a 5/26-6/1 all-day multi-day range.
- Verification passed: focused auth/STT/voice-structure/GPT/voice-analysis/Supabase-auth-option tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-23 Voice Input Append Sheet And Calendar Reload Guard
- Removed the separate `이어서 명령하기` voice-input button while keeping append dictation available through the main `음성으로 일정 입력하기` button when text already exists.
- Added a PlanFlow-styled sheet for existing transcript text with `이어서 말하기`, `지우고 다시 입력`, and `취소하고 현재 내용 유지`, preventing accidental text loss when restarting STT after manual typo edits.
- Hardened CalendarScreen refresh handling so refresh signals arriving during a load are queued, and suspiciously empty/single-event reloads preserve the previous in-memory list instead of making older schedules disappear.
- Verification passed: focused voice input and calendar screen tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/launch/PID check on `192.168.0.102:5555`. `test/screens/confirm_screen_test.dart` still has existing unrelated failures around older ConfirmScreen expectations.

## 2026-05-23 Voice FAB Highlight Refresh
- The shared `PlanFlowVoiceFab` now renders a persistent blue outline glow so the voice entry button reads more clearly on every screen where it appears.
- The pulse ring remains for active listening states, but the default idle state is now also visually emphasized instead of blending into the surrounding chrome.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, debug APK build, install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-22 Naver OAuth WebView Subresource Error Guard
- Naver OAuth WebView now treats only main-frame `WebResourceError` callbacks as fatal page-load failures.
- Subresource failures such as images, favicon, or auxiliary scripts are logged as `web_resource_ignored` and no longer replace the login page with the misleading `네이버 로그인 페이지를 불러오지 못했어요` error.
- The OAuth phase logger now records whether a resource error came from the main frame while still avoiding auth code, token, verifier, and session values.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/naver_oauth_webview_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-22 Naver OAuth WebView Phase Diagnostics
- Split Naver OAuth WebView startup into prepare, OAuth URL generation, and WebView load phases so the app can distinguish setup, URL, and page-load failures.
- Deferred the initial Naver OAuth load until after the first frame, after the WebView controller is configured and the platform view has started rendering.
- Added safe `Naver OAuth phase=...` debug logs with only phase, host, path, forceConsent, and error type; auth code, token, verifier, and session values are not logged.
- Updated user-facing Korean failures so WebView-internal failures stay on the WebView screen, while closing the WebView still returns a normal incomplete-auth result to the login screen.
- Verification passed: focused Naver OAuth WebView, auth service, and login screen tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Voice Conversation STT Feedback Fix
- VoiceConversationScreen now displays live STT partial text in the input field while listening and shows clear status text such as `듣고 있어요...`, instead of dropping partial results silently.
- STT success, silence/failure, event-load skip/failure, initial-text submission, and conversation action results now leave user-visible feedback and debug logs for troubleshooting.
- Initial query text no longer races with auto-start listening; auto-start only begins immediately when there is no initial text to submit first.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/voice_conversation_screen_test.dart --no-pub`, focused voice/input/route tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Voice STT Duplicate Transcript Guard
- VoiceInputScreen now treats voice input after a submitted command as a fresh command, so conversational follow-up text such as `3번째 일정 삭제` does not append to the previous query text.
- STT transcript merging now de-duplicates repeated incoming partial/final phrases before overlap merging, preventing repeated Android partial/final text from being appended two or three times.
- Voice query date parsing now gives explicit weekdays priority over week ranges, so `이번주금요일 일정 전부다 보여줘` queries only Friday instead of the whole Monday-Sunday week.
- Query voice input now opens the conversational voice route with the initial query text, keeping numbered result context available for follow-up commands.
- Manual transcript tap behavior remains preserved: tapping while listening stops STT, suppresses auto-submit, and opens keyboard editing.
- Verification passed: focused voice date/STT/input/action tests, `test/app_home_widget_route_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Voice Transcript Tap Keyboard Fix
- VoiceInputScreen now treats tapping the transcript field during active listening as an explicit manual-edit handoff: it stops the active STT listen, prevents the completed STT result from auto-submitting, and focuses the text field for keyboard correction.
- Added regression coverage proving that tapping the transcript while listening stops STT, keeps the recognized text in place, does not navigate to confirm, and opens the test keyboard.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/voice_input_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Unified Voice Location Edit Checkpoint
- Clear location-add voice commands such as `이번 주 금요일 6시에 있는 일정에 강릉 건도리 횟집 장소 추가` now route as existing-event edits, split target schedule text from the new location, and keep the new location out of candidate matching.
- VoiceInputScreen now hides the separate AI conversation choice, adds `계속 이어서 말하기`, and routes legacy voice launcher/conversation deep links into the unified auto-start voice screen.
- VoiceActionScreen now treats location-only voice edits as location edits, resolves map coordinates before opening edit, and asks before replacing an existing event location.
- Verification passed: focused pipeline/router/voice input/voice action/deeplink tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Kakao And Naver OAuth Login Fix
- Kakao OAuth now passes explicit profile-only scopes (`profile_nickname profile_image`) so the app no longer asks Kakao for the unconfigured `account_email` consent item that produced KOE205.
- Naver `naver-userinfo-proxy` now falls back to a stable PlanFlow-local email when Naver does not return an email, while marking `email_verified` only when the real Naver email exists; deployed to Supabase Edge Functions as version 5 with `verify_jwt=false`.
- OAuth callback errors now use provider-neutral Korean guidance instead of Naver-only messages for Kakao/Naver login failures.
- Verification passed: `scripts/flutter-local.ps1 test test/services/auth_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, Edge Function list/version check, and unauthenticated Edge Function 401 check. Device install to `192.168.0.102:5555` was blocked because ADB reported the device offline and reconnect timed out.

## 2026-05-21 Widget Weekend Toggle And Weekly List Refinement
- Weekly horizontal widget keeps compact hour-only labels, while the vertical weekly-list widget now uses full short times such as `09:00` and date-first labels like `5/18(월)`.
- Added a local Settings toggle under `홈 위젯 표시` to hide weekends in home widgets without changing Supabase schema; the setting is stored locally and mirrored into widget data as `widget_hide_weekends`.
- Widget providers use the weekend flag to hide Saturday/Sunday columns or rows in weekly/monthly widgets, and HomeWidgetService can build payloads with weekend events filtered out for refreshed widget data.
- Verification passed: `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart --no-pub`, Android resource/Kotlin compile, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Weekly Widget Time Compact And Vertical List Checkpoint
- Weekly home-widget event rows now render times as hour-only Korean labels such as `9시` and `15시`, while underlying event timestamps remain unchanged.
- Added a new `PlanFlowWeeklyListWidgetProvider` / `planflow_weekly_list_widget` that shows the week vertically by weekday/date with up to four schedule rows per day, using the same live weekly payload and calendar/event deep links.
- Verification passed: `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart --no-pub`, Android resource/Kotlin compile, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Location Coordinate Status And Overlap Dialog Checkpoint
- Event confirm/edit/detail surfaces now distinguish location text-only events from map-coordinate-resolved events with persistent `지도 위치 미지정` / `지도 위치 연결됨` status cards, and manual location text changes clear stale coordinates.
- Schedule overlap dialogs now list the conflicting event titles, times, and locations, with `중단` and `계속 저장` placed side-by-side in one row.
- Verification passed: focused calendar editor, event model, confirm overlap, and event edit tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build after Gradle daemon cache reset; install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Voice Save Background Follow-ups Checkpoint
- VoiceActionScreen direct save now awaits only the event update, then moves reminders, smart preparation, departure alarm preparation, calendar sync, home-widget refresh, and voice-log writes into background follow-up tasks.
- Voice delete and EventDetail delete now await only event deletion before navigation; cleanup, external preparation resync, widgets, and logs run afterward and each follow-up failure is isolated from the foreground save/delete result.
- Added a shared `BackgroundTaskService` guard and updated the voice action test double so focused save/delete tests do not execute real side effects.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/voice_action_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Background Follow-up Failure Feedback Checkpoint
- Added app-level scaffold messenger feedback so background follow-up failures can show user-visible snackbars even after the save screen navigates away.
- Background task failures now keep the foreground save/delete result intact while surfacing targeted Korean messages such as calendar sync, widget refresh, preparation alarm recalculation, voice log, or delete cleanup failure.
- Verification passed: `scripts/flutter-local.ps1 test test/services/background_task_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/screens/voice_action_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Weekly Widget Capacity And Deeplink Checkpoint
- Weekly widget payload and Android layout now show up to 4 events per day before falling back to `+N`, so empty vertical space is used for actual schedule rows first.
- Enlarged the top-right input chips across schedule widgets and ensured widget title/body surfaces deep-link to the calendar tab while the input chip still opens voice entry.
- Verification passed: `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-19 PlanFlow Release Bootstrap Checkpoint
- Added `scripts/planflow-release-bootstrap.ps1` as the single-command setup helper for new PCs. It auto-discovers the signing archive from OneDrive first, falls back to the repo-local signing backup, restores signing only when needed, builds the debug APK and release appbundle through `scripts/flutter-local.ps1`, verifies the PlanFlow release APK fingerprint, and optionally runs `scripts/adb-install-update.ps1` with `-AllowOneTimeTransition` for the rare old-debug-install case.
- Updated `docs/planflow-signing.md` to recommend the new bootstrap path and document the optional archive/password flags.
- The existing `scripts/restore-planflow-signing.ps1` and `scripts/adb-install-update.ps1` remain the lower-level helpers; the bootstrap script wraps them so the user does not have to repeat the manual sequence.
- Follow-up: `apksigner` Java stderr warnings are now captured without tripping PowerShell's global stop policy, while non-zero verifier exits still fail the bootstrap. Verified with `.\scripts\planflow-release-bootstrap.ps1 -SkipRestore -SkipBuild -SkipInstall`.

## 2026-05-20 Naver CalDAV Import Feedback Checkpoint
- 네이버 CalDAV 연결 성공 후 연결 테스트 성공 스낵바에서 멈춘 것처럼 보이던 흐름을 수정해, 성공 시 바로 `네이버 CalDAV 연결에 성공했습니다. 이제 일정을 가져옵니다.`를 안내하고 실제 `syncAll` 가져오기 진행창을 띄우도록 했습니다.
- 저장된 네이버 CalDAV 자격증명으로 동기화 버튼을 누르는 경우에도 `네이버 일정 가져오는 중` 진행창과 백그라운드 동기화 안내가 보이도록 연결했습니다.
- Supabase가 준비되지 않은 테스트/오프라인 환경에서 설정 화면의 관리자 피드백/백업 영역이 전역 `authProvider`를 먼저 초기화하지 않도록 방어했습니다.
- 검증: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, 앱 실행/PID 확인 통과. focused settings widget test는 기존 Supabase 미초기화 authProvider 접근 경로가 남아 있어 실패했습니다.


## 2026-05-20 Save Session Restore Checkpoint
- ConfirmScreen now refreshes the Supabase session before saving, falls back to `authProvider.userId` when available, and reports state/Postgrest failures with more specific Korean guidance instead of the old generic login/Supabase snackbar.
- EventEditScreen now uses the same session refresh pattern before write operations so edit saves do not fail just because the Supabase snapshot lagged behind the app auth state.
- Added a focused ConfirmScreen regression that proves a missing signed-in session surfaces the new login guidance message.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, focused `test/screens/confirm_screen_test.dart` login-guidance regression, and `test/screens/event_edit_screen_test.dart`. Full `scripts/flutter-local.ps1 build apk --debug --no-pub` still fails on existing Android compileSdk 36 vs `glance-appwidget`/`remote-creation-android` SDK 37 requirements, and no ADB device was connected for a run check.


## 2026-05-20 Android Build Unblock Checkpoint
- Pinned `androidx.glance:glance-appwidget` to `1.0.0` in the Android root Gradle configuration so `home_widget` no longer resolves the alpha Glance dependency that required compileSdk 37 / AGP 9.1.0.
- Re-ran `scripts/flutter-local.ps1 build apk --debug --no-pub` successfully, then installed the APK with `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk` and launched `com.planflow.app` with PID confirmation on the connected device `192.168.0.102:5555`.


## 2026-05-19 Post-save Background Follow-ups Checkpoint
- Voice confirm and event edit saves now return to the user immediately after the event row is written, while follow-up work such as pre_actions, reminders, departure alarms, location history, voice logs, external prep resync, calendar auto-sync, and home-widget refresh runs in the background.
- ConfirmScreen and EventEditScreen both keep the save path focused on the event payload first, so users do not sit through the slower side-effect chain before navigation.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb uninstall com.planflow.app`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app`.
- `test/screens/event_edit_screen_test.dart` passed; `test/screens/confirm_screen_test.dart` still has existing expectation failures around its smart-preparation card assertions and some test-environment initialization paths.

## 2026-05-19 Release Signing Unification Checkpoint
- Android debug builds now use the same `release` signing config as release builds so local APK installs and distribution candidates share the PlanFlow release certificate.
- Verified both `app-debug.apk` and `app-release.apk` are signed by `CN=PlanFlow` with SHA-256 `75ab45c88419d972f46f341fb29760ce7c14fc0ba91dba11936c02df0075361e`.
- The device had an older Android Debug signed install, so it could not be upgraded in place. After targeted cleanup of `com.planflow.app`, the release-signed debug APK installed successfully, a second `adb install -r` succeeded, and the app launched with PID/focused-window confirmation.
- Verification passed: `scripts/flutter-local.ps1 build apk --debug --no-pub`, certificate inspection with `apksigner`, `scripts/flutter-local.ps1 analyze --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, `adb shell pidof com.planflow.app`, and focused window check.

## 2026-05-19 Voice Schedule Structure Service Checkpoint
- `lib/services/voice_schedule_structure_service.dart`를 도입해 `gpt_service.dart`와 `voice_command_analysis_service.dart`에서 공통 제목/장소/메모/시간 힌트 정규화를 공유하도록 전환했습니다.
- 핵심 규칙으로 `오늘 4시에 팀장님 내일 오시는지 확인전화하기`에서 선두 시간 큐를 구조화에서 제거하고 제목은 `팀장님 내일 오시는지 확인전화하기`로 정리되도록 했고, 후행 상대일 표현(`내일`)은 제목에 유지했습니다.
- 음성 입력 안내 첫 예시를 같은 문맥 분리 패턴으로 교체했고 compact 안내는 기존 2줄 구조를 유지했습니다.
- 앱 startup/resume 양쪽에서 업데이트 체크를 수행하고, `last_seen_version_code` 기반 post-update hook으로 알림 채널 재초기화와 Naver ICS 리마인더 재예약을 idempotent하게 실행하도록 했습니다.
- 강제 업데이트는 in-app update 상태가 unavailable/unknown이거나 체크 예외가 발생해도 Play Store fallback으로 이어지며, startup/resume 중복 호출은 service 내부 in-flight lock으로 합쳐집니다.
- 동일 규칙을 보존하는 회귀를 `test/services/gpt_service_test.dart`, `test/services/voice_command_analysis_service_test.dart`, `test/services/voice_schedule_structure_service_test.dart`, `test/services/update_service_test.dart`, `test/screens/voice_input_screen_test.dart`에 추가/갱신했습니다.
- 검증: focused voice/update/UI tests, reviewer 지적 2건 수정 후 재검증, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, PID/focused window 확인 통과.

## 2026-05-19 Calendar Silent Refresh Checkpoint
- CalendarScreen now keeps the last rendered calendar content visible during refresh, no longer shows the `캘린더 확인 중` loading panel, and uses the app bar refresh button only as a silent trigger.
- Only terminal states remain visible on the calendar tab: Supabase missing, signed out, or a real load error. Refreshes now preserve the previous event list instead of clearing the screen.
- Added a focused calendar screen test that asserts the loading panel does not appear while the tab initializes.
- Verification passed: `dart analyze lib/screens/calendar/calendar_screen.dart test/screens/calendar_screen_test.dart test/screens/calendar_marker_test.dart test/screens/calendar_day_events_sheet_test.dart`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app`.

## 2026-05-19 Startup Login Flash Fix Checkpoint
- Hardened auth startup so `AuthProvider` refreshes the Supabase session before marking the initial session resolved, which keeps already-signed-in users on splash until the session is ready instead of flashing the login screen.
- Simplified the splash screen into a passive loading state with no manual login/home buttons during startup, so the first visible screen stays calm while auth settles.
- Added a local `android/key.properties` placeholder pointing at the machine's existing debug keystore so `flutter build appbundle --release` can complete again in this workspace; this is only a local build aid and not a Play release signing replacement.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, and `scripts/flutter-local.ps1 build appbundle --release --no-pub`. ADB install of the debug APK hit a signature mismatch against the already-installed app because the local signing key differs from the previous install.

## 2026-05-19 Permission Onboarding Settings Redirect Checkpoint
- Separated permission onboarding so app notifications and exact alarms are checked independently instead of using the combined notification request path.
- After a denied notification request, the screen now opens Android notification settings; after a denied exact-alarm request, it opens Android app settings.
- The onboarding screen now refreshes on resume and after returning from settings so the permission tiles reflect the latest OS state.
- Added focused widget tests for notification-settings redirect, exact-alarm app-settings redirect, and the request-all flow.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/permission_onboarding_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, and `adb shell am start -n com.planflow.app/.MainActivity`.

## 2026-05-19 Permission Onboarding Resume Message Fix Checkpoint
- Refined the resume path so returning from Android settings clears stale denied messages before the permission tiles refresh.
- Updated the permission onboarding widget tests to simulate a real settings round-trip by opening settings first, then flipping the permission state, then sending the app back to `resumed`.
- Final verification passed after the resume-message fix: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 test test/screens/permission_onboarding_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity`.

## 2026-05-18 Voice Delivery Parsing And Core Guard Checkpoint
- 음성 입력 `지금으로부터 3달뒤 부터 3개월마다 반복알람. 내용은 원주기독 정형외과 김두섭 리바로 갖다주기`가 `김두섭 리바로 갖다주기` 제목, `원주기독 정형외과` 장소, 3개월 뒤 시작일, 3개월 반복 규칙으로 정리되도록 GPT 후처리와 로컬 분석 후처리를 보강했다.
- `원주기독`/`원주세브란스` 계열 장소 검색 alias를 추가해 `원주세브란스기독병원` 검색으로 이어지게 했고, 새 일정 확인 화면은 사용자가 말한 장소 텍스트를 유지하면서 검색 결과 좌표만 자동으로 저장하도록 했다.
- Flow Core/공유 코어 파일은 NexusFlow 등 다른 프로젝트에 영향을 주는 계약으로 보고, `packages/`, `flow_core/`, 공유 모델/저장소/파싱·라우팅 서비스 변경 전 사용자 확인이 필요하다는 규칙을 `AGENTS.md`에 추가했다.
- 검증: focused 음성/GPT/장소 테스트, ConfirmScreen 자동 좌표/사용자 수정 보존 테스트, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, ADB install/launch/PID/focused window 확인 통과. `confirm_screen_test.dart` 전체는 이번 변경과 무관한 기존 기대값 노후화 케이스가 남아 있어 focused 검증으로 대체했다.

## 2026-05-18 Login Permission Onboarding And Icon Checkpoint
- 로그인 성공 후 라우팅을 `AuthProvider`/`GoRouter` 중심으로 정리해 로그인 화면으로 되돌아가는 중간 상태를 줄였다. 초기 세션 확인 전에는 root splash에 머물고, 명시 로그인 중 `/login`은 스플래시로 밀리지 않도록 했다.
- 첫 권한 온보딩은 유지하되 진입만으로 OS 권한 요청을 하지 않고, 사용자가 `필요 권한 모두 요청`/개별 요청을 누른 경우에만 권한 팝업이 뜨게 했다. `나중에 필요한 기능에서 허용할게요`로 첫 온보딩을 완료하면 이후 전체 권한 페이지가 강제 재등장하지 않는다.
- 런처 아이콘을 기본 다이아몬드에서 파란 일정 카드+체크 형태로 교체하고 adaptive/legacy PNG에 safe-area 여백을 적용했다. `AGENTS.md`에는 NexusFlow 연동으로 DB schema/migration/RLS 변경 전 사용자 확인을 요구하는 규칙을 추가했다.
- 검증: focused permission/login tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, ADB install, 앱 실행/PID/focused window 확인, reviewer 재검토 PASS.

## 2026-05-18 Launcher Icon Adaptive Crop Fix Checkpoint
- `planflowlogo.png` 기반 런처 아이콘이 Android adaptive foreground에서 가운데 체크만 확대/크롭되어 보이던 문제를 수정했다.
- 전체 로고 이미지는 adaptive foreground 안쪽 inset 영역에 맞춰 축소 배치하고, 바깥 흰 모서리는 투명 alpha로 제거했다. legacy `mipmap-*` `ic_launcher`/`ic_launcher_round` PNG도 모든 density에서 같은 원본 비율과 투명 모서리로 재생성했다.
- 실행 직후 launch background도 같은 투명 아이콘을 중앙에 표시하도록 바꾸고, Android 상태표시줄 알림용 `ic_stat_planflow`은 플랫폼 규격에 맞춘 흰색 단색 마이크+체크리스트 vector로 교체했다.
- 홈 런처에서 투명 adaptive 배경이 검은 가장자리처럼 렌더링되는 문제를 막기 위해, adaptive background는 파란 그라데이션으로 꽉 채우고 foreground는 심볼만 투명 PNG로 분리했다. legacy PNG도 검은/흰 모서리 없이 완전 불투명 그라데이션 배경+심볼 형태로 다시 생성했다.
- 검증: `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, ADB install, launcher run, PID check 통과.

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

## 2026-05-12: LocationPicker 지도 폴백 상태 기반 구현
- `lib/screens/location/location_picker_screen.dart`에서 지도 렌더 상태를 `_MapRenderState`로 분리해, 인앱 지도 실패/타임아웃 시 `AppBar`만 남는 공백을 막고 폴백 본문(메시지 + 외부 지도 버튼)을 강제 표시하도록 했습니다.
- `canUseInAppMapOverride: false` 및 검색 결과 없는 경우에도 검색창/후보/외부 지도 버튼 구성이 유지되도록 하단 패널 안내 문구를 보강했습니다.
- `debugForceMapUnavailableTimeout` 플래그로 지도 렌더 타임아웃 폴백 시나리오를 테스트 가능하게 만들고, 해당 케이스를 포함해 테스트 3건을 `test/screens/location_picker_screen_test.dart`에 추가했습니다.
- 검증: `flutter-local` 기반 `analyze`, `test/screens/location_picker_screen_test.dart`, `build apk --debug`, `adb install`, `adb shell monkey/pidof`까지 통과.

## 2026-05-13: voice_action_screen 후보 미표시 버그 수정 + CLAUDE.md 생성
- `voice_action_screen.dart` 4가지 수정:
  (1) `_loadCandidates` 시작 시 `_events.clear()` 추가 — 재로드 시 이전 데이터 잔류 방지
  (2) `_candidateEventsForDisplay` 로직 단순화 — 키워드 매칭 없으면 모든 일정 다가오는 순 폴백 보장
  (3) build 조건을 `else if (!_isAdd)`로 변경 — add 모드에서 빈 "대상 일정" 헤더가 나타나는 버그 수정
  (4) 성공 상태에서 진단 정보(후보 수·검색어) 서브타이틀 표시
- `CLAUDE.md` 새 파일 생성: claude-opus-4-5/sonnet/haiku 모델 라우팅, 워커 병렬 실행, 리뷰어 루프 규칙
- `AGENTS.md` 모델명 gpt-5.5 계열 → Claude 모델명으로 업데이트
- 검증: `flutter build apk --debug` 통과, git push 완료

## Current State
- 2026-05-16: GitHub `main`을 `bd648d3`까지 fast-forward pull한 뒤, stash에 보관했던 한국어/영어 기본 UI 전환 작업을 최신 구조 위에 재적용했다. Flutter `gen-l10n` 설정(`l10n.yaml`, `lib/l10n/*.arb`, generated localizations)을 추가하고, 국가 설정의 `uiLocaleCode`로 한국은 한국어 UI, 미국/영국/호주 및 일본/독일/프랑스는 영어 fallback UI를 쓰게 연결했다. 로그인, 쉘 내비게이션, 설정의 국가/시간·캘린더·백업 제목, 음성 입력 핵심 문구, 일정 편집 제목/저장 버튼을 l10n 경로로 옮겼다. 검증은 `./scripts/flutter-local.ps1 analyze --no-pub`, focused settings/voice/event edit 테스트, `git diff --check`, debug APK build, ADB 설치/실행/PID 확인까지 통과했다. 전체 `./scripts/flutter-local.ps1 test --no-pub`는 이번 변경과 무관한 `confirm_screen_test` 실패들과 `location_picker_screen_test` 10분 timeout이 남았다.
- 2026-05-16: `lib/screens/voice/voice_action_screen.dart`의 음성 삭제 후보 카드를 UI-only로 정리했다. 체크박스 옆 작은 휴지통 배지를 제거하고, 후보 카드 표면/선택 배경/테두리/간격을 PlanFlow 톤에 맞게 보강했으며, 카드 하단 버튼은 아이콘 없는 짧은 `삭제` 라벨로 변경했다. `test/screens/voice_action_screen_test.dart`의 관련 기대값만 새 라벨에 맞췄다. 검증은 focused analyze, 전체 `test/screens/voice_action_screen_test.dart`, `git diff --check`, debug APK build, ADB install, 앱 실행/PID/focused app 확인까지 통과했다.
- 2026-05-16: `lib/screens/voice/voice_action_screen.dart`의 음성 삭제 후보 영역을 단순 세로 패널로 재구성했다. 상단 안내/선택 카운트/선택 삭제 버튼을 세로로 분리하고, 각 후보는 체크박스+제목/메타+전체 폭 `삭제 확인` 버튼 카드로 렌더링해 좁은 화면 가로 오버플로우와 텍스트 겹침 위험을 줄였다. 기존 테스트 키(`voice-delete-candidate-list`, `voice-delete-inline-actions`, `voice-delete-candidate-$index-$id`, `voice-delete-inline-button-$index-$id`, `voice-delete-button-$index-$id`)는 유지했고, 선택 삭제 확인 테스트용 키를 보강했다. 검증은 focused analyze, `test/screens/voice_action_screen_test.dart`, `git diff --check`, debug APK build, ADB install, 앱 실행/PID/focused app 확인까지 통과했다.
- 2026-05-15: `lib/data/models/user_settings_model.dart`에 `preferred_map_provider`를 추가해 기본값을 `naver`로 정규화했고, `lib/data/repositories/settings_repository.dart`와 `lib/services/backup_service.dart`에서 `user_settings` 선택/백업 열거에 같은 컬럼을 넣었다. `lib/screens/settings/settings_screen.dart`에는 "기본 지도" 세그먼트 선택 UI를 추가해 네이버 지도, Google 지도, TMAP 중 하나를 저장하도록 연결했다. `supabase/schema.sql`에는 create table/alter table/restoration 경로를 갱신했고, 관련 모델/저장소/설정 테스트를 업데이트했다. 검증은 `./scripts/flutter-local.ps1 analyze --no-pub`, `./scripts/flutter-local.ps1 test --no-pub test/data/models/user_settings_model_test.dart test/data/repositories/settings_repository_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, `adb shell pidof com.planflow.app`까지 통과했다. 설정 화면 위젯 테스트는 워크트리의 기존 `lib/screens/location/location_picker_screen.dart` 컴파일 오류 때문에 이번 변경과 별개로 막혀 있었다.
- 2026-05-12: `lib/screens/voice/voice_action_screen.dart`에서 음성 수정/삭제 후보가 0점 매칭이어도 최근/다가오는 후보를 계속 보여주도록 유지하고, DB 0건일 때는 "저장된 일정이 앱 DB에서 보이지 않아요" 복구 카드와 `동기화 후 다시 찾기` 액션을 노출하도록 정리했다. 후보 조회 시 `action`, `userIdExists`, `totalEventCount`, `filteredCount`, `displayedCount`, `targetQuery`를 debugPrint로 남기도록 추가했고, `test/screens/voice_action_screen_test.dart`에 로그/복구 카드 회귀를 보강했다. 검증은 `dart analyze lib/screens/voice/voice_action_screen.dart test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, `adb shell pidof com.planflow.app`까지 통과했다.
- 2026-05-12: 음성 라우터/분석/입력에서 수정 intent에 `이동`을 추가하고, `첫번째/이걸로/선택/이거/그걸로/골라` 계열 전역 choose intent는 음성 입력 경로에서 더 이상 생성되지 않도록 정리했다. `VoiceCommandAnalysisService` 프롬프트와 로컬 제목 정리에서도 choose 단어를 노이즈로 제거했고, voice input/router/analysis focused tests를 다시 통과했다. 검증은 `./scripts/flutter-local.ps1 test --no-pub test/services/voice_command_router_test.dart test/services/voice_command_analysis_service_test.dart test/screens/voice_input_screen_test.dart`와 `./scripts/flutter-local.ps1 build apk --debug --no-pub`까지 완료했다.
- 2026-05-12: 공용 `VoiceCommandRouter`를 추가해 voice input/action의 add/edit/delete/query 판정과 후보 검색 토큰화를 한곳으로 모았다. `targetQuery`와 `requestedChanges`를 분리해서 수정/삭제 후보 검색이 빈 화면으로 꺾이지 않게 했고, `오늘 오후 3시에서 4시 사이에 팀장님한테 내일 오는 시간 확인하기`/`내일 일정 확인해줘`/`내일 팀장님 동행방문 다음 주 수요일로 연기`/`오늘 아이스크림 전달 일정 삭제해 줘`를 포함한 회귀를 라우터·화면 테스트에 고정했다. 검증은 `./scripts/flutter-local.ps1 analyze --no-pub`, `./scripts/flutter-local.ps1 test --no-pub test/services/voice_command_router_test.dart`, `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_input_screen_test.dart`, `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, `adb shell pidof com.planflow.app`까지 통과했다.
- 2026-05-12: 음성 수정 후보 검색을 다듬어 "이라고 되어 있는 일정" 같은 문장 장식과 "이번 주 목요일로 바꿔 줘 오전 9시로" 같은 새 값 표현을 검색어에서 더 확실히 제거하고, edit/delete에서 매칭이 0점이어도 최근/다가오는 후보를 보여주는 fallback 정렬을 추가했다. `test/screens/voice_action_screen_test.dart`에 해당 회귀와 fallback 순서 테스트를 보강했고, `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 test --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, `adb shell pidof com.planflow.app`를 통과했다.
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

## 2026-05-12 Smart Morning Briefing Schedule Checkpoint
- Changed morning briefing scheduling so the configured morning time is pulled earlier when the first external event's calculated preparation start would happen before that time.
- The adjusted morning briefing is scheduled 30 minutes before the first preparation start, using the same default external-event travel/slack/prep timing model and never scheduling in the past.
- Added tests for early external schedules pulling the morning briefing forward and for past adjusted times falling back to the configured morning time.
- Fixed a date-sensitive ConfirmScreen UTC round-trip test by moving its fixed sample event to a future date relative to the current test date.
- Verification passed: `flutter analyze --no-pub`, focused briefing and ConfirmScreen tests, full `./scripts/flutter-local.ps1 test --no-pub` (228 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `14665`.

## 2026-05-12 GPT-Realtime Product Direction Checkpoint
- Updated `PlanFlow_Codex_Prompt_v3.md` to keep 1st-release voice input on the current low-cost `on-device STT -> text cleanup -> GPT-4o-mini parsing` architecture.
- Added a 2nd-release `실시간 음성 비서 모드` section that recommends GPT-Realtime-2 only for explicit multi-turn voice assistant sessions, not for every basic microphone input.
- Documented the cost/UX guardrails: Realtime sessions must be user-started, separately metered, and still require user confirmation before schedule changes are saved.
- Verification was document-scoped: reviewed the markdown diff and searched the prompt for the new GPT-Realtime direction entries.

## 2026-05-12 Voice Preanalysis Speed Checkpoint
- Added `VoiceCommandAnalysisService` to pre-analyze partial/complete microphone text with normalized text, intent, confidence, uncertain fields, schedule fields, target hints, and requested changes.
- Added session-level AI budget, repeated-text cache, and meaningful-change gating so partial speech analysis can improve speed without calling AI on every transcript update.
- Wired `VoiceInputScreen` to debounce partial STT text, show compact `일정 분석 중` / `준비됨` status, and pass the prepared draft to ConfirmScreen immediately when the user finishes.
- Preserved manual text edits: once the user edits the transcript, prepared AI drafts are cleared and the manually confirmed text remains the source of truth.
- Fixed `scripts/flutter-local.ps1 analyze` so the repo wrapper no longer passes unsupported `--dart-define` flags to Flutter analyze.
- Review passed with a separate verifier agent finding no issues in the service/UI/test changes.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused voice analysis/input tests, full `./scripts/flutter-local.ps1 test --no-pub` (234 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `20743`.

## 2026-05-12 Agent Model Routing Checkpoint
- Updated `AGENTS.md` model routing so planning remains `gpt-5.5`, while execution and review/verification now use `gpt-5.3-codex-spark`.
- Verification was document-scoped: checked the AGENTS model routing diff and reran `node scripts/gsd-context-hygiene.mjs`.

## 2026-05-12 Cost-Aware Agent Routing Checkpoint
- Refined `AGENTS.md` model routing so `gpt-5.3-codex-spark` remains the default execution/review model for cost-effective narrow work.
- Added an explicit escalation rule to use `gpt-5.4-mini` for high-risk work such as calendar sync, auth, timezone/date math, notifications, voice parsing/routing, Supabase schema/RLS, release signing, and broad refactors.
- Verification was document-scoped: checked the AGENTS model routing diff and reran `node scripts/gsd-context-hygiene.mjs`.

## 2026-05-12 Voice Edit Candidate Fallback Checkpoint
- Fixed voice schedule edit candidate search so phrases like `이라고 되어 있는 일정`, `이번 주 목요일`, and `오전 9시로` are stripped from the target search text before ranking saved events.
- Added quote-ending token variants such as `전달이라고` -> `전달`, so spoken Korean wrappers no longer hide matching event titles.
- Added a non-query fallback for edit/delete flows: if no target token matches, the screen still shows upcoming/recent event candidates instead of leaving `대상 일정` empty.
- Added regression tests for the reported `오늘 강릉 아산에서 아이스크림 전달이라고 되어 있는 일정 이번 주 목요일로 바꿔 줘 오전 9시로` phrase and for empty-match fallback ordering.
- Review passed with a separate verifier agent finding no blocking issues.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_action_screen_test.dart`, full `./scripts/flutter-local.ps1 test --no-pub` (237 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `32145`.

## 2026-05-12 Voice Intent Manual Input And Reminder Sheet Checkpoint
- Fixed voice input routing so add/save cues such as `확인하기로 저장` win over query-like content words, while phrases like `저장된 일정 보여줘` still route to query.
- Preserved direct manual transcript edits against both prepared AI drafts and late partial STT updates, so the visible user-edited text remains the source of truth.
- Added candidate-aware fuzzy matching for voice edit target search so one-syllable STT misses such as `강릉하산` can still rank the saved `강릉아산` event without hardcoded place replacements.
- Made the reminder offset bottom sheet scroll-controlled and safe-area constrained so compact screens no longer show the Flutter bottom overflow stripe.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused voice/action/analysis/reminder tests, full `./scripts/flutter-local.ps1 test --no-pub` (244 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, and `adb shell pidof com.planflow.app` returned PID `2734`.

## 2026-05-12 Voice Edit Prefill And Delete Candidate Checkpoint
- Voice edit now applies spoken change values before opening EventEditScreen: date/time phrases such as `금요일로 옮겨줘` prefill the existing event with the new local start while preserving its time and duration.
- EventEditScreen still saves through `updateEvent` for normal existing events, so moving a Tuesday event to Friday updates the original row rather than creating a duplicate.
- Added delete candidate regression for `오늘 아이스크림 전달 일정 삭제해 줘` and a UI guard so delete/edit screens never leave the target area visually blank when no candidate is available.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_action_screen_test.dart`, full `./scripts/flutter-local.ps1 test --no-pub` (247 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, and `adb shell pidof com.planflow.app` returned PID `13784`.

## 2026-05-12 User Feedback Loop Checkpoint
- Added an in-app `문제 신고 / 의견 보내기` section to Settings with a report sheet for bug, voice recognition, calendar sync, notification, map/location, feature request, and other feedback types.
- Added `FeedbackRepository` and Supabase `feedback_reports` schema/RLS so signed-in users can insert/select their own reports; normal update/delete remains blocked by having no user policies.
- Feedback submissions include minimal diagnostics only: app version, platform, OS summary, screen route, and recent calendar sync status keys. Voice files, calendar bodies, and location history are not attached automatically.
- Wired feedback submission to Analytics `feedback_submitted`, Crashlytics nonfatal log/custom keys, and a mailto fallback for `officialfluxstudio.kr@gmail.com`.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused feedback repository/sheet tests, settings screen regression test, full `./scripts/flutter-local.ps1 test --no-pub` (252 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, and `adb shell pidof com.planflow.app` returned PID `15315`.

## 2026-05-12 Voice Router Query Boundary Checkpoint
- Tightened the shared voice command router after review so explicit query phrases such as `내일 일정 확인하기` and `메모 보여줘` route to query instead of being swallowed by the add flow.
- Kept schedule-content phrases such as `오늘 오후 3시에서 4시 사이에 팀장님한테 내일 오는 시간 확인하기` and explicit save phrases such as `확인하기로 저장` on the add path.
- Added router and voice input regressions for these boundary phrases and verified the focused analyze/test commands.

## 2026-05-12 Home Remaining Schedule And External Prep Resync Checkpoint
- Updated the home empty-today card so when all of today’s schedules are already past it says there are no remaining schedules instead of implying this is the first schedule.
- Changed the calendar day tap sheet to a scroll-controlled draggable bottom sheet that opens much taller, can be pulled up near full screen, and keeps direct/voice add actions visible while long event lists scroll.
- Reworked external preparation/departure alarms so the first relevant event means the first future event with an actual outside/location context, not the first event of the day. Locationless tasks such as phone calls no longer steal the “first preparation” slot from later travel appointments.
- Added day-level external preparation resync after event create/update/delete, including old-day resync when an event is moved to another day, so earlier/later location events are promoted and notifications are recalculated.
- Separated generated external-preparation pre-actions with `source='external_preparation'`, added schema/backfill/trigger SQL, and kept generic user/GPT pre-actions under a separate notification key prefix.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused smart-prep/manual-side-effect/calendar-sheet tests, full `./scripts/flutter-local.ps1 test --no-pub` (266 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `9635`.

## 2026-05-12 Agent Enforcement And Voice Candidate Guard Checkpoint
- Updated `AGENTS.md` so work from `C:\PlanFlow`, role/model routing, worker subagents, reviewer verification, fix-after-review loop, tests/build, checkpoint, commit, push, and device run checks are mandatory reporting gates for multi-issue/high-risk work.
- Parallel worker agents completed voice routing and voice action recovery fixes in commits `002aa58` and `47737dd`: `이동` routes to edit, voice candidate selection words no longer become a global choose intent, edit/delete screens show fallback candidates when events exist, and DB-zero states show recovery actions.
- Added an extra router regression test covering `첫번째`, `이걸로`, `선택`, `이거`, `그걸로`, and `골라` so screen candidate selection remains card-tap based instead of voice-routed.
- Reviewer agents reported no blocking issues; the second review suggested adding `골라`, which was added before final verification.
- Verification passed: focused voice/location tests, full `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (270 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `25012`.

## 2026-05-12 Voice Manual Resubmit Button Checkpoint
- Added a visible `현재 내용으로 입력` button next to the idle voice input button, so users can correct the transcript text field and route the currently visible text without starting voice recognition again.
- The button is disabled when the text field is empty and uses the existing `_continueWithRawText` path, preserving manual edit protection and `manual_text_confirmed` behavior.
- Kept the listening state simple: while recording, the primary control remains the single `완료` button; the resubmit button appears only when not listening.
- Added widget tests for corrected text submission and empty-text disabled state, and updated existing voice input tests to use the clearer `현재 내용으로 입력` action.
- Review passed with a separate verifier agent finding no blocking issues.
- Verification passed: focused voice input analyze/test, full `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (272 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, and `adb shell pidof com.planflow.app` returned PID `17100`.

## 2026-05-12 Voice Add Memo Cleanup And Candidate Diagnostics Checkpoint
- Removed default raw transcript memo injection from voice add flows, including the voice action add-confirm handoff, so date/time phrases are not copied into memo by default.
- ConfirmScreen no longer seeds memo from `raw_text` and no longer restores `raw_text` during GPT hydration; manual text submissions can still hydrate structured fields when `parse_pending=true`, while later user edits remain protected.
- Hardened GptService schedule normalization and prompt guidance so date/time/recurrence/reminder metadata is stripped from title/memo and simple phrases such as `내일 오전 9시에 대전출발` become title `대전 출발`, location `대전`, memo null, and the inferred KST start time.
- VoiceActionScreen now retries one forced calendar sync when edit/delete/query candidate DB reads return 0 events, then renders a recovery card with diagnostics (`action`, `userId`, `totalEventCount`, `filteredCount`, `displayedCount`, `targetQuery`) instead of leaving only the `대상 일정` title.
- Worker agents split the memo/parsing and candidate-diagnostics scopes; a reviewer agent reported no blocking issues.
- Verification passed: focused voice/GPT/confirm tests, full `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (274 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `12938`.

## 2026-05-13 Voice Input Hint Copy Checkpoint
- Removed the top helper sentence from the voice input page and added a second example that explicitly teaches schedule edits/changes: `언제 일정을 다음주로 변경해`.
- Kept the existing guidance card and tests aligned so the new copy is visible and the old intro line no longer appears.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub lib/screens/voice/voice_input_screen.dart test/screens/voice_input_screen_test.dart` and `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_input_screen_test.dart`.

## 2026-05-13 Voice Home Prefetch And Candidate Matching Checkpoint
- Added `EventPrefetchService` so authenticated event lists are warmed once at app startup/login, cached per user for a short window, reused by HomeScreen immediately, refreshed in the background, and invalidated when the event refresh bus fires.
- Improved voice edit/delete candidate matching so target date hints such as `오늘`, `내일`, `다음 주` scope the candidate list separately from the requested change date, today past events can still appear for delete/edit, and low-confidence fallback lists are capped instead of flooding unrelated schedules.
- Added prefix-aware fuzzy matching for Korean STT misses such as near-prefix title/place words without hardcoding specific places.
- Worker subagents handled the home prefetch and voice matching scopes in parallel. A reviewer agent found voice regression failures, which were fixed; follow-up reviewer attempts timed out, so final acceptance used full local verification.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (284 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `19192`.

## 2026-05-13 Voice Delete Button Style Checkpoint
- Updated voice edit/delete candidate cards so destructive actions use the app theme `errorContainer/onErrorContainer` tonal styling instead of the awkward dark-blue background with red text.
- Kept non-destructive candidate actions on the existing PlanFlow tonal style, widened the fixed action button from 94 to 104 px, reduced icon size to 18, and tightened horizontal padding so Korean labels such as `삭제하기` and `수정하기` fit more reliably on compact screens.
- Updated the voice delete confirmation dialog to use `colorScheme.error/onError` for the final destructive button while preserving the equal-width cancel/delete layout.
- Worker and reviewer subagents were used; the reviewer flagged the original 94 px width risk, which was fixed, and the follow-up reviewer returned PASS.
- Verification passed: `dart format lib/screens/voice/voice_action_screen.dart`, `./scripts/flutter-local.ps1 analyze --no-pub lib/screens/voice/voice_action_screen.dart`, `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `14351`.

## 2026-05-13 Voice Multi Delete Selection Checkpoint
- Added multi-select deletion to the voice delete candidate screen: delete candidates now show checkboxes, a selected-count bar, and a `선택 삭제` action that deletes only the selected event rows after confirmation.
- Preserved existing single-card delete behavior by routing individual card deletion through the same shared delete pipeline, while keeping edit/query modes free of delete-selection UI.
- Selection state is cleared or pruned when candidates reload, action mode changes, or selected events are deleted, and delete controls are disabled while deletion is in progress.
- Added a widget regression proving that selecting two of three delete candidates deletes only those two IDs.
- Worker and reviewer subagents were used; the reviewer returned PASS after checking mode isolation, selected-id deletion, stale selection cleanup, disabled states, and existing single delete behavior.
- Verification passed: `dart format lib/screens/voice/voice_action_screen.dart test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (285 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `12417`.

## 2026-05-13 Voice Controls And Calendar Editor Polish Checkpoint
- Consolidated STT voice-control command detection so direct detection, inline transcript cleanup, speech_to_text fallback, and native Android STT all route through the shared command resolver/handler for undo, clear, and cancel controls.
- Expanded stop/cancel voice controls to cover `취소`, `그만`, `중단`, `중지`, `정지` and common polite verb variants such as `중지해 줘` / `정지해 주세요`.
- Updated the voice input guide copy to summarize input controls inside the existing guidance card without adding extra UI height.
- Refined the shared calendar-style event editor with section labels and dividers for basic info, date/time, category, recurrence/place, memo, and alarms, and removed the `서울 (GMT+9:00)` timezone row from edit/confirm flows.
- Reworked the inline time wheel to keep 12-hour hour/minute columns looping naturally: 12 to 1 changes AM/PM as needed, 55 to 00 increments the hour, and 00 back to 55 decrements it.
- Worker subagents handled voice-control and editor scopes in parallel. A reviewer initially BLOCKed native STT timing and stale timezone test expectations; both were fixed, and the follow-up reviewer returned PASS.
- Verification passed: focused analyze/test, full `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (289 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `31222`.

## 2026-05-13 Imported Calendar Preparation Alarm Checkpoint
- Investigated the missing smart preparation alarm for the imported `아이스크림 전달 / 강릉아산병원` event on 2026-05-14 09:00 KST using ADB, app logs, Supabase REST with the device session, and Android scheduled-notification storage.
- Root cause: imported calendar events (`naver_device`/CalDAV/device calendar paths) were persisted through repository upsert but skipped the manual-save side effects that geocode location text and schedule smart preparation/departure alarms.
- Updated `CalendarAutoSyncService` so app start/resume calendar sync now resyncs upcoming external preparation alarms after imports and calls `EventPreparationService.prepareAfterSave` for external events inside the departure monitor window.
- Added regression coverage to ensure imported external events trigger day-level preparation resync, locationless earlier events do not steal the first-travel-event slot, past/>7-day events are excluded, and >24-hour events do not trigger departure preparation early.
- Real device verification confirmed the previously missing event now has smart preparation notifications and a route-based `지금 출발해야 해요` alarm for `강릉아산병원`; the route estimate was about 88 minutes with a 30-minute buffer.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused and full Flutter tests, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app`.

## 2026-05-13 Location Picker Map Render Fix Checkpoint
- Applied the `CODEX_MAP_FIX.md` direction to `LocationPickerScreen` after re-checking it against the current PlanFlow route structure.
- The in-app map widget now mounts even while `_MapRenderState.loading`, so Naver/Google map readiness callbacks can actually fire; the loading panel is now an overlay instead of replacing the map widget.
- The existing 5-second readiness timeout, unavailable fallback, external map fallback buttons, gesture hint, and load fallback banner behavior were preserved.
- Wrapped the location picker route in `PopScope(canPop: true)` so AppBar/system back can pop the MaterialPageRoute used by the picker without being swallowed by the shell route.
- Worker and reviewer subagents were used; the reviewer returned PASS for map mounting, fallback preservation, timeout retention, and back navigation routing.
- Verification passed: focused location picker test, full `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (291 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `30422`.

## 2026-05-13 Supabase Persistence And Sync Overwrite Guard Checkpoint
- Investigated why user edits appeared to reset after rebuild/update. Root cause was not `adb install -r` itself; app start/resume sync could re-import external calendar rows and overwrite PlanFlow/Supabase edits, while settings saves could drop rapid follow-up changes during an in-flight save.
- Added a repository-level external import guard so imported Google/Naver/device rows do not overwrite a local PlanFlow edit made after the last successful sync unless a stable external etag actually advanced.
- Changed settings autosave to queue one follow-up save while a save is already running, and prevented stale save results from applying old UI state or stale briefing scheduling over newer user changes.
- Brought voice direct-edit side effects in line with normal edit saves: reminders/pre-actions, day preparation resync for old/new days, calendar export sync, departure preparation, home widget refresh, and refresh bus notification now run after direct voice updates.
- Added refresh notification after preparation checklist changes so Supabase-backed checklist state does not leave home/calendar caches stale.
- Worker/explorer subagents identified the external overwrite, settings-save race, cache/side-effect gaps; reviewer initially flagged the stale settings apply and import timestamp risk, both were fixed, and a follow-up reviewer returned PASS.
- Verification passed: focused external import guard test, full `./scripts/flutter-local.ps1 analyze --no-pub`, full `./scripts/flutter-local.ps1 test --no-pub` (295 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`.

## 2026-05-14 Alarm Reliability Investigation Checkpoint
- Investigated the user's missed-alarm report for the imported `아이스크림 전달 / 강릉아산병원` event on 2026-05-14 09:00 KST using ADB permissions, Android alarm dumpsys, app scheduled-notification prefs, and Supabase REST with the device session.
- Findings: Android notification/exact/full-screen permissions were granted and Android had delivered PlanFlow alarm intents today; the imported event existed in Supabase with duplicated external preparation rows at 07:00/07:30/08:00, but no default `reminders` row existed because external calendar import/resync only handled preparation/departure side effects.
- Updated `NotificationService.scheduleEventReminderWithResult` so normal event reminders and smart-prep notifications use exact scheduling when exact-alarm permission is available, fall back to inexact only when exact is off, and return a clearer permission warning when notifications are blocked or exact alarms are unavailable.
- Added `ManualEventSideEffectService.resyncRemindersForEvents` and wired `CalendarAutoSyncService._resyncUpcomingPreparation` to refresh default reminders for all upcoming imported/local events in the next 7 days, not only external-preparation alarms.
- Hardened external-preparation resync against duplicate rows by deduplicating pre-action payload inserts and reusing an in-flight same-user/same-day resync instead of running the same delete/insert/schedule cycle twice.
- Reviewer flagged critical push/system reminder dedupe and in-flight resync issues; both were fixed and covered with regression tests.
- Verification passed for the alarm scope: `./scripts/flutter-local.ps1 analyze --no-pub`, focused tests for notification/manual side effects/calendar auto sync, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, and `adb shell pidof com.planflow.app` returned PID `7915`.
- Full `./scripts/flutter-local.ps1 test --no-pub` was also attempted but failed on pre-existing unrelated UI/timezone tests (`location_picker_screen_test` duplicate text expectations and `confirm_screen_test` KST expectation), while the alarm-related tests passed.

## 2026-05-14 Voice Control Command Runtime Fix Checkpoint
- Fixed voice-control command handling so inline/partial STT phrases like `내일 오전 아니다 다시 전체 취소` no longer remain in the text field as schedule content.
- Expanded shared STT controls to include `아니다`, `전체 삭제/전체삭제`, `전체 취소/전체취소`, `마지막 삭제`, and `방금 삭제`, with direct detection, transcript normalization, Android native STT, and `speech_to_text` fallback all sharing the same resolver.
- Added partial-result cleanup on `VoiceInputScreen`: clear-all commands immediately empty the visible field, standalone cancel/stop commands stop listening and remove the command text, and async partial processing is token-guarded so stale partials do not overwrite newer input.
- Preserved normal schedule phrases containing `취소`, such as `계약 취소 확인 전화`, by treating cancel as a stop command only when it is a standalone command or an explicit native-session command.
- Updated the voice-input guide copy to mention the new commands within the existing guide card.
- Worker/reviewer agents were used; the first reviewer found blocking gaps for inline `아니다` and stale clear-all partials, both were fixed, and the follow-up reviewer returned no blocking findings.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused `./scripts/flutter-local.ps1 test --no-pub test/services/stt_service_test.dart test/screens/voice_input_screen_test.dart` (27 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, and `adb shell pidof com.planflow.app` returned PID `6499`.

## 2026-05-15 Map Search UX And Provider Preference Checkpoint
- Added candidate-list affordances to `LocationPickerScreen`: multiple location candidates now show left/right chevron controls and a short swipe hint, while 0/1-candidate states stay uncluttered.
- Added local map-search fallback queries in `LocationLookupService` so failed exact searches retry normalized variants and can offer `이런 검색어로 다시 찾아볼까요?` suggestion chips without hiding API authentication failures.
- Added `preferred_map_provider` to `UserSettingsModel`, Supabase settings repository/schema, backup select/restore paths, and Settings UI. Default is `naver`; users can choose `네이버 지도`, `Google 지도`, or `TMAP`.
- Wired `pickLocationFromQuery` to load the preferred provider from saved settings. Naver/Google affect in-app map priority; TMAP opens external TMAP first and falls back to the in-app picker if needed.
- Reviewer agents found and confirmed fixes for three integration risks: preserving auth-failure guidance, backup compatibility before the new DB column is applied, and `voice_auto_start` backup/restore parity.
- Verification passed: focused `./scripts/flutter-local.ps1 analyze --no-pub`, focused location/settings/model/repository tests (32 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`, and `adb shell pidof com.planflow.app` returned PID `2889`.

## 2026-05-15 Location Picker Search Header Checkpoint
- Moved the location picker search field and `검색` button out of the bottom control sheet and into the AppBar bottom area so the keyboard does not cover the search action.
- Kept the bottom sheet focused on selected place details, candidate chips, fallback search suggestions, empty-state guidance, and `이 위치 사용`.
- Preserved map rendering/fallback behavior and the existing candidate swipe chevrons.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub lib/screens/location/location_picker_screen.dart test/screens/location_picker_screen_test.dart`, `./scripts/flutter-local.ps1 test --no-pub test/screens/location_picker_screen_test.dart` (6 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity`; focused app was `com.planflow.app/.MainActivity` with PID `14918`.

## 2026-05-15 Location Search Keyboard And Delete Candidate Checkpoint
- Updated the location picker search flow so both the AppBar `검색` button and keyboard search action dismiss the keyboard before running the shared search path.
- Started current-location lookup in parallel when opening the location picker from a place query, but no longer blocks route entry on slow location resolution; the picker opens as soon as search results/fallback are ready and applies late current-location center updates only if the user has not already selected a candidate or map point.
- Added safe fallback when the permission/location service is unavailable in widget tests or non-device environments, preserving the existing map picker route instead of failing before navigation.
- Strengthened voice delete candidate rendering with stable keys on delete candidate cards and individual `삭제하기` buttons, plus regression coverage for two visible delete candidates and multi-select deletion.
- Worker and reviewer agents were used. The first reviewer blocked the initial implementation because current-location lookup delayed navigation; this was reworked to asynchronous screen-side center updates, and the follow-up reviewer returned no blocking findings.
- Verification passed: full `./scripts/flutter-local.ps1 analyze --no-pub`, focused `./scripts/flutter-local.ps1 analyze --no-pub` for the changed location/voice files, focused `./scripts/flutter-local.ps1 test --no-pub test/screens/location_picker_screen_test.dart test/screens/voice_action_screen_test.dart` (33 tests), `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1`.
- Full `./scripts/flutter-local.ps1 test --no-pub` was attempted but still fails on an existing unrelated `ConfirmScreen stores Korean wall time as UTC once` expectation; the location-picker shared-preferences failure introduced during this change was fixed and the location/voice focused tests pass.

## 2026-05-15 Location Permission Prompt Checkpoint
- Adjusted the map entry flow so opening the location picker first checks/request location permission instead of silently falling back to Seoul/default map state.
- If location permission is denied, PlanFlow now shows a Korean guide dialog with `계속 선택` and `설정 열기`; the picker still opens afterward with a clear permission-needed message and without starting current-location lookup.
- If permission is granted, current-location lookup still starts asynchronously and no longer blocks search-result route entry.
- Added regression coverage for permission-denied map entry, including permission request count, guide dialog display, picker fallback, and `initialMapCenterFuture == null`.
- Reviewer guidance confirmed `pickLocationFromQuery()` is the right central point because confirm/edit map buttons already route through it.
- Verification passed: focused analyze for `location_pick_flow.dart` and `location_picker_screen_test.dart`, focused permission-denied and slow-current-location tests, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell monkey -p com.planflow.app -c android.intent.category.LAUNCHER 1` with PID `1354`.
- Full `location_picker_screen_test.dart` still timed out when run as one file due a test-runner/pending async interaction, so stale `flutter_tester` processes were cleaned up and the relevant new regression tests were run individually.

## 2026-05-15 Voice Memo Cleanup And Query Routing Checkpoint
- Tightened voice schedule parsing so date/time/recurrence/reminder phrases are kept in structured fields and no longer copied into memo/title unless the user explicitly says `메모에`, `설명에`, or similar.
- Preserved schedule titles containing `조회`, such as `월례 조회`, while removing bare `조회` from automatic query routing.
- Routed ambiguous `조회` / `일정 조회` to the voice action chooser instead of the query result screen, while keeping `보여줘`, `알려줘`, `찾아줘`, and `일정 확인해줘` as query commands.
- Worker agents handled routing and memo parsing in parallel; reviewer verified that `choose` no longer maps back to query and returned PASS.
- Verification passed: focused analyze/test for voice router/GPT/analysis/input files, full `./scripts/flutter-local.ps1 analyze --no-pub`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell am start -n com.planflow.app/.MainActivity` with PID `19328`.
- Full `./scripts/flutter-local.ps1 test --no-pub` was attempted and still failed on existing unrelated `ConfirmScreen stores Korean wall time as UTC once` and `location_picker_screen_test` timeout issues; the voice-focused tests passed.

## 2026-05-15 Voice Delete Candidate Rendering Checkpoint
- Investigated a real device screenshot where voice delete showed `2개 후보` diagnostics but no visible candidate cards.
- Split delete mode rendering away from the shared candidate card and added a dedicated `_DeleteCandidateRow` with checkbox, title/time/location, and a stable per-row delete button so delete candidates are always visible when `_events` is non-empty.
- Added a stable key to the final delete confirmation button and updated tests to avoid ambiguous `삭제` label matching.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub lib/screens/voice/voice_action_screen.dart test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 test --no-pub test/screens/voice_action_screen_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, and `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`.
- ADB install succeeded and `adb shell pidof com.planflow.app` returned PID `13633`; `am start` returned Android error code 10 even though the app process was running.

## 2026-05-15 Event Editor Visual Grouping Checkpoint
- Reworked the shared `CalendarStyleEventEditor` used by voice confirmation and normal event editing so essential fields stay visible and less-used fields are collapsed by default.
- Kept `기본 정보`, `날짜 · 시간`, and `장소` immediately visible, while `분류 · 반복`, `설명 · 준비`, and `알림 옵션` now show compact summaries and expand only when needed.
- Added stronger section framing with PlanFlow colors and icons without changing the existing title/date/location save callbacks.
- Added keyboard dismiss behavior for editor text fields, supplies, smart-prep inputs, and voice direct input; voice direct input still submits after dismissing the keyboard.
- Worker/reviewer agents were used. The first reviewer caught a direct-input submit regression, it was fixed, and the follow-up reviewer returned PASS.
- Verification passed: focused analyze, `./scripts/flutter-local.ps1 test --no-pub test/widgets/calendar_style_event_editor_test.dart test/screens/voice_input_screen_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `4953`.

## 2026-05-15 Event Editor Label Refinement Checkpoint
- Renamed the collapsed editor section labels to user-facing wording: `분류 · 반복` became `방문 목표 · 반복 설정`, and `설명 · 준비` became `설명 · 준비물`.
- Updated the widget regression test to match the new labels.
- Verification passed: focused analyze, `./scripts/flutter-local.ps1 test --no-pub test/widgets/calendar_style_event_editor_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `22715`.

## 2026-05-15 Feedback Report Reliability Checkpoint
- Investigated the user report that Settings feedback submission showed no success message, did not create a row, and kept the typed text.
- Root cause risk: `feedback_reports` had RLS policies but the SQL patch/schema did not grant Data API table privileges to the `authenticated` role, so REST insert/select can fail even when the table exists.
- Changed feedback inserts to `insert(...).select('id').single()` so the app treats submission as successful only after Supabase returns the created row id.
- Added a 12-second timeout and visible in-sheet error banner; failures now show the exact reason in the modal instead of only relying on a snackbar that can be hidden behind the bottom sheet. Typed text remains on failure for retry, and clears only on confirmed success.
- Updated `supabase/schema.sql` and `supabase/feedback_reports_patch.sql` with `grant usage on schema public to authenticated` and `grant select, insert on table public.feedback_reports to authenticated`.
- Verification passed: focused analyze, `./scripts/flutter-local.ps1 test --no-pub test/screens/feedback_report_sheet_test.dart test/data/repositories/feedback_repository_test.dart`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `24710`.

## 2026-05-15 Feedback Admin Inbox Checkpoint
- Added an operator feedback inbox for the official account `officialfluxstudio.kr@gmail.com`: when that account is logged in, Settings shows `신고함 열기` under the feedback section.
- The inbox loads `feedback_reports`, displays type/message/expected behavior/screen/user/time, and lets the operator move reports through `신규`, `확인 중`, `수정됨`, and `종료` states.
- Added `FeedbackReport` and `FeedbackReportStatus` models plus repository methods for admin fetch/status update, while keeping existing user report submission unchanged.
- Updated Supabase schema/patch RLS so normal users can still insert/select their own reports, and only the official email JWT can select all reports and update the `status` column.
- Reviewer found no blocking issues; the visible status-change snackbar wording was polished after review.
- Verification passed: focused analyze, focused feedback sheet/repository tests, `git diff --check`, `./scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `19894`.

## 2026-05-15 Feedback Admin Account Correction Checkpoint
- Separated the public support email from the private feedback admin login email.
- Kept `officialSupportEmail = officialfluxstudio.kr@gmail.com` for mailto/user-facing support copy.
- Added `feedbackAdminEmail = tught3@naver.com` and changed Settings admin-inbox visibility to use that account.
- Updated Supabase feedback report admin RLS policies in `schema.sql` and `feedback_reports_patch.sql` so only `tught3@naver.com` can select all reports and update report status.
- Verification passed: focused analyze, feedback sheet widget tests, `git diff --check`, debug APK build, ADB install, app launch, and PID check returned `26626`.

## 2026-05-15 Admin Gmail And Naver CalDAV Account Isolation Checkpoint
- Added `tught3@gmail.com` to the feedback admin account allow-list while keeping `officialfluxstudio.kr@gmail.com` as the public support email and `tught3@naver.com` as another private admin login.
- Updated `supabase/schema.sql` and `supabase/feedback_reports_patch.sql` feedback admin RLS policies so both private admin emails can select all feedback reports and update report status after the SQL patch is applied.
- Fixed Naver CalDAV local credential caching so `FlutterSecureStorage` keys are scoped by the current Supabase user id. This prevents one PlanFlow login account from seeing or migrating another account's Naver ID/app-password cache.
- Verification passed: focused analyze for settings/feedback/Naver CalDAV files, focused Naver credential and feedback sheet tests, `git diff --check`, debug APK build, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `22203`.

## 2026-05-15 Naver CalDAV App Password Visibility Checkpoint
- Changed the Naver CalDAV connection dialog so the `앱 비밀번호` field is visible while typing instead of being masked, because this is an app-specific password and visibility reduces input mistakes.
- Verification passed: focused settings screen analyze, `git diff --check`, debug APK build, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `28597`.

## 2026-05-15 Voice Delete Candidate Visible Section Checkpoint
- Investigated another screenshot where voice delete showed `2개 후보` diagnostics but the actual delete candidate cards were missing from the visible page.
- Reworked delete candidate rendering into a dedicated `_DeleteCandidateList` section that always groups the instruction text, selected-count delete bar, and every delete candidate row together when `_events` is non-empty.
- Strengthened the regression test so `2개 후보` must also render `voice-delete-candidate-list`, the delete instruction, selected-count bar, both candidate rows, and both individual delete buttons.
- Verification passed: focused analyze for `voice_action_screen.dart` and its test, focused delete-candidate widget test, `git diff --check`, debug APK build, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, and `adb shell pidof com.planflow.app` returned PID `10485`; `am start` returned Android code 10 while the app process was already running.

## 2026-05-15 Voice Delete Candidate Device Follow-up Checkpoint
- Pulled a device screenshot and confirmed the real screen still showed `2개 후보` diagnostics without candidate rows, so the issue is below candidate search and around widget rendering/runtime state.
- Added a device-visible render debug log for `_DeleteCandidateList` and changed delete candidate row/button keys to include list index plus event id, avoiding duplicate-key risk when imported/external events produce duplicated ids or repeated rows.
- Verification passed: focused analyze, focused delete candidate tests (including multi-select and two-candidate rendering), `git diff --check`, debug APK build, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am force-stop com.planflow.app`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `28229`.

## 2026-05-15 Voice Delete Candidate Resume Reload Checkpoint
- Confirmed via device screenshot/logcat that Android could keep showing a restored voice-delete screen with old candidate diagnostics and no candidate rows after an update, without running the new delete-candidate render branch.
- Added `WidgetsBindingObserver` to `VoiceActionScreen` so non-add voice action pages reload candidates whenever the app resumes. This refreshes restored edit/delete/query screens instead of leaving stale diagnostics-only UI.
- Added regression coverage for the restored delete screen resume path: listEvents is called again on resume and the delete candidate list is visible afterward.
- Verification passed: focused analyze, focused tests for delete candidates and resume reload, debug APK build, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am force-stop com.planflow.app`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app` returned PID `10366`.

## 2026-05-16 Voice Delete Candidate Stale Route Fix Checkpoint
- Fixed the persistent voice delete blank-candidate issue by giving `VoiceActionScreen` a route key based on `action + rawText`, preventing stale `/voice/action` route reuse from preserving old diagnostics-only state.
- Added `didUpdateWidget` handling in `VoiceActionScreen` so if raw text/action changes on the same State instance, candidate state, diagnostics, snapshot, and delete selections are cleared and candidates are reloaded.
- Added `_CandidateLoadSnapshot` so displayed diagnostics and rendered event cards come from the same immutable candidate load result, preventing `2개 후보` text from diverging from the candidate card list.
- Added a regression test for same-screen raw text updates and re-ran delete-candidate, restored-screen, and route-state focused tests. Reviewer found no blocking issues.
- Verification passed: focused analyze, focused voice action tests, reviewer full voice action test pass, `git diff --check`, debug APK build, `adb install -r -t --user 0`, launcher run via monkey, PID/current focus check for `com.planflow.app`.

## 2026-05-16 Voice Delete Candidate Unified Section Checkpoint
- Revisited the persistent real-device bug where voice delete showed `2개 후보` diagnostics but no candidate cards.
- Root cause class: candidate diagnostics/title and candidate card rendering could still diverge across separate branches/restored runtime state, similar to the previous map loading deadlock pattern.
- Replaced the split non-add candidate rendering with a single always-mounted `_VoiceCandidateSection` that owns the title, candidate count, loading/empty state, query/edit rendering, and delete rows together.
- Delete mode now renders candidate rows directly inside that section from the same `events` list used for the visible candidate count, and logs both section build and delete row rendering for device diagnosis.
- Strengthened voice action tests so `2개 후보` also requires the unified section, delete list, rows, per-row delete buttons, and no empty DB card.
- Reviewer agent returned PASS with no blocking findings.
- Verification passed: focused analyze, focused `voice_action_screen_test.dart`, reviewer rerun of the same test, `git diff --check`, debug APK build, ADB install, launcher run, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-16 Voice Delete Inline Candidate Failsafe Checkpoint
- User confirmed the real device still showed no visible schedule candidates after the unified candidate section fix.
- Added a fail-safe inline delete action strip immediately under the visible candidate count. When delete candidates exist, the screen now shows each candidate title plus a delete action at the top of the target section before the larger card/list body.
- This means even if the lower candidate card area is clipped, restored oddly, or otherwise not visible on a device, actual schedule names and delete buttons should still appear directly under `N개 후보`.
- Updated voice action tests to assert the inline fail-safe exists along with the existing delete list/cards/buttons and adjusted multi-select test scrolling for the taller layout.
- Reviewer agent returned PASS with no blocking findings.
- Verification passed: focused analyze, focused `voice_action_screen_test.dart`, reviewer rerun of focused test, `git diff --check`, debug APK build, ADB install, and PlanFlow process launch/PID check.

## 2026-05-16 Voice Delete Candidate Card Polish Checkpoint
- Fixed the real-device voice delete candidate layout where the `대상 일정` diagnostics and the first delete action visually overlapped.
- Replaced the red outlined inline delete buttons with PlanFlow-style tappable candidate cards that show the event title, KST date/time/location metadata, a subtle primary border, and a compact `삭제 확인` action cue.
- Preserved the existing candidate keys and whole-card tap-to-delete-confirm behavior, while keeping the lower multi-select delete list intact.
- Reviewer agent returned PASS with no blocking findings.
- Verification passed: focused analyze for `voice_action_screen.dart` and `voice_action_screen_test.dart`, full `voice_action_screen_test.dart` widget suite, `git diff --check`, debug APK build, ADB install, PlanFlow launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-16 Voice Delete Candidate Tap And Spacing Checkpoint
- Reworked the voice delete candidate area again after the real-device screenshot still showed header/candidate overlap and non-obvious tap behavior.
- The visible top candidate cards are now the single source of delete interaction: tapping a card opens the existing delete confirmation dialog, the per-card `삭제` button does the same, and the checkbox supports multi-select with `선택 삭제`.
- Added stronger vertical separation between `대상 일정`/candidate diagnostics and the first candidate card, limited diagnostics text to two lines with ellipsis, and removed the duplicate lower delete candidate list to avoid split UX.
- Updated the focused widget test to tap the visible candidate card and confirm deletion through the existing dialog.
- Reviewer agent returned PASS with no blocking findings.
- Verification passed: focused analyze, focused `voice_action_screen_test.dart`, `git diff --check`, debug APK build, ADB install, PlanFlow launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-16 Voice Delete Candidate Visual Polish Checkpoint
- Polished the voice delete candidate cards after user feedback that there were too many delete affordances and the styling felt bland.
- Removed the extra trash icon next to each checkbox, shortened the per-card action label from `삭제 확인` to `삭제`, and adjusted card background/border colors to better match PlanFlow's white schedule-card style with primary-faint borders and clearer selected state.
- Preserved card tap deletion, per-card delete button, checkbox multi-select, and selected-delete behavior.
- Reviewer agent returned PASS with no blocking findings.
- Verification passed: focused analyze, focused `voice_action_screen_test.dart`, debug APK build, ADB install, PlanFlow launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-16 Smart Prep And Departure Alarm Recalculation Checkpoint
- Centralized smart preparation/departure alarm recalculation in `ManualEventSideEffectService` so schedule save/delete and calendar sync share one alarm recalculation path.
- Remaining future events are now recalculated after saves, deletes, and calendar sync; the first location-backed external event for each day gets the smart preparation alert, so a newly-added earlier location event moves the prep alarm earlier, while a place-less earlier event does not steal it.
- Departure alarms are cancelled before rescheduling and stale `eventId:departure` alarms are also cancelled when synced events move to the past, outside the monitoring window, or outside the upcoming window.
- Voice delete cleanup now passes the resolved `userId` into side-effect cleanup so delete-driven recalculation works in the same user context.
- Review loop found and fixed stale departure cases in calendar sync, delete user-id propagation, and empty-upcoming cancellation; final reviewer returned PASS with no blocking findings.
- Verification passed: focused analyze, focused service/voice tests, `git diff --check`, debug APK build, ADB install, launcher run, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-16 Home Recent Past Events Checkpoint
- Changed the Home past-events header so the right-side action opens a recent-past modal instead of implying only the single visible past card.
- Home still shows the latest past schedule card inline, and tapping that card opens its detail page; tapping `최근 12시간` opens a draggable bottom sheet listing every event that ended in the last 12 hours.
- Updated the empty-today card so the calendar icon and `오늘 일정 안내` title sit on the same row.
- Updated the PRO early-bird helper text to `현재 어플이 마음에 드신다면 사전 신청해주세요.`
- Added a regression test for the 12-hour recent-past filter.
- Verification passed: focused analyze, focused recent-past test, debug APK build, ADB install, launcher run, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-16 Early Bird Copy And Storage Checkpoint
- Updated the PRO early-bird helper text in both the Home banner and the reusable signup card to `현재 어플이 마음에 드신다면 사전 신청해주세요. 유료모델 전환때 특별한 혜택을 드립니다.`
- Confirmed the email submission flow still normalizes and validates the email locally, then submits it through the Supabase RPC gateway `submit_early_bird_email`; it is not just a UI-only state change.
- Verification passed: focused analyze, focused early-bird repository/card tests, and the existing RPC-backed repository test continues to prove the save path persists through the gateway layer.

## 2026-05-16 Calendar Resume Sync Reliability Checkpoint
- Changed app pause handling so background calendar sync no longer reuses the foreground session/route/ICS flow; it now performs a quiet calendar-only best-effort sync.
- Changed calendar auto-sync throttling to rely on the last completed summary timestamp, while storing `calendar_sync:last_started_at` separately for diagnostics. This prevents an unfinished background attempt from blocking the next resume sync.
- Added a process-wide in-flight guard for calendar auto-sync so app-level and shell-level lifecycle hooks do not run overlapping sync jobs through separate service instances.
- Home keeps already-rendered schedule content visible during resume refresh, and its regression test now uses injected fakes instead of swallowing SharedPreferences/Supabase setup errors.
- Verification passed: `./scripts/flutter-local.ps1 analyze --no-pub`, focused calendar/home tests, `git diff --check`, debug APK build, ADB install, app launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-17 Briefing Secretary Tone Checkpoint
- Updated the OpenAI morning/evening briefing prompts so important schedules are introduced before the schedule sentence with phrases like `중요한 일정입니다.` instead of ending awkwardly with `중요`.
- Reworked local fallback briefing text to speak like a secretary: greeting, schedule count, first/next schedule transitions, spoken Korean times, optional location, and critical-event lead-ins.
- Updated GPT prompt tests and added fallback execution coverage for critical-event secretary wording.
- Verification passed: focused analyze, focused GPT/briefing scheduler tests, `git diff --check`, debug APK build, ADB install, app launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-17 Voice Edit Candidate Precision Checkpoint
- Tightened voice edit candidate ranking so date/time-like tokens such as `13일`, `5월`, or `9시` do not score title matches, and numeric tokens no longer use fuzzy/prefix matching. This prevents unrelated schedules like `15일 구독갱신` from appearing just because the requested date sounds numerically close.
- Changed voice edit `바로 저장` success navigation from returning to the previous screen to opening the calendar tab directly.
- Added regression coverage for the screenshot-style `5월 13일 팀장 동행방문` case and for direct-save calendar navigation.
- Verification passed: focused analyze, full `voice_action_screen_test.dart`, `git diff --check`, debug APK build, ADB install, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-17 Voice Edit Date And Similarity Checkpoint
- Refined voice edit/delete candidate filtering so absolute date mentions such as `5월 13일` constrain candidates to that exact local date, while title/location/memo/supplies similarity must also match when the command includes target content.
- Kept relative/new-change phrases like `이번 주 목요일 오전 9시로 변경` from incorrectly acting as the original-event date filter, preserving existing edit flows.
- Added regression coverage for cases where content matches but date differs, and where date matches but content does not.
- Verification passed: focused analyze, full `voice_action_screen_test.dart`, `git diff --check`, and debug APK build. ADB install/run check was attempted but no device/emulator was connected at that moment.

## 2026-05-17 Critical Alarm Distinction Checkpoint
- Made important alarms visibly distinct from normal reminders by forcing critical notification titles to start with `중요 알람`, adding an urgent multi-line body that repeats the event title, and using expanded Android big-text styling.
- Strengthened the critical Android notification presentation with red colorization, LED settings, non-auto-cancel behavior, and a longer vibration pattern while preserving exact alarm and full-screen intent scheduling.
- Device permission check confirmed `POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM`, `VIBRATE`, and manifest `USE_FULL_SCREEN_INTENT` are granted/declared; app-ops still reports `USE_FULL_SCREEN_INTENT: default/reject`, so lock-screen full-screen popup behavior depends on the phone's manual PlanFlow full-screen notification setting.
- Verification passed: focused analyze, focused notification/departure/manual side-effect tests, `git diff --check`, debug APK build, ADB install, app launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-17 Full-Screen Alarm Consent Checkpoint
- Added Android native full-screen intent permission status checking through the PlanFlow settings method channel, using `NotificationManager.canUseFullScreenIntent()` on Android 14+ and treating older Android versions as already supported.
- Added a dedicated `전체 화면 알림` onboarding permission tile and included it in the `필요 권한 모두 요청` flow so users are sent to the Android consent screen during first setup.
- Updated event editing so enabling `강한 알림으로 예약` immediately shows a rationale dialog and opens the full-screen notification consent screen; saving a critical event also re-checks the consent path.
- Verification passed: focused analyze, focused onboarding/event-edit/notification/manual side-effect tests, `git diff --check`, debug APK build, ADB install, app launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`. Device app-ops still showed `USE_FULL_SCREEN_INTENT: default/reject` before manual consent.

## 2026-05-17 Critical Alarm Toggle Permission Bundle Checkpoint
- Expanded the event edit `강한 알림으로 예약` toggle flow so it checks and requests the full critical-alarm permission bundle: app notifications, exact alarms, and full-screen notifications.
- The rationale dialog now explains all three required permissions instead of only full-screen notifications, and the save path reuses the same bundle check for critical events.
- Updated the event edit widget regression so toggling a critical alarm proves notification, exact-alarm, and full-screen permission requests are all attempted.
- Verification passed: focused analyze, focused onboarding/event-edit/notification tests, `git diff --check`, debug APK build, ADB install, app launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-17 Critical Alarm Sound Checkpoint
- Added a dedicated Android raw WAV resource `planflow_critical_alarm.wav` for important alarms, using a short multi-tone pattern so users can distinguish it from normal schedule reminders by sound.
- Moved the critical notification channel from `critical_alarms` to `critical_alarms_v2` because Android preserves an existing channel's sound settings after creation; the new channel lets the custom sound apply on upgraded installs.
- Wired `RawResourceAndroidNotificationSound('planflow_critical_alarm')` into critical alarm notifications while keeping the alarm audio usage, max importance, full-screen intent, stronger vibration, and visual styling.
- Verification passed: focused analyze, notification/manual/departure tests, `git diff --check`, debug APK build, APK resource inspection showing `res/raw/planflow_critical_alarm.wav`, ADB install, app launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-17 PlanFlow Split Logo Checkpoint
- Added a shared `PlanFlowLogo` widget styled after the FinFlow reference: bold wordmark, `Plan` in the existing PlanFlow blue and `Flow` in near-black.
- Replaced the Home header wordmark and the Calendar/Settings app-bar titles with the shared logo so all main tabs show the same branded wordmark.
- Added a widget regression test that locks the split text, colors, heavy weight, and zero letter spacing.
- Verification passed: focused analyze, logo/home/calendar/settings tests, `git diff --check`, debug APK build, ADB install, app launch, PID check, and focused window check showing `com.planflow.app/.MainActivity`.

## 2026-05-17 OpenAI Key Connector Setup Checkpoint
- Created a project-specific OpenAI API key named `PlanFlow Codex` through the OpenAI Platform connector and wrote it locally to ignored `.env.local` as `OPENAI_API_KEY` without printing the key value.
- Replaced the existing `.env` OpenAI key value with a placeholder and confirmed both `.env` and `.env.local` are ignored and untracked.
- Synced `.env.local` to Supabase Edge Function secrets for project `xqvvfnvmytjlblcngipn`, so `openai-proxy` uses the connector-created key.
- Updated env documentation and the older Codex prompt to direct OpenAI keys to ignored `.env.local` plus Supabase secrets, and ignored Supabase CLI `.temp` metadata.
- Verification passed: tracked-file secret scan found no OpenAI key patterns, `openai-proxy` smoke request returned HTTP 200 without `missing_openai_api_key`, and `git diff --check` passed.

## 2026-05-17 Voice Ambiguous Add And STT Dedupe Checkpoint
- Added a voice-input confirmation sheet for ambiguous field-addition phrases like `장소 추가`, with choices for updating an existing event, creating a new event, or editing the recognized text.
- Added submit guarding so STT completion and manual submit cannot route the same transcript twice, and tightened Android STT segment merging so rapid restarts do not duplicate overlapping speech.
- Updated voice command routing and direct-save edit handling so `내일 오전 10시에 교보생명 시험 일정에 원주 교보생명빌딩으로 장소 추가` targets the existing event and applies only the location change.
- Verification passed: focused router/STT/voice input/voice action tests, `scripts/flutter-local.ps1 analyze`, `git diff --check`, debug APK build, ADB install, app launch, and PID check showing `com.planflow.app` running.

## 2026-05-17 Feedback Badge And Location Add Correction Checkpoint
- Added a manager-only new-report badge beside `신고함 열기`; it counts `feedback_reports` rows with `status = new`, refreshes on admin auth changes, and refreshes again after closing the admin inbox.
- Corrected voice location-add edits so the target phrase before `일정에` is used only to find the existing event, while the phrase after it becomes the new location. Location-add edits no longer infer or apply a time/date change and now open the edit screen with the location prefilled instead of direct-saving.
- Added regression coverage for `내일 오후 1시에 실매출 확인 일정에 원주 세브란스 기독병원 장소 추가해줘`, proving the `실매출 확인` event is selected, the original start time is preserved, and the hospital is applied as location text.
- Verification passed: feedback repository/sheet tests, settings screen tests, router/voice action tests, `scripts/flutter-local.ps1 analyze`, `git diff --check`, debug APK build, ADB install, app launch, and PID check showing `com.planflow.app` running.

## 2026-05-17 Voice Command Pipeline Checkpoint
- Added a central `VoiceCommandPipeline` that turns voice text into a structured plan: intent, target text, change text, target query, requested fields, field values, confidence, user-choice requirement, and direct-apply safety.
- Routed `VoiceCommandRouter` through the pipeline so add/edit/delete/query decisions share the same target/change split rules, including location-add and date-time-change phrases.
- Updated `VoiceActionScreen` to use pipeline target text for candidate date filtering, pipeline change text for requested new times, pipeline field values for location edits, and pipeline safety flags before showing `바로 저장`.
- Tightened delete commands with no explicit target so they keep an empty search query and show selectable candidates instead of searching for leftover words like `줘`.
- Verification passed: focused pipeline/router/STT/voice input/voice action tests, full `scripts/flutter-local.ps1 analyze`, `git diff --check`, debug APK build, ADB install, launch, PID, and focused window check for `com.planflow.app/.MainActivity`.

## 2026-05-17 Voice Location Coordinate Resolution Checkpoint
- Updated voice location-add/edit flow so selecting a candidate event resolves the requested new place through `LocationLookupService` before opening the edit screen.
- The edit screen now receives an `EventModel` with `locationLat`/`locationLng` when lookup succeeds, so saving preserves real map coordinates for smart preparation and departure alarm calculations.
- If lookup fails or returns no result, the voice flow keeps the requested location text and tells the user to verify the exact map position before saving.
- Added regression coverage proving `내일 오후 1시에 실매출 확인 일정에 원주세브란스기독병원 장소 추가해줘` opens edit with the resolved place coordinates and does not directly save.
- Verification passed: focused voice pipeline/router/action tests, full `scripts/flutter-local.ps1 analyze`, `git diff --check`, debug APK build, ADB install, launch, PID, and focused window check for `com.planflow.app/.MainActivity`; reviewer returned PASS with no blockers.

## 2026-05-17 Naver CalDAV Background Sync Guidance Checkpoint
- Added background-sync guidance in the Naver CalDAV import/progress flow so users are told the sync keeps running even if they send the app to the background.
- Added a slower widget-test path so the progress dialog stays open long enough to verify the guidance text while sync is active.
- Verification passed: `scripts/flutter-local.ps1 test --no-pub test/screens/settings_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n com.planflow.app/.MainActivity`, `adb shell pidof com.planflow.app`.

## 2026-05-19 Voice Relative-Day Preservation Checkpoint
- Updated voice parsing so later relative-day words like `내일` are preserved when they appear after an earlier explicit time cue such as `오늘 오후 2시`.
- Tightened both GPT fallback parsing and local voice analysis title derivation to use the same cue-aware relative-day preservation logic.
- Adjusted regression coverage to verify the start time stays on the earlier explicit cue while the later relative-day wording remains visible in the title.
- Verification passed: `scripts/flutter-local.ps1 test --no-pub test/services/gpt_service_test.dart --plain-name "fallback parsing preserves later relative-day content after an earlier time cue"`, `scripts/flutter-local.ps1 test --no-pub test/services/voice_command_analysis_service_test.dart --plain-name "preserves later relative-day wording after an earlier time cue"`, and `scripts/flutter-local.ps1 analyze --no-pub`.

## 2026-05-19 Session Restore Stability Checkpoint
- Reduced login flicker risk by making the initial auth bootstrap trust the restored Supabase snapshot instead of forcing an immediate refresh on startup.
- Added a small auth-session interface so `AuthProvider` can be tested without a live Supabase instance.
- Preserved the existing signed-in user when a refresh attempt fails during session sync, instead of immediately clearing auth state.
- Added provider tests for restored-session startup and refresh-failure preservation, and verified the login screen still renders correctly.
- Verification passed: `scripts/flutter-local.ps1 test --no-pub test/providers/auth_provider_test.dart`, `scripts/flutter-local.ps1 test --no-pub test/screens/login_screen_test.dart`, and `scripts/flutter-local.ps1 analyze --no-pub`.

## 2026-05-19 Voice People Fields Checkpoint
- Added structured people fields to events: `participants`, `companions`, and `targets`, with schema/model/repository serialization and preservation across edit, calendar, Naver, voice, and preparation copy paths.
- Updated GPT and local voice analysis so person words like `팀장님` remain in the visible title and are also stored in the appropriate people field instead of being dropped.
- Preserved existing people fields during external-id upserts when imported calendar rows do not carry those fields, preventing device-calendar re-sync from clearing PlanFlow-only people metadata.
- Verification passed: focused model/voice/GPT/analysis/device-calendar/calendar-sync/Naver-CalDAV tests, `scripts/flutter-local.ps1 analyze --no-pub`, debug APK build, and reviewer re-check returned `100% 통과`; full `scripts/flutter-local.ps1 test --no-pub` hit the 10-minute command timeout before completion.

## 2026-05-19 Voice People Fields Simplification Checkpoint
- Simplified the event people structure by removing the separate `companions` field from the Flutter model, voice parsing contract, tests, and schema source of truth.
- Voice/direct input now stores 함께 가는 사람 expressions like `김대리랑`, `팀장님과`, and `동행` in `participants`; `targets` remains only for action recipients such as `원장님께 보고`, `팀장님한테 전화`, or `전달/문의/확인`.
- Updated backup restore SQL so `participants` and `targets` survive restore; no live `drop column` was added, so existing databases that already have `companions` keep it harmlessly unused.
- Verification passed: focused model/voice/GPT/analysis tests, device-calendar/calendar-sync/Naver-CalDAV tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build; ADB had no connected devices for install/run.

## 2026-05-19 Release Signing And Smart Travel Alarm Checkpoint
- Created a local PlanFlow release/upload signing setup with ignored `android/app/planflow-release.jks`, ignored `android/key.properties`, and an encrypted ignored signing archive under `android/signing/`; no signing secrets are tracked.
- Added `docs/planflow-signing.md`, `scripts/restore-planflow-signing.ps1`, and `scripts/adb-install-update.ps1` so another PC restores the same key and device checks use `adb install -r` without clearing app data.
- Updated smart preparation side effects so event save, resync, recalculation, and delete cleanup pass user prep offsets and `travelMode`; route estimates use current/event coordinates through map APIs and fall back to 30 minutes with logged reasons when location data is unavailable.
- Verification passed: focused manual side-effect and voice-action tests, `scripts/flutter-local.ps1 analyze --no-pub`, debug APK build, release appbundle build, APK signing certificate check. Device update install was attempted with `adb install -r` and correctly stopped on `INSTALL_FAILED_UPDATE_INCOMPATIBLE` because the installed package is still signed with the old Android Debug key.

## 2026-05-19 Release Signing Device Transition Checkpoint
- Rebuilt debug APK and release AAB with the fixed PlanFlow release certificate and confirmed the APK signer is `CN=PlanFlow, OU=FluxStudio, O=FluxStudio, L=Seoul, ST=Seoul, C=KR` with SHA-256 `b3f2289851b78881263ca939fc09181efc310152828dd700fab7c552bef9a231`.
- Confirmed the device had the old Android Debug certificate, then performed the one-time `adb uninstall com.planflow.app` transition only for the PlanFlow package and installed the release-signed APK.
- Re-ran `scripts/adb-install-update.ps1` after the transition; update install succeeded without clearing app data, proving future local builds with the same release key update normally.
- Copied the encrypted signing backup to `C:\Users\tught\OneDrive\PlanFlow Signing Backup\PlanFlow-signing-keys.zip.aes`; the archive password was not copied with it.
- Verification passed: debug APK build, release AAB build, installed APK signature check, update-install recheck, app launch, PID check, and Gradle daemon closeout.

## 2026-05-19 Codex Prompt Sync Checkpoint
- Hardened Android signing setup so the Gradle build now fails fast if `android/key.properties` is missing or the release keystore path is blank, which keeps the release bootstrap honest on new PCs.
- Added `android:allowBackup="false"` to the manifest, swapped the splash title to `PlanFlowLogo(fontSize: 30)`, and made local Naver CalDAV secure storage explicit with Android encrypted shared preferences.
- Updated smart preparation side effects so missing destination coordinates are geocoded from location text before route estimation, with current-location fallback order preserved and new regression coverage for both the geocode and splash paths.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 test test/services/manual_event_side_effect_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/screens/splash_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `scripts/flutter-local.ps1 build appbundle --release --no-pub`, `scripts/planflow-release-bootstrap.ps1 -SkipRestore -SkipBuild -SkipInstall -SkipLaunch`, `scripts/adb-install-update.ps1`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app`.

## 2026-05-20 Location Fallback Completion Checkpoint
- Extended the geocoding fallback so when `location` is empty, `title` and `memo` are tried as conservative secondary queries before smart preparation gives up, which lets title-only place names still resolve coordinates for save-time preparation and alarm routing.
- Kept the fallback order conservative by still preferring explicit `location` and explicit coordinates first, then trying title and memo-derived queries only when needed.
- Added regression coverage for title-only destination resolution in both the save/preparation path and the manual smart-preparation path.
- Verification passed: `scripts/flutter-local.ps1 test test/services/manual_event_side_effect_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/event_preparation_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `scripts/adb-install-update.ps1`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app`.

## 2026-05-20 Device Calendar People Field Preservation Checkpoint
- Hardened external import syncing so device-calendar relinks and external metadata attachment keep `participants` and `targets` from the existing PlanFlow event instead of letting blank incoming arrays silently clear them.
- Added a regression test proving a reflected device-calendar duplicate preserves `participants` and `targets` when it relinks to an existing manual event.
- Verification passed: `scripts/flutter-local.ps1 test test/data/repositories/event_repository_external_import_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/device_calendar_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/manual_event_side_effect_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/event_preparation_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `scripts/adb-install-update.ps1`, `adb shell am start -n com.planflow.app/.MainActivity`, and `adb shell pidof com.planflow.app`.

## 2026-05-20 Database Backup Automation Checkpoint
- Added an operations runbook and PowerShell scripts for whole-database backups: `scripts/planflow-db-backup.ps1` creates compressed Postgres dumps and optionally restores them into a separate backup DB; `scripts/register-planflow-db-backup-task.ps1` registers a daily Windows scheduled task.
- Added ignored local config path `env/db-backup.local.json` plus `env/db-backup.example.json`; database URLs and passwords stay out of Git.
- Confirmed the PlanFlow Supabase project `xqvvfnvmytjlblcngipn` is active and read the current `auth`, `public`, and `storage` table list without changing DB schema/RLS.
- Verification passed: PowerShell syntax checks for both backup scripts and `git diff --check`. Actual backup execution is blocked until `env/db-backup.local.json` contains production and backup DB connection strings plus PostgreSQL client tools are installed.

## 2026-05-20 In-Project Supabase Backup Checkpoint
- Added and applied `supabase/in_project_backup.sql`, creating the `backup` schema, `backup.daily_snapshots`, snapshot/prune/restore helper functions, and a Supabase `pg_cron` job named `planflow-daily-in-project-backup`.
- The cron schedule is `30 18 * * *` UTC, which runs at 03:30 KST daily. A first `manual_initial` snapshot and today's `automatic` snapshot were created successfully.
- Current automatic snapshot counts confirmed: users 4, events 474, reminders 61, pre_actions 42, voice_logs 31, location_history 14, user_settings 3, calendar_connections 4, user_backups 18, feedback_reports 2, early_bird_emails 0, user_behavior_logs 0.
- Updated `supabase/schema.sql` and `docs/database-backup-runbook.md` so the in-project backup path is the active backup method, with external `pg_dump` backups documented as an optional later layer.

## 2026-05-20 Feedback Admin Inbox RLS Checkpoint
- Fixed the live Supabase feedback admin policies so both app-admin emails, `tught3@naver.com` and `tught3@gmail.com`, can select and update feedback report statuses.
- Updated local feedback SQL sources so status updates also grant `updated_at`, matching the `feedback_reports_set_updated_at` trigger that runs during status changes.
- Added `supabase/feedback_reports_admin_policy_fix.sql` and a schema regression test to keep future feedback SQL patches aligned with the app admin list.
- Verification passed: Supabase policy and column privilege queries, `scripts/flutter-local.ps1 test test/supabase/feedback_reports_schema_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/screens/feedback_report_sheet_test.dart --no-pub`, and `scripts/flutter-local.ps1 analyze --no-pub`.

## 2026-05-20 Dynamic Departure Alarm Checkpoint
- Changed smart preparation behavior for external/place events to departure-only scheduling with a user setting `departure_safety_margin_min` (10/20/30 minutes, default 20) and applied the live Supabase `public.user_settings` column patch.
- Departure alarms now refresh from the current/last known location on app start, resume, auth changes, save/delete resyncs, and periodic monitor runs; monitor cadence is 30 minutes normally and 15 minutes when an event is within 6 hours.
- Travel-time routing now uses `MapService` first, so car mode prefers Tmap, transit mode prefers Naver, and Google/heuristic estimates are fallback paths.
- Verification passed: focused settings, voice action, departure alarm, smart preparation, travel time, manual side-effect, event preparation, calendar auto-sync, model/repository/schema tests; `scripts/flutter-local.ps1 analyze --no-pub`; live Supabase column query; debug APK build; install/run on `192.168.0.102:5555`; release AAB build at `build/app/outputs/bundle/release/app-release.aab`.

## 2026-05-20 Home Widget UX Checkpoint
- Reworked the five Android home widgets around clearer roles: next action, today's timeline, monthly density, weekly summary, and a compact 1x1 voice entry widget.
- Updated widget styling to the PlanFlow blue/white tone, added small voice chips, distinct critical-event badges/colors, departure/travel/countdown labels, and monthly/weekly count/critical metadata.
- Extended `HomeWidgetService` and event/voice update paths so widget data includes critical flags, monthly counts, weekly counts, and stale optional widget values are cleared.
- Verification passed: `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.102:5555 install -r -t --user 0 build\app\outputs\flutter-apk\app-debug.apk`, `adb -s 192.168.0.102:5555 shell am start -n com.planflow.app/.MainActivity`, and `adb -s 192.168.0.102:5555 shell pidof com.planflow.app`.

## 2026-05-20 Home Widget Calendar Refinement Checkpoint
- Refined the Android home widgets after device UX review: the 1x1 voice widget now uses a clear mic icon, today's widget separates recent past/today/tomorrow sections, weekly view is a 7-column board, and monthly view is a 42-cell calendar layout with event titles and overflow counts.
- Centralized home-widget schedule payload generation so save/edit/delete/voice refresh paths use the full event list rather than only upcoming events, preserving past-today, tomorrow fallback, weekly, monthly, and multi-day/ongoing event visibility.
- Verification passed: `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.102:5555 install -r -t --user 0 build\app\outputs\flutter-apk\app-debug.apk`, `adb -s 192.168.0.102:5555 shell am start -n com.planflow.app/.MainActivity`, and `adb -s 192.168.0.102:5555 shell pidof com.planflow.app`.

## 2026-05-21 Widget Compact UI & 월간 위젯 Fallback Checkpoint
- Android 1x1 마이크 위젯의 벡터/레이아웃을 보강해 작은 크기에서도 파란 배경 안의 흰색 마이크가 선명하게 보이도록 버튼 크기·패딩·텍스트를 조정했습니다.
- 주간 위젯은 7열 레이아웃은 유지하면서 `appwidget` 최소 높이와 패딩/상단 마진을 줄여 전체 높이 피트를 축소했습니다.
- 월간 위젯 바인딩에서 Flutter가 월 데이터(payload)를 저장하기 전에도 42칸 달력을 구성하도록 Kotlin fallback 로직을 추가했습니다. 현재 월 기준(서울 타임존) 첫 날 정렬 기준으로 날짜와 inMonth를 계산해 `month_cell_1~42_day/in_month` 를 채우고, 이벤트 텍스트는 payload 없을 때 숨기고 기본 제목도 날짜 기준으로 구성합니다.
- 검증: `node scripts/gsd-context-hygiene.mjs`, `.\gradlew :app:processDebugResources`(android), `git diff --check`.

## 2026-05-21 Home Widget Live Refresh Follow-up
- Made the 1x1 mic widget more recognizable by using a clear white microphone vector in a larger blue circular button.
- Reduced the weekly widget default height to keep the horizontal 7-day board compact.
- Added a monthly-widget Kotlin fallback so dates are visible even before Flutter has saved month-cell payload data.
- Added a HomeScreen-driven widget refresh path so real app events are written to home widgets on fresh app load/resume/event refresh, while cached UI data is not allowed to overwrite widget payloads.
- Verification passed: focused home widget and home screen tests, analyze, git diff check, debug APK build, reviewer PASS, and install/launch/PID check on 192.168.0.102:5555.

## 2026-05-21 Voice Name Target Preservation Checkpoint
- Expanded voice people-field parsing without hardcoding specific names: name-like Korean tokens near recipient particles or contact/question verbs now become `targets`, while companion particles remain `participants`.
- Added safeguards so common place/work words such as hospitals, meetings, documents, and projects are not promoted into people fields; date-context STT `모래` is normalized to `모레` only when schedule wording is present.
- Hardened voice confirm saving so successful event writes are no longer reported as failures if post-save settings lookup fails, and added legacy Supabase payload fallback for live `events` tables that do not yet expose `participants`/`targets`.
- Verification passed: focused voice structure/analysis/GPT tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/run on `192.168.0.102:5555`, and reviewer checks.

## 2026-05-21 Voice Conversation Mode Checkpoint
- Added the first AI schedule conversation mode entry from the voice input screen, routed through `/voice/conversation`, with a chat-style screen that can query schedules, keep session-local visible events, resolve follow-up references, open edit with resolved location coordinates, and require confirmation before delete.
- Extended `VoiceConversationController` with duplicate-time ambiguity handling so commands like “오후 3시 일정 삭제” do not pick the first event when multiple visible events match the same time.
- Hardened the conversation screen around STT lifecycle and delete confirmation: active listening is canceled on dispose, STT completion checks `mounted`, and UI delete confirmation clears pending state before deleting.
- Verification passed: `scripts/flutter-local.ps1 test test/services/voice_conversation_controller_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, reviewer re-check PASS, install on `192.168.0.102:5555`, app launch, and PID check.

## 2026-05-21 Auth Update Session Restore Checkpoint
- Confirmed on device `192.168.0.102:5555` that PlanFlow installs are true updates: `firstInstallTime` stayed `2026-05-19 21:43:41` while `lastUpdateTime` changed, so app data was not cleared by `adb install -r`.
- Fixed the login flash/session-loss perception by making `AuthProvider` wait briefly for Supabase's delayed auth recovery event before marking the initial session as resolved with no user.
- Added a provider regression proving a delayed `tokenRefreshed` auth event restores the user before the app is considered signed out.
- Verification passed: `scripts/flutter-local.ps1 test test/providers/auth_provider_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, `adb install -r -t --user 0`, app launch, PID check, and logcat confirmation of `AuthChangeEvent.tokenRefreshed user=...`.

## 2026-05-21 Home Widget Deep Link & Voice Launcher Checkpoint
- Added `planflow://voice-launcher`, `planflow://voice?autoStart=1`, `planflow://voice-conversation?autoStart=1`, `planflow://calendar?date=YYYY-MM-DD`, and `planflow://event/{eventId}` routing from Android home widgets into the right PlanFlow screens.
- Added a Korean voice launcher screen so the 1x1 mic widget opens a choice between schedule voice input and AI schedule conversation, then auto-starts STT in the selected flow.
- Extended home-widget payloads with event IDs and date keys, fixed the local-day tomorrow fallback, and added monthly-cell fallback linking so existing widgets remain clickable after update.
- Refined widget styling around the blue/white PlanFlow tone, including a clearer 1x1 microphone widget with an `음성입력` label.
- Verification passed: home-widget route, voice launcher, calendar deep-link, and home-widget service focused tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; install and launch/PID check on `192.168.0.102:5555`; separate reviewer pass after fixes.
## 2026-05-21 Today Widget Tomorrow Visibility Fix
- Fixed the today home-widget payload so tomorrow events are always saved to `tomorrow_event_1/2`, even when there are remaining events today.
- Updated the home-widget service regression tests so tomorrow events stay visible alongside today-upcoming and ongoing multi-day events.
- Verification passed: `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Today Widget Shared Slot Priority Fix
- Changed the today widget policy from fixed `today 4 + tomorrow 2` slots to a shared 6-row display: today-upcoming fills first, and tomorrow events only fill leftover rows.
- Added Android today rows 5 and 6, hides the tomorrow section when no tomorrow rows are shown, and preserves event deep links for all six today rows.
- Added regression coverage for 0/1/4/5/6/8 today-event scenarios, including the `오늘 일정 N개 더` overflow row.
- Verification passed: `scripts/flutter-local.ps1 test test/services/home_widget_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.
## 2026-05-21 Voice Conversation Blank Screen Fix
- Restored Flutter render-error visibility by calling `FlutterError.presentError` before Crashlytics recording and logging uncaught platform errors to `debugPrint`.
- Stabilized `VoiceConversationScreen` layout by moving the conversation input bar into `Scaffold.bottomNavigationBar`, keeping the message list in the body, and replacing the constrained `SwitchListTile` input header with a finite `Row` layout.
- Added mobile-size widget coverage for the base conversation UI and initialText schedule-card rendering with an injected repository, while preserving the production Supabase/auth guard for live data.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/voice_conversation_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/run on `192.168.0.102:5555`, PID check, and logcat check for Flutter/render errors.

## 2026-05-21 Voice Conversation Loading And Ordinal Location Fix
- Added a visible assistant-side loading bubble and bottom status text `AI 문맥 분석중이에요...` while a follow-up voice/text command is being interpreted and routed.
- Fixed follow-up location parsing so ordinal target particles such as `4번에` are removed from the location payload; `4번에 강릉 건도리횟집 장소추가` now targets the 4th visible event and stores only `강릉 건도리횟집` as the location text.
- Verification passed: focused voice conversation controller and screen tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Event Edit Expansion Scroll And Voice Stop Fix
- All collapsible event-edit sections now auto-scroll into view after expansion: `방문 목표 · 반복 설정`, `설명 · 준비물`, and `알림 옵션`.
- Voice input and AI conversation flows now stop active STT before navigating into event edit/confirm routes, so editing starts without background listening or keep-listening restarts.
- Verification passed: focused event edit, voice conversation, and voice input screen tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 Auth Persistence And Social Login Cleanup
- Supabase auth initialization now uses a PlanFlow-owned local storage key with secure-storage backup and legacy Supabase key migration, so newly saved sessions survive app restart/update paths consistently.
- Background isolate Supabase initialization now uses the same auth options as the main app, avoiding mismatched session storage between alarms/sync jobs and the foreground app.
- Naver calendar missing-permission guidance now routes to Settings for CalDAV ID/app-password setup instead of relaunching OAuth, and settings shows a provider label such as 네이버 로그인됨 when a social account has no email.
- Kakao OAuth scopes now use comma-separated OIDC/profile-only scopes and still avoid account_email; Kakao/Supabase console must also allow emailless Kakao users or enable the Kakao email consent item.
- Verification passed: focused auth/storage/settings tests, scripts/flutter-local.ps1 analyze --no-pub, git diff --check, debug APK build, install -r and launch/PID check on 192.168.0.102:5555.

## 2026-05-21 Naver Login Reprompt And Account Diagnostics
- Naver OAuth now has an explicit recheck path that keeps normal login unchanged but can launch with `auth_type=reprompt` when the user needs to force the Naver consent/simple-signup screen again.
- AuthProvider now derives social account display data from `user.email`, `userMetadata`, and `identities`, logs non-token social profile diagnostics, and flags social sessions that lack email/name/identity info.
- Settings now shows the provider separately, displays the best available social account identifier instead of only "로그인됨", and offers "네이버 계정 정보 다시 확인" for Naver sessions.
- The Naver calendar guidance dialog keeps login and CalDAV sync separate and places `나중에` / `설정으로 이동` actions on one row.
- Verification passed: focused auth/settings tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-21 OAuth Browser Return Loading Guard
- LoginScreen now observes app resume while an OAuth login is pending; if the browser/Naver flow returns without a callback session, the email-login spinner is cleared and a Korean retry message points the user to the PlanFlow browser-return permission.
- If a session is already present on resume, the login screen syncs the current Supabase session instead of staying in the pending external-browser state.
- Settings account display now keeps a single primary login-status row and shows the social provider as secondary text, avoiding the appearance of two separate logins.
- Verification passed: focused login/settings/auth provider/auth service tests and `scripts/flutter-local.ps1 analyze --no-pub`.

## 2026-05-21 OAuth In-App Browser Launch Fix
- Changed OAuth login launch mode from Android external browser handoff to `LaunchMode.inAppBrowserView`, reducing Samsung Browser "app opens browser blocked" interruptions during Naver/Kakao auth.
- Lengthened the OAuth resume guard delay so PlanFlow does not show the incomplete-auth warning while the browser permission/interstitial handoff is still settling.
- Confirmed on `192.168.0.102:5555` that `planflow://auth-callback` resolves to `com.planflow.app.MainActivity`.
- Verification passed: focused auth service and login screen tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install on `192.168.0.102:5555`, app launch, and PID check.

## 2026-05-21 Naver OAuth WebView Bypass
- Added a Naver-only OAuth WebView route so Naver login no longer launches through Samsung Browser/Custom Tabs, while Kakao and Google keep their existing OAuth launch behavior.
- The WebView intercepts `planflow://auth-callback` internally and hands it to the shared OAuth callback/session exchange flow; non-web app-intent navigations are blocked with Korean guidance to use Naver ID login inside the page.
- Settings' Naver account recheck path now uses the same WebView route with `forceConsent=1` instead of opening the external browser flow.
- Verification passed: focused auth service, login screen, and Naver OAuth WebView flow tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; install/launch/PID check on `192.168.0.102:5555`; callback scheme resolution check.

## 2026-05-22 Smart Departure Preflight Recalculation
- Changed smart departure alarms so the first computed departure time schedules an Android preflight alarm rather than freezing the user-visible notification immediately.
- The preflight callback reloads the event, reads the current location, recalculates travel time/safety margin, and either fires the departure alarm immediately when due or schedules another preflight when the recalculated departure time is still in the future.
- Existing preparation alarms and the periodic departure monitor remain intact; no Supabase schema, migration, RLS, Flow Core, or shared-core files were changed.
- Verification passed: focused departure/event-preparation/manual-side-effect tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build. Device install/run check was skipped because `adb devices` showed no connected device.

## 2026-05-22 Departure Preflight Location-Failure Safety Net
- Hardened departure preflight so a live-location failure at alarm time no longer silently skips the user-visible departure alarm.
- When current location cannot be resolved during preflight, PlanFlow now fires a fallback departure alert with Korean guidance that the location check failed and the user should confirm departure timing.
- Verification passed: focused departure alarm tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, `adb install -r -t` on `10.64.235.8:5555`, app launch, PID check, and focused window check.

## 2026-05-23 FluxStudio Dashboard Tables And Relative Date Labels
- Added FluxStudio dashboard intake schema to live Supabase project `xqvvfnvmytjlblcngipn` and mirrored it in `supabase/schema.sql`: `admin_roles`, `contact_messages`, `product_early_birds`, and `product/source` columns on `early_bird_emails`.
- Confirmed `tught3@naver.com` is registered in `admin_roles` as `owner`; public insert policies are available for homepage/app intake while select/update are limited to admin-role users.
- Updated home upcoming cards and the Android next-event widget time label so events tomorrow and the day after tomorrow show `내일 HH:mm` / `모레 HH:mm`; all other dates keep the normal date label.
- Verification passed: focused home screen and home-widget service tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-23 Feedback Reports Product Tag
- Confirmed `feedback_reports` submissions did not include `product`; added `product: 'planflow'` to the app insert payload.
- Added `product text not null default 'planflow'` with a Flow-product check constraint to live Supabase, `supabase/schema.sql`, and `supabase/feedback_reports_patch.sql`.
- Updated `FeedbackReport` parsing so older rows without the column still read as `planflow`.
- Verification passed: feedback repository test, feedback schema test, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-23 Voice Input Button Highlight Polish
- Changed the voice input primary button label to `음성으로 다시 입력하기` when text already exists, while keeping the initial empty-state label as `음성으로 일정 입력하기`.
- Replaced the current-text submit action with a stronger outlined/highlighted button so `현재 내용으로 입력` stands out when text is present.
- Strengthened the shared `PlanFlowVoiceFab` border and glow so the `음성으로 일정 관리` button is visibly highlighted on all pages that use the shared FAB.
- Verification passed: focused voice input screen tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install on `192.168.0.102:5555`, and PID check.

## 2026-05-23 Naver OAuth WebView Registration Fix
- Fixed Naver login WebView startup by registering `webview_flutter_android` in the Android plugin registrant; the previous runtime failure was `plugins.flutter.io/webview` being unregistered even though the OAuth URL was generated successfully.
- Added a regression test that keeps `WebViewFlutterPlugin` present in the Android registrant and verifies `webview_flutter_android` remains in Flutter plugin metadata.
- Verification passed: focused WebView/auth/login tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, install/launch on `192.168.0.102:5555`, and device screenshot/logcat confirmation that the internal Naver login page loads.

## 2026-05-23 External Calendar Sync Guide
- Replaced the Naver-login-only CalDAV popup with a provider-neutral one-time external calendar sync guide for Google/Naver/Samsung calendar users.
- The guide now routes directly to Settings with `open=naver-caldav`, and Settings can scroll to the calendar sync section and open the Naver CalDAV ID/app-password connection dialog immediately.
- Added regression coverage for the initial Naver CalDAV settings action; verification passed for focused settings tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-23 Naver Account Display Fallback
- Fixed Naver account display fallback so nested OAuth identity payloads such as `identityData.response.email` are used when Supabase `user.email` is empty.
- Added AuthProvider regression coverage for nested Naver response email data so Settings can show the actual account identifier instead of only `네이버 로그인됨`.
- Verification passed: focused auth provider tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-23 Naver OAuth Success Message Guard
- Prevented stale or premature Naver OAuth failure banners from showing during a successful WebView callback by clearing old OAuth messages, waiting briefly for session sync, and closing the WebView quietly on success.
- Updated Naver account display so metadata/identity email values populate `authProvider.email`; Settings now prefers real email identifiers before falling back to provider labels.
- Verification passed: focused auth provider, Naver WebView, and login screen tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-24 External Calendar Guide Connected-State Skip
- Added `ExternalCalendarSyncGuideService` so the one-time external calendar sync guide checks existing sync state before showing.
- The guide is now skipped and marked seen when Google Calendar is already connected, Naver CalDAV credentials exist, or the auto-sync snapshot has a healthy provider such as the device/Samsung calendar import.
- `ShellScreen` now asks the guide service whether to show the modal instead of relying only on the seen flag.
- Verification passed: focused external calendar guide service tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-24 External Calendar Critical Import
- Added `ExternalEventImportClassifier` so imported external calendar events can preserve important buckets without over-marking ordinary reservation text.
- Google, Naver CalDAV, Naver ICS, and Android device/Naver calendar import now set `isCritical` when external signals indicate importance, including iCal `PRIORITY:1..3`, `Important`/`중요` categories, or Naver Booking style calendar buckets.
- Critical import tests now cover classifier rules, device calendar Naver booking calendars, Naver CalDAV priority/categories, and Naver ICS important buckets.
- Verification passed: focused external import tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build.

## 2026-05-24 Critical Alarm Visible Difference Test
- Bumped the Android critical alarm channel id to `critical_alarms_v3_loud` so devices with an older immutable notification channel recreate the important-alarm channel with the dedicated sound/vibration/full-screen settings.
- Added a Settings test action labeled `일반/중요 알림 차이 테스트`; it schedules a normal reminder first and a critical alarm shortly after so the user can compare the actual device behavior.
- The critical test alarm uses the existing critical scheduling path, including exact alarm permission handling, full-screen intent request, dedicated raw sound, max importance/priority, strong vibration pattern, and critical title/body formatting.
- Verification passed: focused notification/settings tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-24 Critical Alarm Exact-Permission Fallback
- Fixed an important-alarm scheduling bug where critical alarms were blocked entirely when Android exact-alarm permission was false, while normal alarms still fell back to inexact scheduling.
- Critical alarms now only block when app notification permission itself is disabled; if exact alarms are unavailable, they still schedule with `inexactAllowWhileIdle` and return a warning message about possible Android delay.
- Added notification service regression tests for critical alarm exact/inexact schedule-mode selection.
- Verification passed: focused notification service tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, launcher start, focused-window check, and PID check.

## 2026-05-24 Critical Alarm Full-Screen Denial Fallback
- Device evidence showed the critical alarm's scheduled receiver fired, but the notification did not post while `USE_FULL_SCREEN_INTENT` had a recent rejection on the 102 Samsung device.
- Critical alarms now attach `fullScreenIntent` only when the Android permission check/request says it is actually allowed; otherwise the important notification still posts through the loud critical channel without the full-screen popup.
- Added notification service regression coverage for the critical full-screen intent gating helper.
- Verification passed: focused notification service tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, launcher start, and PID check.

## 2026-05-24 Voice Button Visual Cleanup
- Removed the highlighted border/glow treatment from the shared `PlanFlowVoiceFab` and made the floating voice management action use the darker PlanFlow primary color.
- Added the same floating voice management button to the Settings tab so Home, Calendar, and Settings all expose the voice schedule management entry point.
- Swapped the Home empty-state voice-add button to the previous FAB accent color, and removed the highlighted background/border from the Voice Input `현재 내용으로 입력` outlined button.
- Verification passed: focused Settings and Voice Input screen tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, launcher start, and PID check.

## 2026-05-24 Critical Alarm Safe Channel And Button Polish
- Moved important alarms to a new safe Android channel `critical_alarms_v4_safe` that uses the system notification sound and strong vibration instead of depending on the previous raw alarm sound/full-screen-heavy channel path.
- Explicitly creates the normal and important notification channels during notification initialization, so Android channel state is visible immediately after app launch.
- Adjusted Voice Input action styling: `음성으로 다시 입력하기` now uses the briefing-style purple button, `현재 내용으로 입력` uses the default filled button, and the Home empty-state voice-add button uses the calmer `primaryMid` blue.
- Verification passed: focused notification and voice-input tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, launcher start/PID check, and `dumpsys notification` confirmed `critical_alarms_v4_safe` with importance 5 plus default notification sound and strong vibration.

## 2026-05-24 Critical Alarm Distinct UX
- Reintroduced a distinct important-alarm sound through a new explicitly-created channel `critical_alarms_v5_distinct`, while keeping the safer notification audio usage and full-screen gating from the previous stability fix.
- Important alarms now include clearer body text telling the user to check the important schedule and that tapping the notification opens the schedule.
- Local event, critical, and departure notifications now pass `event:` / `departure:` payloads so notification taps route to the relevant event detail screen.
- Verification passed: focused notification, departure, and manual side-effect tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install and launch on `192.168.0.102:5555`, and `dumpsys notification` confirmed `critical_alarms_v5_distinct` with the raw PlanFlow sound resource.

## 2026-05-24 Location Coordinate And Critical Alarm Persistence
- Confirm, edit, and voice-action save paths now resolve missing location coordinates before writing the event row, so voice-entered location text is not saved as unresolved when lookup can find coordinates.
- External calendar merge now preserves an existing PlanFlow `isCritical=true` value, preventing later sync imports from downgrading a user-marked important event.
- Added a one-time per-user/per-channel future critical alarm migration so existing upcoming critical events are rescheduled on the current `critical_alarms_v5_distinct` channel.
- Settings now exposes a direct `중요 알림 소리 바꾸기` button that opens the exact Android notification channel settings instead of relying on notification long-press behavior.
- Verification passed: focused critical alarm migration, notification, confirm save-time location, voice action, and event edit tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; update install and launch on `192.168.0.102:5555`; `dumpsys notification` confirmed the active critical channel.

## 2026-05-24 Voice Input Cobalt Accent And Early-Bird Legacy Removal
- Set the third accent color to cobalt blue `#1A4FD6`, applied it to the Home empty-state voice CTA and all Voice Input primary restart/start states, and changed requested Settings actions to either `primaryMid` or cobalt.
- Stabilized the Voice Input primary button so text entry/deletion no longer swaps button classes or interpolates incompatible text styles during transcript changes.
- Removed legacy `public.early_bird_emails` from the production DB and local schema/backup SQL, while preserving `planflow.early_bird_emails` and `public.product_early_birds`.
- Verification passed: focused voice/home/settings tests, Supabase table/function checks, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, launcher start, focused-app check, and PID check.

## 2026-05-25 Password Recovery Callback Routing
- Password reset callbacks with `type=recovery` or password-recovery event markers now bypass the normal OAuth-home routing, exchange the recovery session even when an old session exists, mark password recovery locally, and route to `/reset-password`.
- Added regression coverage for recovery callback detection, including Supabase fragment-style recovery links, while leaving normal OAuth callbacks unchanged.
- Verification passed: `test/services/oauth_callback_handler_test.dart`, `test/providers/auth_provider_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, and PID check.

## 2026-05-25 Naver OAuth Callback Status Tone
- Naver OAuth WebView no longer renders the successful callback-processing status as a red retry/error box; callback handling clears the message and relies on the loading bar while the session is confirmed.
- Real WebView/OAuth failures still use the red retry message, while the blocked Naver-app navigation hint now uses a neutral info tone.
- Verification passed: focused Naver OAuth WebView test, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, and PID check.

## 2026-05-25 Naver Login Consent Route And Recheck Visibility
- The Login screen Naver button now opens the Naver OAuth WebView with `forceConsent=1`, so normal Naver login requests the same reprompt/account-confirmation path as the previous account recheck action.
- The Settings account section now shows `네이버 계정 정보 다시 확인` only when the current signed-in Naver profile is actually missing usable account information.
- Verification passed: focused login/settings/auth-service tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build. Device install was attempted, but `192.168.0.102:5555` was offline and reconnect timed out.

## 2026-05-25 Naver CalDAV Mirror And Travel Transit
- Added a Supabase-backed Naver CalDAV credential mirror with local-first read/write semantics so secure-storage loss can be restored after the user has re-linked once.
- Added the Naver transit endpoint path for public-transit travel estimates, with driving fallback when transit is unavailable, and backfilled missing event coordinates after successful location geocoding.
- Smart departure payloads now mark fallback travel estimates in the notification title/body, while preserving the 30-minute fallback value.
- Tightened STT cancel-command cleanup so `6월1일 취소` leaves `6월1일` instead of `6월1일 취`, without treating content such as `계약 취소 확인 전화` as a cancel command.
- Verification passed: full `scripts/flutter-local.ps1 test --no-pub`, focused STT/voice-input tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, and PID check.

## 2026-05-25 Android Package Rename To FluxStudio
- Changed the Android package/application id from `com.planflow.app` to `com.fluxstudio.planflow`, including Gradle namespace, Kotlin package declarations, widget providers, update tests, install scripts, and release console docs.
- Rebuilt debug APK, release APK, and release AAB; verified APK badging shows package `com.fluxstudio.planflow`, versionCode `3`, versionName `1.1.0`, targetSdk `36`, and the existing PlanFlow release SHA-256 certificate `b3f2289851b78881263ca939fc09181efc310152828dd700fab7c552bef9a231`.
- Installed and launched the new package on `192.168.0.102:5555`; both old `com.planflow.app` and new `com.fluxstudio.planflow` coexist on the test device, so `planflow://auth-callback` currently opens Android's resolver until the old test package is removed.
- Verification passed: focused update-service test, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, release APK build, release AAB build, update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-25 Email Sign-Up Confirmation Callback Guard
- Email sign-up confirmation callbacks such as `type=signup` are now handled separately from social OAuth callbacks, so expired/cancelled email verification links no longer show the misleading social consent failure message.
- Successful email confirmation callbacks route through the existing session sync/home flow and log email sign-up, while email confirmation failures now show Korean email-verification-specific guidance.
- Verification passed: focused OAuth callback handler tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install/launch/PID check on `192.168.0.102:5555`, and `planflow://auth-callback` resolves directly to `com.fluxstudio.planflow.MainActivity`.

## 2026-05-26 Location Auto-Resolve, Widget Date Deep-Link, And Voice Title Cleanup
- Location lookup now accepts a current-location origin and ranks ambiguous multi-branch results by distance when the user has not explicitly named a region; confirm/edit/voice/AI/side-effect paths pass the origin when available and save the chosen provider label with coordinates.
- Calendar widget/date deep-links now open the selected date's day sheet after the calendar events load, and notification/event back navigation falls back to the Home tab instead of closing the app when there is no previous route.
- Voice title cleanup now removes weekday/repetition command words from recurring input while preserving the real object phrase, so `매주 월요일 오전 7시에 태블릿 계기판찍기 반복설정` becomes title `태블릿 계기판 찍기` with weekly recurrence intact.
- Login sign-up guidance now unfocuses the keyboard and scrolls the success/error message into view after returning to login mode, so the full email confirmation notice is visible.
- Verification passed: focused location, confirm, calendar, event edit/detail, voice action/conversation, preparation, voice-structure, GPT, and login tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build after clearing a conflicting Gradle/Flutter SDK cache state; update install/launch/PID check on `192.168.0.102:5555`.

## 2026-05-26 Confirm Optional Section Expansion
- Calendar-style event editor now accepts initial expansion hints for classification, details, and alarm sections.
- Confirm screen opens the recurrence section when a parsed recurrence exists, opens details when parsed supplies or explicit smart-prep actions exist, and opens alarm options for important events.
- Confirm hydration now applies a later parsed `recurrence_rule` into the screen state before saving, preventing async parsing from dropping the recurrence.
- Verification passed: `test/widgets/calendar_style_event_editor_test.dart`, `test/screens/confirm_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, and PID check.

## 2026-05-27 Monthly Widget Readability And Play Console Data Safety
- Monthly home widget now renders a denser PlanFlow-style calendar: event rows hide time prefixes, day numbers are centered, today's date gets a circular highlight, and out-of-month days stay visible but muted.
- Monthly widget navigation now supports `오늘`, previous month, and next month actions backed by a clamped `month_widget_offset`, with Flutter saving previous/current/next month payloads for native rendering.
- Added `docs/play-console-data-safety.md` with the requested Play Console table format, including collection/sharing flags, temporary-processing status, optional/required status, reasons, and excluded data types.
- Verification passed: `test/services/home_widget_service_test.dart`, `test/screens/confirm_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build. Device install was attempted, but `192.168.0.102:5555` was offline and reconnect timed out.

## 2026-05-27 Voice Input Native STT Recovery
- Root cause: the Android on-device speech recognizer could get stuck at capacity after leaving/re-entering voice input, while the native channel retried `startListening()` too aggressively.
- The native STT channel now cancels any active recognizer before a fresh start, throttles restart attempts, recreates the recognizer on busy/client errors, and ignores stale delayed restarts using a generation guard.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 test test/services/stt_service_test.dart --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, update install on the only connected device `192.168.0.103:5555`, app launch, and logcat confirmation that offline Korean STT opened the microphone without the previous capacity-full loop.

## 2026-05-27 Voice Widget Routing And Multi-Day Calendar Display
- Stabilized the 1x1 voice widget route so `planflow://voice-launcher` is received explicitly and retried after initial auth routing until `/voice?autoStart=1` is applied.
- Calendar and monthly widget payloads now treat events spanning multiple local days as range events even when `isMultiDay` is false, and clip midnight-ended ranges to the previous display day.
- Added a PlanFlow-styled monthly widget preview SVG at `docs/widget-previews/monthly-widget-preview.svg` without changing the Android monthly widget layout.
- Verification passed: focused widget-route/calendar/home-widget tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build. ADB install/run was skipped because no device was connected.

## 2026-05-27 Widget Deep-Link, Duplicate Guard, And Confirm Polish
- Rechecked widget/date deep-link routing and added a startup retry for initial widget launches so first taps are less likely to be overwritten by home routing.
- Tightened multi-day range display in the calendar tab and monthly widget, including cross-month ranges such as May 26 to June 1 and muted out-of-month cells.
- Duplicate warnings now require the same local schedule window or genuinely similar content/location, avoiding warnings for unrelated overlapping events.
- Confirm/edit save feedback now uses a top overlay message, resolved location phrases are stripped from voice titles after async coordinate resolution, empty details stay collapsed, and important alarms are independent from the normal `미리알림` offset.
- Verification passed: focused route/calendar/home-widget/duplicate/confirm/location/reminder/editor tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.219.43:5555`, app launch/PID/focused-window check, and voice/calendar deep-link launch checks.

## 2026-05-27 Voice Confirm Timeout And Personal Place Guard
- Fixed a confirm-screen stall caused by Firebase Analytics rejecting boolean custom parameters; analytics parameters are now sanitized to Firebase-supported string/number values and analytics failures no longer interrupt UI flows.
- Added a GPT completion timeout so schedule cleanup falls back to local parsing instead of leaving the confirm screen in `음성 내용을 정리하는 중` for several minutes.
- Prevented automatic map resolution for personal place aliases such as `원주집`, so external search results like restaurants cannot replace the user's intended place without an explicit map pick.
- Voice widget auto-start now waits briefly after route startup and retries once when the first STT attempt immediately returns silence/unavailable.
- Verification passed: focused confirm/GPT/voice-input tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.219.43:5555`, app launch/PID check, and post-install log check for the prior Firebase assertion pattern.

## 2026-05-28 Auth Session Recovery And Backup Schema Guard
- Confirmed production data was still present, then patched only the approved missing `public.user_settings` region/provider columns so backup creation/restore matches `supabase/schema.sql`.
- AuthProvider now shares an in-flight Supabase session refresh between bootstrap/startup/resume callers, reducing the `refresh_token_already_used` race that made the app appear signed out with empty data.
- BackupService now distinguishes signed-out, schema mismatch, and general backup failures; Settings restore flow no longer reports “no backups” after a backup-list load failure.
- Verification passed: auth provider, backup service, and settings screen focused tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; update install/launch on `192.168.219.43:5555`; log check showed no `refresh_token_already_used` after reinstall, but the device still needs a fresh login because its old refresh token was already missing.

## 2026-05-28 Home Past Same-Time Events
- Home now keeps the compact “latest past schedule” behavior but renders every past event that shares the latest local start minute, so simultaneous past schedules are all visible instead of only the final one.
- Added focused home tests for same-minute past event selection and rendering, while older past events remain available through the recent-past sheet instead of crowding the main Home tab.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/home_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, and `git diff --check`.

## 2026-05-28 Voice Correction Learning Pipeline
- Added a rule-based personal voice correction learning pipeline for STT transcript fixes and parsed schedule field corrections, with personal rules applied before trusted anonymous common rules.
- Added Supabase schema/migration support for `voice_correction_rules`, authenticated read-only common correction rules, and user settings toggles for personal correction learning plus anonymous common improvement opt-in.
- Voice input, confirm save, GPT schedule parsing, and settings management now connect to the correction learning service while avoiding full raw utterance storage in correction rule tables.
- Verification passed: focused correction/repository/schema/settings/backup/voice/GPT/confirm tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and debug APK build. ADB install/run was skipped because no device was connected.

## 2026-05-28 Auth Persistence And First Frame Splash
- Supabase auth local storage now suppresses persisted-session deletion unless the app is inside an explicit sign-out guard, and AuthProvider ignores non-explicit transient `signedOut` events while a user is active.
- App startup now calls `runApp` before Firebase/NaverMap/Supabase initialization, so the Flutter splash/loader can render immediately while platform services initialize in the background.
- Splash screen background now uses the PlanFlow background color instead of white, reducing the visible white frame when launching from the app icon or 1x1 voice widget.
- Verification passed: focused auth storage/provider tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, PID, and focused-window check.

## 2026-05-28 App Feedback Toast Offset
- Moved the custom top overlay feedback message below the status bar plus toolbar height so it no longer overlaps the top-left PlanFlow app title.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, PID, and focused-window check.

## 2026-05-28 Voice Correction Learning Consent Copy
- Reworded the settings copy for personal correction learning and anonymous common improvement so users can tell that anonymous minimum-pattern sharing happens only when the opt-in switch is enabled, and framed the feature as improving PlanFlow's AI learning ability rather than just "correction".
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, PID, and focused-window check.

## 2026-05-29 Tablet And Foldable Responsive Pass
- Added shared responsive window helpers for 600/840dp classes, large-screen two-pane thresholds, keyboard inset awareness, and foldable display-feature safe-size decisions.
- Marked `MainActivity` resizeable for large-screen Play compatibility and routed Shell navigation rail decisions through the new safe-size logic so narrow fold states keep bottom navigation.
- Calendar now uses a two-pane month + selected-day agenda layout on large screens, LocationPicker shows map and candidates side-by-side on tablet/fold widths, and Home/Settings/Event/Confirm/Voice screens use shared responsive content widths.
- Verification passed: `scripts/flutter-local.ps1 test test/core/responsive_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:5555`, app launch, and PID check.

## 2026-05-29 Google OAuth Callback Listener Fix
- Root cause on `192.168.0.105:5555`: Android/app_links received `planflow://auth-callback?code=...`, but `OAuthCallbackHandler.start()` had returned early before Supabase initialization, so the app never processed the Google callback.
- OAuth callback listening now starts as soon as valid Supabase config exists, even before Supabase is fully initialized; actual callback handling waits briefly for Supabase readiness before exchanging the session.
- Verification passed: `scripts/flutter-local.ps1 test test/services/oauth_callback_handler_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, debug APK build, update install and launch on `192.168.0.105:5555`, and ADB Google login retry showed `OAuth callback observed`, `OAuth callback exchange completed`, and `AuthChangeEvent.signedIn`.

## 2026-05-29 Active Auth Session Guard And Portrait Lock
- AuthProvider now separates cached account snapshots from active Supabase sessions, so Settings can show account identity while server-backed features require a real `currentSession`.
- Home, briefing, and backup flows now block server reads without an active session and show session recheck guidance instead of pretending there are no schedules or no backups.
- MainActivity is portrait-locked with `android:screenOrientation="portrait"` so repeated build/install updates do not leave the phone orientation unlocked.
- Verification passed: auth provider, Supabase auth storage, briefing scheduler, and settings focused tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; debug APK build; update install and launch on `192.168.0.102:5555`; installed package reports `versionCode=3`, `versionName=1.1.0`.

## 2026-05-29 Voice Widget And STT Session Boundary
- Added a direct `app_links` listener for non-auth `planflow://` links so `planflow://voice-launcher` can still route to `/voice?autoStart=1` when the home widget plugin initial URI probe misses or app startup routing races.
- Hardened `VoiceInputScreen` with listen-session generations and finish-state guards so partial/final callbacks from an old listen are ignored after 완료, manual edit, cancel, back navigation, tab changes, or route transitions.
- Native Android STT now snapshots text at stop time, ignores partial/results after user-requested stop, and Dart detaches native handlers after stop fallback completion so late microphone callbacks cannot append complaint speech to the next command.
- Verification passed: `test/screens/voice_input_screen_test.dart`, `test/services/stt_service_test.dart`, `test/app_home_widget_route_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install/launch on the only connected ADB device `emulator-5554`, and direct `planflow://voice-launcher` intent delivery to `MainActivity`.

## 2026-05-29 Recovering Redirect And Location Resolution State
- Router now treats `AuthSessionStatus.recovering` as a non-redirecting intermediate state so save-time session sync no longer bounces the user to the login screen.
- Location lookup now queries TMap/Naver/Google in parallel and location resolution status renders three states: unresolved, searching, and resolved, with the searching state exposed in both confirm and event edit flows.
- Verification passed: `test/widgets/calendar_style_event_editor_test.dart`, `test/screens/event_edit_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, and update install/launch on `192.168.0.102:5555`. `test/screens/confirm_screen_test.dart` still has preexisting `pumpAndSettle` timeout cases unrelated to the code compiled here.

## 2026-05-29 Location Lookup And Title Preservation Follow-up
- Confirm and event edit no longer wait for GPS before starting geocoding; GPS lookup now runs in the background while place search starts immediately with `origin: null`.
- Voice schedule title normalization now preserves leading place names such as `강릉 건도리횟집에서 ...` instead of stripping them away.
- Location picker timeout copy now tells users to choose from the candidate list when the map cannot load.
- Verification passed again: `test/services/voice_schedule_structure_service_test.dart`, `test/screens/location_picker_screen_test.dart`, `test/screens/confirm_screen_test.dart`, `test/screens/event_edit_screen_test.dart`, `test/widgets/calendar_style_event_editor_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, and update install/launch on `192.168.0.102:5555`.

## 2026-05-30 Naver Custom Provider Cutover
- Switched PlanFlow's Naver OAuth path from `custom:naver` to the new Supabase custom provider `custom:planflow-naver` in the auth service, supporting docs, and auth-provider test fixtures.
- Simplified social-provider detection so any Naver-flavored provider key still resolves to the Naver label without hard-coding the old provider ID.
- Verification passed: `scripts/flutter-local.ps1 test test/providers/auth_provider_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, update install on `192.168.0.102:5555`, and a real `am start` launch check on `com.fluxstudio.planflow/.MainActivity`.

## 2026-05-31 Query Cue And Manual Briefing Notification Suppression
- Expanded voice query intent cues so phrases like `몇시야`, `있어?`, and related question forms route to query flow instead of edit flow.
- Manual briefing playback from the app foreground now suppresses the one-second notification and only plays TTS, while scheduled/background briefing behavior stays unchanged.
- Verification passed: `scripts/flutter-local.ps1 test test/services/voice_command_pipeline_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/briefing_scheduler_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, and update install/launch on `192.168.0.102:33125`.
## 2026-05-31 Voice Conversation Input Boundary Fix
- AI 일정 대화 화면에 입력 턴 세대와 음성 세대를 분리하는 가드를 추가해, 사용자가 다시 입력한 뒤에도 이전 STT partial/final 콜백이 입력창을 다시 채우지 못하게 막았다.
- 수동 전송 시에는 기존 음성 listen을 강제로 끊고, 음성 final 제출은 예외 처리해 늦은 콜백이 새 입력을 덮지 않도록 정리했다.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/voice_conversation_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, and update install/launch on `192.168.0.102:33125`.

## 2026-05-31 Voice Conversation First-Listen Recovery And Multi-Target Preservation
- AI 일정 대화에서 프로그램matic clear가 입력 턴 세대를 깨지 않도록 가드를 추가해, 첫 음성 입력이 실패하는 경로를 막고 재입력 없이도 첫 partial/final이 정상 반영되게 정리했다.
- 삭제/종료/전송 경로의 clear도 같은 가드를 공유하도록 맞춰 늦은 STT 콜백이 새 입력을 덮지 않게 했고, 다중 대상 후속 수정은 `selectedEvents` 세션 상태로 유지해 단일 대상으로 축소되지 않게 보존했다.
- Verification passed: `scripts/flutter-local.ps1 test test/screens/voice_conversation_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/voice_conversation_controller_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, update install on `192.168.0.102:33125`, and `am start` launch check on `com.fluxstudio.planflow/.MainActivity`.

## 2026-05-31 Voice Pipeline And Naver Map Follow-up
- AI 일정 대화의 음성 입력 파이프라인을 다시 정리해서, 첫 입력 실패나 늦은 STT 콜백이 새 입력을 덮는 흐름을 막고, 직접입력 전환/전송/이탈 시 stop-cancel 경계를 더 분명히 유지하도록 손봤다.
- 위치 문자열 정규화는 시간 표현을 먼저 제거하도록 강화해서 `오늘 오후 5시 판교 대장동 해링턴플레이스 방문`이 `대장동 해링턴플레이스`로 남게 했고, 네이버 지도는 준비될 때까지 기다렸다가 우선 사용하도록 바꿨다.
- Naver Map 초기화 성공/실패 로그를 추가하고, 위치 픽커 대기 시간을 10초로 늘려 Naver 우선 렌더링이 너무 빨리 Google fallback으로 내려가지 않도록 조정했다.
- Verification passed: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 test test/services/voice_schedule_structure_service_test.dart test/screens/voice_conversation_screen_test.dart --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, update install on `192.168.0.102:33125`, and `am start` launch check on `com.fluxstudio.planflow/.MainActivity`.
## 2026-05-31 Departure Alarm Acknowledgement Flow
- 출발 알림에 `출발했어요` 액션과 앱 내 `출발하셨나요?` 확인 모달을 추가하고, 이벤트별 로컬 acknowledgement 상태로 같은 이벤트가 monitor/refresh에서 다시 예약되지 않게 정리했다.
- 이벤트 수정/삭제 시 acknowledgement를 함께 해제하고 departure/preflight 알림 아티팩트를 취소하도록 연결했다.
- Verification passed: `scripts/flutter-local.ps1 test test/services/departure_alarm_service_test.dart test/services/manual_event_side_effect_service_test.dart test/services/notification_service_test.dart test/screens/event_detail_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, update install on `192.168.0.102:42887`, and `am start` launch check on `com.fluxstudio.planflow/.MainActivity`.

## 2026-05-31 Startup Auth Session Race Fix
- 앱 시작/복귀 시점에 초기 auth 복구가 끝나기 전에 `syncCurrentSession()`이 다시 refresh를 걸며 세션 만료/재인증 snackbar가 튀던 경로를 막기 위해, 초기 auth resolution completer를 추가하고 bootstrap in-flight refresh를 재사용하도록 정리했다.
- startup / resume / shared-ICS 진입은 초기 auth resolution이 끝날 때까지 기다린 뒤 세션 동기화를 진행하도록 바꿔서, 빌드/설치 직후 로그인 세션이 불필요하게 풀리는 현상을 줄였다.
- Verification passed: `scripts/flutter-local.ps1 test test/providers/auth_provider_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, update install on `192.168.0.102:42887`, and `am start` launch check on `com.fluxstudio.planflow/.MainActivity`.

## 2026-05-31 Voice Conversation Beep Interval Tuning
- AI 음성 대화에서 한마디마다 시작음이 반복되는 문제를 줄이기 위해 conversation listen silence를 2초대에서 10초로 늘리고, Android 네이티브 STT 쪽의 최소 길이도 이에 맞게 완화했다.
- 연속 발화 중에는 재시작이 덜 일어나도록 조정하되, 전송/종료 시에는 기존 턴 경계와 자동 재시작 제어를 유지한다.
- Verification passed: `scripts/flutter-local.ps1 test test/services/stt_service_test.dart test/screens/voice_conversation_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`.
## 2026-06-01 Background Session Rotation And Holiday Date Fix
- Background Supabase initializers for briefing, auto-sync, backup, and departure alarms now pass `autoRefreshToken: false` so one-shot background work no longer rotates the foreground refresh token and breaks the signed-in session.
- Naver Open API calendar import now parses all-day date-only holidays with the local-day helper and marks all-day multi-day spans correctly so holidays like 광복절 and 개천절 stay on the intended local date.
- Naver calendar reconnect now falls back gracefully when the Naver identity is already linked, and the related regression tests were added/updated.
- Verification passed: `scripts/flutter-local.ps1 test test/core/supabase_auth_options_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/naver_open_api_calendar_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/auth_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/providers/auth_provider_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/device_calendar_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, update install on `192.168.0.102:36273`, and `am start` launch check on `com.fluxstudio.planflow/.MainActivity`.

## 2026-06-01 Departure Alarm And Voice Stability Follow-up
- Repetition command words are now stripped from titles only when a recurrence intent exists, including `매월 1일 톨비 작성 반복` -> `톨비 작성` with monthly recurrence preserved.
- Smart departure notification mojibake strings were restored to UTF-8 Korean and covered by a static source regression scan across notification/departure/preparation alarm services.
- Conversation STT listen/pause windows were extended to 5 minutes, and the Android native silence window now matches 300 seconds to reduce repeated start/stop beeps during natural pauses.
- Departure alarms now have a local repeat interval setting in Settings, throttle repeated due-departure notifications by that interval, and reuse a recent cached origin when live location lookup is unavailable.
- Naver calendar connection now requests `email,calendar` for calendar consent paths, including the already-linked identity fallback and the no-active-session reconnect path.
- Verification passed: focused voice schedule, GPT recurrence, STT, notification, departure alarm, settings, and auth service tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; `scripts/flutter-local.ps1 build apk --debug --no-pub`. ADB install/run could not be completed because `adb devices` returned no connected devices.

## 2026-06-01 Calendar Date Route And Ambiguous Prep Guard
- Calendar direct-add routes now include the selected date, and new event edit screens initialize their date from the `date=YYYY-MM-DD` query instead of falling back to today.
- Monthly widget fallback cells keep date-number deep links while blank month-cell areas remain no-op, preserving visible-date navigation without accidental background launches.
- Broad medical category place queries such as `병원 방문`, `병원 미팅`, `병원 진료`, `치과 예약`, and `약국 가기` no longer auto-resolve to arbitrary coordinates, while region-qualified queries like `성남 병원` still resolve.
- Ambiguous visit/meeting schedules no longer receive automatic movement-preparation alarms; explicit medical/patient-visit/travel contexts still keep useful preparation guidance.
- Verification passed: focused calendar/event editor/time wheel/location lookup/smart preparation tests, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, and `scripts/flutter-local.ps1 build apk --debug --no-pub`. Full `scripts/flutter-local.ps1 test --no-pub` still has 6 failures in unrelated existing settings/background/voice conversation tests, and ADB install/run could not be completed because no device was connected.

## 2026-06-01 Naver Permission Probe And Widget Date Tap Follow-up
- Naver calendar permission probing now uses the read-only `findSchedules.json` endpoint with a one-day window instead of sending a dummy `createSchedule` payload, preventing false "permission not confirmed" results when sync itself is working.
- Monthly widget visible date cells now bind the whole visible cell container as well as the day number to `planflow://calendar?date=YYYY-MM-DD`, while truly blank cells remain no-op.
- Verification passed: `test/services/naver_calendar_permission_service_test.dart`, `test/app_home_widget_route_test.dart`, `test/screens/calendar_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:41013`, `am start` launch check, and direct `planflow://calendar?date=2026-06-15` intent showing the selected date panel.

## 2026-06-01 STT Final Restart And Naver Consent Follow-up
- Android native conversation STT no longer treats each `onResults` final callback as user completion; in conversation mode it publishes the final text and restarts listening until the user explicitly stops, reducing short-pause turn endings.
- Naver Open API access checks now verify actual calendar permission via `NaverCalendarPermissionService.refreshStatus()` instead of treating any stored provider token as sufficient.
- Settings no longer shows a false "권한 동의가 확인되지 않았습니다" snackbar two seconds after launching external Naver OAuth; it now asks the user to complete consent and retry sync after returning.
- Verification passed: `test/services/stt_service_test.dart`, `test/services/naver_open_api_calendar_service_test.dart`, targeted `test/screens/settings_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, debug APK build, update install on `192.168.0.102:41013`, and `am start` launch check.
## 2026-06-01 STT Segmented Session Quiet-Restart Follow-up
- Conversation-mode Android STT now requests segmented sessions and skips the extra cancel step when restarting the same conversation listen, which should reduce repeated start beeps on newer devices that support segmented recognition.
- The native STT regression test now checks for the segmented-session intent path and the segmented-session end callback in MainActivity.
- Verification passed again: `scripts/flutter-local.ps1 test test/services/stt_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install` on `192.168.0.102:41013`, and `am start` launch check.

## 2026-06-02 Voice State Sync And Location Provider Flow
- AI 일정 대화 now listens to native STT ready/speech/error/stalled events so the bottom bar only says `듣고 있어요...` after the native recognizer is actually ready, and `onResults()` in segmented conversation mode no longer forces a restart on every phrase.
- Voice command intent scoring now treats `휴가 취소하기` and `월례조회` as addable schedule content when date/time/action context is strong, while actual schedule delete/query commands still route to delete/query.
- Location picking no longer auto-launches external TMAP for TMAP preference; it opens the in-app Naver/Google map path and ranks candidates by text/region relevance before provider preference.
- Verification passed: focused STT, AI conversation, command pipeline, location lookup, and location picker tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; `scripts/flutter-local.ps1 build apk --debug --no-pub`; update install and launch on `192.168.0.102:43119`.

## 2026-06-02 Residual Voice Edit And Departure Origin Follow-up
- `stripScheduleNoise()` now keeps ordinary person/place/action words while still removing date/time/range field noise such as `오후3시에` and `부터/까지`, so `오후3시에 요미 약받기` normalizes to `요미 약받기` without regressing date-range titles.
- AI 일정 대화 now recognizes important/normal alarm edits as `is_critical_true`/`is_critical_false`, resolves ordinal or title-based targets from the current result list, and applies critical/location edits directly instead of forcing the edit screen.
- Departure alarm origin lookup now tries the injected/current live location path first, then falls back to a recent SharedPreferences origin cache with a 2-hour validity window; Home resume keeps that foreground cache warm.
- Verification passed: focused voice schedule, GPT, voice command pipeline, voice conversation controller/screen, and departure alarm tests; `scripts/flutter-local.ps1 analyze --no-pub`; `git diff --check`; `scripts/flutter-local.ps1 build apk --debug --target-platform android-arm64 --no-pub`.
- Full `scripts/flutter-local.ps1 test --no-pub` still has unrelated existing failures in Settings/Naver, background task, voice action/input, and voice command analysis/router expectations; the focused tests for this task pass.
## 2026-06-03 반복 시작일 정렬
- `매월 1일 ... 반복` 입력에서 반복 규칙은 유지하되 시작일이 오늘로 밀리던 경로를 `gpt_service.dart`에서 보강했다.
- `매월 1일 법인카드 정리 반복`에 대해 시작일이 이번 달 1일로 고정되는 회귀 테스트를 추가했다.
- `gpt_service_test.dart`, `voice_schedule_structure_service_test.dart` focused tests, `analyze`, debug APK build, and ADB install/launch on `192.168.0.102:42445` passed.

## 2026-06-03 반복 표현/설정 UI/Naver sync 정리
- 반복 파싱과 제목 정규화가 `매주 목요일`, `매월 첫 번째 월요일`, `매월 마지막 금요일`, `매월 1일`을 함께 다루도록 확장되었고, 편집 UI의 반복 선택도 월간 숫자형/요일형을 분리해 복원되게 정리했다.
- 설정 화면의 출발 알림 반복주기 칩 UI를 좁혀서 오버플로우를 줄였고, 네이버 일정 가져오기 안내 문구와 백그라운드 동기화 상태 표시가 실제 결과를 더 잘 따라가도록 맞췄다.
- 검증 통과: `scripts/flutter-local.ps1 test test/services/voice_schedule_structure_service_test.dart test/services/gpt_service_test.dart test/widgets/recurrence_selector_test.dart test/screens/settings_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, 그리고 `adb -s 192.168.0.102:42445 install -r -t --user 0 build\\app\\outputs\\flutter-apk\\app-debug.apk` / `am start -W -n com.fluxstudio.planflow/.MainActivity` 확인.

## 2026-06-05 AI 일정 대화 날짜 이동 초안
- AI 일정 대화가 `1번 일정 그 다음날로 변경해줘` 같은 상대 날짜 이동을 편집 초안으로 넘기도록 `voice_command_pipeline.dart`, `voice_conversation_controller.dart`, `voice_conversation_screen.dart`를 정리했다.
- `VoiceConversationResult`에 `draftEvent`를 추가해, 선택한 일정의 날짜를 실제 이동한 초안 이벤트를 편집 화면에 넘기고 저장 전 미리 반영되게 했다.
- `naver_caldav_service.dart`의 불필요한 널 단언 경고를 제거해 `flutter analyze`를 0 issue로 맞췄다.
- 검증 통과: `scripts/flutter-local.ps1 test test/services/voice_command_pipeline_test.dart --no-pub -r expanded`, `scripts/flutter-local.ps1 test test/services/voice_conversation_controller_test.dart --no-pub -r expanded`, `scripts/flutter-local.ps1 test test/screens/voice_conversation_screen_test.dart --no-pub -r expanded`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, 그리고 `adb -s 192.168.0.102:33607 install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk` / `am start -W -n com.fluxstudio.planflow/.MainActivity` 확인.
## 2026-06-05 제목 이름 보존과 시작일 이동 보존
- `김창민 만나기`처럼 사람 이름만 남아야 하는 제목에서 bare-name recipient 추출을 보강해 `만나기`만 남는 과도한 절삭을 막았다.
- 일정 편집과 확인 화면 모두에서 시작일을 옮길 때 기간을 늘리지 않고 기존 종료 시각을 같은 delta만큼 함께 이동하도록 맞췄다.
- 검증 통과: `test/services/voice_schedule_structure_service_test.dart`, `test/screens/event_edit_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `am start -W -n com.fluxstudio.planflow/.MainActivity`.
## 2026-06-05 AI 일정 대화 시작시간 초안 반영
- AI 일정 대화에서 `1번 일정 시작시간 8시반으로 해줘` 같은 시간 수정도 편집 초안으로 넘기도록 `voice_conversation_controller.dart`를 보강했다.
- `voice_command_pipeline.dart`는 `시작시간 ... 해줘` 형태를 수정 분리로 잘라내도록 조정했고, 컨트롤러/파이프라인 회귀 테스트를 추가했다.
- 검증 통과: `scripts/flutter-local.ps1 test test/services/voice_command_pipeline_test.dart test/services/voice_conversation_controller_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/screens/voice_conversation_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.102:37581 install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb -s 192.168.0.102:37581 shell am start -W -n com.fluxstudio.planflow/.MainActivity`.

## 2026-06-06 비공개 테스트 전 회귀 복구와 브리핑 알림 진입 안정화
- 브리핑 알림 진입 화면이 초기 세션 복구를 기다린 뒤 사용자 세션이 있을 때만 `executeBriefing(isManualTrigger: true)`를 실행하도록 정리했다. 복구 실패 시에는 “일정 없음”이 아니라 재로그인 필요 안내를 표시한다.
- 설정탭에 브리핑 예약 상태와 출발 알림 상태 카드를 복원하고, 화면 진입/앱 복귀/브리핑 예약·테스트 후 런타임 상태를 다시 읽도록 연결했다.
- 백그라운드 실패 안내는 overlay가 없는 widget test 환경에서도 ScaffoldMessenger fallback으로 표시되도록 보강했고, `일정 조회`는 관리 선택으로 분기되게 보정했다.
- `우리회사에서 매월 월례 조회 메모에 주차장 B2 확인`은 제목 `월례 조회`, 장소 `우리회사`, 메모 `주차장 B2 확인`, 월간 반복으로 분리되도록 장소 추론 경계를 보강했다.
- 검증 통과: `background_task_service_test.dart`, `voice_command_router_test.dart`, `voice_command_analysis_service_test.dart`, `voice_input_screen_test.dart`, `settings_screen_test.dart`, `briefing_launch_screen_test.dart`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build appbundle --release --no-pub`. ADB 기기는 `192.168.0.102:37581`가 offline으로 재연결 실패해 설치/실행 확인은 진행하지 못했다.

## 2026-06-06 중요한 일정 명칭과 첫 외부 일정 준비 알림 복구
- 사용자-facing `강한 알림` 문구를 `중요한 일정`으로 정리하고, AI 일정 대화 응답도 `중요한 일정으로 표시했어요/표시하지 않을게요`로 통일했다.
- `강한 알림`, `강한 알람`, `중요한 일정`, `중요한 알림`, `중요한 알람`, `긴급`, `급한`은 `isCritical=true`로, `일반/보통 알림`과 중요 일정 해제/끄기 표현은 `isCritical=false`로 분류되게 보강했다.
- 장소가 있는 하루 첫 번째 외부 일정은 `SmartPreparationAlarmService.buildExternalEventPayloads()`에 `includePreparationAlarms`를 함께 넘겨 준비 시작 알림과 출발 알림이 모두 생성되게 복구했다.
- 검증 통과: `scripts/flutter-local.ps1 test test/services/voice_command_pipeline_test.dart test/services/voice_conversation_controller_test.dart test/services/manual_event_side_effect_service_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/widgets/calendar_style_event_editor_test.dart test/screens/event_edit_screen_test.dart test/screens/voice_conversation_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`. ADB 연결 기기가 없어 설치/실행 확인은 진행하지 못했다.

## 2026-06-06 설정 화면 앱 버전 표시
- `PackageInfo.fromPlatform()` 값을 설정탭 하단 `앱 정보` 카드에 표시해 사용자가 현재 설치 버전과 빌드 번호를 앱 안에서 확인할 수 있게 했다.
- 현재 `pubspec.yaml` 기준 표시는 `버전 1.1.0 (빌드 3)` 형식이다.
- 검증 통과: `scripts/flutter-local.ps1 test test/screens/settings_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `git diff --check`, `scripts/flutter-local.ps1 build apk --debug --no-pub`.

## 2026-06-06 shell 탭 스와이프 경계 복원
- `ShellScreen`의 탭 전환 스와이프를 화면 전체에서 양쪽 가장자리 24px로만 제한해, 중앙 영역의 세로/가로 스크롤이 탭 전환에 끼어들지 않게 했다.
- `test/screens/shell_swipe_gesture_test.dart`에 center drag/edge fling 회귀 테스트를 유지하고, `SharedPreferencesAsyncPlatform` 인메모리 모킹을 넣어 SettingsScreen 부수 초기화가 테스트를 깨지 않게 했다.
- 검증 통과: `scripts/flutter-local.ps1 test test/screens/shell_swipe_gesture_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.102:37369 install -r -t build/app/outputs/flutter-apk/app-debug.apk`, `adb -s 192.168.0.102:37369 shell am start -W -n com.fluxstudio.planflow/.MainActivity`.

## 2026-06-06 custom scheme 딥링크 라우팅 크래시 완화
- go_router가 `planflow://voice-launcher` 같은 플랫폼 딥링크를 기본 위치로 쓰지 않도록 `overridePlatformDefaultLocation: true`를 켜고, 앱 시작 위치를 `AppRoutes.root`로 고정했다.
- `test/app_home_widget_route_test.dart`에 라우터가 플랫폼 기본 딥링크를 덮어쓰는지 확인하는 회귀 테스트를 추가했다.
- 검증 통과: `scripts/flutter-local.ps1 test test/app_home_widget_route_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.102:37369 install -r -t build/app/outputs/flutter-apk/app-debug.apk`, `adb -s 192.168.0.102:37369 shell am start -W -a android.intent.action.VIEW -d "planflow://voice-launcher"` 및 logcat에서 `Bad state: Origin is only applicable...` 재현 없음 확인.

## 2026-06-08 Play internal deploy 실행 완료
- `E:\FluxStudio\tools\deploy-play.bat planflow`를 실행해 내부 테스트용 배포 흐름을 완료했다. `pubspec.yaml` 버전은 `1.1.0+7 -> 1.1.0+9`로 올라갔고, release AAB도 다시 생성됐다.
- 이번 실행에서 콘솔 출력은 비어 있었지만 종료 코드는 0이었고, `build/app/outputs/bundle/release/app-release.aab` 갱신과 `pubspec.yaml` 버전 증가를 확인했다.

## 2026-06-08 deploy-play version result fallback 복구
- `scripts/bump-version-code.ps1`가 `OldVersion/NewVersion`만 가진 `PSCustomObject`를 반환하도록 정리하고, `scripts/deploy-play-internal.ps1`은 배열/문자열 혼합 반환에서도 `NewVersion`을 안전하게 추출한 뒤 실패 시 `pubspec.yaml` 버전으로 fallback 하도록 보강했다.
- `scripts/build-internal-aab.ps1`도 마지막에 버전/아AB 경로 표준 객체를 반환하도록 맞춰 deploy 호출부의 파싱 안정성을 높였다.
- 검증 통과: `E:\FluxStudio\tools\deploy-play.bat planflow -SkipUpload` 실행 완료, version `1.1.0+6 -> 1.1.0+7` bump 확인, `analyze/test/build appbundle` 모두 성공, 최종 validation 메시지 출력 확인.

## 2026-06-07 Play 자동 업로드 GPP 전환
- Google Play 내부 테스트 배포 자동화의 업로드 엔진을 fastlane에서 Gradle Play Publisher(GPP)로 전환했다. `android/app/build.gradle.kts`에 `com.github.triplet.play` 플러그인과 internal track, 서비스 계정 경로 주입을 연결했고, 업로드용 Gradle property는 `planflowPlayServiceAccountJson`로 받도록 맞췄다.
- `scripts/deploy-play-internal.ps1`는 fastlane/Ruby/gem 검사와 안내를 제거하고, version bump -> analyze -> tests -> release AAB 빌드 -> GPP publish 흐름으로 바꿨다. `-SkipUpload`면 빌드/검증만 하고 업로드는 건너뛴다.
- `E:\FluxStudio\tools\README-play-deploy.md`와 `deploy-play.bat`도 Windows/GPP 기준으로 갱신했다.
- 검증 통과: `scripts/flutter-local.ps1 build appbundle --release --no-pub`로 release AAB 생성 확인, PowerShell 스크립트 문법 검사 통과. GPP publish task 확인은 Gradle 스타트업이 오래 걸려 별도 업로드 실행 없이 보류했다.

## 2026-06-07 월간 위젯 예비줄 스타일 정리와 AI 제목검색/날짜이동 복구
- 월간 위젯의 overflow 예비줄을 다른 일정 줄과 같은 왼쪽 정렬/색상 계열로 맞춰서, 아래쪽 텍스트가 별도 안내처럼 보이지 않게 정리했다.
- `VoiceConversationController`는 제목/사람 검색의 기본 1개월 범위와 확장 질문 흐름, 그리고 `이 일정 6월 19일로 바꿔줘` 같은 후속 날짜 이동을 현재 날짜 기준으로 제대로 해석하도록 보강했다.
- `test/services/home_widget_service_test.dart`의 월간/주간 payload 기대값을 현재 visible row 수에 맞춰 갱신했다.
- 검증 통과: `scripts/flutter-local.ps1 test test/services/voice_conversation_controller_test.dart test/services/home_widget_service_test.dart test/services/notification_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.102:46561 install -r -t build/app/outputs/flutter-apk/app-debug.apk`, `adb -s 192.168.0.102:46561 shell am start -W -n com.fluxstudio.planflow/.MainActivity`.

## 2026-06-08 1x1 위젯 직행과 음성 조회 후보 정밀화
- 1x1 위젯으로 진입할 때는 앱 시작 중 로그인 화면이 잠깐 보이지 않도록 `startupRouteGate`를 추가해 widget launch pending 동안 라우터의 로그인 redirect를 억제했다.
- 음성 입력의 `완료` 동작은 현재 입력을 캡처한 뒤 즉시 다음 단계로 이어지도록 정리해, 별도의 `현재 내용으로 입력` 재탭 없이도 다음 화면으로 넘어가게 했다.
- `voice_action_screen.dart`의 제목/이름 검색은 `만나기라` 같은 조사 꼬리를 정규화하고, 정확 일치가 있으면 그것만 우선 보여주며 약한 유사 후보는 숨기도록 조정했다. 날짜 기반 조회는 `이번주금요일` 같은 표현이 summary 카드로 계속 보이도록 유지했다.
- 검증 통과: `scripts/flutter-local.ps1 test test/app_home_widget_route_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/screens/voice_input_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/screens/voice_action_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.102:33527 install -r -t --user 0 build/app/outputs/flutter-apk/app-debug.apk`, `adb -s 192.168.0.102:33527 shell am start -W -n com.fluxstudio.planflow/.MainActivity`.

## 2026-06-11 GroupEvent UI baseline
- Added GroupEventProvider, GroupEventList, GroupEventCreate, and GroupEventDetail screens plus `/groups/events` routes.
- Wired the GroupList entry point to the new group event flow without touching the personal event screens.
- Verified `flutter analyze --no-pub`, targeted group tests, full `flutter test --no-pub`, and `git diff --check`.

## 2026-06-11 voice / event_edit polish
- 이번 턴에서 이벤트 편집 저장 버튼을 더 크고 색이 있는 버튼으로 바꿨고, 음성 날짜 파서에 "28일" 단독 입력을 현재 달로 해석하는 경로를 추가했다. 또한 `VoiceScheduleStructureService`의 날짜 범위 해석이 시간 범위와 충돌하지 않도록 경계를 보강했다.
- 검증 통과: `scripts/flutter-local.ps1 test test/services/voice_date_range_parser_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/screens/event_edit_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 test test/services/voice_schedule_structure_service_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `adb -s 192.168.0.103:45819 install -r -t build/app/outputs/flutter-apk/app-debug.apk`, `adb -s 192.168.0.103:45819 shell am start -W -n com.fluxstudio.planflow/.MainActivity`.

## 2026-06-11 달력 위젯/일정탭 가독성 정리
- 월간 위젯과 앱 내 calendar 탭의 일정 렌더링을 packed cell 방식으로 맞춰, 남는 공간이 있으면 실제 일정을 우선 채우고 정말 부족할 때만 `+n`을 보여주도록 정리했다.
- 연속 일정은 위젯처럼 이어지는 밴드로 보이게 바꾸고, 공휴일 날짜는 빨간색으로 강조했다.
- 분석/테스트/디버그 빌드와 실기기 설치까지 확인해 가독성 회귀를 막았다.

## 2026-06-12 PlanFlow main 브랜치: 달력/음성 검색/키보드 정리 진행 중
- 월간 위젯과 일정탭의 여분 슬롯 표시를 조정하고, +n 표시와 일정 밴드 스타일을 손봤다.
- AI 일정 대화의 키보드 인셋 대응, 날짜 단독 입력(28일) 해석, 제목/이름 검색 정규화를 보강했다.
- focused test/analyze/build/install까지는 통과했고, 실기기에서는 PlanFlow 홈 화면까지 재진입을 확인했다. 달력 화면의 시각 확인은 다음 재진입 때 추가 점검이 필요하다.
## 2026-06-12 GroupDashboard baseline
- Added GroupDashboardRepository, GroupDashboardProvider, GroupDashboardState, and GroupDashboardScreen for leader-oriented summary counts and upcoming events.
- Wired a minimal GroupList dashboard entry point without touching calendar overlay or personal event screens.
- Verified `flutter analyze --no-pub`, targeted dashboard/group tests, full `flutter test --no-pub`, and `git diff --check`.

## 2026-06-12 일정탭 overflow와 연속일정 표시 보정
- 앱 내 일정탭 월간 그리드가 5줄을 억지로 렌더링하다 Flutter OVERFLOWED BY 디버그 문구가 빨간색으로 보이던 문제를 수정했다.
- 한 날짜 칸은 최대 4줄 체계로 제한하고, 숨겨진 일정은 마지막 표시 슬롯 대신 오른쪽 정렬 +n개로 보여주도록 조정했다.
- 연속 일정의 중간/끝 구간도 빈 밴드가 아니라 ----, --> 표시를 넣어 이어진 일정임을 알 수 있게 했다.
- 검증: calendar_screen_test, nalyze, debug APK build, ADB install/launch 확인.
## 2026-06-12 일정탭 연속 일정 밴드 연결 보강
- 일정탭 월간 그리드의 연속 일정 표시를 문자(----, -->)가 아니라 날짜 칸 경계를 넘는 실제 색상 밴드로 이어지게 조정했다.
- 중간/끝 구간의 텍스트 표시는 제거하고, 시작 구간 또는 주 시작 구간에만 제목을 보여줘 달력 위젯과 비슷한 시각 흐름을 만들었다.
- 검증: calendar_screen_test, analyze, debug APK build, ADB install/launch 확인. 기기 화면 잠금으로 최종 달력 화면 스크린샷은 확인하지 못했다.

## 2026-06-12 일정탭 연속 일정 밴드 겹침 보정
- 앱 내 일정탭 월간 그리드의 연속 일정 밴드가 인접 날짜에서 살짝 겹치며 중간이 진해 보이던 문제를 보정했다.
- 날짜 칸 좌우 1.5px 여백만큼만 확장하도록 조정해, 밴드가 끊기지 않고 맞닿되 투명도 중첩으로 진해지지 않게 했다.
- 검증: `scripts/flutter-local.ps1 analyze --no-pub` 통과, debug APK 산출물 갱신 확인, ADB install/launch 및 앱 PID 확인.

## 2026-06-12 연속 일정 색상 구분 적용
- 앱 내 일정탭과 Android 월간 위젯의 연속 일정은 연한 세이지 그린 배경과 짙은 그린 텍스트로 표시하도록 맞췄다.
- 중요+연속 일정은 세이지 그린 배경을 유지하고 상단 코랄 포인트 라인을 얹어, 기간 의미와 중요 표시가 동시에 보이게 했다.
- 검증: `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, ADB install/launch 및 앱 PID 확인.

## 2026-06-12 중요+연속 일정 텍스트 위치 보정
- 중요+연속 일정의 코랄 상단 라인이 제목 윗부분을 가려 보이지 않도록, 해당 케이스에서만 제목을 1px 아래로 내렸다.
- Android 월간 위젯도 같은 조건에서 텍스트 top padding을 1px 적용해 앱 안 일정탭과 시각 흐름을 맞췄다.
- 검증: `scripts/flutter-local.ps1 analyze --no-pub`, debug APK 산출물 갱신, ADB install/launch 및 앱 PID 확인.

## 2026-06-12 선택된 연속 일정 밴드 연결 보정
- 앱 내 일정탭에서 선택된 날짜의 연속 일정 라벨이 흰 반투명 스타일로 바뀌며 주 경계처럼 끊겨 보이던 문제를 수정했다.
- 선택된 날짜라도 연속 일정은 세이지 그린 밴드와 텍스트 색을 유지하게 해, 일요일 시작 구간과 다음 월요일 구간이 같은 일정으로 이어져 보이게 했다.
- 검증: `scripts/flutter-local.ps1 test test/screens/calendar_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, `git diff --check`. ADB 기기가 없어 설치/실행은 진행하지 못했다.

## 2026-06-12 일정탭 주 경계 기준 수정
- 앱 내 일정탭 월간 그리드가 일요일 시작 달력인데 연속 일정 세그먼트는 월요일 시작 기준으로 끊고 있어, 일요일마다 밴드가 끝나는 문제를 수정했다.
- 연속 일정의 주 시작/끝 판단을 일요일 시작, 토요일 끝으로 맞춰 일요일 칸에서도 다음 날짜로 이어지는 밴드처럼 보이게 했다.
- 검증: `scripts/flutter-local.ps1 test test/screens/calendar_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, debug APK 산출물 갱신, ADB install/launch 및 앱 PID 확인.

## 2026-06-12 중요 연속 일정 코랄 라인 연결 보정
- 중요+연속 일정의 상단 코랄 라인이 텍스트용 좌우 padding 안에서 그려져, 초록 밴드는 이어져도 빨간선만 날짜 칸마다 끊겨 보이던 문제를 수정했다.
- 밴드 컨테이너 padding을 제거하고 텍스트에만 좌우 padding을 적용해, 코랄 라인이 초록 밴드와 같은 폭으로 이어지게 했다.
- 검증: `scripts/flutter-local.ps1 test test/screens/calendar_screen_test.dart --no-pub`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build apk --debug --no-pub`, ADB install/launch 확인.

## 2026-06-13 Play 광고 ID 선언 대응
- 광고 기능을 넣지 않았는데 Play Console에서 광고 ID 선언 오류가 나는 원인을 `firebase_analytics` -> Google measurement SDK의 AD_ID/AdServices 권한 주입으로 확인했다.
- `firebase_analytics` 의존성과 초기화를 제거하고, 기존 `AnalyticsService` 호출부는 no-op으로 유지해 앱 기능 코드의 호출 계약은 보존했다.
- Android manifest에는 AD_ID/AdServices 권한 제거 지시를 남겨 향후 transitive SDK가 들어와도 광고 ID 권한이 병합되지 않게 했다.
- 검증: `flutter pub get`, `scripts/flutter-local.ps1 analyze --no-pub`, `scripts/flutter-local.ps1 build appbundle --release --no-pub`, 릴리즈 AAB/manifest 문자열 검사에서 AD_ID/ACCESS_ADSERVICES/play-services-measurement 미검출. Play commit은 기존 alpha/보류 변경의 광고 ID 선언 상태로 계속 차단됨.

## 2026-06-13 Group member remove RPC 보강
- `group_members` 제거 경로를 UI/provider의 직접 update에서 `remove_group_member` RPC로 옮겨 서버 측에서 자기 자신 제거와 마지막 리더 제거를 함께 차단했다.
- `group_members` RLS는 직접 `removed` 갱신 경로를 좁히고, 리포지토리 테스트에는 RPC 주입 훅과 리더 검증 훅을 추가해 호출 경로를 안정적으로 검증했다.
- 검증: `flutter analyze --no-pub`, `flutter test --no-pub test/features/groups -r compact`, `flutter test --no-pub`, `git diff --check`.
