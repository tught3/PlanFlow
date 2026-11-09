# v8c 지시 — 후속 정리(디플레이크 + QA 트리 정리) (2026-11-10, Claude 작성)

**정본**: v8b-r9 종결. **폰·서버 작업 없음.**

## v8c-1 플레이크 테스트 디플레이크 (main 트리)
대상: `test/ios_release_contract_test.dart`의 "pipe-safe version capture preserves a multi-line producer" — Git Bash `-lc` 로그인 셸 기동 스파이크에 30초 상한이 걸려 간헐 타임아웃(r3 통과/r6·r7 타임아웃 실증).
1. 원인 구조 확인: 테스트 본문(L876 부근)의 Process.run 타임아웃 상수와 `-l` 사용 지점 파악.
2. 최소 수정(택일 순서): ① `-lc` → `-c`(로그인 셸 불필요 시) 또는 프로파일 로딩 제외 ② 상수 30초→120초 상향 ③ 1회 재시도 래퍼. **①이 가능하면 ①만.** 테스트의 검증 의미(멀티라인 producer 파이프 전달)는 불변.
3. 해당 테스트 파일 전체 1회 실행(TZ unset 유지) + 타깃 관련 contract 테스트 확인. main 브랜치에 직접 커밋 금지 — 임시 워크트리 경유(기존 절차): worktree add origin/main → 수정·테스트 → 커밋 → push origin HEAD:main → 워크트리 제거·prune. 훅 지연 감안(완료까지 대기, stale lock 시 경로 보고).

## v8c-2 QA 트리 정리
기능은 main에 반영 완료(d25d1bb8). QA 트리 `.tmp/voice-first-tour-20261017`는 **제거한다**:
1. 사전 확인: `git -C E:/FluxStudio/PlanFlow/.tmp/voice-first-tour-20261017 log --oneline -3`이 origin/main에 포함됨(fetch+merge-base 또는 cherry 확인). 커밋 누락이 있으면 즉시 중단 보고.
2. 미추적 잔여 중 **보존 가치 파일**(.codex/tasks 상태 JSON, manual-guide-entry 문서, 진단 jsonl 등)을 `E:/FluxStudio/PlanFlow/.codex/tasks/qa-tree-archive-20261110/`로 복사(이동 아님, qa-live 링크·토큰 파일 제외 — 토큰 파일은 복사 금지).
3. `git worktree remove --force E:/FluxStudio/PlanFlow/.tmp/voice-first-tour-20261017` → prune → worktree list 0 확인(브랜치 fix/voice-first-tour-20261017은 원격에 남아 있으므로 안전). `qa/voice-tour-physical-20261018` 워크트리는 이번 범위 아님 — 건드리지 말 것.
4. 문서 갱신: 인수인계서(`docs/handoffs/PLANFLOW-TUTORIAL-HANDOFF-20261106-CLAUDE-TO-NEXT.md`) 말미에 종결 부기 1단락(QA COMPLETE·main 통합 d25d1bb8·v7s 결과는 별도 보고) — 이건 커밋해서 main push.
5. 보고: 결과 한 줄 / 디플레이크 수정 내용·테스트 증거 / 아카이브 파일 수·경로 / 워크트리 제거 확인 / 커밋 해시 / 잔여 경로.

## 불변
폰·ADB·서버 0. v7s 라운드와 동시 실행 금지(순차 — 폰 작업이 끝난 뒤 가능하지만, 서로 소유 영역이 다르므로 Codex 판단으로 순서 무관 단, 폰은 v7s 전용). 메인 워크트리 dirty 파일(타 세션) 건드림 금지. force push 금지. 토큰·키 출력 금지. 토큰 파일 복사 금지. 호스트 파일 작업 막히면 경로 보고(Claude 정리).
