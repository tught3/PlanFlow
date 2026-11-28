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
전체 목록: `04_Memory/Preference/` (status: confirmed, 총 14개). 작업과 관련 있어 보이면 열람할 것.

최근 확정 5건:
- **escalation_and_ai_handoff**:  (`04_Memory/Preference/escalation_and_ai_handoff.md`)
- **보고양식맞춰서_완료보고해줘**: 모든 구현 작업이 끝나면 사용자가 요청한 항목별 결과를 빠짐없이 대조한 완료보고를 즉시 제공한다. 보고서는 한 번에 복사해 붙여넣기 쉽도록 하나의 자기완결형 Ma... (`04_Memory/Preference/보고양식맞춰서_완료보고해줘.md`)
- **production_app_emulator_test**:  (`04_Memory/Preference/production_app_emulator_test.md`)
- **instruction_md_auto_optimize**: 모든 세션·모든 도구에서 AGENTS.md·CLAUDE.md·preference 등 지시 문서를 추가/변경/삭제할 때, CEO에게 요청받지 않아도 자동으로 최적화... (`04_Memory/Preference/instruction_md_auto_optimize.md`)
- **auto-finish-after-main-merge**:  (`04_Memory/Preference/auto-finish-after-main-merge.md`)

<!-- [AI_WIKI_COMMON_RULES:START] -->
## AI_WIKI 공통 규칙
- **조사·분석·계획·지시서 작성·통합 리뷰**: **Claude Code ↔ Antigravity**만 담당한다(한도·상황에 따라 교차 사용, 앱 코드 구현 금지, ZCode 제외).
  - Claude는 `flux_delivery_gate.py`, Antigravity는 `flux-ceo-rules/hooks.json` PreToolUse 게이트로 차단한다.
  - Claude: `E:/AI_WIKI/04_Memory/Preference/claude_plans_codex_implements.md`
  - Antigravity: `E:/AI_WIKI/04_Memory/Preference/antigravity_plans_codex_implements.md`
- **구현 전담 (한도 우선순위 · 난이도 분리 교차)**:
  - **1순위(한도 여유 시)**: **MiniMax Code + ZCode**로 구현한다. MiniMax는 난이도별 추론 강도(`low`/`medium`/`high`/`xhigh`)를 차등 적용해 가능한 작업을 구현하고, `xhigh`로도 1회 완수가 어려운 고난도 항목은 가능한 작업 완료 후 마지막에 ZCode 이관 항목으로 분리 보고한다. **ZCode**(`GLM-5.4`/`GLM-5.3-Flash`)는 MiniMax 한계 밖 고난도 구현을 맡고, 두 구현 결과는 Claude/Antigravity가 통합 리뷰한다(지시서 작성 시 MiniMax용과 ZCode용을 사전 분리 발행).
  - **2순위(MiniMax·ZCode 한도 소진 또는 일괄 구현 시 ↔ 자유 왕복)**: **Codex**가 난이도 무관 전체 구현을 담당한다. DeepSeek Harness는 CEO 직접 지시 작업을 수행한다.
- **프로덕션 배포 앱의 수정 검증**은 공용 에뮬레이터 A/B/C 풀에서만 한다. 코드 수정 전에 점유 중인 에뮬레이터 슬롯·ADB 임대를 반납하고 수정 후 재검증에 필요한 권한을 다시 획득한다.
- **완료·결과 보고**는 결과, 수행 내역, 검증 증거, 변경 파일·마무리 상태, 남은 위험을 마지막 줄까지 Markdown 코드 펜스 하나로 감싼다. 중첩 삼중 백틱은 금지하며 CEO 액션은 눈에 띄게 표시한다.
- **조사·계획·지시서·검토 승격**은 Claude·ZCode·Antigravity가 동일 원인으로 2회 초과 실패하면 즉시 상위 모델로 전환하고, 최상위 티어도 실패하면 타 AI 인수인계 패키지를 자동 준비해 보고한다.
- **조사·분석 전 기준 확인**은 프로젝트 루트에서 `git branch --show-current`, `git status --short`, `git log -n 5 --oneline`, `git worktree list`, `git fetch`, `git branch -a --sort=-committerdate`로 최신 상태를 실측·보고한다. 보고 첫 줄에 기준 브랜치와 커밋 SHA를 적고 과거 메모리·백업을 현재 코드의 근거로 쓰지 않는다.
- **CEO 규칙 추가·변경**은 모든 도구에서 `04_Memory/Preference/` 유사·중복 문서 통합·아카이브와 원본 최신화 → `global-common-rules.md` 정본 최신화 → `sync-ai-rules-hub.ps1` 실행 → `optimize_instruction_md.py --check --strict --json` 검증 순서로 전파한다. 생성 파일은 허브로 갱신한다.
- AI_WIKI common rules: E:/AI_WIKI/00_Constitution/global-common-rules.md
<!-- [AI_WIKI_COMMON_RULES:END] -->

<!-- [WIKI:END] -->

## 과거 기록 보관
비관리 영역에 있던 과거 기록(원인 로그 등)은 `AGENTS_ARCHIVE.md`로 이전했다. 필요 시 열람.
