# v8b 본앱 머지 지시 (2026-11-08, Claude 작성, CEO 승인 "남은거 전부다 진행해")

**정본**: v8a 델타. **이번이 본앱(main) 통합 단계다.**

## v8a 리뷰 판정 (Claude)
- COMPLETE 인정: H4/H5 수정·집중 6/6·스위트 399/400·커밋 34a26d24 원격 일치. main 머지 보류도 지시대로.
- diff 스코프 검토 완료(Claude 직접): 114파일 +30,226/−1,540 — lib(onboarding/screens/data/core/services/l10n)·test·integration_test·android(native probe)·supabase 마이그레이션 1건. **브랜치 tip(d7c8bb67)은 main에 이미 포함 → 머지는 사실상 단일 커밋 반영, 충돌 위험 낮음.**
- 머지 전 재검증 2건(독립 리뷰 지적): ① readback "(a)" 테스트 0 실패 원인 ② OS·앱 시간대 차이 날짜 복원.

## v8b 실행 절차
1. **readback "(a)" 원인 규명(test 폰 스코프)**: `test/screens/event_detail_guide_readback_test.dart:77` — 앵커 0개 원인을 테스트 셋업(게이트 조건 누락: createdEventId/sessionId/uid 세팅, pump 타이밍)에서 특정. **프로덕션 코드 수정은 게이트 로직 버그가 확정될 때만** — 그 경우 수정 전 diff를 보고하고 대기하지 말고 수정·테스트 통과까지 진행(단, 변경은 event_detail_screen 게이트 또는 테스트 중 한쪽 최소화).
2. **시간대 재검증**: H5 수정(toLocal)이 러너 TZ(KST)에 의존하지 않는지 — 오프셋 문자열(`+09:00` 외 `+00:00`/`-05:00`/`Z`) 입력으로 날짜 복원 단위 테스트 1건 추가(guide_route_recovery 대상) 후 통과 확인.
3. **main 머지**: PlanFlow 루트에서 임시 워크트리 생성(`git worktree add E:/FluxStudio/PlanFlow/.tmp/main-merge-tmp origin/main -b main-merge-tmp`) → `git merge --no-ff fix/voice-first-tour-20261017` → 충돌 시 재시도 없이 BLOCKED 보고 → 머지 워크트리에서 `flutter analyze` + real_ui_guide 관련 타깃 테스트 전부 통과 → 통과 시 `git push origin HEAD:main`(non-FF·거부 시 재시도 금지 BLOCKED) → 머지 워크트리 remove --force + prune. push 성공이 완료 기준.
4. 머지 후 확인: origin/main에 머지 커밋 존재(fetch+rev-list), QA 트리는 그대로(건드리지 않음).
5. 보고: 결과 한 줄 / (a) 원인·조치 / 시간대 테스트 증거 / 머지 커밋 해시·푸시 확인 / analyze·테스트 수 / 잔여 경로.

## 불변
폰 조작·서버 호출 0. QA 트리(`.tmp/voice-first-tour-20261017`)의 파일 수정 금지 — 이번 수정은 머지 워크트리에서만(1~2단계는 브랜치에 커밋한 뒤 머지하거나, 머지 워크트리에서 커밋 후 merge 구성 — Codex가 안전한 쪽으로 택하되 브랜치 push도 갱신). 메인 워크트리(E:\FluxStudio\PlanFlow 루트) dirty 파일 건드리지 금지. force push·kill-server·큐 state 편집 금지. 토큰 출력 금지.
