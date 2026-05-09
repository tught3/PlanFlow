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
- GSD 초기화가 없던 저장소에 2026-04-01 기준 기본 `.planning` 문맥을 생성했다.
- 메인 앱과 `lite-app` 모두 금융 파이프라인 구조 로그를 일부 도입한 상태다.
- `npm run check`와 `npm run test:financial-regression`은 최근 작업 기준 통과 상태다.
- 환경 제약 때문에 이 세션에서는 `npm run build`가 `vite/esbuild spawn EPERM`으로 막힐 수 있다.
- Phase 6으로 GSD 컨텍스트 위생 자동화를 추가해 장기 세션 품질 저하를 줄이는 작업을 시작했다.
- 사용자가 별도로 중지하지 않는 한 항상 GSD 우선 모드로 작업한다.
- 새 세션에서는 `.planning/STATE.md` 확인 후 `gsd-progress` 성격으로 현재 상태를 먼저 정리한다.
- 새 세션 시작 직후와 최종 완료 보고 직전에는 `node scripts/gsd-context-hygiene.mjs`를 자동 실행해 활성 요약을 갱신한다.


- 2026-05-09~10: `CODEX_FIREBASE_SETUP.md` 기준으로 Firebase Step 1~5를 순서대로 진행했다. `pubspec.yaml`에 `firebase_core`, `firebase_crashlytics`, `firebase_analytics`를 추가했고, `android/settings.gradle.kts`와 `android/app/build.gradle.kts`에 Google Services/Crashlytics 플러그인을 연결했다. `lib/main.dart`에서 `Firebase.initializeApp()`과 Crashlytics 전역 오류 핸들러를 붙였고, `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build apk --release`, 실기기 설치/실행까지 통과했다. `flutter pub get`은 Windows symlink 지원 경고가 있었지만 이후 검증은 정상 통과했다.
- 2026-05-10: Supabase `calendar_sync_patch.sql` / `schema.sql`에서 `upsert_naver_caldav_credentials` 함수 생성보다 앞서 있던 `REVOKE/GRANT`를 함수 뒤로 이동시켜 SQL Editor의 `42883 function ... does not exist` 실패를 정리했다. 다음 적용 때는 함수 생성 후 권한 부여 순서로 실행된다.

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
