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
