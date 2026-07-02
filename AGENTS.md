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
- 표준 흐름은 `Claude Code 계획 -> Codex 구현 -> Claude Code 리뷰 -> CEO 보고`다.
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
> 2. **계획 = `gpt-5.5`(상위 모델).** 범위·영향파일·리스크·검증기준 먼저 제시.
> 3. **구현 = 난이도별 병렬 서브에이전트 위임.** 단순/보일러플레이트 = `gpt-5.3-codex-spark`(경량), 난도 높음 = `gpt-5.4-mini`(중간). 파일 비중첩이면 동시 실행.
> 4. **별도 리뷰어(`gpt-5.4-mini`)가 전체 diff를 리뷰** — 계약 정합·회귀·규약 위반 점검. (구현 워커와 다른 별도 세션)
> 5. 지적사항 **수정** → 6. **재리뷰** → 7. **검증(analyze/test/build)·보고**.
> 메인(오케스트레이터) 세션은 **직접 구현을 쏟지 말고** 계획·분배·검토·보고만 담당한다. 이 흐름을 지키지 않고 메인이 다 처리하거나 모델 라우팅/별도 리뷰어를 건너뛰면 규약 위반이다.
- 비단순 작업은 계획 -> 병렬 작업자 -> 별도 리뷰어 -> 수정 -> 재리뷰 순서로 진행한다.
- 계획 단계는 `gpt-5.5`를 우선한다.
- 일반 구현은 `gpt-5.3-codex-spark`를 우선한다.
- 난도가 높은 구현과 리뷰어 검토는 `gpt-5.4-mini`를 우선한다.
- 계획이 끝나면 실제 작업은 가능한 한 무조건 병렬로 진행한다.
- 파일, 모듈, 서브시스템이 겹치지 않으면 워커를 동시에 띄우고 병렬 완료를 우선한다.
- 병렬 작업 후 자기 할 일이 끝난 서브에이전트는 즉시 닫는다.
- 완료된 서브에이전트를 띄워둔 채로 방치하지 않고, 다음 병렬 작업에 자원을 바로 쓸 수 있게 한다.
- 비단순 작업의 구현 단계는 메인(오케스트레이터) 세션이 직접 코드를 쏟아내지 말고 경량 서브에이전트에 위임한다. 메인 세션은 계획·분배·검토·보고만 담당하고, 실제 구현과 반복 작업은 난이도에 맞는 서브에이전트(단순=경량 모델, 난도 높음=중간 모델)로 병렬 위임해 비용을 낮춘다. 이것이 기본값이며, 사용자가 따로 지시하지 않아도 비단순 구현은 위임을 우선한다.
- 메인 세션은 자기 모델을 임의로 바꿀 수 없으므로, "계획은 상위 모델 / 구현은 경량"을 달성하려면 반드시 서브에이전트 위임을 사용한다. 메인 모델 자체를 낮추려면 사용자가 직접 모델을 전환해야 한다.
- 다만 도구/하네스 정책이 불필요한 서브에이전트 생성을 억제할 수 있어 위임이 자동으로 항상 적용되지는 않는다. 위임이 확실히 필요한 작업이면 사용자가 "구현은 서브에이전트로" 같은 트리거를 주거나, 작업 시작 시 위임 방침을 명시한다.

## 작업 방식
- 기존 코드, 기존 문서, 기존 구조를 먼저 확인한다.
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
- 실제 Android 기기를 무선 디버깅으로 연결할 때는 `adb connect <ip>:<port>`의 명시 IP 연결을 우선하고, 같은 기기가 `adb-..._adb-tls-connect._tcp` mDNS 항목으로 중복 표시되지 않게 자동 정리한다.
- ADB/Flutter 실행 전에는 공용 래퍼가 `E:\AI_WIKI\scripts\adb-single-device.ps1`를 자동 호출해 mDNS 자동 연결을 비활성화하고, 같은 기기의 mDNS 중복 연결을 끊어 하나의 device만 유지한다.
- 무선 디버깅 포트를 고정해서 자동 재연결해야 할 때만 사용자 환경변수 `AI_WIKI_ADB_DEVICE=<ip>:<port>`를 설정한다.
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


