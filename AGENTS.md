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
전체 목록: `04_Memory/Preference/` (status: confirmed, 총 11개). 작업과 관련 있어 보이면 열람할 것.

최근 확정 5건:
- **보고양식맞춰서_완료보고해줘**: 모든 구현 작업이 끝나면 사용자가 요청한 항목별 결과를 빠짐없이 대조한 완료보고를 즉시 제공한다. 보고서는 한 번에 복사해 붙여넣기 쉽도록 하나의 자기완결형 Ma... (`04_Memory/Preference/보고양식맞춰서_완료보고해줘.md`)
- **worker-watchdog-policy**: 백그라운드 worker가 예상 시간을 초과하면 무조건 확인한다. 단순 대기 금지. (`04_Memory/Preference/worker-watchdog-policy.md`)
- **flux_routing_tiers_detail**:  (`04_Memory/Preference/flux_routing_tiers_detail.md`)
- **auto-finish-after-main-merge**:  (`04_Memory/Preference/auto-finish-after-main-merge.md`)
- **flux_gates_detail**:  (`04_Memory/Preference/flux_gates_detail.md`)

<!-- [WIKI:END] -->

## 과거 기록 보관
비관리 영역에 있던 과거 기록(원인 로그 등)은 `AGENTS_ARCHIVE.md`로 이전했다. 필요 시 열람.
<!-- FLOW-DEVICE-ISOLATION:START -->
## 가상 기기는 공용 A·B만 사용
- 프로젝트 전용 AVD와 이전 팜의 직접 시작은 금지한다. 공용 풀에서 A/B 중 한 자리를 임대하고 그 자리만 사용한 뒤 즉시 반납한다.
- 정본: `E:/AI_WIKI/04_Memory/Preference/android_emulator_farm_on_demand.md`. 실행 도구: `E:/FluxStudio/.tools/emulator-pool/Invoke-EmulatorPool.ps1`. 세 번째 요청부터 대기한다.
- 다른 세션의 임대를 빼앗지 않으며, 원래 실기기 큐·세로 고정·출시/금융 승인 경계는 그대로 유지한다.
<!-- FLOW-DEVICE-ISOLATION:END -->
