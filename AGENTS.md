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

# Codex Common Rules
<!-- 프로젝트 공통 Codex 작업 규칙 -->

## FluxOS Pipeline Gate
- FluxStudio 계열 프로젝트에서 사용자가 개발, 수정, 분석, 리뷰가 필요한 비단순 지시를 내리면 먼저 FluxOS 파이프라인을 사용한다.
- 표준 흐름은 `Claude Code 계획 -> GLM 구현 -> Claude Code 리뷰 -> CEO 보고`다(Codex는 폐지 대신 dormant 상태로 필요 시에만 활성화).
- 프로젝트 세션이 직접 코드를 수정해야 하는 경우에도 수정 전 `python E:\FluxStudio\.fluxos\run.py pipeline "<지시내용>" --project <Project> --source <session>` 또는 이미 생성된 task의 `pipeline-audit` 결과를 확인한다.
- 진행 확인은 `python E:\FluxStudio\.fluxos\run.py pipeline-audit [TASK_ID]`를 사용하고, 최소한 `Claude Code 계획` 단계가 생성됐는지 확인한 뒤 구현에 들어간다.
- Claude Code가 인증, 한도, 연결 문제로 실패하면 FluxOS의 Codex-only fallback을 사용하되, 최종 보고에 fallback 사유를 명시한다.
- 긴급 단순 수정으로 파이프라인을 생략한 경우에는 생략 사유, 변경 범위, 검증 결과를 최종 보고에 반드시 남긴다.
- 프로젝트 세션을 직접 열어야 하는 경우에도 먼저 `python E:\FluxStudio\.fluxos\run.py session start --project <Project> --source <session> --label "<세션명>" --cwd "<프로젝트경로>"` 또는 기존 세션에 `session attach`로 FluxOS 메타를 붙이고, 가능하면 `FLUXOS_SESSION_ID`, `FLUXOS_SESSION_PROJECT`, `FLUXOS_SESSION_TASK_ID`, `FLUXOS_SESSION_OWNER`, `FLUXOS_SESSION_SOURCE`, `FLUXOS_SESSION_LABEL`, `FLUXOS_SESSION_NOTE`, `FLUXOS_SESSION_CWD`를 함께 전달한다.

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

## 모델 라우팅과 병렬 처리 (⚠️ 비단순 작업 필수 워크플로우 — 예외 없이 준수)
> 사용자가 매번 지시하지 않아도, 개발·수정·리팩토링·분석·리뷰 등 **비단순 작업은 아래 순서를 기본값으로 반드시 따른다.** 모델 라우팅과 별도 리뷰어 단계를 생략하지 않는다.
>
> **필수 체크리스트 (7단계):**
> 1. **FluxOS 파이프라인 등록** — 위 "FluxOS Pipeline Gate"대로 `run.py pipeline` 등록(또는 pipeline-audit 확인) 후 진입.
> 2. **계획 = `Claude`(상위 모델).** 범위·영향파일·리스크·검증기준 먼저 제시.
> 3. **구현 = 난이도별 병렬 서브에이전트 위임.** 구현은 `GLM`을 주력으로 하며, 난이도에 맞는 서브에이전트로 위임한다. 파일 비중첩이면 동시 실행.
> 4. **별도 리뷰어(`Claude`)가 전체 diff를 리뷰** — 계약 정합·회귀·규약 위반 점검. (구현 워커와 다른 별도 세션)
> 5. 지적사항 **수정** → 6. **재리뷰** → 7. **검증(analyze/test/build)·보고**.
> 메인(오케스트레이터) 세션은 **직접 구현을 쏟지 말고** 계획·분배·검토·보고만 담당한다. 이 흐름을 지키지 않고 메인이 다 처리하거나 모델 라우팅/별도 리뷰어를 건너뛰면 규약 위반이다.
- 비단순 작업은 계획 -> 병렬 작업자 -> 별도 리뷰어 -> 수정 -> 재리뷰 순서로 진행한다.
- 계획 단계는 `Claude`를 우선한다.
- 일반 구현은 `GLM`을 주력으로 한다.
- 난도가 높은 구현과 리뷰어 검토는 `Claude`를 우선한다. Codex는 폐지 대신 dormant 상태로 필요 시에만 활성화한다.
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
- Android 빌드(`flutter build apk/appbundle`)는 직접 호출하지 말고 항상 `E:\AI_WIKI\scripts\flutter-build-guarded.ps1`를 경유한다. 모든 FluxStudio 프로젝트가 `GRADLE_USER_HOME=E:\.gradle`를 공유해 Gradle 데몬 레지스트리가 하나이므로, 동시 빌드 시 서로의 데몬에 stop 명령이 닿아 "Gradle build daemon has been stopped"로 빌드가 깨진다. 이 래퍼가 FluxOS 공유 자원 락 `android-build`를 claim해 한 번에 하나의 빌드만 돌리고, 점유 중이면 FIFO 큐로 대기 후 자동 승격되면 빌드하며, 종료 시 항상 release한다. 호출 예: `powershell -File E:\AI_WIKI\scripts\flutter-build-guarded.ps1 -ProjectPath <flutter_app 경로> -Project <프로젝트> -Owner <세션> -BuildArgs "apk --release"`.
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
- 30초 이상 변화가 없으면 프로세스 CPU/RAM, 하위 프로세스, 로그 tail, 네트워크 대기 여부를 확인한다.
- 같은 명령을 무작정 반복하지 않는다. 범위를 줄이거나 다른 검증 경로로 우회한다.
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
- **비단순 작업(개발·수정·리팩토링·분석·리뷰)은 예외 없이 "모델 라우팅과 병렬 처리" 필수 워크플로우를 따른다: FluxOS 파이프라인 등록 → 계획(상위 모델) → 난이도별 병렬 서브에이전트 위임(단순=경량, 난도 높음=중간) → 별도 리뷰어 → 수정 → 재리뷰 → 검증. 사용자가 매번 지시하지 않아도 이것이 기본값이며, 메인 세션이 직접 다 처리하거나 모델 라우팅/별도 리뷰어 단계를 생략하면 규약 위반이다.**
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

