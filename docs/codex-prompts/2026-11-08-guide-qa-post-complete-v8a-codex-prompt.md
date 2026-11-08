# Guide QA 종결 후 — v8a 본앱 적용 1단계 지시 (2026-11-08, Claude 작성, CEO 승인 "남은거 전부다 진행해")

**정본**: v7r 종결 판정 + 인수인계. **이번부터는 QA가 아니라 본앱 적용 준비다.** 폰 조작·서버 호출 0.

## 배경 (Claude 조사 완료)
- 가이드 기능(lib/onboarding/real_ui_guide/ 전체)은 **어떤 브랜치에도 커밋되지 않은 상태**다. `fix/voice-first-tour-20261017` 브랜치 tip(d7c8bb67)에는 real_ui_guide가 없고, 전부 `.tmp/voice-first-tour-20261017` 워크트리의 미커밋 파일(lib 76+ 중 ?? 포함, 총 132 dirty)로만 존재한다. 워크트리 유실 시 기능 소실 위험.
- v7k(coordinator conflict 복구)·v7q(fence optional-background)·v7r 검증까지의 수정도 전부 이 미커밋 상태에 있다.

## v8a 실행 절차 (QA 트리: `E:\FluxStudio\PlanFlow\.tmp\voice-first-tour-20261017`)
1. **H5 수정**: `lib/onboarding/real_ui_guide/guide_route_recovery.dart` L35 근처 — `savedLocalDate`가 UTC(isUtc)면 `.toLocal()`로 변환한 뒤 날짜를 계산. `2030-01-02T01:30:00+09:00`·`Z` 문자열 모두 KST 달력 날짜(2030-01-02)로 복원되어야 함. H5 테스트 2건(guide_guards_consistency_test.dart)이 통과 기준.
2. **H4 수정**: `lib/onboarding/real_ui_guide/guide_guards.dart` L70 — `identity` 조건에서 `target.isMultiDay` 제거(캘린더는 다일 행을 앵커링하므로 recovery도 일관). H4 테스트 1건이 통과 기준. `groupEventId/externalId/recurrenceRule` 등 나머지 조건 유지.
3. **진단 확장**: `integration_test/real_ui_guide_manual_app.dart` L427 `_diagAnchorIds`에 `'saved.summary'`, `'saved.departure'` 추가.
4. **타깃 테스트**: H4/H5 관련 스위트(guide_guards_consistency_test 등 real_ui_guide 전체 + guide_route_recovery 관련) 실행 — H4 1건·H5 2건이 실패→통과로 전환되는지 확인. readback "(a)"(event_detail_guide_readback_test)은 셋업 문제로 남을 수 있음 — 변화만 기록.
5. **브랜치 커밋(본앱 적용의 전제)**: QA 트리에서 `git status --porcelain -uall` 전수 목록화 → **빌드 산출물·임시 파일(.dart_tool, build/, *.log, qa-live 링크 등) 제외**한 소스(lib/, test/, integration_test/, android 설정 등 기능 필수 파일)만 선별 add → 브랜치 `fix/voice-first-tour-20261017`에 커밋(메시지에 v7k/v7q/H4/H5 수정 포함 명시) → `git push origin fix/voice-first-tour-20261017`. non-FF·푸시 거부 시 재시도 금지 BLOCKED 보고. 커밋 훅이 막으면 banned-ok 주석 확인 후 재시도 1회, 그래도 막으면 해당 파일만 제외하고 보고.
6. **병합 범위 보고(커밋 후)**: `git log --oneline main..fix/voice-first-tour-20261017` 및 `git diff --stat main...fix/voice-first-tour-20261017` 요약(파일 수·라인 수·lib 외 영역 포함 여부)을 보고 — **main 머지는 실행하지 말 것.** Claude가 범위 검토 후 v8b 머지 지시서를 만든다.
7. 임시 파일은 삭제 시도 없이 경로만 보고.

## 불변
폰 조작·ADB·서버 호출 0. main 브랜치 조작(merge/commit) 금지 — 이번은 기능 브랜치만. 메인 워크트리(E:\FluxStudio\PlanFlow 루트)의 dirty 파일 건드리지 말 것(타 세션 작업). monkey/kill-server/큐 state 편집 금지. 토큰·키 출력 금지. 호스트 파일 작업 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / H4·H5 테스트 전환 증거(통과 수) / 커밋 해시·푸시 확인 / diff --stat 요약 / 잔여 경로.
