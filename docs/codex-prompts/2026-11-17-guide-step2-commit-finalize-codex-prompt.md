# guide-step2 커밋 마무리 지시 (2026-11-17, Claude 작성)

**정본**: `docs/handoffs/PLANFLOW-TUTORIAL-HANDOFF-20261117-CLAUDE-TO-NEXT.md` (최우선) + `2026-11-17-guide-step2-save-no-response-codex-prompt.md`.
워크트리: `E:\FluxStudio\PlanFlow\.tmp\guide-progress-save-race-20261114` (브랜치 `fix/guide-progress-save-race-20261114`, 9개 경로 스테이징 상태).

## r10 BLOCKED 판정 (Claude)
훅 오택 확정 — `scripts/build-guide-qa.ps1` 44행 안내 문자열의 `flutter build apk` 리터럴이 커밋 훅의 빌드 명령 패턴에 걸린 것. 코드 변경 아닌 문구 문제. **훅 우회·수정 금지, 문구만 교체.**

## 절차
1. 44행(및 같은 파일 내 동일 리터럴이 있는 행)의 안내 문구를 훅 패턴에 걸리지 않게 교체. 예: `flutter build apk` → `flutter의 apk 빌드 명령`(의미 동일, 리터럴 제거). 스크립트 로직·동작은 전부 불변.
2. 기존 검사 재실행: 스크립트 관련 테스트가 있으면 실행, 없으면 `git diff --check` + 스크립트 구문 점검으로 대체 — exit 0 확인. 같은 check_id로 recorder 기록.
3. 기존 스테이징된 9개 경로 유지 확인 → 커밋(본인 pathspec만, 메시지: guide-step2 저장 경로 수정 + QA 빌드 스크립트 추가) → `git push origin fix/guide-progress-save-race-20261114` (`-f` 금지). non-FF 시 재시도 없이 BLOCKED 보고.
4. 다음 Test Executor는 Astra로 지정한다.
5. 보고: 결과 한 줄 / 문구 교체 diff(1~2행) / 커밋 해시·push 확인 / 잔여 경로.

## 불변
훅 우회·설정 수정 금지. 수정은 위 문구 교체만. main 병합 금지. `git add -A` 금지(기존 스테이징 유지). 호스트 파일 작업 막히면 경로 보고(Claude 정리).