### [PREVENT] AI 운용 일정: 2026-07-24까지 Claude Code 전용, 7-25부터 GLM 파이프라인 (2026-06-26)
CEO 지시(2026-06-26): 200달러 Claude Code 무제한 기간이라 7/24까지 모든 작업을 Claude Code로만(GLM/API 비용 차단), 7/25부터 파이프라인(Claude 계획→GLM 구현→Claude 검토). 규칙: 사용자가 'GLM 사용' 명시(FLUXOS_IMPLEMENTER=glm) 전까지, 그리고 2026-07-25 전까지 모든 AI 세션은 GLM 디스패치 금지하고 Claude Code로 직접 수행한다. utils/ai_schedule.claude_only_period()가 단일 소스. plan_gate.mode()는 그 기간 off(편집 자유), ai_fallback_router는 GLM 제외. 7/25 자동 전환.

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


# PlanFlow

## 경로
E:\FluxStudio\planflow

## 현재 상태
- Stage: 1차 핵심 기능 구현 완료, V2 그룹 기능 병합 완료, Play Alpha 배포 중
- 버전: 1.1.1+77 (2026-07-05)
- 코드베이스 규모: 176개 Dart 파일 (services 57, screens 26, features/groups 46)
- 1차 구현 완료: 음성 입력 -> AI 파싱 -> 확인 UI -> 저장 -> 알림, 아침/저녁 브리핑, 역산 알림(pre-action), 이동 시간 버퍼, Google/Naver 캘린더 양방향 동기화, 시스템 알람, 홈 위젯(마이크 버튼)
- V2 그룹 기능 구현: 그룹 생성/초대/멤버 관리, 그룹 일정 공유-연동, 그룹 이벤트 코멘트, 초대 링크, 역할 위임(leader/member), 그룹 나가기, 그룹 캘린더 오버레이
- DB: 24개 테이블 (V2 groups 인프라 포함), 18개 마이그레이션, 3개 Edge Function (naver-geocode, naver-userinfo-proxy, openai-proxy)
- 최근 변경(2026-07-05): PlanFlow-v2(feature/team-v2-planning) 병합으로 그룹 기능 완전 통합, 앱 정체 단일화, 로그인 회귀 복원

## 다음 작업
- 그룹(V2) 기능 엣지 케이스 안정화 및 크래시 모니터링 강화
- 1차 배포 Play Alpha -> Internal -> 프로덕션 진행
- Naver/Google 캘린더 동기화 안정성 및 예외 처리 개선
- 성능 최적화 (홈 화면 로딩, 이벤트 프리패치, 배터리 소모)
- 2차 배포 기능(KakaoTalk/SMS/통화 일정 감지) 검토-설계

## 기술스택
- Framework: Flutter (Android-first)
- Backend: Supabase (PostgreSQL + Auth)
- AI: GPT-4o-mini
- STT: on-device (onDevice: true - 음성 절대 서버 전송 금지)
- TTS: flutter_tts

## DB 스키마
- 코어: users, events, pre_actions, reminders, voice_logs, location_history, user_settings, calendar_connections
- V2 그룹: groups, group_members, group_invites, group_role_delegations, group_events, group_event_comments, group_backups
- 음성 교정: voice_correction_rules, voice_common_correction_rules
- 기타: early_bird_emails, user_backups, feedback_reports, admin_roles, contact_messages, product_early_birds, backup.daily_snapshots

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
