# v8b-r1 델타 지시 (2026-11-08, Claude 작성)

**정본**: v8b 델타. **BLOCKED 원인 확정 — v8a 커밋 누락이 근본 원인.**

## Claude 진단 (직접 확인)
- analyze 오류 1건의 원인: `utteranceHasExplicitEndOrDurationCue`의 **정의가 v8a 커밋에 누락됨**. 정의는 QA 트리 워킹 카피 `lib/services/event_range_utils.dart`(아직 ` M` — 미커밋)에 있고, 분기 커밋 34a26d24엔 구버전만 들어감.
- 같은 사고 유형이 더 있음: QA 트리에 **트래킹된 수정 16파일 +625/−111**(event_detail_screen, voice_conversation_controller, gpt_service, map_service, notification_service, voice_action_screen + 대응 테스트)과 미추적 테스트(test/services/event_range_utils_test.dart 등)가 **커밋 누락 상태**. 즉 v8a의 "선별 add"가 기능 소스의 최신 수정을 빠뜨렸고, 브랜치는 불완전.
- ADB getprop 중단: test/** 안의 네이티브 프로브성 테스트가 adb를 호출하는 것으로 추정 — 오프라인 스위트에서 해당 파일 제외로 해소.

## v8b-r1 실행 절차
1. **QA 트리 누락분 커밋**: `.tmp/voice-first-tour-20261017`에서 `git status --porcelain` 기준:
   - 포함: 트래킹된 ` M` 소스·테스트 전부(lib/, test/, android manifest, GeneratedPluginRegistrant, supabase/functions), 미추적 중 `test/**` 파일(event_range_utils_test.dart 포함)과 기능에 필요한 integration_test 파일.
   - 제외: `*.bak-*`, `.codex/`, `manual-guide-entry-*.md`, 로그·티켓·빌드 산출물.
   - 하나의 커밋으로 fix/voice-first-tour-20261017에 추가 → push origin(메시지: "v8a 누락분 보완 — event end-cue·컨트롤러·서비스 최신 수정").
2. **머지 트리 갱신**: `.tmp/main-merge-tmp`에서 fetch → `git reset --hard origin/main` → 다시 `git merge --no-ff fix/voice-first-tour-20261017`(충돌 시 BLOCKED).
3. **analyze**: 0 오류 확인(경고·정보는 기록만). 오류가 더 나오면 동일 유형(정의 누락)인지 확인하고 1단계 재확대 — 재귀 최대 2회.
4. **오프라인 타깃 테스트**: `test/**` 대상 실행. adb getprop을 호출하는 테스트 파일이 나오면 그 파일만 제외 목록에 기록하고 나머지로 통과 판정. readback "(a)"·H5/H4·시간대 신규 테스트 포함 필수.
5. **push main**: `git push origin HEAD:main`(거부 시 BLOCKED) → 워크트리 remove --force + prune.
6. 보고: 결과 한 줄 / 누락분 커밋 해시·파일 수 / analyze 0오류 / 테스트 통과·제외 목록 / 머지 커밋·push 확인 / 잔여 경로.

## 불변
v8b 불변 전부 유효(폰·서버 0, QA 트리 브랜치 커밋만 가능·main 직접 수정 금지 — 머지 워크트리 경유, force push 금지, 타 세션 dirty 건드림 금지, 토큰 출력 금지). `git reset --hard`는 위에서 지정한 머지 워크트리 한정으로 허용.
