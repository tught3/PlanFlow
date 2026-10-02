<!-- [WIKI:START] Personal Wiki Reference - 직접 수정 금지 -->
<!-- 작업 경로: E:\FluxStudio\planflow -->
<!-- 생성: 2026-05-24 09:48 -->

## 참조 문서 (원본 위치 — 필요 시 직접 Read)
- Codex Common Rules: `00_Constitution/agents-common.md`
- Resource Optimization Rules: `00_Constitution/resource-optimization.md`
- AI Behavior Rules: `00_Constitution/ai-behavior-rules.md`
- Anti-Patterns: `00_Constitution/anti-patterns.md`
- 프로젝트 노트 (PlanFlow): `03_Projects/FLUXSTUDIO/planflow.md`

## 확정 선호 (CEO 승인)
전체 목록: `04_Memory/Preference/` (status: confirmed, 총 9개). 작업과 관련 있어 보이면 열람할 것.

최근 확정 5건:
- **no_visible_console_windows**: 사용자가 일부러 띄운 창을 제외한 모든 프로세스는 화면에 보이면 안 된다. 백그라운드·예약·스크립트 실행이 검은 콘솔 창(깜빡임 포함)을 만드는 것은 결함이다. (`04_Memory/Preference/no_visible_console_windows.md`)
- **instruction_md_auto_optimize**: 모든 세션·모든 도구에서 AGENTS.md·CLAUDE.md·preference 등 지시 문서를 추가/변경/삭제할 때, CEO에게 요청받지 않아도 자동으로 최적화... (`04_Memory/Preference/instruction_md_auto_optimize.md`)
- **auto-finish-after-each-task**: 모든 프로젝트·모든 세션·모든 코딩 프로그램에서, 작업 단위가 실제로 완료될 때마다 "마무리해" 지시 없이 자동으로 마무리 시퀀스를 실행한다. 항상, 어디서든,... (`04_Memory/Preference/auto-finish-after-each-task.md`)
- **workspace-hygiene-main-checkout**: 기존 프로젝트 메인 체크아웃과 현재 대화 내 난이도별 서브에이전트를 기본 작업 방식으로 사용한다. 새 worktree, runtime/session 디렉터리 또는... (`04_Memory/Preference/workspace-hygiene-main-checkout.md`)
- **glm-worker-pipeline-auto**: CEO가 비단순 작업(개발·수정·리팩토링·분석·리뷰)을 지시하면, GLM은 자동으로 worker pipeline 루프를 실행한다. CEO가 모델을 지정하지 않아도... (`04_Memory/Preference/glm-worker-pipeline-auto.md`)

<!-- [WIKI:END] -->

## 과거 기록 보관
비관리 영역에 있던 과거 기록(원인 로그 등)은 `AGENTS_ARCHIVE.md`로 이전했다. 필요 시 열람.
