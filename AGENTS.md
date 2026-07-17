## FluxOS 파이프라인 연결
이 세션의 작업 지시는 FluxOS 파이프라인을 통해 처리된다.

### 작업 시작 전 필수
`python E:\FluxStudio\.fluxos\pipeline\task_queue.py --input "<지시 내용>" --project "PlanFlow" --source "planflow"`

### 파이프라인 흐름
1. `task_queue.py`가 태스크를 생성한다.
2. `claude_runner.py`가 Claude Code 분석을 시도한다.
3. `TASK_{ID}_codex.md`를 읽고 Codex가 구현한다.
4. 완료 후 `TASK_{ID}_done.md`를 생성해 리뷰 단계로 넘긴다.

### 주의사항
- 이 프로젝트 폴더만 수정하고 다른 프로젝트에는 접근하지 않는다.
- Supabase 스키마 변경 시 대용님 확인이 필수다.
- 완료 시 빌드 확인, 커밋, 푸시까지 수행한다.

<!-- [WIKI:START] Personal Wiki Reference - 직접 수정 금지 -->
<!-- 작업 경로: E:\FluxStudio\planflow -->
<!-- 생성: 2026-05-24 09:48 -->

## 사용자 확정 선호
<!-- 04_Memory/Preference status:confirmed 항목 자동 반영. 원본 수정은 04_Memory/Preference/*.md에서, 승인/반려는 run.py memory confirm/reject로. -->
- **marketing-skills 플러그인처럼 상시 활성화 비용이 큰(~7,733 토큰/세션) 플러그인은 자동으로 켜지 않고, 관련 주제(ASO·구독전환·referral·paywall·이메일마케팅·가격정책·카피라이팅 등)가 나오면 먼저 사용자에게 활성화 여부를 물어본 뒤 사용한다.**
  - Why: always-on 비용이 개발 작업 세션에서 낭비되므로, 사용자가 필요할 때만 쓰길 원함. How to apply: 마케팅 관련 주제가 대화에 등장하면 작업 전에 '마케팅 스킬 플러그인 활성화할까요?'라고 먼저 물어보고 허락받은 후 해당 스킬(/paywalls, /referrals 등)을 사용한다.
- **워크트리에서 작업을 마치면 기능적으로 문제가 없는 한(빌드/테스트 그린, 회귀 위험 낮음) main으로 머지·푸시하는 것을 기본값으로 제안한다. 충돌이 발생하면 임의로 강제 처리(-X ours/강제푸시/리셋)하지 않고 대기 후 사용자에게 확인한다.**
  - Why(2026-06-30 CEO 방침): 워크트리 브랜치에 작업이 고립되면 잊혀지거나 다이버전스가 깊어진다. main에 빨리 합치는 게 깔끔하지만, 충돌·기능 위험은 사용자만 아는 맥락이라 판단을 넘긴다. How to apply: 워크트리 작업 완료 보고 시 'main으로 머지·푸시할까요?'를 기본 제안으로 붙인다. 단순 non-fast-forward는 pull --rebase로 자동 해소하되, 같은 줄 머지 충돌·기능 회귀 신호가 보이면 진행을 멈추고 충돌 내용을 요약해 물어본다.
- **장시간 실행되는 작업(테스트 스위트, 빌드, 백그라운드 명령 등)을 띄운 뒤에는 시키지 않아도 스스로 주기적으로 상태를 확인하고 진단한다. 5분 넘는 프로세스는 자동 점검 대상이며, 사용자가 먼저 물어서 확인하게 되면 그 자체가 실패다.**
  - Why: CLAUDE.md 리소스 규칙에 '30초 이상 무변화 시 즉시 상태 확인'이 명시돼 있음에도 반복적으로 어겨 CEO가 여러 번 지적함(2026-06-26 재지적, 2026-07-03 재발). How to apply: 백그라운드 작업 완료 알림을 받으면 즉시 로그를 확인하고 다음 단계로 진행하며, 완료를 기다리는 동안 사용자 입력 없이 손 놓고 방치하지 않는다. 변화 없으면 멈춤으로 진단(프로세스 생존/입력대기/병목)한다.
- **사용자가 어느 세션에서든(각 프로젝트 세션·FluxOS 큐 등 어디든) 지시에 '제발'이라는 단어를 쓰면, 그 지시는 반복 확인 없이 1회만 관찰해도 즉시 확정(confirmed)하고 바로 실행한다. 단, 그 지시가 '되돌리기 어려운 작업(구조 변경·데이터 삭제·외부 API 실제 호출·사업적 판단)'에 영향을 미치면 '제발'이라도 예외 없이 먼저 사용자에게 확인받고 진행한다 — ai-behavior-rules.md의 '반드시 질문' 조건은 그대로 유지된다.**
  - Why: 사용자가 '제발'을 강조·최우선 신호로 직접 지정함(2026-07-03). 다만 최초 등록 시도가 안전 분류기에 '되돌리기 어려운 작업까지 무조건 실행'으로 해석될 위험이 있다고 차단돼, 사용자가 직접 '구조 변경·데이터 삭제· 외부 API 실제 호출·사업적 판단에 영향 있으면 물어보고 진행'이라는 예외를 명시적으로 재확인함(2026-07-03). How to apply: '제발'이 포함된 지시는 원칙적으로 질문 없이 즉시 실행하되, 그 실행이 되돌리기 어려운 작업 범주에 해당하면 '제발'이라도 예외 없이 먼저 확인을 받는다. 나머지(되돌리기 쉬운 작업)는 기존 '질문 타이밍 기준'의 질문 없이 진행 조건과 동일하게 취급.
- **모든 상태·판단은 추측이 아니라 실측 근거(로그, 실제 조회 결과, 코드 확인)에 기반해서 보고한다. python datetime.now()는 UTC이므로 사용자에게 말할 때는 KST(+9) 환산값을 함께 제시한다.**
  - Why: 근거 없는 추측이 잘못된 조치로 이어져 문제를 키운다. 실제로 시각 착오(UTC를 그대로 KST처럼 말해 '9시간+ lock 만료 버그'로 오진단, 실제론 1시간 미만 정상 lock)로 문제를 키운 사례가 있었다. How to apply: 상태/숫자는 추정하지 말고 실측(audit_tasks, load_locks, git status 등)으로 집계해 보고한다. '확실하냐'는 질문엔 100% 보장 대신 보장 가능한 범위를 정직하게 말한다.
- **S23 테스트기기에 release APK를 설치할 때 INSTALL_FAILED_UPDATE_INCOMPATIBLE(서명 불일치)로 실패하면, 매번 물어보지 않고 adb uninstall 후 재설치를 즉시 진행한다.**
  - Why: 서버 계정 데이터는 Supabase에 있어 재로그인으로 복구되고, 로컬 캐시만 날아가는테스트기기 한정 저위험 작업이라 CEO가 반복 확인 없이 자동 진행을 승인함(2026-07-04). How to apply: PlanFlow 등 어떤 프로젝트든 S23 설치 중 이 에러가 나오면 확인 없이 adb uninstall <package> 후 adb install -r <apk>로 즉시 재설치한다. 프로덕션 서버 데이터나 다른 기기(S8 등)에는 적용하지 않는다 — S23 로컬 테스트 설치에만 한정.


# Codex Common Rules
<!-- 프로젝트 공통 Codex 작업 규칙 -->

## FluxOS Pipeline Gate
- FluxStudio 계열 프로젝트에서 사용자가 개발, 수정, 분석, 리뷰가 필요한 비단순 지시를 내리면 먼저 FluxOS 파이프라인을 사용한다.
- CEO OS 자동 파이프라인의 구현자·검토자 모델 배정은 `utils/routing_engine.py`(5종 사다리: GLM-5.2·MiniMax M3·DeepSeek Pro·DeepSeek Flash·GPT-5.4 Mini)가 단일 소스다. **Claude Opus/Sonnet·Codex GPT-5.6 Luna/Terra/Sol은 자동 라우팅에서 전면 제거**됐다(2026-07-16, 상세 사다리는 `AI_RULES.md` §7 참조). 대화형 Claude Code 세션이 직접 계획·리뷰를 맡는 흐름 자체는 유지되나, 그 세션이 CEO OS 자동 라우팅 대상은 아니다.
- 프로젝트 세션이 직접 코드를 수정해야 하는 경우에도 수정 전 `python E:\FluxStudio\.fluxos\run.py pipeline "<지시내용>" --project <Project> --source <session>` 또는 이미 생성된 task의 `pipeline-audit` 결과를 확인한다.
- 진행 확인은 `python E:\FluxStudio\.fluxos\run.py pipeline-audit [TASK_ID]`를 사용하고, 최소한 `Claude Code 계획` 단계가 생성됐는지 확인한 뒤 구현에 들어간다.
- Claude Code가 인증, 한도, 연결 문제로 실패하면 FluxOS의 Codex-only fallback을 사용하되, 최종 보고에 fallback 사유를 명시한다.
- 긴급 단순 수정으로 파이프라인을 생략한 경우에는 생략 사유, 변경 범위, 검증 결과를 최종 보고에 반드시 남긴다.
- 프로젝트 세션을 직접 열어야 하는 경우에도 먼저 `python E:\FluxStudio\.fluxos\run.py session start --project <Project> --source <session> --label "<세션명>" --cwd "<프로젝트경로>"` 또는 기존 세션에 `session attach`로 FluxOS 메타를 붙이고, 가능하면 `FLUXOS_SESSION_ID`, `FLUXOS_SESSION_PROJECT`, `FLUXOS_SESSION_TASK_ID`, `FLUXOS_SESSION_OWNER`, `FLUXOS_SESSION_SOURCE`, `FLUXOS_SESSION_LABEL`, `FLUXOS_SESSION_NOTE`, `FLUXOS_SESSION_CWD`를 함께 전달한다.

### 개발 지시 → 실행자 자동 선택 (Codex 위임 포함)
- 개발·수정·리팩토링 작업은 기존 FluxOS 파이프라인과 모델 라우터를 사용한다(메인 세션이 직접 구현하지 말고 등록·계획 후 진행).
- 계획 뒤 구현 실행자는 라우터가 자동 선택한다. 사용자가 명시적으로 Codex 위임을 요청한 경우에만 그 작업의 task metadata(`execution_policy=claude_plan_codex_implement`)로 해당 작업만 Codex 경로로 보낸다(전역 설정·기존 정책 변경 없음, 미지정 작업은 기존 중앙정책을 따른다).
- **[정책, CEO 결정 2026-07-17, 날짜 무관 영구 정책] Desktop(Claude Desktop·Codex Desktop)과 CEO OS 큐는 완전히 분리된다.** Desktop 세션에서 시작한 작업은 CEO OS 큐에 절대 등록하지 않는다 — 특정 시점까지의 임시 조치가 아니라 영구 정책이다. Desktop 세션은 시작부터 검토 완료까지 그 세션 안에서 직접 수행한다(직접 Edit/Write 허용, 파이프라인 등록·Scope Lock 연결 불필요). 역방향도 동일하게 금지한다: CEO OS 큐에서 시작된 작업이 Codex Desktop 같은 Desktop 전용 도구로 실행되는 경로는 두지 않는다.
  - CEO OS 큐에서 시작한 작업은 기존 CEO 파이프라인(`routing_engine.py` 5종 사다리)을 그대로 타고, 결과 보고는 CEO OS 커맨드센터 AI 채팅으로 수신한다.
  - Desktop 세션의 구현 모델 라우팅은 세션 종류로 나뉜다: **Claude Desktop = Claude 모델군**(단순 Haiku·중간 Sonnet·계획/리뷰/고난도 Opus), **Codex Desktop = Codex 모델군**(아래 "Codex Desktop 내부 기본 모델 라우팅" 참조). 구체 모델명·매핑표는 이 문서에 하드코딩하지 않고 단일 소스(Claude는 `config/claude-roles.json`, Codex는 `07_System/codex/model-routing.json`)를 가리킨다.
  - 날짜 기반 자동 전환은 두지 않는다. 과거 7/25 cutover처럼 시간이 지나면 자동 활성화되는 설계는 금지하며, 정책 변경은 오직 명시적 설정(코드·config) 변경으로만 이뤄진다.
  - (정리, 2026-07-17 실측 확인) 과거 문서에 있던 Desktop 코드편집 강제 게이트 opt-in 안내와 CEO OS 파이프라인/락 연결용 Desktop 세션 등록 명령 안내는 제거한다. 전자의 게이트 코드는 이번에 저장소에서 제거됐고, 후자의 등록 명령은 실제 `run.py`에 존재한 적 없는 허구 명령이었다.
- 계획 단계에서 그 지시가 실제 저장소 변경이 필요한지 구조화 값(`requires_repository_changes`/`task_intent`)으로 판정해 남긴다(CEO OS 큐 경로에 적용). 질문·설명·읽기전용 조사·계획만 요청이면 변경 불필요로 처리한다.
- 구현자와 검토자는 분리한다(구현 provider와 다른 provider의 독립 검토, **2026-07-16부터 1단계로 통합** — 과거 1차검토+2차검토 2단계 구조 폐지). 구현에 쓰인 provider는 그 Task의 검토 후보에서 제외한다(자기검토 금지). 구현 세션의 자기승인(done 내 자기평가)을 정식 검토로 인정하지 않는다.
- Claude 최종 단계는 중복 코드리뷰가 아니라 과정 감사(process QA)다: 계획이 요구를 반영했는지, 독립 1차검토가 실제로 검증했는지, PASS가 증거로 정당한지, 테스트가 사용자 요구를 증명하는지를 확인하고, 근거 없는 통과는 되돌린다.
- Desktop 세션(Claude·Codex 공통)은 CEO OS 큐에 등록하지 않으므로, 큐의 파이프라인 실행 기록(구현 모델·독립 검토 모델·QA 결과 등)에서 생성하는 실행 요약 카드를 적용할 수 없다. Desktop 세션의 완료 보고는 그 세션이 직접 수행한 계획·구현·검증·검토 내용을 응답에 그대로 담는다.
- 새 Claude Desktop 세션에서는 첫 사용자 응답 맨 위에, 현재 FluxOS 파이프라인·정책 상태를 요약한 세션 배너를 한 번만 표시한다(세션당 1회). 세션 생성 직후 무입력 자동 출력은 Desktop 제약상 불가하여 UserPromptSubmit hook가 배너를 주입하고 모델이 첫 응답에 렌더하는 방식이다. 배너는 관찰·안내 전용이며 실행 정책을 바꾸지 않는다. 검증된 Desktop origin·등록 프로젝트에서만 표시하고 다른 출처(Claude Code/CLI/데몬/CI/API)에는 표시하지 않으며, 중앙 FluxOS를 못 찾으면 성공 배너 대신 경고를 낸다. 배너 값은 실제 런타임 상태에서 읽고 날짜·모델 라우팅을 문서에 하드코딩하지 않는다.
- Claude Desktop 개발 작업 진행 중에는 주요 단계 전환(계획 확정·구현 완료/실패·검토·수정/모델 승격·최종 검증·승인 대기/차단)에서만 한국어 `[작업 진행 상황]`을 표시한다(현재 단계·현재 단계의 실제 모델·완료 단계의 실제 소요시간). 저수준 로그나 명령 한 줄마다 표시하지 않는다. 값은 그 세션이 직접 관측한 실제 단계 이벤트에서만 읽고 단계·모델·시간을 추측하지 않으며, 계산 불가한 시간은 미기록으로 둔다. 실시간 메시지 수정은 Desktop 제약상 불가하므로 기존 메시지를 덮어쓰지 말고 전환 시 스냅샷을 새로 보여준다. 최종 완료 보고에는 단계별 소요시간을 포함한다. 질문·조사에는 진행 표시를 하지 않는다.
- 검증된 Claude Desktop 세션에서는 세션 배너와 별개로, **모든 사용자 응답 맨 위에** 한국어 `[요청 처리 상태]`를 한 번 표시한다(매 응답, 4줄 안팎 간결). 방금 요청의 출처·요청 유형(개발/질문/조사)·저장소 변경 필요·현재 단계를 실제 데이터에서만 채운다(추측 금지). Desktop 세션은 CEO OS 큐에 등록되지 않으므로 "Claude 직접 응답 / Codex 실행: 없음" 또는 그 세션이 직접 수행 중인 단계로 표기하고, CEO OS 큐 조회 출력(`run.py request-status` 등)을 인용하지 않는다. 사용자 노출 문구(상태·단계·판정·사유)는 전부 한국어로 렌더한다(내부 코드/JSON 키는 영어 유지). 다른 출처에는 이 상태를 적용하지 않는다.
- 실제 검증(테스트·독립 검토)을 통과하기 전에는 사용자에게 완료보고를 하지 않는다.
- 날짜·가격·구체 모델명·fallback 순서 같은 가변 정책은 이 문서에 하드코딩하지 않고 중앙 코드/설정(`config.py`·`ai_schedule.py`·`plans.json`)에 둔다.

## 기본 원칙
- 기본 응답 언어는 한국어다.
- 여기에 남길 규칙은 둘 이상의 프로젝트군에서 재사용되는 것만 둔다.
- 하나의 프로젝트나 도메인에만 해당하는 규칙은 여기로 올리지 말고 해당 문서로 내린다.
- 세션 시작 시 `.planning/STATE.md`, `.planning/context/ACTIVE_SUMMARY.md`를 확인한다. `.planning/STATE.md`는 FluxOS의 `python E:\FluxStudio\.fluxos\scripts\gen_state.py`가 생성하므로, 최신화가 필요하면 이 스크립트를 다시 돌린다(과거의 `node scripts/gsd-context-hygiene.mjs`는 존재하지 않으니 호출하지 않는다).
- 컨텍스트 hygiene 점검은 별도 노드 스크립트가 아니라 FluxOS가 `utils/hygiene.py`로 자체 수행하므로, 위키나 세션에서 임의의 hygiene 스크립트를 직접 만들어 부르지 않는다.
- 모든 작업을 진행하기 이전에 이전 대화 기록과 현재 작업 맥락을 먼저 컨텍스트 압축한 뒤 진행한다.
- 한글 중심 작업 환경이므로 모든 파일 읽기/쓰기는 UTF-8을 기준으로 처리하고, 한글이 깨지지 않게 확인한다.
- PowerShell에서 한글 파일을 읽거나 쓸 때는 `Get-Content -Encoding UTF8`, `Set-Content -Encoding UTF8`, `[System.IO.File]::ReadAllText(..., [System.Text.Encoding]::UTF8)`, `[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::UTF8)`처럼 인코딩을 명시한다.
- `type`, `more`, `echo > file`, 기본 인코딩의 `Get-Content`/`Set-Content`, Python/Node의 기본 인코딩 추정처럼 코드페이지에 의존하는 방식으로 한글 문서를 읽거나 쓰지 않는다.
- 이미 글자가 깨져 보이면 그 상태로 저장하지 말고 즉시 중단한 뒤 UTF-8로 다시 읽어 원문을 확인한다.
- PowerShell 명령에서는 `&&`를 쓰지 않는다. 여러 명령을 이어야 하면 명령을 분리해서 실행하거나, PowerShell 네이티브 방식인 세미콜론과 `$LASTEXITCODE`/`if ($?) { ... }` 조건문을 사용한다.
- Bash/CMD 전용 체이닝 문법을 PowerShell에 그대로 가져오지 않는다. 특히 `cmd /c`, `bash -lc`로 우회해 삭제/이동/생성 같은 파일 작업을 섞어 실행하지 않는다.

## Codex Desktop 내부 기본 모델 라우팅 (⚠️ 구현 요청 완료 게이트)
> Codex Desktop 세션의 버그수정·기능구현·리팩토링·최적화·연결·테스트보강·완성 요청에 기본 적용한다. 질문·조사·계획·테스트·검토만 명시한 요청은 그 범위를 넘지 않는다. 상세 절차의 Source of Truth는 `00_Constitution/codex-execution-spec.md`, 모델 매핑 원본은 `07_System/codex/model-routing.json`, 실행 Skill은 `end-to-end-delivery`다.

- 기본 순서: Explorer 조사 → Planner 계획·완료조건 → 항목별 Simple/Complex 분류 → Simple/Complex Implementer 구현 → Test Executor 검증 → Failure Analyst 실패분석(필요 시) → 독립 Reviewer → 수정·재검증·재리뷰 → Integrator 최종 판정.
- 모델 매핑: Explorer `gpt-5.4-mini` medium, Planner `gpt-5.6-terra` high, Simple Implementer `gpt-5.4-mini` medium, Complex Implementer `gpt-5.6-luna` medium, Test Executor `gpt-5.4-mini` low, Failure Analyst `gpt-5.6-luna` high, Reviewer `gpt-5.6-luna` high, Integrator `gpt-5.6-terra` medium, High-risk Escalation `gpt-5.6-sol` high.
- 구현자는 자기 작업을 최종 승인할 수 없다. Reviewer 미실행, 필수 테스트 미실행·실패, 계획 항목 미완료, Reviewer `BLOCKER`/`HIGH` 잔존, 검증 공백이 중대한 상태에서는 `COMPLETE`를 출력하지 않는다.
- 애매하거나 판단이 필요한 구현은 Simple로 낮추지 말고 Complex로 분류한다. 인증·권한·결제·보안·운영 DB·데이터 손실·광범위한 아키텍처·반복된 BLOCKER는 High-risk Escalation을 요청한다.
- 실제 Codex가 지원하지 않는 hook, 모델 ID, config 필드, 강제 차단 기능은 만든 것처럼 보고하지 않는다. 지원 불가 항목은 Skill·custom agents·검증 스크립트·작업 상태 파일로 대체하고 한계를 최종 보고에 공개한다.

## FluxOS 및 Claude Desktop 모델 라우팅과 병렬 처리 (⚠️ 비단순 작업 필수 워크플로우 — 예외 없이 준수)
> 사용자가 매번 지시하지 않아도, 개발·수정·리팩토링·분석·리뷰 등 **비단순 작업은 아래 순서를 기본값으로 반드시 따른다.** 모델 라우팅과 별도 리뷰어 단계를 생략하지 않는다.
>
> **필수 체크리스트 (7단계):**
> 1. **FluxOS 파이프라인 등록** — 위 "FluxOS Pipeline Gate"대로 `run.py pipeline` 등록(또는 pipeline-audit 확인) 후 진입.
> 2. **계획 = `Claude`(상위 모델).** 범위·영향파일·리스크·검증기준 먼저 제시.
> 3. **구현 = 난이도별 병렬 서브에이전트 위임.** CEO OS 자동 파이프라인의 구현자는 `routing_engine.py` 5종 사다리(GLM-5.2·MiniMax M3·DeepSeek Pro·DeepSeek Flash·GPT-5.4 Mini)를 따른다. 현재 세션이 직접 서브에이전트(Claude Agent 도구)로 위임할 때는 난이도에 맞는 Claude 모델(Haiku/Sonnet/Opus)로 위임한다. 파일 비중첩이면 동시 실행.
> 4. **별도 리뷰어가 전체 diff를 리뷰**(구현 워커와 다른 provider/세션) — 계약 정합·회귀·규약 위반 점검, **1단계로 완결**(2026-07-16부터 2차검토 없음).
> 5. 지적사항 **수정** → 6. **재리뷰** → 7. **검증(analyze/test/build)·보고**.
> 메인(오케스트레이터) 세션은 **직접 구현을 쏟지 말고** 계획·분배·검토·보고만 담당한다. 이 흐름을 지키지 않고 메인이 다 처리하거나 모델 라우팅/별도 리뷰어를 건너뛰면 규약 위반이다.
- 비단순 작업은 계획 -> 병렬 작업자 -> 별도 리뷰어(1단계) -> 수정 -> 재리뷰 순서로 진행한다.
- 계획 단계는 `Claude`를 우선한다(현재 세션이 직접 계획하는 경우).
- CEO OS 자동 파이프라인의 구현·검토자 배정은 `routing_engine.py` 5종 사다리를 따른다(GLM 단독 주력 아님, Claude Opus/Sonnet·Codex GPT-5.6 Luna/Terra/Sol은 자동 라우팅 제외 — `AI_RULES.md` §7 참조).
- 대화형 세션 자체의 서브에이전트 위임(Claude Agent 도구)은 위 CEO OS 라우팅과 별개로 난이도별 Claude 모델(Haiku/Sonnet/Opus)을 그대로 사용한다.
- 계획이 끝나면 실제 작업은 가능한 한 무조건 병렬로 진행한다.
- 파일, 모듈, 서브시스템이 겹치지 않으면 워커를 동시에 띄우고 병렬 완료를 우선한다.
- 병렬 작업 후 자기 할 일이 끝난 서브에이전트는 즉시 닫는다.
- 완료된 서브에이전트를 띄워둔 채로 방치하지 않고, 다음 병렬 작업에 자원을 바로 쓸 수 있게 한다.
- 비단순 작업의 구현 단계는 메인(오케스트레이터) 세션이 직접 코드를 쏟아내지 말고 경량 서브에이전트에 위임한다. 메인 세션은 계획·분배·검토·보고만 담당하고, 실제 구현과 반복 작업은 난이도에 맞는 서브에이전트(단순=경량 모델, 난도 높음=중간 모델)로 병렬 위임해 비용을 낮춘다. 이것이 기본값이며, 사용자가 따로 지시하지 않아도 비단순 구현은 위임을 우선한다.
- 메인 세션은 자기 모델을 임의로 바꿀 수 없으므로, "계획은 상위 모델 / 구현은 경량"을 달성하려면 반드시 서브에이전트 위임을 사용한다. 메인 모델 자체를 낮추려면 사용자가 직접 모델을 전환해야 한다.
- 다만 도구/하네스 정책이 불필요한 서브에이전트 생성을 억제할 수 있어 위임이 자동으로 항상 적용되지는 않는다. 위임이 확실히 필요한 작업이면 사용자가 "구현은 서브에이전트로" 같은 트리거를 주거나, 작업 시작 시 위임 방침을 명시한다.

## 작업 방식
- 기존 코드, 기존 문서, 기존 구조를 먼저 확인한다.
- 새로운 방법이 더 좋아 보여도 이미 결정된 Decision·Constitution·프로젝트 규칙을 먼저 확인하고 우선한다. 변경이 필요하면 임의로 기존 규칙을 무시하지 말고 새로운 Decision(05_Decisions)을 제안한다(구 Obsidian Vault 흡수, 2026-07-03).
- 모든 파일 수정 전에는 FluxOS 잠금 상태를 확인하고, 같은 프로젝트에 active 작업이 있으면 새 작업을 직접 시작하지 않고 지시사항 단위로 FIFO 큐에 넣는다.
- 큐 대기는 파일 하나가 풀렸는지가 아니라 앞선 지시사항 전체가 완료되어 release될 때까지 유지한다. 앞 작업이 여러 파일을 수정 중이면 그중 일부 파일이 먼저 끝났더라도 다음 지시는 시작하지 않는다.
- 큐에 올라간 지시사항은 앞 작업 release 후 첫 번째 대기 항목부터 순서대로 active로 승격하고, 필요한 payload가 있으면 그때 실행한다.
- FluxOS 운영은 모든 등록 프로젝트를 독립 lane으로 본다. 같은 프로젝트는 active 지시 1개와 FIFO queue를 유지하지만, 서로 다른 프로젝트는 공용 자원 충돌이 없으면 병렬 진행한다.
- `AGENTS.md`, `CLAUDE.md` 같은 생성 문서는 다른 세션이 작업 중인 프로젝트에 직접 재생성하지 않고, AI_WIKI 원본만 수정한 뒤 해당 프로젝트 doc-generate 작업을 큐에 적재한다.
- 새 기능, 화면, 컴포넌트, UI 요소를 추가하기 전에는 반드시 기존 디자인 스타일, CSS, 테마, 토큰, 공용 컴포넌트, 레이아웃 패턴이 있는지 먼저 확인한다.
- 새 UI는 프로젝트가 이미 쓰는 스타일과 시각 언어에 맞춰 통일해서 개발하고, 기본 브라우저/프레임워크 스타일을 그대로 덧붙이지 않는다.
- 버튼, 카드, 입력창, 모달, 색상, 간격, 폰트, 아이콘, 상태 표시 등은 기존 앱의 구현 방식을 우선 재사용한다.
- 장시간 실행 작업은 30초 이상 응답이나 로그 변화가 없으면 즉시 상태를 확인한다.
- 실행 중인지, 멈췄는지, 입력 대기인지, 네트워크/빌드 병목인지 구분하고 근거를 남긴다.
- 멈춤이나 무의미한 대기라고 판단되면 같은 방식으로 3분, 5분, 10분씩 기다리지 말고 프로세스 확인, 로그 확인, 타임아웃 재실행, 범위 축소, 다른 명령/경로 우회 중 하나로 전환한다.
- 장시간 명령을 시작할 때는 가능한 경우 타임아웃, 로그 파일, 진행 상태 확인 방법을 함께 둔다.
- 검색, 분석, 컨텍스트 수집은 `node_modules`, `.git`, `build`, `dist`, `.next`, `.dart_tool`, `.gradle`, `.gradle-local`, `coverage` 같은 의존성/빌드 산출물 폴더를 기본 제외한다.
- Windows 작업에서는 iOS/Xcode 전용 MCP나 도구를 자동으로 띄우지 않는다. 이미 떠 있는 `xcodebuildmcp`처럼 현재 플랫폼에 불필요한 보조 프로세스는 확인 후 정리한다.
- Flutter 앱을 에뮬레이터로 실행해야 하거나 연결된 장치가 없으면 `flutter devices`로 먼저 확인하고, 항상 같은 AVD `flux_phone`의 `emulator-5554`에서 `flutter run -d emulator-5554`로 실행한다.
- `flux_phone`/`emulator-5554`는 한 번에 하나의 세션만 사용한다. 다른 세션이 사용 중이면 새 실행을 직접 시작하지 말고 FIFO 큐에 적재해 앞 세션이 끝난 뒤 다음 세션이 이어서 사용하게 한다.
- 같은 프로젝트에서 같은 에뮬레이터 실행 요청이 반복 입력되면 큐에 중복으로 쌓지 말고 기존 대기 항목 하나만 유지한다.
- 실제 Android 기기 무선 디버깅은 S23(대용의 S23 Ultra) 자동 연결만 기본으로 유지한다. `ADB_MDNS_AUTO_CONNECT=1`(User 환경변수, 상시 설정)로 무선 디버깅 토글을 켤 때마다 바뀌는 IP:포트를 mDNS가 자동 감지·연결하므로, 더 이상 IP:포트를 수동으로 등록할 필요가 없다.
- ADB/Flutter 실행 전에는 공용 래퍼가 `E:\AI_WIKI\scripts\adb-single-device.ps1`를 자동 호출한다. 이 스크립트는 mDNS 자동 연결을 켜둔 상태에서, 연결된 각 device의 실제 serial을 조회해 `config\adb_device_roster.json`의 `s23` 슬롯 serial과 다르면 즉시 `adb disconnect`한다 — S8/태블릿 등 다른 기기가 같이 mDNS로 잡혀도 자동으로 잘려나가고 S23 하나만 남는다.
- 여러 기기를 동시에 붙여야 하는 예외(예: PlanFlow 3기기 설치)만 `adb-single-device.ps1 -AllowMultipleDevices`로 필터링을 건너뛴다. 그 외 프로젝트/세션은 이 예외를 쓰지 않는다.
- 무선 디버깅 IP:포트를 수동으로 고정 등록하는 `AI_WIKI_ADB_DEVICE` 방식은 더 이상 기본 흐름이 아니다(포트가 토글마다 바뀌어 금방 stale해짐). 자동 감지가 실패할 때만 임시 진단용으로 쓴다.
- 로컬 개발/디버그의 AI 호출은 기본적으로 Hermes 로컬 경로를 우선하고, 배포/릴리즈와 127.0.0.1을 직접 볼 수 없는 런타임은 OpenAI 배포 경로를 우선한다.
- Hermes 로컬 기본값은 `http://127.0.0.1:8645/v1`, API key 예시는 `hermes-local`이다. 수동 override가 필요할 때만 `OPENAI_BASE_URL`로 바꾼다.
- FLUXSTUDIO 계열의 공용 AI 호출은 Hermes 기본 경로를 사용하되, PlanFlow는 이번 자동 전환 범위에서 제외한다.
- Docker는 세션별로 직접 start/stop 하지 말고 FluxOS 공용 lease 명령(`docker status --project <Project>`, `docker ensure --project <Project> --owner "<session>" --reason "<task>"`, `docker release <lease_id> --project <Project> --owner "<session>"`, `docker refresh <lease_id> --project <Project> --owner "<session>"`, `docker watch <lease_id> --project <Project> --owner "<session>" --parent-pid <pid>`, `docker daemon`)으로만 다룬다.
- Docker가 필요한 작업은 먼저 lease를 확보하고, 끝나면 반드시 release한다. active lease가 남아 있으면 다른 세션은 기다린다.
- 실행 중인 컨테이너가 하나라도 있으면 Docker를 함부로 끄지 않는다.
- 범위는 사용자 요청에 맞게 좁게 유지한다.
- 관련 없는 파일을 수정하거나 삭제하지 않는다.
- 사용자가 만든 변경은 되돌리지 않는다.
- 새 구조는 정말 필요할 때만 만든다.
- 공통 규칙과 프로젝트 규칙이 충돌하면 프로젝트 문서를 우선한다.
- 프로젝트별 세부 규칙은 해당 프로젝트 문서에서 확인한다.

## 검증과 마무리
- 변경 후에는 재생성 스크립트와 검증 스크립트를 다시 돌린다.
- 모든 작업이 끝난 뒤에는 의도한 변경만 커밋하고 푸시한다.
- 앱/서비스 프로젝트는 커밋과 푸시 후 빌드와 실행 검증까지 완료한다.
- 앱이 아닌 문서/스크립트/위키 작업은 커밋과 푸시까지 완료한다.
- 결과를 설명할 때는 무엇을 바꿨는지, 무엇을 검증했는지, 남은 위험이 있는지를 분리해서 말한다.

## 코드 변경 후 기본 자동화 (커밋 -> 푸시 -> 빌드 -> 설치 -> 실행)
- 앱/서비스 프로젝트(*flow)에서 코드 수정이 끝나면, 기본값으로 의도한 변경만 pathspec로 커밋하고 푸시한 뒤 빌드 -> 설치 -> 실행까지 자동으로 이어서 진행한다. 사용자가 따로 막거나 범위를 좁히지 않는 한 이 흐름이 기본이다.
- 커밋은 자기 변경만 pathspec로 올리고 `git add -A`/`git commit -a`는 쓰지 않는다. 푸시까지 마친다.
- 빌드는 release 기준으로 한다(debug 금지 - 서명 불일치). Android 빌드는 항상 `E:\AI_WIKI\scripts\flutter-build-guarded.ps1`를 경유한다.
- 설치 대상은 adb로 연결된 실기기다. PlanFlow는 연결된 v2 기기 3대 모두에 설치하고, 그 외 모든 프로젝트는 S23에만 설치한다.
- 연결된 adb 기기가 없으면 빌드한 release APK를 `I:` 드라이브(Google Drive 마운트)에 `Copy-Item`으로 올리고 완료 보고한다.
- 이 자동화는 모든 *flow 프로젝트의 기본 동작이며, CEO OS 등 어디서 지시했는지와 무관하게 동일하게 적용한다. 단순/긴급 수정으로 일부 단계를 생략하면 생략 사유와 검증 결과를 최종 보고에 남긴다.

## 프로젝트에서 반복 확인된 공통 규칙
<!-- [AUTO-COMMON:START] -->
- (새로 승격할 공통 규칙 없음)
<!-- [AUTO-COMMON:END] -->


---
tags: [layer/truth, type/gov, ai/all]
---

# Resource Optimization Rules
<!-- 32GB RAM 로컬 개발 환경에서 AI 세션이 과도한 CPU/RAM/IO를 쓰지 않게 하는 공통 규칙 -->

## 기본 원칙
- 이 환경은 여러 AI 세션, Supabase, Vercel, Flutter/Android 도구가 동시에 실행될 수 있는 Windows 로컬 개발 환경이다.
- 정확도보다 무거운 전체 탐색을 우선하지 않는다. 필요한 파일만 좁게 읽고, 근거가 부족할 때만 범위를 단계적으로 넓힌다.
- 30초 이상 응답, 로그, 파일 변경, 프로세스 변화가 없으면 즉시 상태를 확인한다.
- 멈춤, 입력 대기, 네트워크 지연, 빌드 병목, Git hook 대기, 외부 도구 대기를 구분하고 다음 행동을 바꾼다.

## 탐색 범위 제한
- 기본 검색은 사용자 작성 소스와 설정 파일 중심으로 한다.
- 다음 폴더는 기본적으로 검색, 인덱싱, 컨텍스트 수집에서 제외한다: `node_modules`, `.git`, `build`, `dist`, `.next`, `.dart_tool`, `.gradle`, `.gradle-local`, `coverage`, `.cache`.
- 외부 라이브러리 구현을 로컬에서 훑지 않는다. 표준 API 사용법은 공식 지식이나 프로젝트의 직접 사용 예시만 확인한다.
- 대규모 재귀 검색이 필요하면 먼저 `rg --files`와 glob 제외를 사용하고, 결과 수를 제한한다.
- 저장소 전체 diff/status가 느리면 프로젝트별, 파일별, 생성 문서별로 쪼개서 확인한다.

## 컨텍스트와 출력
- 긴 세션에서는 현재 작업과 직접 관련 없는 큰 코드 블록, 로그, 중복 파일 내용을 다시 읽거나 다시 출력하지 않는다.
- 기존 내용을 설명할 때는 파일 경로와 핵심 함수/섹션만 유지하고, 전체 파일 재출력은 피한다.
- 코드 제안은 diff, 패치, 특정 함수/블록 중심으로 제공한다.
- 전체 파일 출력은 사용자가 명시적으로 요청했거나 파일이 매우 작을 때만 한다.

## 프로세스 관리
- 리소스 우선순위는 1순위 Codex, 2순위 Chrome/Edge의 ChatGPT·Claude 같은 AI 채팅, 3순위 그 외 앱이다.
- Codex 프로세스는 자동 종료하지 않고 CPU 우선순위를 높게 유지한다.
- Chrome/Edge는 ChatGPT·Claude 작업이 들어 있을 수 있으므로 기본 자동 종료 대상에서 제외하고, CPU 우선순위를 일반 백그라운드 앱보다 높게 유지한다.
- Windows에서는 `wiki ios-off`로 Codex의 iOS/Xcode 플러그인을 꺼서 `xcodebuildmcp` 재시작 루프를 막는다.
- AI_WIKI가 실행하는 큰 빌드, 테스트, 대량 검색, 장시간 동기화는 가능하면 `scripts/invoke-guarded-task.ps1` 또는 `wiki guarded`를 통해 실행한다.
- FluxOS의 Docker는 세션별 직접 start/stop보다 공용 lease가 우선이다. `python E:\FluxStudio\.fluxos\run.py docker status --project <Project>`, `python E:\FluxStudio\.fluxos\run.py docker ensure --project <Project> --owner "<session>" --reason "<task>"`, `python E:\FluxStudio\.fluxos\run.py docker release <lease_id> --project <Project> --owner "<session>"`, `python E:\FluxStudio\.fluxos\run.py docker refresh <lease_id> --project <Project> --owner "<session>"`, `python E:\FluxStudio\.fluxos\run.py docker watch <lease_id> --project <Project> --owner "<session>" --parent-pid <pid>`, `python E:\FluxStudio\.fluxos\run.py docker daemon` 흐름으로만 제어하고, active lease가 남아 있으면 다른 세션은 대기한다.
- 전체 메모리 사용량이 70% 이상이거나 예상 작업 메모리를 더했을 때 70%를 넘으면 큰 작업을 즉시 실행하지 않고 리소스 큐에 넣는다.
- 큐에 쌓인 작업은 FIFO 순서로 처리하고, 실행해도 70%를 넘지 않을 때만 시작한다.
- 같은 작업이 반복 입력되면 `cwd + category + command` 기준으로 동일 여부를 판단하고, 이미 대기 중이거나 실행 중인 작업은 새로 쌓지 않고 스킵한다.
- 프로젝트 작업은 프로젝트별 lane에서 병렬 진행하되, Android 기기/에뮬레이터, Docker, Supabase 로컬 컨테이너, 동일 포트 dev server 같은 공용 자원은 별도 FIFO resource lock을 우선한다.
- 현재 상태는 `wiki resource` 또는 `wiki queue`로 확인한다.
- 메모리가 70%를 넘으면 큰 프로세스부터 종료하지 않는다. 먼저 Phone Link, Steam WebHelper, Discord, Teams, Epic, qBittorrent처럼 코딩 작업과 무관한 백그라운드 앱과 오래된 잔여 서버/데몬을 정리한다.
- 그래도 70%를 넘으면 큰 프로세스는 자동 종료하지 않고 후보로만 보고한다. 현재 작업 중인 Codex 세션, 빌드, 테스트, dev server, 브라우저 작업은 사용자가 명시하지 않는 한 종료하지 않는다.
- 사용자가 현재 Codex 작업만 한다고 명시하면 `wiki light`로 백그라운드 앱을 정리해 메모리를 즉시 낮춘다. Chrome/Edge는 2순위 보호 대상이므로 `wiki light aggressive`처럼 명시적인 공격 모드에서만 닫는다.
- Windows에서는 iOS/Xcode 전용 MCP나 도구를 자동 실행하지 않는다.
- `xcodebuildmcp`처럼 현재 플랫폼과 작업에 불필요한 보조 프로세스가 떠 있으면 확인 후 정리한다.
- Java/Gradle/Kotlin 데몬은 빌드 중인지 확인하고, 빌드가 끝난 뒤 남은 재시작 가능한 데몬만 정리한다.
- Android 빌드(`flutter build apk/appbundle`)는 직접 호출하지 말고 항상 `E:\AI_WIKI\scripts\flutter-build-guarded.ps1`를 경유한다. **(2026-07-15 정정)** 과거엔 모든 FluxStudio 프로젝트가 `GRADLE_USER_HOME=E:\.gradle`를 공유해 Gradle 데몬 레지스트리가 하나였고, 락도 전역 `android-build` 하나였다 — 이 전역 락이 종료된 소유자와 대기열 취소를 구분 못 해 다른 프로젝트 빌드를 장시간 막는 사고(2026-07-13)가 나서, 지금은 **프로젝트 단위로 완전히 분리**돼 있다: 이 래퍼가 `GRADLE_USER_HOME`을 프로젝트 로컬 경로(`<ProjectPath>\.gradle-local\gradle-home`)로 설정해 Gradle 데몬/캐시 자체를 프로젝트별로 격리하고, FluxOS 락도 `android-build:<Project>`(예: `android-build:ValueFlow`, `android-build:FinFlow`) 키를 쓴다. 그래서 **같은 프로젝트 내 동시 빌드만 FIFO로 직렬화**되고, 서로 다른 프로젝트의 빌드는 병렬로 돌아도 안전하다(점유 중이면 같은 프로젝트 것만 대기, 자동 승격되면 빌드, 종료 시 항상 release). 호출 예: `powershell -File E:\AI_WIKI\scripts\flutter-build-guarded.ps1 -ProjectPath <flutter_app 경로> -Project <프로젝트> -Owner <세션> -BuildArgs "apk --release"`.
- 활성 Flutter/Node/Vercel/Supabase dev server, test, build는 사용자의 다른 세션 작업일 수 있으므로 무작정 종료하지 않는다.
- 오래 멈춘 진단 명령, 중복 status/diff, 종료된 작업의 잔여 프로세스는 정리 대상이다.
- 자동 종료는 안전 목록에 한정한다. Codex 본체, 현재 작업 중인 Codex 세션, 활성 dev server, 활성 빌드/테스트, 브라우저, 보안/은행/드라이버 앱은 자동 종료하지 않는다.
- `taskkill /f /im node.exe /t`, `taskkill /f /im postgres.exe /t`처럼 이름 기준으로 Node/PostgreSQL 전체를 강제 종료하지 않는다.
- Node/PostgreSQL 정리는 작업 소유권과 종료 조건이 확인된 경우에만 한다. FluxOS/AI_WIKI가 실행한 작업은 작업 종료 시 해당 작업의 자식 프로세스만 정리하고, 전역 감시는 부모 프로세스가 사라졌고 TCP 리스닝 포트가 없으며 보호 대상 명령이 아닌 오래된 orphan 런타임만 자동 종료한다.
- 포트를 열고 있는 dev server, Supabase/PostgreSQL, Vercel/Next/Vite 서버는 다른 세션이 사용 중일 수 있으므로 자동 종료하지 않고 모니터/후보 보고로 남긴다.
- 작업이 끝난 Node는 퇴근시키는 것이 기본이다. guarded launcher로 시작한 작업은 종료 시 자식 `node.exe`/`postgres.exe`를 정리하고, 직접 실행된 Node는 부모 없음, 리스닝 포트 없음, 낮은 CPU 활동, 보호 명령 아님, 최소 age 초과 조건을 모두 만족할 때만 자동 종료한다.
- WSL2/Docker는 `%USERPROFILE%\.wslconfig`에서 `memory=8GB` 상한을 기본으로 둔다. 기존 `kernelCommandLine` 등 사용자 설정은 보존하고, 적용은 Docker/WSL 재시작 후 이루어진다.
- VS Code/Cursor는 `node_modules`, `.git`, `build`, `dist`, `.next`, `.dart_tool`, `.gradle`, `.gradle-local`, `coverage`, `.cache`를 watcher/search 제외 대상으로 둔다.
- 퇴근/리셋은 `python E:\FluxStudio\.fluxos\run.py resource reset --mode safe`를 우선한다. 이 명령은 완료 작업 자식 프로세스, 확실한 orphan, idle daemon, 안전 캐시만 정리하고, active dev server/build/test는 보호한다.
- 핸들, 스레드, 디스크 I/O, 캐시 후보, orphan 런타임은 FluxOS Monitor의 리소스 상태에서 확인한다.

## 장시간 명령 운영
- 장시간 명령은 가능하면 타임아웃, 로그 파일, 진행 확인 방법을 붙여 실행한다.
- **모든 Codex·Claude 세션은 장시간 작업을 스스로 감시한다.** 30초 동안 새 로그·파일 갱신·프로세스 CPU 변화가 없으면, 사용자에게 "확인하겠다"고만 말하거나 다음 지시를 기다리지 않는다. 즉시 프로세스 CPU/RAM·부모/자식 관계·로그 tail·산출물 갱신 시각·네트워크·입력 대기·공유 락을 확인해 정지 지점을 분류하고 근거를 남긴다.
- **판정과 조치는 같은 작업 턴에서 끝낸다.** 정상 진행 근거(CPU/로그/산출물 변화)가 있으면 계속 감시하고, 종료·무출력 정체·입력 대기·반복 오류·고아 래퍼/락 등 비정상 근거가 있으면 가장 좁고 안전한 복구를 자동 적용한다(타임아웃/명령 경로 조정, 범위 축소, 정상 대체 경로 사용, 자신이 만든 잔여 프로세스 정리, 확인된 안전 락 해제 등). 복구 결과를 검증한 뒤 원래 작업의 다음 단계까지 즉시 재개한다.
- **고아 작업 판정**: 명령의 부모 프로세스가 끝났고 산출물·로그 갱신이 멈췄으며 자식 래퍼/데몬만 남았으면, 그 작업은 정상 빌드가 아니다. 소유자가 현재 세션임이 확인된 경우에만 해당 작업 트리와 락을 정리하고 재시도한다. 다른 세션 소유 가능성이 있으면 소유자·heartbeat·실제 프로세스를 확인한 뒤 정상 근거가 없을 때만 정리한다.
- 같은 명령을 무작정 반복하거나 원인 미확정 상태에서 주기 감시만 하지 않는다. 주기 감시는 원인이 확인된 외부 의존성·공유 자원 대기 또는 복구 효과 검증에만 쓴다.
- 다른 세션 소유 가능성이 있는 프로세스·락·배포·데이터는 소유권을 확인하기 전 자동 종료·해제·변경하지 않는다. 파괴적·되돌릴 수 없는·외부 영향이 있는 복구만 사용자 확인 후 진행한다.
- 병렬 실행은 파일/모듈/저장소가 겹치지 않을 때만 사용하고, 완료된 하위 작업은 즉시 닫는다.

## 완료 기준
- 리소스 최적화 관련 변경은 실제 프로세스 상태, 모니터 로그, 또는 제외 규칙 적용 여부로 검증한다.
- 작업이 끝나면 관련 변경만 커밋/푸시한다.
- 기존 사용자 작업으로 보이는 dirty 파일은 확인 없이 되돌리거나 묶어 커밋하지 않는다.


---
tags: [layer/truth, type/gov, ai/all]
---

# AI Behavior Rules
<!-- AI가 작업 시 반드시 따라야 할 행동 원칙. 모든 프로젝트에 공통 적용. -->

## ⚠️ 필수 — 코드 수정 후 재발 방지책 캡처(최우선 확인)
- **코드를 수정하면(버그수정·기능·리팩토링 무관) 완료 보고 전에 반드시 재발 방지책(회귀 테스트·가드 등)을 만든다 — 기록보다 재발 방지가 목적.** FluxStudio 계열에서는 `python E:\FluxStudio\.fluxos\run.py prevent capture --title "<제목>" --root-cause "<근본원인>" [--files <변경파일들>] [--commit <해시>] [--ai claude|codex|glm] [--project <프로젝트>]`로 근본원인을 남기면, 도구가 유형에 맞는 강제 계층(코드=회귀테스트 자동 스캐폴드 / 행동·교차AI=AI_WIKI 공통규칙 / 메타패턴=메모리)에 예방책을 배치한다. 이는 모든 AI(Claude·Codex·GLM)·모든 프로젝트의 완료 기준이며, FluxOS는 `FLUXOS_PREVENTION_GATE=block`에서 **방지책 없는 완료를 차단**한다(방지책 캡처 시 해제).

## 절대 금지
- 계획 없이 코드 먼저 작성
- 기존 동작 중인 코드를 이유 없이 리팩토링
- 승인 없이 아키텍처 변경
- 가격/구독 정책 임의 변경
- iOS 관련 코드 추가 (Android-only 프로젝트)
- 검증 없이 완료 보고
- 컨텍스트 압축 없이 작업 시작

## 필수 행동
- **비단순 작업(개발·수정·리팩토링·분석·리뷰)은 예외 없이 적용 경로의 모델 라우팅·독립 검토·수정·재검토·검증을 따른다. Codex Desktop 구현 요청은 `agents-common.md`의 "Codex Desktop 내부 기본 모델 라우팅"과 `00_Constitution/codex-execution-spec.md`를 우선 적용한다(Explorer 조사 → Terra Planner 계획 → 항목별 Simple/Complex 구현 → Test Executor 검증 → Luna Reviewer 독립 검토 → Terra Integrator 최종 판정). CEO OS/Claude Desktop은 해당 경로의 별도 파이프라인 정책을 따른다. 사용자가 매번 지시하지 않아도 이것이 기본값이며, 구현자가 자기 승인하거나 모델 라우팅·독립 검토를 생략하면 규약 위반이다.**
- **AI가 직접 할 수 있는 모든 것은 사용자에게 묻지 않고 바로 실행한다. 사용자에게는 직접 해야만 하는 것(콘솔 접근, 물리 기기 조작, 외부 서비스 설정 등)만 전달한다.**
- 작업 전: 컨텍스트 압축 -> 계획 제시 -> 승인 대기
- 작업 중: 계획 외 변경 발생 시 즉시 보고
- 작업 후: push -> 빌드 -> 실행 -> 테스트 순서로 검증
- 코드 수정 후 재발 방지책 캡처 — 파일 맨 위 필수 섹션 참조
- 모르면 가정하지 말고 질문
- **질문 타이밍 기준(2026-07-03, "가정 말고 물어볼 것" 원칙 유지 + 예외 조건 명시)**: 아래 조건에 해당하면 질문 없이 진행하고, 그 외에는 원칙대로 질문한다.
  - **질문 없이 진행**: (a) 동일 유형의 결정이 이미 2회 이상 반복 확인되어 `confirmed` 상태로 `04_Memory/Preference` 또는 `05_Decisions`에 존재하는 경우, (b) 되돌리기 쉬운 작업(읽기전용 조사, 즉시 revert 가능한 범위의 코드 수정)인 경우.
  - **반드시 질문**: (a) 처음 보는 유형의 결정이거나, (b) 되돌리기 어려운 작업(구조 변경·데이터 삭제·외부 API 실제 호출·사업적 판단)이거나, (c) `confirmed` 규칙끼리 서로 충돌하는 경우.
  - **애매하면 질문 쪽으로 기운다**(fail-safe — exhausted 모드의 fail-closed 철학과 동일한 임계값 철학 재사용, 새로 발명하지 않음).
- 난이도와 모델이 맞지 않으면 모델 변경 후 진행
- **작업이 끝나면 완료 보고 전에 스스로 Review를 수행한다**: 이번 작업에서 배운 것, 재발 방지 후보, 자동화 후보, 기존 규칙과의 충돌 여부를 스스로 점검한 뒤 보고한다(구 Obsidian Vault 흡수, 2026-07-03).
- **작업 예상시간 선언 + 1N 1차 점검 + 2N 상한 + 뻔한 블로커 자동해결(2026-07-13 지시, 2026-07-17 CEO 개정, E:\FluxStudio 전역·전 AI·모든 경로 공통)**: (1) 모든 작업, 특히 백그라운드 작업(테스트·빌드·커밋·긴 명령)을 시작할 때 원래 걸리는 **예상시간 N을 근거와 함께 전달**한다(예: FluxOS pre-commit 훅 커밋 ~2-3분, 전체 테스트 ~X분). (2) **예상시간 N이 지나면 그 시점에 1차 점검**한다 — 먼저 그 작업 본인에게 문의(진행 중인가/결과 나왔나/문제 있나/어떤 문제냐 — 서브에이전트 SendMessage, FluxOS `run.py progress`·`request-status`·liveness·stage_events, 명령 로그 tail). **정상 진행 근거가 있으면 2N까지 계속 대기**, **문제 신호가 있으면 즉시 조치**(2N까지 기다리지 않는다). 자기보고가 불가능하면(무응답·로그 무변화·상태파일 부재) 그 자체가 문제 신호이므로 직접 조사로 에스컬레이션한다. (2-1) **2N은 상한**이다 — 2N을 넘기면 "살아있다"만으로 넘어가지 말고 "지금 속도로 남은 작업량이면 총 몇 분인가, 그게 이 작업의 합리적 비용인가"를 자문해 설계 결함(항목마다 subprocess spawn 등)을 의심하고 **근본원인을 해결**한다(같은 방식으로 재대기 금지). (3) 원인이 뻔하고 되돌리기 쉬운 블로커는 **사용자 지시 없이 스스로 해결**한다: 신규 파일이면 커밋 전 자동 `git add`(pathspec 매칭 실패 예방), stale `index.lock`(죽은 프로세스 것)은 제거 후 재시도(원자 시퀀스 `rm -f lock; git commit` + 락 경합 시 자동 재시도 루프), 포트충돌·미스테이징 등도 즉시 처리. (4) **리소스 최소**: 이 재점검·재시도 로직은 무겁지 않게 — 짧은 상태확인(로그 tail·상태파일 읽기) 위주, 무거운 전체 스캔·sleep 폴링 루프 금지, 완료 알림/이벤트 우선, 폴링 불가피하면 긴 간격. (기존 "AI가 직접 할 수 있는 건 바로 실행"·"장시간 작업 스스로 확인" 원칙의 강화·구체화.)

## 응답 원칙
- 한국어로 응답
- 코드 변경 시 변경 전/후 명시
- 영향 범위 항상 명시 (어느 파일, 어느 기능)
- 에러 발생 시 원인 -> 해결책 -> 예방법 순서로 설명
- 사람은 작업 과정보다 결과를 본다. 가능한 모든 작업을 수행한 뒤 무엇을 변경했는지·왜 변경했는지·어떻게 검증했는지·남은 위험 요소·다음 권장 작업을 보고한다. 중간 진행 상황은 필요한 경우에만 보고하고 과정 서술을 늘어놓지 않는다(구 Obsidian Vault 흡수, 2026-07-03).


---
tags: [layer/truth, type/gov, ai/all]
---

# Anti-Patterns
<!-- 이미 실패했거나 기각된 접근법. AI에게 다시 제안하지 말 것. -->

## 전역 금지 패턴

### 상태관리
- Flutter에서 Provider 사용 -> Riverpod 사용
- React에서 Redux -> Zustand 사용

### 아키텍처
- React Native (Flutter 전환 완료, 롤백 금지)
- Firebase (Supabase로 확정, 변경 금지)
- iOS 빌드 시도 (SMS/알림 API 접근 불가)

### 코드 품질
- any 타입 남발
- useEffect 안에 직접 fetch 호출
- 하드코딩된 API 키/비밀값

## 프로젝트별 anti-patterns
-> 각 03_Projects/[프로젝트].md 파일의 금지 패턴 섹션 참조

### [PREVENT] 안전 게이트는 차단입력을 실입력으로 통과하는 테스트 1개 필수 (2026-06-25)
안전 게이트(진행·커밋·차단을 막는 판정)를 추가하거나 수정할 때, 그 게이트의 차단 입력을 만드는 producer(파서·git status·pid 생존·로그 파싱 등)를 mock한 테스트만 두지 말 것. 최소 하나의 테스트는 그 producer를 mock하지 말고 실제 입력(임시 git repo·실제 문자열·실제 파일 상태)으로 게이트를 통과시켜야 한다. 안 그러면 producer가 깨져 게이트가 死문서가 돼도 테스트가 green으로 통과한다(mocked-contract-hides-bug). 실증 사례: git status 파서가 worktree 변경 경로 첫 글자를 잘라 부분커밋 정합 게이트가 死문서였는데 모든 테스트가 그 파서를 mock해 잡지 못함.

### [PREVENT] 동시 AI 세션 git add-commit 레이스로 staged 흡수 (2026-06-25)
여러 AI 세션(Claude/Codex)이 같은 repo에서 git add 후 staged 전체를 커밋(git add . / git commit -a)하면, 한 세션이 add해둔 변경을 다른 세션의 commit이 자기 커밋에 흡수한다. FluxOS git_autocommit는 pathspec(git commit -- files)+git lease로 안전하나, AI 세션의 직접 커밋이 staged 전체를 가져가는 게 문제. 방지: AI 세션은 항상 pathspec 커밋(git commit -- <files> 또는 -o)으로 자기 파일만 커밋하고, git add . / commit -a / staged 전체 커밋을 금지한다.

**(2026-07-03 CEO 확인)** 이 근본(pathspec=파일단위, hunk단위 아님)의 재발이 2회(2026-07-01 보강, 2026-07-03 재발+강화)까지 누적됐으나, 두 재발 모두 동일한 단일 메커니즘의 발현이라 meta-pattern 승격은 보류한다. **3번째 재발 시 재검토**, 현재는 behavior tier 강화조치(commit_guard.py의 hotspot 파일 커밋 가시성 경고)로 유지한다.

### [PREVENT] 단위·픽스처 테스트가 라이브 공유상태를 주입 없이 읽어 비결정 실패 (2026-06-26, 보강)
FluxOS 테스트가 fixture로 격리된 것처럼 보여도 내부에서 라이브 전역 상태를 읽어 환경 의존 실패가 반복됨. 같은 근본이 수십 건 재발하는 **메타패턴**이다(차단/판정/시각 계산이 저장된 라이브 상태를 실측 격리 없이 신뢰).

실증(누적):
- run_controlled_parallel이 build_parallel_plan에 load_resource_locks()(라이브 공유락) 주입 → 타 프로젝트 android-build 락이 fixture lane을 blocked로.
- test_api_runner_*가 _chat을 mock했지만 run_api_implementation이 ensure_hermes_running()을 먼저 호출 → 라이브 Hermes 404.
- (2026-06-26 추가) `pytest tests/` 13건 동시 재발: ① dashboard/ai_org_report/lane_inventory가 실제 ROOT_DIR git·worktree·registry·**실제 큐 전수 audit**을 격리 없이 스캔 → 수분 hang(원인 `audit_tasks`·`build_lane_inventory`·`_secret_risks` 미게이트). ② `_mark_executor_blocked`이 전역 `quota_manager`(MEMORY_DIR/quota_state.json)에서 earliest_reset을 읽어 누적 라이브 상태가 테스트 reset 시각을 덮어씀. ③ adb `probe_wireless_state`가 전역 `ADB_DEVICE_ROSTER_PATH`(E:\AI_WIKI\config\adb_device_roster.json) 파일을 읽어 테스트 가짜 타깃을 allowlist에서 걸러냄. ④ `worktree_ownership_check`가 실제 FinFlow git dirty/라이브 세션을 스캔 → 실행마다 다른 PROTECTED 사유로 실패.

**FluxOS 테스트가 격리해야 할 라이브 전역상태 소스(체크리스트):** 공유락(load_resource_locks) · Hermes(ensure_hermes_running) · 작업큐(QUEUE_DIR audit_tasks/list_tasks) · ownership/dirty git 스캔 · `_secret_risks` rg 스캔 · quota_manager(QUOTA_STATE_PATH) · adb 디바이스 roster(ADB_DEVICE_ROSTER_PATH) · 세션/워크트리 레지스트리 · 실제 프로젝트 git(FinFlow 등).

**격리 레시피(택1, 우선순위순):** ⓐ 함수에 주입 파라미터(resource_locks_path/queue_dir/path=)가 있으면 temp로 주입 · ⓑ skip 플래그(skip_hermes_check=True) 사용 · ⓒ `_skip_heavy_scan()` 게이트(env FLUXOS_TEST_LIGHTWEIGHT, **단 그 테스트 파일에만 conftest로 한정** — tests/ 전체에 켜면 형제 파일 깨짐) · ⓓ 전역 경로 상수가 default-arg로 바인딩돼 상수 patch가 안 통하면 그 함수/모듈을 setUp에서 patch.object로 격리(quota_manager·adb roster 사례). 공용 헬퍼는 `.fluxos/tests/_live_state_isolation.py` 참조. 프로덕션 코드는 항상 그 주입 지점(path 파라미터/스킵 플래그)을 제공해야 한다.

### [PREVENT] sys.modules에 mock 주입한 모듈은 지연 import되는 상수/속성까지 mock에 넣어야 함 (2026-06-26)
무거운 의존성 체인을 피하려고 테스트가 `sys.modules['pipeline.task_queue']`에 경량 mock 모듈을 주입할 때, 프로덕션 코드가 tick/함수 내부에서 `from pipeline.task_queue import TERMINAL_TASK_STATUSES`처럼 **지연 import하는 상수/함수가 mock에 없으면** 호출 시점에 "cannot import name X (unknown location)"으로 깨진다(모듈 최상단 import는 멀쩡해 보여도 함수 내부 지연 import가 mock을 친다). 실증: supervisor_daemon tick의 safe_hold/stale 단계가 TERMINAL_TASK_STATUSES 지연 import → mock task_queue에 상수 누락으로 6건 실패(앞서 MEMORY_DIR도 동일 사유로 추가했던 전례 존재). 규칙: 모듈을 mock으로 주입하면 프로덕션이 그 모듈에서 import하는 **상수까지** 전부 mock 모듈에 채운다. 새 지연 import를 추가하면 해당 테스트 mock 빌더(_build_sys_modules_mocks 등)도 같이 갱신한다.

### [PREVENT] 동시 세션이 타 세션 미커밋 워크트리 편집을 자기 커밋에 휩쓸어감 (2026-06-26, 2026-07-01 보강, 2026-07-03 재발+강화)
다중 세션 환경에서 한 세션이 git add -A / git commit -a / commit --all 또는 파일 전체 재생성(테스트 스캐폴드 regenerate)을 하면, 다른 세션이 워크트리에 만들어둔 미커밋 편집이 의도치 않게 그 세션 커밋에 섞이거나 유실된다. 이번 세션 실증 2건: (1) 내 controlled-parallel 테스트 편집을 stash한 사이 타 세션이 test_fluxos.py를 재생성 → stash pop 머지에서 내 편집 유실. (2) 내 api_runner 테스트 편집(미커밋)이 타 세션 커밋 5283dc4에 통째로 휩쓸려 들어감. 규칙: 모든 세션은 자기가 바꾼 파일만 pathspec(git add <경로> / git commit -- <경로>)으로 스테이징·커밋한다. git add -A / git add . / git commit -a / git commit --all 금지. 다른 세션이 동시에 같은 파일(특히 자동 재생성되는 test_fluxos.py)을 건드릴 수 있으면 git stash 대신 별도 워크트리나 패치 파일로 격리한다. 커밋 전 git diff --cached로 자기 hunk만 들어갔는지 확인한다.

**(2026-07-01 보강) pathspec 커밋은 파일 단위지 hunk 단위가 아니다.** `git commit -m ... -- <경로>`는 인덱스에 무엇이 스테이지됐는지와 무관하게 그 경로의 **현재 워킹트리 전체 내용**을 그대로 커밋한다(내부적으로 그 경로만 `git add` 후 커밋하는 것과 동일). 그래서 "다른 파일"은 안전하게 걸러내지만, 같은 파일 안에 타 세션이 남긴 다른 hunk(예: test_fluxos.py 끝에 붙는 다른 세션의 prevent-capture 스텁 테스트)는 그대로 함께 커밋된다. 실증: 9b3cd99 커밋에서 test_fluxos.py를 `git commit -- tests/test_fluxos.py`로 pathspec 커밋했더니, 내가 고친 단언 1곳 외에 다른 세션이 만들어둔 미커밋 스텁 테스트 2건(test_p0_150/151)까지 같은 커밋에 흡수됨(내용 자체는 무해한 표준 스캐폴드였지만 attribution이 내 커밋으로 잘못 붙음). 규칙: test_fluxos.py처럼 여러 세션이 상시 이어붙이는 핫스팟 파일을 pathspec 커밋하기 **전에** 반드시 `git diff -- <경로>`(스테이지 여부 무관, 워킹트리 vs HEAD)로 전체 diff를 읽고 내가 의도한 hunk만 있는지 확인한다. 예상 못한 hunk가 섞여 있으면 pathspec 전체 커밋을 쓰지 말고, `git diff -- <경로>`를 패치 파일로 떠서 원치 않는 hunk를 제거한 뒤 `git apply --cached <패치>`로 내 hunk만 인덱스에 올리고 pathspec 없이 `git commit`한다(인터랙티브 터미널이 있으면 `git add -p <경로>` + pathspec 없는 `git commit`도 동일 효과). 어느 경우든 이 마지막 커밋은 pathspec을 쓰지 않아야 하며, 남은 hunk는 워킹트리에 미커밋 상태로 남겨 그 hunk를 만든 세션이 직접 커밋하게 둔다.

**(2026-07-03 재발 — 2회째, 강화 조치 추가)** 문서화된 "커밋 전 git diff 확인" 규칙은 **내가 커밋을 실행하는 시점의 확인**만 다루는데, 실제 재발 경위는 그게 아니라 **내가 아직 커밋을 시도하기도 전에** 다른 세션(직접 pathspec 커밋)이나 FluxOS 자동커밋(cadence, `utils/git_autocommit.py`)이 먼저 test_fluxos.py를 스윕해 커밋해버린 것이었다(coding-side 데이터 유실은 없었음, attribution만 다른 세션 커밋 메시지로 잘못 붙음). 조사 결과: index.lock 경합은 이미 `safe_git()`(4회 재시도+백오프)로 방지되고 있고, `commit_guard.py`(pre-commit, `core.hooksPath` 정상 설정 확인됨)는 "교차파일 부분 커밋으로 코드가 깨지는 것"만 막지 "같은 파일 안에서 attribution만 섞이는 것"(코드는 안 깨짐)은 원래 탐지 대상이 아니었다. 이건 pathspec이 파일 단위라는 근본 제약상 완전 차단이 불가능하고(강제 차단 시 여러 세션이 같은 파일의 서로 다른 부분을 정당하게 나눠 작업하는 경우까지 오탐 차단할 위험), 대신 **가시성 확보**로 강화했다: `commit_guard.py`의 `hotspot_commit_summary()`가 hotspot 파일(`tests/test_fluxos.py`) 커밋 시 diff stat을 pre-commit 단계에서 stderr에 강제 출력해, 커밋하는 세션이 "확인 안 하고 그냥 커밋"하기 어렵게 만든다(차단은 아님, fail-open 유지). 회귀: `tests/test_commit_guard.py::HotspotCommitWarningTest`(실제 임시 git repo, mock 없음).

### [PREVENT] 장시간 전체 테스트 런이 동시 소스변경으로 구조가드 거짓 실패를 낸다 (2026-06-26)
inspect.getsource 기반 구조 가드 테스트(예: test_glm_org_path_uses_worktree_resolver, test_runnable_clears_ownership_gate_outside_executor_blocked)는 라이브 상태가 0이지만, 25분짜리 전체 스위트가 도는 동안 다른 FluxOS 세션·데몬이 대상 소스(pipeline/auto_follow.py 등)나 test_fluxos.py를 동시 수정하면 단언 문자열이 일시적으로 어긋나 거짓 실패한다. 실증: 8분 부분런과 6분 통합런에서는 6/6 통과했으나 25분 전체런에서만 같은 3건 실패. 규칙: CI/완료 판정용 전체 스위트(특히 inspect.getsource 구조가드 포함)는 데몬·타 세션이 소스를 안 건드리는 정숙 창에서 1회 돌려 그린을 판정한다. 다중 세션 활성 중의 전체 런 실패는 먼저 동일 테스트를 단독·소그룹으로 재실행해 거짓 실패(동시변경) 여부를 가린 뒤 보고한다. 구조가드가 동시변경에 덜 취약하려면 대상 소스를 한 번 읽어 스냅샷한 뒤 단언하는 것을 고려한다.

### [PREVENT] 정체·완료·차단 판정은 terminal을 task.status로 (pipeline_state 금지) (2026-06-26)
FluxOS에서 task가 종료(취소/완료)됐는지는 task.status(TERMINAL_TASK_STATUSES={done,failed,cancelled})로 판정해야 한다. audit가 계산하는 pipeline_state(REVIEWING/EXECUTOR_BLOCKED/DONE 등)는 종료 작업에서도 stale 비terminal로 남을 수 있어, 정체 감지·자동수렴·runnable·차단 등 어떤 루프든 pipeline_state로 terminal을 판정하면 종료 작업을 살아있는 것으로 오판한다(실측 재발: DONE을 terminal로 본 runnable 누락 / cancelled를 정체로 본 75건 허위 알림). 규칙: 진행/알림/수렴/차단을 결정하는 모든 루프는 먼저 str(row.status).lower() in TERMINAL_TASK_STATUSES로 종료 작업을 거른 뒤 pipeline_state 분기한다. 알림 같은 출력 경계에는 권위 frontmatter status로 재확인하는 불변식 필터를 둔다.

### [PREVENT] terminal·완료·정체 판정은 task_queue.is_terminal로 (로컬 terminal set 정의 금지) (2026-06-26)
작업 종료 여부는 pipeline/task_queue.py의 is_terminal(row)(status=done/failed/cancelled 권위)·is_pipeline_terminal(state)·단일 TERMINAL_PIPELINE_STATES/STALL_EXEMPT_PIPELINE_STATES로 판정한다. monitor/project_lanes/supervisor 등 어디서도 TERMINAL_PIPELINE_STATES를 새로 정의하거나 pipeline_state in {DONE...}로 terminal을 판정하지 말 것. 복제하면 멤버 드리프트로 stranded-DONE 오판·정체가 재발한다(test_hardening_invariants가 재정의를 잡음).

### [PREVENT] 공유 상태 JSON 쓰기는 state_store.locked_section/atomic으로 (직접 truncate-write 금지) (2026-06-26)
work_locks·session_registry·notifications·company_memory·director_inbox·project_registry·codex_state·task .md 같은 다중 세션·데몬 공유 상태는 utils/state_store.py의 locked_section/locked_atomic_write_json/locked_update_json(파일락+RLock+temp·os.replace)으로만 read-modify-write 한다. 평이 write_text(json.dumps)/json.dump truncate-write는 동시쓰기 lost-update·torn JSON으로 알림 중복·상태 유실이 재발한다.

### [PREVENT] 안전 게이트 기본값은 fail-closed (or PASS/or True 금지) (2026-06-26)
계약/리뷰/승인/preflight 등 판정 게이트는 값 없음·파싱 실패 시 기본을 차단/보류로 둔다(or FAIL/or BLOCKED/or False/NEEDS_REVISION). or PASS/or True로 fail-open 하면 producer가 깨질 때 게이트가 조용히 통과(死게이트)된다. 단 데몬 생존·best-effort 알림·anti-stall(멈춤0)은 fail-open이 정당하니 구분.

### [PREVENT] 누적 자원은 생성 시 retention + consolidation prune 배선 (무한 적체 금지) (2026-06-26)
매 호출 timestamp 디렉토리/jsonl append/history 리스트를 만드는 자원은 (a) 생성 시점 keep_last N retention (b) consolidation.run_consolidation_tidy의 artifact age-prune에 배선한다. cap·정리 없으면 worktree 238개·artifacts 247MB처럼 적체로 시스템이 마비된다. worktree는 프로젝트당 생성 cap, released는 재활성 금지.

### [PREVENT] 한도/인증 실패는 retry 소진해도 give-up 금지 (failure_policy 순서 END→quota→retry소진) (2026-06-26)
failure_policy.classify_pipeline_failure 분기 순서는 명시 END → quota(CONTINUE) → retry-소진(terminal)이다. retry-소진 terminal을 quota 위로 올리면 한도 작업이 영구 포기된다(하드닝 중 실제 회귀). quota는 reset 대기.

### [PREVENT] ensure-daemon spawn은 debounce + Popen 직후 PID 기록 (respawn 버스트 금지) (2026-06-26)
백그라운드 데몬을 "PID 죽었으면 Popen"으로 기동하는 ensure_*_daemon_running류는, child가 lock 획득 후에야 PID 파일을 쓰면 그 startup 윈도우(수 초) 동안 PID가 옛 죽은 값을 가리킨다. supervisor가 매 tick마다 ensure를 부르면 계속 "죽음"으로 보고 재spawn → spawn-then-exit 버스트(실측: scheduler-daemon ~30개/9초; child들은 daemon lock 못 잡고 즉시 종료해 동시 실행은 1개지만 낭비·로그오염). 규칙: ensure는 (a) 직전 spawn 후 startup 윈도우(예: 30s) 안엔 재spawn하지 않는다(spawn mark 타임스탬프 파일) (b) Popen 직후 child PID를 즉시 PID 파일에 기록해 다음 ensure가 startup 중에도 alive로 보게 한다. lock으로 동시 실행만 막는 것으로는 부족(버스트는 spawn 호출 빈도 문제). 회귀 test_scheduler_spawn_debounce.py.

### [PREVENT] 계획모드 지시는 FluxOS 파이프라인 등록 후에만 진행(plan-gate 하드 강제) (2026-06-26)
AI 세션이 CEO 파이프라인(계획→구현→리뷰→보고)을 무시하고 계획모드 지시도 직접 구현하던 문제. plan-gate 도입: 계획모드(Claude permission_mode=plan)/계획해(Codex) 지시는 run.py pipeline 등록 전 편집(Claude PreToolUse deny)·커밋(pre-commit FLUXOS_SESSION_ID 세션 commit-check) 차단. utils/plan_gate.py(gate_status ALLOW|REQUIRE_PIPELINE, FLUXOS_PLAN_GATE=block|warn|off), scripts/claude_hooks/plan_gate_hook.py, ~/.claude/settings.json 훅. fail-open·TTL 2h·세션한정. 규칙: 계획모드/'계획해' 지시는 반드시 run.py pipeline로 등록한 뒤 진행하라(미등록 편집·커밋은 plan-gate가 차단).

### [PREVENT] AI 운용 일정 정책: 2026-07-24 Claude 전용은 5종 사다리 확정으로 폐기 (2026-06-26 지시 → 2026-07-16 실제 5종 사다리 확정 → 2026-07-17 CEO 확인)
**원 지시(2026-06-26):** 200달러 Claude Code 무제한 기간이라 7/24까지 모든 작업을 Claude Code로만(GLM/API 비용 차단), 7/25부터 파이프라인(Claude 계획→GLM 구현→Claude 검토).

**사문화 근본:** 2026-07-16 `utils/routing_engine.py:227`의 5종 사다리(GLM-5.2·MiniMax M3·DeepSeek Pro·DeepSeek Flash·GPT-5.4 Mini) 확정 시점에 PRE(`_POLICY_PRE`)와 POST(`_POLICY_POST`)가 **동일 사본** 처리되어, 날짜 기반 자동 라우팅 전환이 무력화됐다. 즉 2026-07-17 현재 자동 라우팅은 오늘부터 **이미 GLM/DeepSeek으로 운영되고 있다**. CEO 확인(2026-07-17): "의도한 상태다 — 그대로 둬라."

**현재 단일 소스:** `utils/routing_engine.py` 5종 사다리 (변경 시 이 파일 수정). `plan_gate.mode()`의 날짜 자동활성은 2026-07-17 제거됨(커밋 10fb2ce) — 이제 명시 opt-in `FLUXOS_PLAN_GATE` env로만 작동.

**교훈:** 날짜 기반 자동 전환을 문서·코드에 심으면 정책이 바뀌어도 문구와 시한폭탄이 남는다. 가변 정책은 반드시 중앙 코드가 단일 소스이고, 문서는 그 소스를 가리키는 참조만 두어야 한다.

### [PREVENT] consolidation 알림 노이즈 — advisory 후보가 30분마다 텔레그램 반복 (2026-06-26)
consolidation tidy advisory 모드가 정리 후보(세션/산출물 등)가 있으면 30분마다 텔레그램 알림을 보내, 안 지워지는 후보가 계속 핑을 유발(노이즈). 수정: 텔레그램은 관리 필요한 경고(워크트리 폭증·미머지 누적 임계초과 alerts)에만, 실제 안전청소는 모니터 로그만, advisory 단순 후보는 무알림. apply 모드로 안전 후보 자동청소(후보 0 유지). 규칙: 주기 데몬 알림은 '조치 필요/변화'에만 텔레그램, 일상 housekeeping은 모니터 채널만.

### [PREVENT] NexusFlow codextest isolated resource guard (2026-06-27)
External smoke tests can accidentally touch existing cloud resources unless every generated/deletion target is gated by a codextest prefix and verified with real input.

### [PREVENT] ValueFlow WIP 분리 커밋·EOL/ignore 가드 (2026-06-28)
포맷·로컬산출물·CRLF가 기능 커밋을 오염하고 salvage 두 브랜치 온보딩 중복

### [PREVENT] Flow deploy 기본값 공유 헬퍼 통일 (2026-06-29)
Flow 프로젝트별 Flutter 래퍼가 ADB 설치와 Google Drive 복사 fallback을 각자 구현해 기본 빌드 모드, 탐색기 오픈, android-build 락 사용이 달라질 수 있었음

### [PREVENT] Flow deploy defaults use shared build-install-copy helper (2026-06-29)
Flow 프로젝트별 deploy 래퍼가 빌드 설치 복사 동작을 각자 구현하면 ADB 없음 처리, Drive 복사, 탐색기 오픈, Gradle 공유락 사용이 프로젝트마다 달라져 회귀한다.

### [PREVENT] FluxStudio root git status storm (2026-06-29)
FluxStudio root repo exposed separate project roots and generated sandboxes as dirty or untracked files, causing Codex/FluxOS git status/diff/add processes to fan out and leave stale index locks during slowdowns.

### [PREVENT] Flow deploy fallback helper (2026-06-29)
Flow 프로젝트별 배포 래퍼가 ADB 기기 부재 시 공통 Google Drive 복사 fallback을 일관되게 제공하지 않음

### [PREVENT] plan_gate=block는 자율 실행기(claude/codex CLI·Hermes) 인증 정상일 때만 활성 (2026-07-01)
Claude 전용 기간 + codex/claude CLI 401·Hermes chat 404(자율 실행기 전부 인증/라우트 깨짐) 상태에서 FLUXOS_PLAN_GATE=block로 파이프라인 등록을 강제하면, FluxOS 데몬이 등록 태스크를 깨진 실행기로 자동 디스패치해 반복 실패 알림이 뜬다. 대화형 Claude가 유일한 작동 실행기인 기간엔 하드 block이 성립 불가. 규칙(AI_WIKI)로 워크플로우를 강제하고 게이트는 warn, 하드 block은 CLI 재로그인+Hermes 복구 후 재활성.

### [PREVENT] pathspec 커밋이 hunk 단위가 아니라 파일 단위라 동시세션 편집이 재차 휩쓸림 (2026-07-01)
상세 규칙·절차는 위 "동시 세션이 타 세션 미커밋 워크트리 편집을 자기 커밋에 휩쓸어감" 항목의 (2026-07-01 보강) 문단 참조(중복 방지로 본문은 그쪽에 통합). 요지: `git commit -- <path>`는 인덱스와 무관하게 그 경로의 현재 워킹트리 전체를 커밋하므로 파일 단위 격리이지 hunk 단위 격리가 아니다. 실증: 9b3cd99에서 test_fluxos.py pathspec 커밋 시 타 세션의 미커밋 스텁 테스트 2건이 함께 흡수됨.

### [PREVENT] CEO OS pipeline_progress + 회사 거버넌스 정책이 여전히 Codex를 실행자로 표시 (2026-07-01)
CEO OS api.py의 _PIPELINE_STAGES가 구현 단계 model을 'Codex'로 하드코딩, Monitor의 파이프라인 스테이지 키가 '코덱스 구현'으로 고정, company_governance.py의 기본 정책+영속 스냅샷(2026-06-20 저장분)이 role_model_matrix/workflow_policy에 'Codex GPT-5.4 Mini'/'Codex Implementation'을 고정 저장해 load 시 fresh default를 덮어씀. 표시 로직과 저장된 스냅샷 둘 다 실제 실행자 상태(config.codex_enabled/ai_schedule.active_implementer)를 반영하지 않고 정적 문자열/과거 저장값에 의존했기 때문.

### [PREVENT] 공유 AI 캐시(context_hash 재사용 테이블)에 사용자 원문 자유텍스트 저장 금지 (2026-07-02)
LLM 응답을 (context_type, context_hash) 조합으로 재사용하는 공유 캐시 테이블(예: HealthFlow hf_ai_insights)은 여러 사용자가 같은 캐시 행을 읽도록 설계되며, RLS도 보통 `to authenticated using (true)`처럼 로그인 사용자 전원에게 읽기를 열어둔다. 이때 클라이언트가 Edge Function payload(`input`)에 넣는 필드가 사용자가 직접 타이핑한 원문 자유텍스트(검색어·서술형 입력 등)를 하나라도 포함하면, 그 `input`이 가공 없이 그대로 캐시 컬럼(예: `input_summary` jsonb)에 영구 저장돼 다른 로그인 사용자 전원에게 노출된다. 실증: HealthFlow 검색 화면이 Edge Function `hf-ai-analyze` payload에 `'query': 검색어원문`을 그대로 실어 보내 `hf_ai_insights.input_summary`에 저장·노출됨(RLS를 anon→authenticated로만 좁히는 것으로는 안 막힘 — 로그인 사용자끼리도 문제). 이 패턴은 HealthFlow만의 문제가 아니라 LLM 응답 캐싱 + 공유 읽기 RLS를 쓰는 어떤 FluxStudio *flow 프로젝트에서도 동일하게 재발할 수 있다. 규칙: Edge Function payload/캐시에 값을 넣기 전 필드 단위로 "Rule Engine·카탈로그·고정 열거형이 만든 통제된 값인가, 아니면 사용자가 직접 입력한 원문인가"를 리뷰한다. 원문이 필요하면 LLM 프롬프트 조립에만 쓰고 캐시 저장 컬럼에는 넣지 않거나, 저장 전에 통제된 라벨/분류값으로 먼저 변환한 뒤에만 넣는다.

### [PREVENT] PowerShell 재현(Python) 로직이 원본 .ps1과 인코딩(BOM) 처리에서 미세 드리프트 (2026-07-03)
PowerShell 채널이 일시 무응답이라 generate-claude-md.ps1/generate-agents-md.ps1 로직을 Python으로 재현해 실행했다. 이후 PowerShell 복구 후 실제 스크립트와 diff 비교한 결과 콘텐츠는 100퍼센트 일치했으나 BOM 처리 방식이 달랐다: PowerShell ReadAllText는 각 소스파일 BOM을 자동 스트립하고 WriteAllText가 결과물 맨 앞에만 새 BOM을 붙이는 반면, Python open().read()는 각 파일 BOM을 그대로 유지해 결과물 안에 여러 개 산재시켰다. 콘텐츠 손상은 아니었으나 재현 로직이 원본과 별도 유지보수되면 드리프트가 축적될 위험이 있다. 규칙: PowerShell 실행 채널이 막혀 부득이 다른 언어로 로직을 재현했다면 채널 복구 즉시 실제 원본 스크립트로 재실행해 결과를 덮어써 정합성을 확보하고, 재현 코드는 1회성 우회로만 쓴다.

### [PREVENT] 완료 판단은 신규 테스트뿐 아니라 영향받는 모듈 전체 스위트로 (2026-07-03)
Task002(Mode C 자율성 수정) 완료 판단 시 신규 테스트(test_exhausted_review_glm_autonomy.py)만 돌리고 넘어갔다가, 정작 test_fluxos.py 안에 있던 기존 test_p0_61이 실제 외부 GLM API를 호출하고 있던 회귀를 놓쳤다(수정한 로직의 전제가 바뀐 기존 테스트를 전체 스위트로 안 돌려서 발견 못함). 규칙: 코드 수정 후 완료 판단은 (1) 신규/직접 관련 테스트 (2) 수정한 모듈을 import하는 모든 테스트 파일 전체 실행 두 단계를 모두 거친다. 전체 스위트에서 무관한 실패(다른 프로젝트 파일 상태, 피크시간 의존, 무관 모듈)가 나오면 트레이스백으로 원인을 확인해 내 변경과 무관함을 실측 확인한 뒤에만 넘어간다(git stash로 baseline 비교는 동시세션 편집 휩쓸림 위험이 있어 금지 — 트레이스백 분석 우선).

### [PREVENT] 무인 상시 자동화(삭제·재시작 등) 요청은 명시적 위험 재확인 필수 (2026-07-03)
사용자가 '매번 정리하라고 말하기 어려우니 자동으로 해줘'처럼 파괴적 동작(삭제·핵심 데몬 재시작·공유 체크아웃 전환)을 영구 무인 자동화로 요청하면, 모호한 AskUserQuestion만으로는 승인으로 보지 않는다. 방지: (1) 지금 만들려는 것을 구체적으로 설명한다('항상 켜진 데몬 안에서 영구히 확인 없이 X를 삭제/재시작하는 기능'). (2) AskUserQuestion에 위험을 그대로 명시한 질문을 던진다(예: '이 자동삭제 기능을 사람 확인 없이 영구적으로 심어도 될까요?') — 일반적인 '자동화할까요?' 질문으로는 부족하다. (3) 명시적 yes 이후에만 계획→구현→적대적 리뷰어(fail-closed 의심 시 무조건 REQUEST CHANGES)→수정→재검증→pathspec 커밋 파이프라인을 정상 엄격도로 적용한다. (4) 파괴 로직 자체는 scope allowlist/denylist, fail-closed 안전게이트(git dirty-check 등), 배치/시간예산 제한, off|advisory|apply 모드(기본은 명시 승인 시에만 apply), --force/reset --hard/git clean 금지, 로그전용 보고를 재사용 패턴(utils/worktree_autoclean.py)으로 따른다. 자가재시작 데몬에는 시간당 재시작 상한(supervisor_daemon.py의 _DAEMON_RESTART_TIMES 패턴 재사용)을 반드시 둔다.

### [PREVENT] AI 폴백 회전 시 claude CLI는 구현 작업에 permission_mode=bypassPermissions 명시 필수 (2026-07-03)
AI 작업이 한도/인증으로 막히면 codex↔claude→GLM 순으로 회전하며 give-up하지 않고 계속 시도한다(기존 [PREVENT] 한도/인증 실패 retry소진 give-up금지 원칙과 결합). 확정 순서(2026-07-02): GLM 1차 → claude CLI 2차(무료, Nous 불필요) → Hermes/Nous 유료 3차. 피크시간 15:00~19:00(KST)은 토큰 3배라 이 시간엔 구현하지 않고 계획만 적재, 비피크에 구현한다. GLM은 동적 한도(고정 아님)이므로 막히면 끝이 아니라 주기적으로 재확인해 한도 회복 시 재개한다. 중대 발견: claude CLI로 실제 파일 수정이 필요한 구현 작업을 실행할 때 permission_mode 기본값(dontAsk)은 자동승인이 아니라 도구 사용을 거부한다 — 그 결과 claude가 '권한 필요' 메시지만 남기고 실제로는 아무 파일도 안 고쳤는데 done.md가 비어있지 않아 시스템이 DONE으로 오판하는 잠복 버그가 있었다(모든 AI 폴백이 사실상 이 2차 경로에서 무동작이었음). 방지: claude CLI로 파일 읽기/쓰기/명령 실행 등 실제 작업을 시킬 때는 permission_mode를 반드시 명시한다 — 구현(파일 수정)=bypassPermissions, 읽기전용 계획/검증=plan. dontAsk는 계획/리뷰 같은 단발 텍스트 응답에만 쓴다. 에이전트형 구현은 단발 대비 수 분 이상 걸리므로 타임아웃도 별도 상수(예: CLAUDE_IMPL_TIMEOUT_SECONDS, 900s)로 분리한다.

### [PREVENT] 시간의존 테스트에 절대 날짜 하드코딩 금지(클램프·만료 로직 있는 경우) (2026-07-03)
클램프·만료·과거차단 로직을 거치는 시간의존 테스트에 특정 절대 날짜(예: DateTime(2026,6,13,10))를 하드코딩하면, 작성 시점엔 미래라도 시간이 지나 과거가 되는 순간 그 클램프/만료 로직에 걸려 테스트가 갑자기 깨진다(시한폭탄 — 앱 버그가 아니라 테스트가 늙은 것). 실증: PlanFlow-v2 confirm_screen_test가 ConfirmScreen의 '1일 이상 과거면 now()로 클램프'하는 의도된 로직에 걸려 날짜가 지나며 실패. 방지: 클램프/만료/과거차단을 타는 시간의존 테스트는 절대 날짜 대신 현재 기준 상대 미래를 쓴다(예: `final year = DateTime.now().year + 1;` 또는 `planflowNow().add(Duration(days: N))`). 기대값도 같은 상대식으로 계산한다. 새 테스트 리뷰 시 리터럴 연·월·일이 보이면 그 값이 시간이 지나도 유효한지 자문한다. FinFlow/PlanFlow 등 시간의존 로직이 있는 모든 Flutter 테스트에 공통 적용.

### [PREVENT] 깊게 갈라진 브랜치 머지는 hunk 단위(-X ours) 대신 공유코드 전체 통일로 (2026-07-03)
공통 조상에서 크게 갈라진(수십~백여 커밋, 다수 파일) 두 브랜치를 '충돌 시 최신(보통 로컬) 우선'으로 합칠 때, `git merge -X ours`처럼 hunk 단위로 충돌만 해소하면 파일 간 의존 관계가 어긋나(정의는 로컬인데 호출부는 origin 것을 참조하는 식) 빌드가 깨진다(duplicate_definition·undefined·non-exhaustive switch 등). 실증: PlanFlow-v2 team-v2-planning 병합(공통조상에서 각각 74/66커밋, 118파일 갈라짐)에서 -X ours 부분머지가 빌드를 깨뜨림. 방지 절차: ① 양쪽 tip을 백업 태그로 보존(무손실 보험). ② 머지 커밋을 만들어 origin을 조상으로 기록(푸시 가능하게). ③ `git checkout <최신-백업태그> -- .`로 공유 파일 전부를 최신(로컬) 전체로 통일(hunk 혼합 금지). ④ `git diff --diff-filter=A`로 origin이 새로 추가한 파일만 확인해 코드면 검토, 비코드(문서·마이그레이션)는 그대로 보존. ⑤ 머지 전 별도 워크트리에서 기존 실패 기준선을 잡고, 머지 후 실패가 기준선과 같으면 회귀 0으로 판정한다.

### [PREVENT] 다중세션 동시편집 환경의 커밋/푸시 마찰은 rebase.autoStash+pull.rebase 전역설정으로 해소 (2026-07-03)
여러 AI 세션이 같은 메인 체크아웃/브랜치를 동시 편집하는 구조에서는 push가 거부될 때마다 수동으로 stash→rebase→pop을 반복하게 되고, 그 과정에서 자기 편집이나 타 세션 편집이 휩쓸릴 위험이 있다. 방지: `git config --global rebase.autoStash true`와 `git config --global pull.rebase true`를 설정해두면, push 거부 시 `git pull` 한 번만으로 자동 stash→rebase(내 커밋만 replay)→pop이 이뤄지고 워킹트리의 타 세션 dirty 파일은 그대로 유지된다(수동 stash dance 불필요). 런타임 산출물(`.fluxos/queue_archived_stale/`, `.fluxos/**/*.lock`, `.fluxos/*_STALL_REPORT_*.md` 등)은 `.gitignore`에 등록해 불필요한 untracked 노이즈를 줄인다. 새 흐름: `git commit -- <내파일>` → `git push` → (거부 시) `git pull` → `git push`. autostash는 rebase 충돌만 흡수할 뿐 잘못된 staging은 막지 않으므로 pathspec 커밋 원칙(git add -A/commit -a 금지)은 그대로 유지한다.

### [PREVENT] Google Drive 업로드는 Chrome MCP file_upload 대신 로컬 마운트 경로 직접 복사 (2026-07-03)
대용량 파일(특히 100MB+ APK)을 Google Drive에 올릴 때 Chrome MCP의 file_upload 도구를 쓰면 '세션에 공유된 파일'만 허용되고 10MB 한도가 있어 무조건 실패한다. 방지: Google Drive for Desktop이 마운트된 로컬 드라이브 경로(예: `I:\내 드라이브\`)에 PowerShell `Copy-Item`으로 직접 복사한다 — 복사하면 자동 동기화된다. 이 방법은 파일 업로드가 필요한 모든 상황(APK 배포 산출물, 대용량 리포트 등)에 공통 적용.

### [PREVENT] 백그라운드 서브에이전트 완료 후 UI 배지가 계속 실행중으로 남음(stale) (2026-07-03)
Claude Code 앱에서 Agent 도구로 여러 서브에이전트를 한 메시지에 병렬 호출하면 harness가 자동으로 run_in_background 모드로 전환한다(명시적으로 지정하지 않아도). 서브에이전트가 실제로는 정상 완료되어 TaskOutput(block=true)로 결과를 성공적으로 회수했고, 이후 같은 task_id로 TaskOutput(block=false)/TaskStop을 다시 호출하면 둘 다 "No task found with ID"를 반환한다 — 이는 백엔드가 해당 작업을 이미 정상 종료·정리(reap)했다는 뜻이다. 그런데 화면 우측 "백그라운드 작업" 패널의 카드는 완료 이벤트를 받지 못해 "실행 중" 상태와 경과시간 카운터가 계속 올라가는 채로 남는다 (실측 사례: 3시간 넘게 "실행 중"으로 표시, 4개 전부 동일 증상). 이건 Claude Code 앱(플랫폼) 프론트엔드의 완료-상태 동기화 버그이며, 이 저장소 코드로 직접 고칠 수 있는 대상이 아니다. 방지책은 코드 수정이 아니라 진단 절차다: (1) 배지가 이미 결과를 사용한 뒤에도 오래(30분+) "실행 중"으로 남아 있으면, 그 경과시간 숫자만 보고 "멈췄다/과다실행 중"이라고 판단하지 않는다(evidence-based-no-guessing과 동일 원칙 — UI 표시는 실측이 아니다). (2) 먼저 TaskOutput(task_id, block=false, timeout=짧게) 또는 TaskStop(task_id)으로 실제 백엔드 상태를 실측 확인한다. "No task found with ID"가 나오면 이미 완료·정리된 것이고 UI만 stale — 추가 조치나 재시도, 리소스 낭비 걱정이 불필요하다. (3) 실측상 stale로 확인되면 사용자에게 해당 카드 우측 상단 체크박스/닫기 아이콘을 눌러 수동으로 지우도록 안내한다(사용자가 직접 확인한 해소 방법, 데이터 손실 없음 — 그 시점에 이미 백엔드에 작업이 없으므로 지워도 안전). (4) 같은 대화에서 이미 TaskOutput(block=true)로 결과를 받아 활용한 서브에이전트라면, 그 결과를 이미 다 썼다는 사실 자체가 완료의 증거이므로 배지 상태와 무관하게 작업을 이어가도 된다.

**(같은 날 보강 — 수동 삭제는 일시적일 수 있음)** 사용자가 (3)의 카드 삭제 버튼으로 4개를 전부 지웠는데, 이후 대화가 이어지자(새 메시지 전송 시점) 같은 4개 배지가 **끊기지 않고 원래 경과시간에 이어서**(0부터 재시작이 아니라 3시간대→3시간40분대로 계속 누적) 다시 나타났다. 이는 삭제가 그 시점 렌더링에서만 반영되고 배지의 실제 데이터 소스(원본 시작시각을 들고 있는 어떤 세션/로그 레코드)는 지워지지 않는다는 뜻 — 즉 TaskOutput/TaskStop이 보는 레지스트리와 UI 배지가 읽는 소스가 서로 다르거나 최소한 삭제 동기화가 안 되는 것으로 보인다(추정, 미확정). 방지책 갱신: (5) 카드 삭제는 완전한 해결로 보장하지 말 것 — 재발하면 그 자체가 새 문제가 아니라 같은 stale 배지의 재표시임을 사용자에게 먼저 설명한다. (6) 완전 제거를 원하면 앱 완전 종료 후 재시작을 먼저 시도하도록 안내한다(단순 탭/대화 재진입보다 강한 조치). (7) 재시작 후에도 재발하면 이는 이 저장소로 고칠 수 있는 범위를 벗어난 Claude Code 플랫폼 자체의 버그이므로, 계속 반복될 경우 Anthropic에 재현 절차(병렬 Agent 호출 → TaskOutput으로 정상 회수 → TaskOutput/TaskStop 모두 "no task found" 확인 → UI 배지만 몇 시간째 미종료 → 수동삭제해도 다음 메시지에서 원래 경과시간 이어서 재출현)와 함께 제보하는 것을 권장한다. 이 경우에도 실제 연산/비용 발생은 없다(백엔드 레지스트리 기준으로는 이미 종료).

**(최종 확인 — 재부팅 후 정정된 근본원인)** 사용자가 앱을 완전히 재부팅하자 즉시 4개 task_id 전부에 대해 harness가 자동으로 `status: failed` 알림을 보내며 사유를 명시했다: "Background agent ... was running when the previous Claude Code process exited and did not complete. Its in-process state was lost." 이는 (2)~(4)에서 추정했던 "완료됐는데 UI만 stale"이 아니라, **실제로는 이전 Claude Code 프로세스가 죽을 때 그 백그라운드 에이전트들의 진행상태가 함께 유실되며 좀비로 남아 있었다**는 뜻이다(TaskOutput(block=true)로 결과를 회수했던 시점엔 정상 완료였으나, 그 이후 무언가의 이유로 프로세스/세션이 비정상 종료됐고 그 좀비 흔적이 배지에 계속 남음). 새 프로세스(재부팅 후)가 기동되며 고아 상태를 스캔해 명시적으로 failed 처리하고 나서야 배지가 사라졌다. 근본원인 정정: "UI 프론트엔드 동기화 버그"가 아니라 **"백그라운드 에이전트의 진행상태가 상위 프로세스 비정상종료에 취약하고, 그 좀비 상태는 같은 프로세스 재시작 없이는 절대 스스로 해소되지 않는다"**가 맞다. 방지책 최종: (8) 배지가 오래 남아 TaskOutput/TaskStop 둘 다 "no task found"인데도 화면에서 안 사라지면, 카드 삭제를 반복 시도하지 말고 곧바로 **앱 완전 재부팅**으로 넘어간다(추정 단계 건너뛰기 — 재부팅이 유일하게 확인된 해결책). (9) 재부팅 시 harness가 스스로 좀비를 감지해 `failed` 알림을 보내는 것이 정상 동작이며, 이 알림의 "in-process state was lost" 문구가 뜨면 그건 실제 새 문제가 아니라 이 방지책이 다루는 바로 그 정리 과정이 끝났다는 신호다. 이미 TaskOutput(block=true)로 결과를 회수해 활용까지 끝낸 작업이었다면 재작업 불필요.

### [PREVENT] Claude Code 한도 이중 모델 구현 완료 확인 (2026-07-03)
CEO 지시(2026-07-03): 주간(weekly) + 5시간 롤링(five_hour) 한도를 독립 추적. 지시 시점에 이미 완전 구현되어 있었음을 확인. 재발 방지: test_p0_199_claude_dual_quota_weekly_five_hour가 이중 한도 모델의 모든 동작을 검증함.

### [PREVENT] Android 화면 회전 설정 시스템 간섭 (2026-07-03)
AndroidManifest.xml의 android:configChanges에 orientation을 포함하면 앱이 시스템 전체 화면 회전 설정을 변경할 수 있음. FluxStudio 프로젝트들(MenuFlow, PlanFlow, ValueFlow)이 이 설정으로 인해 사용자 기기의 자동 회전 설정을 계속 켜는 문제 발생.

### [PREVENT] S23 무선디버깅 mDNS 재연결 실패 시 좌표만 반복 재시도 (2026-07-04)
adb 무선 디버깅(mDNS 자동연결)이 세션 중간에 갑자기 끊기는 경우, 근본 원인 진단 없이 화면 탭 좌표를 반복 추측하며 시간을 낭비했다. 실측 조사 결과: (1) Windows 방화벽의 mDNS(UDP 5353) inbound 규칙은 Private/Domain/Public 전부 Allow로 이미 정상이라 원인이 아님(Get-NetFirewallRule로 확인). (2) adb kill-server/start-server로 mdns 데몬을 재기동해도 'adb mdns services'가 계속 비어있다면, 이는 컴퓨터 쪽이 아니라 폰 쪽 문제(화면 꺼짐/잠김 상태에서 삼성 기기가 무선 디버깅 브로드캐스트를 일시 중단하는 경우가 많음)일 가능성이 크다. 수정: E:\AI_WIKI\scripts\adb-mdns-diagnose.ps1 신규 작성 — adb 서버 재시작 후 짧은 간격으로 재시도(기본 5회x3초)하며 대상 기기(roster의 s23 슬롯 serial과 getprop ro.serialno 비교) 연결 여부를 확인하고, 그래도 못 찾으면 폰 화면 켜기/Wi-Fi 확인/토글 재시작 체크리스트를 한국어로 즉시 출력한다. 교훈: 무선 기기 연결 실패 시 좌표 재시도나 추측 대신 이 스크립트로 먼저 원인(방화벽 vs mdns데몬 vs 폰상태)을 구분해야 한다. 부수적으로 이 파일 작성 중 PowerShell이 UTF-8 BOM 없는 .ps1의 한글 주석을 시스템 코드페이지로 오인식해 파싱 에러를 낸 것도 확인 — 한글 포함 신규 .ps1은 항상 UTF-8 BOM으로 저장해야 함(기존 AI_WIKI 공통규칙에 이미 있는 원칙의 재확인).

### [PREVENT] feature/groups-port를 운영 main(+70)에 병합 - 6파일 자동해소 검증 (2026-07-04)
그룹 다중공유·팀나가기·구글로그인복구 브랜치가 운영 19커밋(오전오후모달전환·강조스타일·PlanFlowActionButtons통일 등)과 6개 파일(AndroidManifest/pubspec/app.dart/settings_widgets/confirm_screen/confirm_screen_test)에서 겹침. git merge(ort strategy)가 충돌마커 없이 자동해소했으나, 과거 -X ours로 기능이 조용히 드롭된 사고가 있어 자동해소 결과를 맹신하지 않고 6개 파일 전부 코드레벨로 직접 대조(grep으로 양쪽 함수/필드명 존재 확인)해 병합 정합성을 실측 검증함.

### [PREVENT] PowerShell Mandatory 파라미터 누락 시 무한 대화형 프롬프트 대기로 조용히 멈춤 (2026-07-04)
deploy-play-internal.ps1의 -ProjectKey는 [Parameter(Mandatory=true)]인데 이를 빠뜨리고 백그라운드/비대화형으로 호출. PowerShell이 누락된 필수 파라미터 값을 콘솔에서 물어보려 대기하는데, 비대화형 실행 환경이라 입력을 영원히 못 받아 에러도 CPU사용도 없이 조용히 멈춤(95분+2회 재현, 상태파일/로그 0바이트, 자식프로세스 0개, CPU 0.9초 고정이 유일한 단서). Read-Host 등 명시적 대화형 코드가 없어 grep으로도 못 잡히는 은닉된 hang 패턴.

### [PREVENT] mDNS 중복 광고 시 flutter devices가 구분자 붙은 adb 시리얼을 못 찾음 (2026-07-04)
adb가 같은 무선디버깅 기기를 두 번 mDNS로 광고받으면 시리얼에 '(2)._adb-tls-connect._tcp' 구분자를 붙이는데(예: adb-R3CW90940TA-L7evoK (2)._adb-tls-connect._tcp), raw adb -s는 이 전체 문자열로 정상 통신되지만 flutter devices/flutter run -d는 구분자 없는 원래 이름만 찾아 'device not found'/unsupported로 오판한다. 실제로는 연결이 끊긴 게 아니라 Flutter 자체 기기탐색 로직의 시리얼 매칭 한계였다. 우회책: adb devices -l로 실제 전체 시리얼을 확인한 뒤 adb -s '<전체시리얼>' install/uninstall처럼 raw adb로 직접 설치하면 flutter 툴링을 거치지 않고 sideload할 수 있다.

### [PREVENT] MenuFlow ic_stat_notification 리소스 중복 빌드실패 (2026-07-05)
android/app/src/main/res/drawable/ 아래 ic_stat_notification.png(구, Jun 7)와 ic_stat_notification.xml(신, Jul 2 벡터)이 같은 리소스명으로 동시 존재해 mergeReleaseResources에서 Duplicate resources 실패. xml이 상태바 알림 아이콘 규격(흰색 벡터)에 맞는 최신 의도된 리소스이므로 png를 삭제해 해소.

### [PREVENT] model_routing_guard: 서브에이전트 모델 미구분 시 차단 강화 (2026-07-05)
CEO 지시(2026-07-05): 서브에이전트(Agent 도구)를 한 번이라도 쓰면 무조건 통과시키던 것을, 여러 개 위임했는데 전부 같은 모델(또는 model 파라미터 미지정)이면 난이도별 모델 라우팅이 아니므로 여전히 차단하도록 강화. scan_current_turn이 각 Agent tool_use의 input.model을 수집해 2개 이상 호출 시 distinct model이 2종 이상이어야 통과(routing_ok)하도록 model_routing_guard.py의 handle_stop을 수정. Agent 호출 1개뿐이면 난이도 구분 판단 대상이 없어 예외적으로 통과시켜 과도한 엄격화를 방지함.

### [PREVENT] ValueFlow dart-define 누락/키 엇갈림으로 Supabase 미초기화 (2026-07-05)
VS Code launch.json 부재, .idea runConfiguration이 참조하는 scripts/valueflow-dart-defines.json 이 .env 와 별도 수작업 관리돼 PDMV_ANON_KEY 가 구형 JWT 와 신형 sb_publishable 으로 엇갈림. 그리고 IDE/터미널 직접 flutter run 시 dart-define 자체가 주입되지 않아 main.dart 가 조용히 Supabase.initialize 를 생략 -> login_screen 에서만 늦게 '실행용 Supabase 설정이 안 들어왔다' 메시지 노출.

### [PREVENT] adb-device-resolver Strict 크래시 + wireless 슬롯 ID 매칭 stale (2026-07-05)
resolver가 모든 roster 슬롯에 device_key 속성이 있다고 가정해 legacy_tcpip 슬롯에서 PropertyNotFoundStrict 크래시. 또한 wireless 슬롯의 device_key가 mDNS 풀네임/포트인데 포트가 회전하거나 legacy tcpip가 DHCP로 바뀌면 stale 돼 S23 대신 S8을 잡음. 추가로 adb-device-resolver.ps1 자체가 AI_WIKI git tracked에서 누락(untracked)돼 형제 스크립트와 달리 버전 관리 안 됨.

### [PREVENT] PowerShell ConvertTo-Json 단일요소 raw 직렬화 + powershell.exe -File 자식호출 JSON 인자 깨짐 (2026-07-05)
두 가지가 겹친 메타패턴. (1) PowerShell 5.1 ConvertTo-Json 은 -InputObject 가 단일 요소 배열일 때 JSON 배열이 아니라 raw 문자열로 직렬화해 수신측 ConvertFrom-Json 이 실패. (2) & powershell -File child.ps1 -Param \ 으로 자식 프로세스 호출하면 Windows 프로세스 인자 파싱에서 JSON 의 따옴표/대괄호가 깨져 첫 토큰만 전달. 실증: valueflow-local deploy 의 dart-define JSON 이 깨져 'Invalid JSON primitive: --dart-define', flutter-deploy-or-copy 의 BuildArgsJson 이 깨져 'Invalid JSON primitive: apk'. 방지: JSON 배열은 수동 빌드(escape 직접 처리), 자식 프로세스 -File 호출 대신 같은 런타임 & 직접 호출. AI_WIKI scripts 중 adb-device-resolver.ps1, flutter-deploy-or-copy.ps1 이 tracked 에 누락돼 형제 스크립트와 달리 버전관리 안 되고 있었음(별개 근본이지만 같은 세션에서 발견).

### [PREVENT] 그룹 위젯 프리뷰 XML이 참조하는 스타일 미정의로 release 빌드가 여러 커밋째 깨져 있었음 (2026-07-07)
9ca6c2a에서 planflow_group_calendar_widget_preview.xml에 PlanFlowWidgetPreviewCell/Day/Count 스타일을 참조하는 레이아웃을 추가했는데, styles.xml에 해당 스타일 정의를 빠뜨렸다. 이후 커밋(7e46022)까지 이어졌지만 실제 release 빌드(flutter build apk --release)를 돌리지 않고 debug/분석만 통과시켜 AAPT 리소스 링크 실패를 아무도 발견하지 못했다. 위젯 레이아웃처럼 style 참조가 많은 XML을 추가/수정한 뒤에는 flutter analyze만으로는 부족하고, 최소 1회 release 빌드(android-build 공유락 경유)까지 돌려 AAPT 리소스 링크 오류가 없는지 확인해야 한다.

### [PREVENT] dart-define 설정 누락 2차 재발 - flutter-build-guarded.ps1 파일명 불일치 (2026-07-07)
공용 android-build 락 래퍼(E:/AI_WIKI/scripts/flutter-build-guarded.ps1)의 dart-define 자동주입 로직이 'env/local.json'이라는 고정 파일명만 인식했다. ValueFlow는 이 파일명을 쓰지 않고 scripts/valueflow-dart-defines.json(sync-dart-defines.ps1이 .env 기준으로 생성)을 쓰는데, 이 이름이 후보 목록에 없어 Test-Path가 항상 false를 반환했다. 그 결과 -BuildArgs에 dart-define을 명시하지 않고 이 래퍼로 release 빌드하면 매번 Supabase 설정 없이 조용히(에러 없이) 빌드가 완료돼, S23 실기기에서만 '실행용 Supabase 설정이 아직 들어오지 않았습니다' 에러 배너로 뒤늦게 발견됐다. f82dc1f(scripts/valueflow-local.ps1 수정)로 이미 한 번 고쳤던 문제였으나, 그 수정은 valueflow-local.ps1 경로만 다뤘고 실제로 반복 사용되는 release 빌드 경로(flutter-build-guarded.ps1)의 파일명 불일치는 그대로 남아있어 재발했다. 수정: flutter-build-guarded.ps1이 여러 후보 dart-define 파일 경로(env/local.json, scripts/valueflow-dart-defines.json)를 순회하도록 확장하고, scripts/sync-dart-defines.ps1이 있으면(ValueFlow) 빌드 직전 자동으로 최신화하며, release/profile 빌드인데 후보가 전혀 없으면 강한 경고 배너를 출력하도록 fail-open 방어를 추가했다.

### [PREVENT] 홈 위젯 배치화면 프리뷰는 런타임 레이아웃 재사용 시 항상 빈칸(tools:text만 있음) (2026-07-08)
Android AppWidgetProviderInfo의 previewLayout이 런타임 레이아웃(planflow_monthly_widget.xml)을 그대로 가리키면, 위젯 배치 화면(런처 피커)은 이 XML을 RemoteViews 데이터 바인딩 없이 그대로 렌더링한다. 런타임 레이아웃의 TextView들은 실제 값이 tools:text(디자인타임 전용, 빌드시 스트립됨)로만 채워져 있고 android:text는 비어있어, 피커에서는 완전히 빈 칸으로 보인다. 그룹 달력 위젯은 이미 전용 프리뷰 레이아웃(planflow_group_calendar_widget_preview.xml, 실제 android:text로 채운 샘플 데이터)을 만들어 이 문제를 해결해뒀는데, 개인 월간 위젯은 이 패턴이 적용되지 않은 채 남아있었다. 수정: planflow_monthly_widget_preview.xml을 새로 만들어 런타임과 동일한 셀 구조(layout_columnWeight/rowWeight 등 GridLayout 배치 속성까지 명시)에 실제 android:text 샘플 값(날짜/이벤트 제목/중요일정 빨간색/오버플로우)을 채우고, provider info의 previewLayout을 이걸로 바꿨다. 규칙: 새 홈위젯을 추가하거나 기존 위젯의 previewLayout이 런타임 레이아웃을 그대로 가리키고 있으면, 항상 별도의 프리뷰 전용 레이아웃(실제 android:text 샘플, 런타임과 동일한 배치 속성 명시)을 만들어야 한다.

### [PREVENT] 홈위젯 마지막(overflow) 줄만 다른 gravity로 정렬돼 앞줄들과 다르게 보임 (2026-07-08)
planflow_monthly_widget.xml의 event_1~4 title은 PlanFlowWidgetMonthCellEvent 스타일(gravity 미지정, 기본 좌측정렬)을 쓰는데, 그 아래 overflow_count TextView만 PlanFlowWidgetMonthCellOverflow 스타일을 써서 이 스타일에만 gravity=end + textAlignment=viewEnd(우측 정렬)가 걸려 있었다. 텍스트 길이가 셀 폭보다 짧으면 우측 정렬 때문에 시작 위치가 오른쪽으로 밀려, 사용자 눈에는 마지막 줄만 원인 모를 들여쓰기가 생긴 것처럼 보였다. 이미 존재하는 형제 스타일(PlanFlowWidgetOverflowText, 주간 위젯들이 씀)은 애초에 gravity=start였는데 월간 위젯의 overflow 스타일만 우측정렬로 남아있었다(아마 뱃지처럼 오른쪽에 붙이려던 의도였다가 실제로는 다른 줄과 정렬을 맞추는 게 맞았던 사례). 규칙: 한 셀/카드 안에서 여러 줄(제목들+요약/오버플로우 줄)을 같은 좌측 기준선에 맞추려면, 그 줄들에 쓰는 모든 스타일이 동일한 gravity/textAlignment를 명시적으로 공유하는지 확인한다 — 스타일 이름이 비슷해 보여도(Event vs Overflow) 개별 속성은 복사되지 않으므로 항상 실제 값을 직접 비교해야 한다.

### [PREVENT] main-feature 브랜치 66/120 커밋 분기 병합 절차 실행 (2026-07-09)
main과 feature/menuflow-integration이 장기간 각자 독립 진행되며(main=66개 자체 커밋으로 Sprint 6~13/알리익스프레스 어댑터 등, feature=120개 자체 커밋으로 이번 세션의 JWT수정+Sprint13-1/2/3+검색스모크테스트+알리토글) 23개 파일(content 17 + add/add 6)에서 실제 충돌. CLAUDE.md에 이미 문서화된 '깊게 갈라진 브랜치 병합' 절차(백업태그->공유파일 최신전체통일->add/add 개별검토->회귀0 확인)를 그대로 적용해 안전하게 병합. 재발 방지보다는 절차가 이미 있었고 정확히 준수했음을 기록하는 목적.

### [PREVENT] CEO OS 커맨드센터 버튼 레이아웃 UI 일관성 (2026-07-09)
기능이 폐기된 미리보기 버튼이 HTML에 남아있고, 여러 줄로 산재된 버튼 배치가 가로 공간을 낭비함. UI 개선 후 레이아웃 규칙이 문서화되지 않으면 향후 버튼 추가 시 다시 여러 줄로 배치될 위험

### [PREVENT] FluxOS V11.1: Scope Lock Recovery and Autonomous Task Continuation (2026-07-09)
152 active locks accumulated in work_locks.json, ~140 of which are orphan (expired but never moved to released). 123 non-terminal tasks in queue, many from June 1 (38 days ago). 10 tasks classified as RESUME-able (continueable=True) but blocked by 'other owner active session present'. MANUAL_REVIEW classification for preflight BLOCKED tasks is correct - they genuinely need lock release intervention. Resume attempt on TASK_20260709_105520_01 failed because of active session holding scope.

### [PREVENT] FluxOS V12.0: Production Burn-in and Autonomous Company Certification (2026-07-09)
CEO OS had never been tested as a full autonomous company operating system. No burn-in with real projects had been performed. Operational gaps (lock visibility, resume UX, queue bloat) needed to be verified through actual production use.

### [PREVENT] 분석 전용 태스크의 PlanFlow 전체 잠금 방지 (2026-07-10)
코드 수정 금지 분석 태스크가 Debug high-risk로 라우팅되고 플래너 폴백이 구현 패킷을 생성해 coding 상태와 전체 프로젝트 잠금을 유지했다. 활성 세션과 소스 변경이 없는 분석 전용 태스크는 구현 단계나 파일 잠금을 획득하면 안 된다.

### [PREVENT] Gateway gh/supabase 강제는 python -c·개발도구 경유 우회를 정적스캔으로 막지 않기로 확정 (2026-07-11)
GATEWAY_ENFORCED_COMMANDS(gh/supabase raw 차단)는 api_runner.py run_safe_command 분기에서 변형(대소문자/확장자/절대경로)까지 정규화해 완전 차단하지만, python/python3/dart는 ALLOWED_COMMANDS의 정당한 개발도구라 그대로 passthrough된다(test_gateway_enforcement.py GeneralShellUnaffectedTest가 이를 의도된 설계로 명시 검증). 이 passthrough를 악용하면 python -c "import subprocess; subprocess.run(['gh', ...])" 형태로 게이트를 우회한 gh/supabase 직접실행이 가능하다. 검토 결과 이 경로를 substring 정적스캔으로 막지 않기로 결정했다: python -c는 본질적으로 완전 RCE라 gh/subprocess 문자열 스캔은 난독화(동적 import, base64, os.system) 한 줄로 뚫리며, 방어력 없이 '막힌 척'하는 死게이트만 추가하는 것이라 반복 경고된 fail-open 거짓확신 안티패턴을 재생산한다. Gateway의 실질 목적은 협조적 모델의 audit trail+steering이지 작정한 adversary에 대한 하드 보안경계가 아니므로, 진짜 하드 격리가 필요해지면 python/dart를 whitelist에서 제거하거나 OS 샌드박스를 써야지 문자열 스캔으로는 안 된다. 별도로 Claude CLI 자율구현 경로(auto_follow._claude_cli_implementation)는 이미 핸드오프 프롬프트에 Tool Gateway 사용 지시가 주입돼 있고 test_tool_gateway_wiring.py가 소스레벨로 가드해 처리 완료 상태였다.

### [PREVENT] adb monkey 실행이 시스템 자동회전을 전역 해제(thawRotation) (2026-07-12)
adb shell monkey는 실행 시 WindowManager thawRotation을 호출해 accelerometer_rotation=1을 시스템 권한(package:android)으로 강제 기록, 사용자의 세로고정이 풀린다. S23/태블릿 실측 재현(am start=유지, monkey=즉시풀림), 앱 무관(삼성인터넷도 동일 재현). 설치 후 앱 실행은 반드시 am start(-W -n pkg/activity, 실패시 cmd package resolve-activity --brief로 동적 확인 후 재시도)를 사용하고 monkey는 금지. 2026-07-03 기존 방지책의 configChanges orientation 원인 지목은 오진이었음

### [PREVENT] NexusFlow 세션: prevention hook이 타 세션 사전 dirty 파일을 내 변경으로 오인 (2026-07-12)
prevention_stop_hook.py가 세션 diff가 아니라 현재 git status 전체를 스캔해, 세션 시작 전부터 이미 dirty였던 다른 세션의 미커밋 변경(lib/screens/* 등 18개 파일)까지 내가 만든 변경으로 잘못 판단함. 이번 세션은 nexusflow_pipeline.dart 1줄 import 제거만 시도했으나 ownership gate에 막혀 실제 반영은 0건(git diff 빈 결과로 확인).

### [PREVENT] MarketingFlow Publishing Layer fail-closed 게이트 (2026-07-12)
SNS 반복게시 계층 신설 시 미승인/PII/미검수자산/토큰없음 콘텐츠가 실게시로 새어나갈 위험. 다층 fail-closed(승인+approve+confirm-network 3중 잠금, PII/placeholder 스캔, 자산존재검증, 중복ledger)로 차단하고 회귀테스트 16건으로 고정.

### [PREVENT] CEO OS 정체 복구와 폴링 계약 (2026-07-12)
자동 재시작 제외 플래그와 행 세션 구형 락이 복구 판정을 막고, 중복 폴링과 정체 카드 액션이 실제 서버 상태 계약과 분리되어 있었다. 회귀 테스트로 복구·락 회수·UI 액션 계약을 고정했다.

### [PREVENT] 무인 정리 자동화 안전 게이트 (2026-07-12)
전 레포 tick과 FluxOS ownership 매핑을 fail-closed로 연결하고 회귀 테스트로 고정했다

### [PREVENT] publish.mjs 상태판정이 이번실행분 아닌 전체 publish_results 누적이력으로 FAILED 오판 (2026-07-12)
실제 YouTube 비공개 테스트 업로드가 성공(status=ok, video_id 발급, API 재조회로 private 확인)했음에도 packet_state가 FAILED로 표시됨. 원인은 상태마감 로직이 packet.publish_results.filter(mode==live) 전체(과거 blocked 시도 4,5번 포함)를 판정 대상으로 삼아 allOk가 false가 된 것 — 정상 성공(6번)이 과거 실패 이력에 가려짐. 첫 실행이 아니면(재시도·재승인 흐름에서) 항상 재발 가능한 구조적 결함. 수정: 루프 시작 전 publish_results.length를 저장해 이번 실행분만 slice해서 판정. 회귀: 같은 패킷 재실행(ledger skip) 시 PUBLISHED로 정상 판정되는지 실측 검증.

### [PREVENT] Meta(Instagram/Threads) 토큰 갱신은 Google과 다른 모델 — refresh_token 없이 장기토큰 자체를 refresh (2026-07-12)
Google OAuth는 access_token(단기)+refresh_token(장기, 별도 값)을 발급해 refresh_token으로 새 access_token을 계속 재발급받는 구조. Meta(Instagram Business Login/Threads)는 이 구조가 아니라 short-lived token을 GET 요청으로 long-lived token(~60일)으로 1회 교환한 뒤, 만료 전(발급 24h 경과 시점부터) 그 long-lived token 자체를 refresh 엔드포인트에 넘겨 새 long-lived token으로 갱신하는 방식이다(refresh_token이라는 별도 값이 없음). google-oauth.mjs 패턴을 그대로 복붙하면 존재하지 않는 refresh_token 필드를 찾다가 항상 NEEDS_REAUTH로 빠지는 버그가 생긴다. meta-oauth.mjs를 Google과 별도 모듈로 분리하고 REFRESH_WINDOW_MS(만료 7일전)로 자체 판정하도록 구현, 테스트 5건(만료前재사용/만료임박자동갱신/이미만료NEEDS_REAUTH/파일없음/refresh API실패)으로 고정.

### [PREVENT] Meta Instagram Business Login http 127.0.0.1 루프백 거부 (2026-07-12)
Google/YouTube OAuth 데스크톱 클라이언트는 http 127.0.0.1 루프백 허용하나 Meta Instagram Business Login 콘솔 실측 결과 http/localhost 둘다 거부, https 127.0.0.1만 허용. meta-oauth-connect.mjs가 google-oauth 패턴 따라 http 서버였음. 대응: local-https.mjs 신규, openssl로 self-signed 인증서 생성 캐싱, node:https 전환. 실제 HTTPS 리스닝응답 실측검증.

### [PREVENT] FinFlow resolved activity launch fallback (2026-07-13)
Hard-coded MainActivity launch can fail when the installed package exposes a different launcher activity; monkey fallback has unsafe device-wide side effects.

### [PREVENT] 음성 일정 수정이 새 일정 생성으로 떨어지는 회귀 방지 (2026-07-13)
일정 제목에 시간과 회의 같은 생성 단서가 포함되면 strongScheduleAdd가 수정 동사보다 먼저 평가됐고, STT로 이름 일부가 누락된 수정 발화는 제목 대상 매칭이 없어 생성 폴백으로 이어졌다. 수정 동사를 생성 단서보다 우선하고, 수정 명령에서만 제목 또는 참석자 토큰 두 개 이상이 단일 일정에 일치할 때 기존 일정 편집 초안으로 연결한다.

### [PREVENT] ffmpeg subtitles+apad filter_complex ENOSPC 큐 오버플로우 (2026-07-14)
libavfilter 필터그래프에서 느린 subtitles(libass) 비디오 체인과 apad로 무한 패딩되는 오디오 체인을 같은 filter_complex 안에 함께 두면 두 체인 간 프레임 스레드 메시지 큐가 넘쳐 AVERROR(ENOSPC)='No space left on device'로 오표시되며 인코딩이 특정 프레임에서 중단됨(실제 디스크 용량과 무관, E: 383GB/C: 123GB 여유 확인함). 자막 번인과 오디오 딜레이+패딩을 한 filter_complex에 절대 같이 넣지 말고, 1) subtitles만 있는 비디오 전용 패스로 먼저 번인 후 2) -c:v copy로 오디오만 별도 filter_complex(mux)하는 2단계로 분리해야 재발하지 않음. 부수적으로 정지 프레임(freeze-frame) 세그먼트를 jpg에서 만들 때 -pix_fmt yuv420p를 명시하지 않으면 libx264가 yuvj420p(full-range)로 인코딩해 인접 세그먼트와 색공간이 어긋나는 것도 같은 세션에서 발견(별도 원인이나 같은 파이프라인에서 중첩 재발).

### [PREVENT] status.showUntrackedFiles=no로 소스·회귀테스트 158개가 미추적 방치 (2026-07-14)
루트 .git/config에 status.showUntrackedFiles=no가 설정돼 신규 파일이 git status에 전혀 표시되지 않았다. 그 결과 S02~S07의 코어 프로덕션 모듈 7개(execution_lifecycle/process_ownership/merge_queue/lifecycle_adapters/task_finalizer 등)와 회귀 테스트 20개(총 303개 test 함수)가 한 번도 커밋되지 않은 채 워크트리에만 존재했다. 자동 salvage도 추적 파일만 커밋하므로 이들을 건지지 못했고, 워크트리 정리 시 방지책(회귀 테스트)이 통째로 유실될 상태였다. 또한 .fluxos/.gitignore에 runtime/ 규칙이 없어 런타임 산출물 130개가 같은 untracked 더미에 섞여 소스를 가렸다. 방지: 신규 파일을 만든 작업은 커밋 전 반드시 git status --untracked-files=all로 확인하고, 런타임 산출물은 gitignore에 등록해 소스가 묻히지 않게 한다.

### [PREVENT] ValueFlow 로컬 dart-defines.json이 다른 프로젝트(PlanFlow) Supabase URL로 stale (2026-07-14)
scripts/valueflow-dart-defines.json은 sync-dart-defines.ps1이 .env 기준으로 자동생성하는 파생 산출물인데, 실제로는 .env에 SUPABASE_URL이 없어(PDMV_URL만 있음, 정상 폴백 대상) 스크립트가 재실행됐다면 pdmvgpgmchdptyzusyea로 정상 생성됐어야 함에도 파일 안에는 xqvvfnvmytjlblcngipn(PlanFlow 프로젝트 ref)이 박혀 있었다. 즉 과거 어느 시점에 이 파일이 수동 편집되었거나 다른 프로젝트 컨텍스트에서 잘못 복사돼 저장된 뒤, 이후 아무도 sync 스크립트를 재실행하지 않아 .env가 갱신돼도 파생 산출물만 계속 stale 상태로 남아있었다. Sprint 14-2 S23 릴리즈 빌드 직전에 발견 — 발견 못 했으면 빌드된 APK가 전혀 다른 Supabase 프로젝트를 바라봐 모든 검색·DS 기능이 조용히 실패했을 것(에러 없이 그냥 다른 프로젝트의 빈 데이터/404). 교훈: '.env가 단일 소스, json은 파생물'이라는 스크립트 주석의 원칙이 있어도 실제로 최신 상태인지는 검증하지 않으면 신뢰할 수 없다. 배포/빌드 직전에는 파생 config 파일이 실제로 최신 .env에서 재생성된 것인지(sync 스크립트 재실행 또는 최소 프로젝트 ref 문자열 대조) 확인하는 습관이 필요하다 — 특히 여러 Supabase 프로젝트(FinFlow/ValueFlow 공유 pdmv, PlanFlow xqvv 등)를 오가는 이 환경에서는 프로젝트 ref 혼동이 조용한 실패로 이어지기 쉽다.

### [PREVENT] seed_audio voice_id 지정이 영어 억양까지 클론 + 과한 lowpass/aecho가 음질 파괴 (2026-07-14)
MarketingFlow 광고 VO 제작에서 한국어 대사에 seed_audio를 쓰며 voice_id(영어권 프리셋 'Roman')를 지정했더니 응답에 voice_as_reference=true가 붙어 그 영어 음성 샘플을 레퍼런스로 클론했다. 그 결과 목소리 톤뿐 아니라 '영어 억양'까지 복제돼 한국어가 외국인 발음('회의'가 '웨이릿')으로 나왔다. voice_id를 아예 생략하면 모델이 해당 언어의 네이티브 음성으로 합성하므로 발음이 정상이다. 규칙: 비영어(특히 한국어) TTS를 seed_audio로 만들 때 영어권 프리셋 voice_id를 넘기지 말 것 — 목소리 지정이 곧 억양 클론이다. 성별/톤이 필요하면 pitch_rate 강제 조정 대신 해당 언어 네이티브 화자 샘플로 클론하거나 실제 사람 녹음을 쓴다(pitch_rate -12 같은 강제 시프트는 포먼트가 깨져 '뭉개진' 소리가 남). 별개의 동반 실수: '멀리서 말하는 느낌'을 낸다고 lowpass=5200+aecho를 걸었더니 고음이 전부 깎여 '마이크 물먹은 소리'가 됐고, speech_rate를 0으로 방치해 발화가 늘어졌다(3.4s). 원거리감은 과한 lowpass가 아니라 볼륨/약한 EQ로 최소 처리하고, TTS 속도는 speech_rate로 명시 조정한다(20 적용 시 1.92s로 정상화).

### [PREVENT] Korean male VO via video-model audio extraction not TTS (2026-07-14)
TTS path could not produce a natural Korean male voice: English preset voice_id clones the English accent via voice_as_reference; omitting voice_id yields native Korean but female-only default; forced pitch_rate shift breaks formants; no Korean male voice installed on the system; the inworld engine with Korean male voices is game-pipeline-only. Solution: generate a short clip with seedance_2_0 generate_audio=true showing a Korean male manager speaking the line, then extract only the audio track. The model makes the character speak the language natively so intonation is real acting, not TTS. Use mode=fast, 480p, minimum duration since video quality is discarded (6 credits). Clean the extracted audio with afftdn and compress inter-phrase gaps only; never apply heavy lowpass or aecho (causes muffled underwater sound).

### [PREVENT] CEO OS 안전정리: dead code 제거+terminal 판정 단일화 (2026-07-15)
CEO OS에 호출자 0인 죽은 라우트/함수(dead code)와 task_queue.is_terminal을 안 쓰고 로컬에서 재정의한 하드코딩 terminal set이 누적됨. 로컬 terminal set 재정의는 멤버 드리프트로 stranded-DONE 오판을 유발할 수 있어 단일 소스(pipeline/task_queue.is_terminal)로 통일해야 한다.

### [PREVENT] adb-single-device mDNS 실패 시 저장 endpoint 직접 connect 폴백 (2026-07-15)
adb-single-device.ps1이 S23 무선디버깅 자동연결을 mDNS 브로드캐스트에만 의존했는데, PC가 유선(이더넷)·폰이 Wi-Fi로 서브넷 경계를 넘거나 Tailscale이 멀티캐스트를 간섭하면 adb mdns services가 비어 자동탐색이 실패한다(실측: ADB_MDNS_AUTO_CONNECT=1·방화벽 adb.exe Allow·Openscreen 데몬 정상인데도 discovery 0건, Bonjour 백엔드는 미설치라 교체 불가). 그 결과 무선디버깅을 켜도 기기가 안 잡혀 설치가 막혔다. 수정: 래퍼에 폴백 추가 — mDNS 창 이후 타겟 S23 serial이 안 잡혔고 roster 슬롯에 last_endpoint(IP:포트)가 있으면 adb connect로 직접 연결하고, 타겟이 IP:포트로 연결될 때마다 현재 endpoint를 roster에 재저장해 다음 폴백이 항상 최신값을 쓰게 한다(기존 device_key 영속 선례와 동일 패턴). 실작동 검증: S23 강제 disconnect 후 래퍼 실행 시 저장 endpoint로 자동 재연결 성공. 무선디버깅 토글로 포트가 바뀌면 그 세션에서 mDNS나 최초 1회 연결로 endpoint가 갱신돼 이후 폴백이 유효.

### [PREVENT] 검증용 until 무한루프를 백그라운드에 걸고 117분 방치 — 2배 초과 자가점검 규칙 50회+ 재발 (2026-07-16)
행동 규칙(2배 초과 시 재점검)이 반복 교육에도 재발하는 구조적 원인 2개 확정: (1) 백그라운드 Bash는 timeout 파라미터가 강제되지 않아(실측: 240000ms 지정, 117분 생존) 2배 알람을 timeout에 위임하면 알람이 안 울림. (2) until 성공조건 대기 루프는 실패(잘못된 파일 수정으로 조건 영원히 거짓)에 무한 침묵 — 완료/실패 알림 모두 없어 턴 종료 후 재호출 불가. 동반 원인: 수정 대상이 실제 서빙 경로인지 호출자 역추적 생략(api.py 미사용 사본 수정). 방지: 예상 5분 이하 검증은 백그라운드 금지(포그라운드 단발), until 검증 루프 전면 금지, 대기 필요 시 timeout 강제되는 Monitor 도구 사용, 수정 전 호출자 grep 의무

### [PREVENT] 2N 시간예산 점검은 문의 우선(직접조사는 무응답 시만) + E:FluxStudio 전역 적용 (2026-07-16)
CEO 확정(2026-07-16): 백그라운드 작업 2배 초과 점검 시 무조건 무거운 직접 조사부터 하지 말고 작업 본인에게 먼저 문의한다(진행 중인가/결과 있나/문제 있나/어떤 문제냐 — 채널: 서브에이전트 SendMessage, FluxOS task progress·request-status·liveness·stage_events, 명령 로그 tail). 자기보고가 불가능한 상태일 때만 직접 조사 에스컬레이션. 이 프로토콜(예상시간 선언+2N 알람+문의 우선)은 세션 한정이 아니라 E:FluxStudio 안의 모든 백그라운드·장시간 작업 단위에 기계 장치로 적용한다.

**(2026-07-17 CEO 개정 — 점검 시점을 2N에서 1N으로 당김)** 2N까지 아무것도 안 하고 기다리면 실패를 최대 2N 동안 방치하게 된다(N=30분이면 1시간 침묵). 개정: **1N에 1차 점검(문의)**를 한다 → 정상 진행 근거가 있으면 2N까지 계속 대기, **문제 신호가 있으면 즉시 조치**(2N 기다리지 않음). 2N은 상한선으로 유지(2N 초과 시 "살아있음"으로 넘어가지 말고 설계 결함 의심·근본원인 해결). 기계 장치: 백그라운드 발사 시 알람을 `Monitor(timeout_ms=N)`으로 걸고, 1N 점검이 정상이면 남은 N만큼 재장착한다.

### [PREVENT] GT Override가 QA 규칙·LLM 검토 REWORK 합의를 뒤집어 무산출 구현을 REVIEW_PASS로 둔갑(허위 DONE) (2026-07-16)
glm_org QA에서 W01 FAILED(파일 0개 작성)+규칙기반 REWORK+LLM검토 REWORK인데 GT Verdict GT_WARN(score 60)의 GT Override=True가 최종 판정을 REVIEW_PASS로 뒤집었고, 이후 최종 검토자(minimax)도 실코드 검증 없이 done.md 서술만 보고 PASS — 산출물 0인 task가 done terminal로 종결(TASK_20260716_155807 실증). 안티패턴 'or PASS fail-open 금지'의 변종: override는 상향(REWORK→PASS) 방향으로 작동하면 안 되고 하향(PASS→REWORK) 안전 방향만 허용해야 함. 후속 수정 대상: glm_org QA의 GT override 로직을 방향 제한(fail-closed)으로 교정 + 최종 검토 프롬프트에 '파일 변경 실존 확인 필수' 강제

### [PREVENT] ESTsoft TMPDIR 리다이렉트 — 임시파일이 인덱싱·백신검사 위치에 쌓여 업데이트 후 인덱서 폭주 (2026-07-16)
느려짐이 방지책(알약 예외) 후에도 재발한 3중 원인. (1) 알약 예외가 Windows 업데이트(빌드 8737→8875)+재부팅 후 소실돼 프로세스 실행이 다시 2~30초(정상 130ms). (2) ESTsoft(알약)가 User 환경변수 TMPDIR을 C:\Users\Public\Documents\ESTsoft\CreatorTemp로 영속 설정 — python tempfile은 TMPDIR을 TEMP보다 우선하므로 모든 python/pytest 임시파일이 그 위치에 생성됐다. 그 위치는 Public Documents라 Windows 검색 인덱싱 대상+백신 검사 대상이라는 최악의 조합. (3) 대량 pytest 실행이 임시 git repo 3,294개를 거기 축적했고, Windows 업데이트가 인덱스 리빌드를 트리거하자 SearchIndexer가 그 수천 repo를 크롤하며 CPU 100% 지속. 부차로 claude.exe 20개+/5~6GB 누적이 얹힘. 조치: TMPDIR User env 제거(python 임시 정상화 실측), 24시간 이전 잔재 1,871개 삭제(2,848→977, 인덱서 100%→0.8% 실측), perf-canary 상시 감시 등록(10분 주기: git 실행비용>1s=백신예외 풀림/TMPDIR 재오염/인덱서 폭주/claude 10GB+를 텔레그램 경보). 방지 원칙: (a) 느려짐 진단 시 파일 I/O(stat 루프)와 프로세스 실행(git --version) 비용을 분리 측정하라 — I/O 정상+실행만 느리면 백신/커널콜백, 인덱서 CPU 확인. (b) python 임시 경로는 TEMP만 보지 말고 tempfile.gettempdir() 실측으로 확인하라 — TMPDIR이 우선하며 서드파티가 박아둘 수 있다. (c) 재부팅/OS 업데이트 후에는 백신 예외·환경변수가 유지되는지 재검증하라 — 카나리아가 자동화함. (d) 방지책은 '한 번 조치'가 아니라 '풀림을 감지하는 감시'까지 포함해야 강력하다.

### [PREVENT] 미묘한 git 절차(hunk 분리)를 Haiku에 배정해 타 세션 hunk가 내 커밋에 흡수됨 — 라우팅 오판 (2026-07-17)
2026-07-17 실사례. stale 문서 정정 작업을 '텍스트 1곳 수정 + 스크립트 실행'으로 보고 Haiku에 배정했다. 지시문에는 'anti-patterns.md는 이미 dirty이니 git diff로 타 세션 hunk를 확인하고, 있으면 git apply --cached로 내 hunk만 분리해 pathspec 없이 커밋하라'고 명시했다. 그런데 워커는 'pathspec 커밋으로는 같은 파일 안의 다른 hunk를 보호할 수 없다'까지는 정확히 판단하고 거기서 멈춰, 타 세션이 추가한 방지책 10개(~100줄)를 자기 커밋(0a6a672)에 함께 넣었다. 실측: 107줄 추가 중 내 정정은 2줄. 데이터 유실은 0(타 세션 작업 보존됨), attribution만 오염. history 수정(rebase/amend)은 타 세션이 그 커밋 위에서 작업 중일 수 있어 더 위험하므로 되돌리지 않고 기록으로 남김. 근본: 작업을 '표면 난이도'(텍스트 1곳 = 단순)로 분류했는데 실제 난이도는 '동시편집 환경에서 hunk 단위 격리'라는 절차적 판단에 있었다. 그 판단은 (a)pathspec이 파일 단위지 hunk 단위가 아님을 이해하고 (b)그 한계에 부딪혔을 때 patch 분리로 전환하는 2단계 추론이 필요한데, 지시문에 절차를 써주는 것만으로는 경량 모델이 그 전환을 수행하지 못했다. 방지: 작업 난이도는 '수정할 코드의 양'이 아니라 '요구되는 판단의 종류'로 분류한다. 특히 (1)동시편집 파일(dirty 상태)을 다루거나 (2)git 이력·인덱스를 조작하거나 (3)fail-open/fail-closed 방향을 판정하거나 (4)'A가 안 되면 B로 전환'하는 조건부 절차가 들어가면, 코드가 1줄이어도 Sonnet 이상으로 배정한다. 오케스트레이터 체크리스트: 워커 배정 전 '이 작업에 조건부 분기나 실패 시 대체경로가 있는가?'를 자문하고, 있으면 경량 모델 금지. 부수 규칙: 이미 dirty인 파일을 수정하는 작업은 배정 시점에 그 사실을 난이도 산정에 반영한다(clean 파일 수정과 같은 난이도가 아니다).

### [PREVENT] 워크트리가 supervisor/pipeline/scheduler 데몬 셋 전체를 복제해 메인과 동시 tick(구코드로 큐·락 경쟁) (2026-07-17)
task worktree(E:/FluxStudio-worktrees/fluxos/fluxos-task-20260717-002400)에서 데몬 3종(supervisor 412360/pipeline-daemon 412480/scheduler-daemon 399836)이 09:54에 기동돼 메인 체크아웃 데몬과 동시 실행. 부모 프로세스는 전부 죽어 고아 상태였고, 워크트리 체크아웃 코드라 메인의 최신 수정(1N 시간예산 점검)이 반영 안 된 구 convergence로 tick. PID 파일은 메인 것만 등록해 중복이 가시화되지 않음 — 기존 dedupe(5560a41 계열)가 이 경로를 못 잡음

### [PREVENT] 1N/2N 알람만 걸고 주기 진행 이벤트를 안 걸어 22분간 이상신호(CPU 5%·7%) 방치 — 침묵을 정상으로 착각 (2026-07-17)
예상시간 N 선언과 Monitor(timeout_ms=N) 알람 장착은 규칙대로 했는데도 CEO가 22분 시점에 먼저 물어봄(=실패). 뚫린 지점은 알람이 아니라 Monitor grep 필터: 최종 요약줄('=+ passed/failed =+')에만 걸어서 그 사이 이벤트가 0건이었고, 그 침묵을 정상 진행으로 착각했다. 실제로는 CPU 5%(22분간 71초)+진행률 7%(이 속도면 총 5시간)라는 이상신호가 로그에 이미 있었고 5분 시점에 계산 가능했다. 근본: 1N/2N 알람은 상한 감시일 뿐이며 그 사이 이상신호는 주기 진행 이벤트로만 보인다 — 알람 하나만 걸면 N분 내내 아무것도 안 보게 된다(Monitor 규약의 silence is not success를 필터 설계에 미적용). 방지: 백그라운드 발사는 3겹(본작업+주기 진행 이벤트+1N 알람), 진행 이벤트마다 잔여시간 재계산(현재 X%/경과 T → 총 T/X*100분이 선언 N의 2배 궤도면 알람 안 기다리고 즉시 조치), CPU 5% 근처는 계산 아니라 I/O·락 대기 = 설계/환경 결함 신호.


# PlanFlow

## 경로
E:\FluxStudio\planflow

## 현재 상태
- Stage: 아키텍처 확정, 구현 시작 단계

## 기술스택
- Framework: Flutter (Android-first)
- Backend: Supabase (PostgreSQL + Auth)
- AI: GPT-4o-mini
- STT: on-device (onDevice: true - 음성 절대 서버 전송 금지)
- TTS: flutter_tts

## DB 스키마
users, events, pre_actions, reminders, voice_logs,
location_history, user_settings, early_bird_emails

## 핵심 기능 (1차 배포)
- 음성 입력 -> AI 파싱 -> 확인 UI -> 저장 -> 알림
- 아침/저녁 브리핑
- 역산 알림 (pre-action reverse-calculation)
- 이동 시간 버퍼
- Google/Naver 캘린더 양방향 동기화
- 시스템 알람, 홈 위젯 (마이크 버튼)

## 핵심 기능 (2차 배포)
- KakaoTalk/SMS 일정 감지 (Notification Listener API)
- 통화 내용 일정 감지 (로컬 call-to-text)
- 위 기능: 명시적 온보딩 동의 + 개별 권한 토글 필수

## AI 작업 시 절대 금지
- onDevice: false 설정 (음성 서버 전송 절대 금지)
- 2차 배포 기능을 1차에 포함
- 유료화 코드를 1차 배포에 추가 (1차는 전체 무료)
- iOS 빌드 관련 코드

## AGENTS (Project)
- Flutter 명령은 가능하면 `scripts/flutter-local.ps1`를 통해 실행한다.
- `C:\PlanFlow`를 작업 루트로 두고, `E:\Project\PlanFlow`는 읽기 전용 참고 자료로만 본다.
- `supabase/schema.sql`이 스키마 기준이며, DB schema/migration/RLS 변경 전에는 사용자 확인을 받는다.
- `G:\AI-automatic-expense-tracker`는 수정하지 않는 참고 저장소다.
- 1차 출시 범위에는 billing, ads, reward ads, Kakao/SMS/call detection, TEAM/BUSINESS 기능을 넣지 않는다.
- Naver Calendar는 1차 기능으로 유지하고, OAuth consent/token/export 흐름은 검증 가능해야 한다.
- 완료 전에는 analyze, test, Android build 또는 run check, 가능한 경우 실제 실행 확인을 거친다.
- 완료 시 커밋과 푸시까지 마친다.


<!-- [WIKI:END] -->

# AGENTS.md for `C:\PlanFlow`

This file is the top-priority working rule for this repo.
Secondary detail sources: `CLAUDE.md` and `docs/agent-rules-*.md`.

## Default language
- Always respond in Korean.

## Default operating order
1. If a request has 2 or more issues, or spans multiple subsystems, plan first with the strongest planner available.
2. Use the plan to execute with worker agents, preferably in parallel when file scopes do not overlap.
3. Always run a separate review/verifier pass after implementation.
4. If review finds anything incomplete or risky, fix it and review again.
5. Only report completion when nothing is left to change.

## Model routing
- Default behavior: route work by task complexity automatically, even if the user names a model.
- Planner/Main for non-trivial work: `gpt-5.5`.
- Worker agents for simple implementation, code edits, and test updates: `gpt-5.3-codex-spark`.
- Slightly harder implementation, complex refactors, architecture changes, or hard bugs: `gpt-5.4-mini`.
- Review / verification: `gpt-5.4-mini`.
- If `gpt-5.3-codex-spark` is at capacity or the exact model cannot be selected in the current environment, keep the same role split and use `gpt-5.4-mini` as the fallback for implementation / review.
## Workflow rules
- Mandatory enforcement: for multi-issue or high-risk work, do not report completion unless context hygiene, role/model routing, worker delegation, reviewer verification, fix-after-review loop, tests/build, checkpoint, commit, push, and device run check have all been attempted and explicitly reported.
- Model routing is not advisory. Use `gpt-5.5` for planning, `gpt-5.3-codex-spark` for simple execution, and `gpt-5.4-mini` for review plus harder execution / fallback cases.
- When the user says "AGENTS.md대로" or asks for subagents/reviewer, treat worker and reviewer agents as required. If a tool/runtime limit blocks spawning, close completed agents and retry; if still blocked, report the blocker and continue with the closest safe fallback.
- Every task must begin with context hygiene: check `.planning/STATE.md`, check `.planning/context/ACTIVE_SUMMARY.md`, and run `node scripts/gsd-context-hygiene.mjs` when it exists. If the script is missing, explicitly record that it is missing and continue.
- Every completed task/logical change must end with verification, a planning-context checkpoint, a Git commit, and a push to the remote repository.
- Every completed task/logical change must also end with a fresh build and, when the target device is available, a real run/launch check before reporting completion.
- For any Flutter run/build/test command in this repo, prefer `scripts/flutter-local.ps1` so `env/local.json` and the local `--dart-define` set are injected automatically. Do not fall back to raw `flutter` unless the wrapper is missing or the user explicitly asks.
- **APK 빌드는 반드시 `--release`만 사용한다.** `flutter build apk --debug` 또는 `flutter build apk` (mode 미지정) 절대 금지. 디버그 키스토어와 릴리즈 키스토어 서명이 달라 OS가 앱 데이터를 삭제하므로 사용자 세션이 소실된다. 올바른 명령: `scripts\flutter-local.ps1 build apk --release`
- Before starting work, check `.planning/STATE.md` and `.planning/context/ACTIVE_SUMMARY.md`.
- Run `node scripts/gsd-context-hygiene.mjs` at session start, before long work, and before final report. If the script is missing, record that and continue.
- After every completed logical change, update `.planning/context/ACTIVE_SUMMARY.md` with a short checkpoint.
- After every completed logical change, commit and push to the remote repository.
- Do not leave unused helper terminals or sessions open; close them when they are no longer needed.
- Do not commit unrelated or user-created untracked files unless explicitly requested.
- Prefer existing code, shared helpers, and existing docs before creating new structures.
- Create new code only when reuse is clearly worse.
- Do not delete unused code until implementation and verification are fully complete.
- ADB package-destructive commands (`adb uninstall`, `pm uninstall`, `pm clear`, broad app cleanup scripts) must target only this repo's package `com.fluxstudio.planflow`. Never target FinFlow or other app package names from this workspace while working in PlanFlow, and never use wildcard/broad package deletion.
- For complex work, split into independent subagent tasks and run them in parallel when safe.
- When code changes are needed, prefer worker agents for implementation and a separate reviewer for verification.
- Completed worker/reviewer agents must be closed unless there is a specific reuse plan.
- Keep direct edits narrow; use them only for trivial fixes or repo settings/doc updates.
- If a request has 2 or more issues, the plan-review-implement-review loop is mandatory by default.
- Do not ask for permission between intermediate steps in the same batch unless a real decision is blocked.
- Answer all user questions that appear in the same request, even if they are separate from the code task.
- Do not modify tests unless the task explicitly asks for test changes or the implementation requires test updates.
- Keep the scope tight; do not add unrelated changes, and report known gaps instead.

## Repo-specific rules
- Work from `C:\PlanFlow` unless the user explicitly changes the working path.
- `E:\Project\PlanFlow` is a read-only reference source for files that previously worked, especially login and app flow.
- `G:\AI-automatic-expense-tracker` is reference-only and must not be modified.
- PlanFlow product scope is defined by `PlanFlow_Codex_Prompt_v3.md`.
- Supabase schema source of truth is `supabase/schema.sql`.
- Because of NexusFlow integration, stop and get explicit user confirmation before any DB schema, migration, or RLS change.
- Treat future Flow Core/shared-core files as cross-project contracts for NexusFlow and related apps. If `packages/`, `flow_core/`, shared domain models, shared repositories, shared parsing/routing services, or other Flow Core extraction targets are created or modified, stop first and get explicit user confirmation unless the user has directly requested that exact change.
- For 1st release, do not implement billing, ads, reward ads, Kakao/SMS/call detection, or TEAM/BUSINESS features.
- Naver Calendar is now a 1st-release working feature. Keep OAuth consent, token handling, and calendar export behavior visible and testable.
- Flutter/Android 코드 수정은 기본적으로 **코드 수정까지만** 수행한다.
- 배포 파이프라인(`analyze` -> related tests -> versionCode bump -> Play internal upload -> Telegram notification)은 사용자가 **명시적으로 배포를 요청했을 때만** 실행한다.
- 사용자가 `배포하지 마`, `SkipUpload`, `코드만 수정`이라고 말한 경우는 물론, 배포 요청이 없으면 항상 배포를 생략한다.
- When deploy automation runs, keep the final report format aligned to:
  - `[PlanFlow 배포 완료]`
  - `Version:`
  - `Analyze: PASS/FAIL`
  - `Tests: PASS/FAIL`
  - `Play Internal Upload: PASS/FAIL`
  - `Telegram: PASS/FAIL`
- Keep all user-facing UI text Korean unless a platform/provider brand requires otherwise.
- If Korean text appears broken/mojibake in terminal output, re-read the file or output explicitly as UTF-8 before interpreting or editing it. Do not make decisions from broken Korean text.
- Voice files must never be sent to external servers. Only STT text may be stored or sent for parsing.
- `speech_to_text` must use `SpeechListenOptions(onDevice: true)` for STT.
- If ADB screenshots or mirroring are black, ask the user to turn on the phone screen before visual verification.
- Keep the PlanFlow Home UI close to the compact card-based reference: clean Korean schedule cards, no large blank first viewport.

## Project structure

```text
lib/
├── core/                # env, routing, theme, constants, supabase_auth_options
├── data/
│   ├── models/          # event, pre_action, user_settings, calendar_connection, feedback_report, ...
│   └── repositories/    # Supabase CRUD repositories
├── features/
│   └── groups/          # V2 그룹 기능 (models, providers, repositories, screens, services, widgets)
├── providers/           # auth/settings state
├── screens/             # auth, briefing, calendar, event, home, location, onboarding, settings, splash, voice
├── services/            # STT, GPT, calendar sync, notification, widget, backup, Naver CalDAV, TTS, alarm
├── widgets/             # shared UI components
└── l10n/                # 한국어/영어 localization
android/                 # Android app, widget, manifest
supabase/                # schema.sql, migrations/ (18개), functions/ (3개 Edge Function)
```

## Deployment structure
- Android first for 1st release.
- Supabase: Auth, PostgreSQL, RLS, backup/restore RPC.
- Google Cloud: Google Calendar OAuth and Google Maps travel-time API.

## Detail references
- Workflow details: `docs/agent-rules-workflow.md`
- Validation details: `docs/agent-rules-validation.md`
- Operations details: `docs/agent-rules-operations.md`

## FluxOS 안전 게이트
- 루트 FluxOS 또는 다른 세션에서 내려온 작업이라도, 코드 수정 전 `python E:\FluxStudio\.fluxos\run.py preflight --project PlanFlow` 결과를 확인한다.
- 수정 예정 범위는 `python E:\FluxStudio\.fluxos\run.py claim PlanFlow "<file-glob>" --owner "<세션명>"`으로 잠그고, 완료/중단 시 `release <lock-id>`로 반납한다.
- 다른 세션 잠금, 동일 파일 dirty 상태, 실행 중인 빌드/테스트가 있으면 기존 세션 작업을 우선하고 대기한다.
- Gradle/Flutter build/test는 PlanFlow 안에서 동시에 하나만 실행한다.
- Gradle 설정, wrapper, generated/ephemeral 파일, `.dart_tool`, `.gradle`, `build`는 명시적 목적 없이 수정/삭제/커밋하지 않는다.
- API 키와 토큰은 명령줄, 로그, 보고에 원문 출력하지 않는다.

---

## AGENTS.md Changelog

### TASK_20260705_091341 — GLM Worker W01 현행화 (2026-07-05)
- **현재 상태 갱신**: "아키텍처 확정, 구현 시작 단계" -> v1.1.1+77, 1차 핵심 기능 구현 완료, V2 그룹 병합, Play Alpha 배포 중. 코드베이스 규모(176 Dart 파일), DB(24 테이블/18 마이그레이션/3 Edge Function), 최근 변경 이력 반영.
- **DB 스키마 갱신**: 8개 테이블 -> 24개 테이블 (V2 groups 인프라, 음성 교정, calendar_connections, feedback_reports, user_backups, admin_roles 등 추가).
- **Project structure 갱신**: features/groups(V2) 디렉터리, data/models+repositories 분리, l10n, supabase/migrations+functions 반영.
- **다음 작업 섹션 신규 추가**: 그룹 안정화, 배포 진행, 캘린더 동기화 개선, 성능 최적화, 2차 기능 검토.
- **규약 섹션 원문 보존**: FluxOS Pipeline Gate, 기본 원칙, 모델 라우팅, 작업 방식, Anti-Patterns, Workflow rules, Repo-specific rules 등 변경 없음.