# AI Behavior Rules
<!-- AI가 작업 시 반드시 따라야 할 행동 원칙. 모든 프로젝트에 공통 적용. -->

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
- **코드를 수정하면(버그수정·기능·리팩토링 무관) 완료 보고 전에 반드시 재발 방지책(회귀 테스트·가드 등)을 만든다 — 기록보다 재발 방지가 목적.** FluxStudio 계열에서는 `python E:\FluxStudio\.fluxos\run.py prevent capture --title "<제목>" --root-cause "<근본원인>" [--files <변경파일들>] [--commit <해시>] [--ai claude|codex|glm] [--project <프로젝트>]`로 근본원인을 남기면, 도구가 유형에 맞는 강제 계층(코드=회귀테스트 자동 스캐폴드 / 행동·교차AI=AI_WIKI 공통규칙 / 메타패턴=메모리)에 예방책을 배치한다. 이는 모든 AI(Claude·Codex·GLM)·모든 프로젝트의 완료 기준이며, FluxOS는 `FLUXOS_PREVENTION_GATE=block`에서 **방지책 없는 완료를 차단**한다(방지책 캡처 시 해제).
- 모르면 가정하지 말고 질문
- 난이도와 모델이 맞지 않으면 모델 변경 후 진행

## 응답 원칙
- 한국어로 응답
- 코드 변경 시 변경 전/후 명시
- 영향 범위 항상 명시 (어느 파일, 어느 기능)
- 에러 발생 시 원인 -> 해결책 -> 예방법 순서로 설명

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
-> 각 02_PROJECTS/[프로젝트].md 파일의 금지 패턴 섹션 참조

### [PREVENT] 안전 게이트는 차단입력을 실입력으로 통과하는 테스트 1개 필수 (2026-06-25)
안전 게이트(진행·커밋·차단을 막는 판정)를 추가하거나 수정할 때, 그 게이트의 차단 입력을 만드는 producer(파서·git status·pid 생존·로그 파싱 등)를 mock한 테스트만 두지 말 것. 최소 하나의 테스트는 그 producer를 mock하지 말고 실제 입력(임시 git repo·실제 문자열·실제 파일 상태)으로 게이트를 통과시켜야 한다. 안 그러면 producer가 깨져 게이트가 死문서가 돼도 테스트가 green으로 통과한다(mocked-contract-hides-bug). 실증 사례: git status 파서가 worktree 변경 경로 첫 글자를 잘라 부분커밋 정합 게이트가 死문서였는데 모든 테스트가 그 파서를 mock해 잡지 못함.

### [PREVENT] 동시 AI 세션 git add-commit 레이스로 staged 흡수 (2026-06-25)
여러 AI 세션(Claude/Codex)이 같은 repo에서 git add 후 staged 전체를 커밋(git add . / git commit -a)하면, 한 세션이 add해둔 변경을 다른 세션의 commit이 자기 커밋에 흡수한다. FluxOS git_autocommit는 pathspec(git commit -- files)+git lease로 안전하나, AI 세션의 직접 커밋이 staged 전체를 가져가는 게 문제. 방지: AI 세션은 항상 pathspec 커밋(git commit -- <files> 또는 -o)으로 자기 파일만 커밋하고, git add . / commit -a / staged 전체 커밋을 금지한다.

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

### [PREVENT] 동시 세션이 타 세션 미커밋 워크트리 편집을 자기 커밋에 휩쓸어감 (2026-06-26)
다중 세션 환경에서 한 세션이 git add -A / git commit -a / commit --all 또는 파일 전체 재생성(테스트 스캐폴드 regenerate)을 하면, 다른 세션이 워크트리에 만들어둔 미커밋 편집이 의도치 않게 그 세션 커밋에 섞이거나 유실된다. 이번 세션 실증 2건: (1) 내 controlled-parallel 테스트 편집을 stash한 사이 타 세션이 test_fluxos.py를 재생성 → stash pop 머지에서 내 편집 유실. (2) 내 api_runner 테스트 편집(미커밋)이 타 세션 커밋 5283dc4에 통째로 휩쓸려 들어감. 규칙: 모든 세션은 자기가 바꾼 파일만 pathspec(git add <경로> / git commit -- <경로>)으로 스테이징·커밋한다. git add -A / git add . / git commit -a / git commit --all 금지. 다른 세션이 동시에 같은 파일(특히 자동 재생성되는 test_fluxos.py)을 건드릴 수 있으면 git stash 대신 별도 워크트리나 패치 파일로 격리한다. 커밋 전 git diff --cached로 자기 hunk만 들어갔는지 확인한다.

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
├── core/                # env, routing, theme, constants
├── data/                # models and Supabase repositories
├── providers/           # app/auth/event/settings state
├── screens/             # Flutter screens
├── services/            # STT, GPT, calendar, notification, widget, backup
└── widgets/             # shared UI widgets
android/                 # Android app, widget, manifest
supabase/schema.sql      # DB schema and RLS source of truth
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
