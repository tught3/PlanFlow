# PlanFlow iOS Simulator E2E — Run#4 판독 결정 트리 (Phase P9)

> **역사적 판독 기록 — 현재 workflow의 실행 승인이 아님**
>
> 이 문서는 Run#4 이전의 후보 1(`flutter test -d`) 관측과 판정 기준을
> 보존한다. Run#6 이후 현재 simulator 경로는 공식 XCTest host로 전환됐고,
> FLOW5 Group A는 host-side fake 테스트로 분리됐다. 따라서 이 문서의
> “P10 승격”, “FLOW5 현행 유지”, watchdog 상한, 예정 마커에 관한 문구는
> 당시의 판독 기록이며 현재 구현·실행 경로의 기준이 아니다. 현재 기준은
> `docs/ios/E2E_XCTEST_ARCHITECTURE.md`와
> `.github/workflows/ios-simulator-e2e.yml`이다.

> **이 문서의 목적은 다음 재실행(Run#4) 결과의 해석을 *미리* 고정하는 것이다.**
> 결과를 보고 나서 판정 기준을 만들면 어느 쪽으로든 끼워 맞추게 된다. 그래서 결과가 나오기 전인
> 지금, "무엇을 보고 어떻게 판정하는가"를 관측 가능한 파일명·마커 문자열 수준으로 못 박는다.
> Run#4 결과가 나온 뒤 이 문서의 판정 기준을 수정하는 것은 금지한다 — 기준이 부족했다면
> 그 사실 자체를 별도 항목으로 기록하고, 판정은 이 문서대로 내린다.

---

## 0. 배경 (Run#3에서 실측된 것)

Run#3(run id `33837500675`)에서 iOS Simulator E2E 워크플로의 **모든 job이 자체 워치독
타임아웃(exit 124)** 으로 종료됐다. flow05 leg의 verbose 콘솔 로그를 직접 열람한 결과:

- 780초 워치독 상한 안에서 아직 **Xcode 빌드의 극초반**(CocoaPods 각 타겟의
  `CreateBuildDirectory`)에 머물러 있었다.
- 콘솔 로그가 **최소 143,388줄** 누적돼 있었다.
- 같은 빌드가 이전(non-verbose) 실행에서는 **399.2초 / 525.2초**에 완주했었다.

→ **가설**: `--verbose` 출력을 GitHub Actions 콘솔로 실시간 스트리밍(`tee` 포함)하는 것 자체가
심각한 실행 지연 요인이며, 원래 조사 대상이던 Run#2의 hang(= "빌드 완료 후 완전 침묵")에
**도달하기도 전에** 워치독이 먼저 끊었을 가능성이 크다.

Wave1~3(P2~P8)은 이 가설을 분리 검증하기 위한 계측이다:
verbose 출력을 콘솔 tee 대신 **파일로만** 기록, 워치독이 **heartbeat**(경과시간 + 로그줄수 +
증가분)를 콘솔에 남김, 타임아웃/실패 시 **로그 tail 2000줄 + 마일스톤 grep** 노출,
모든 종료 경로에 **`E2E_TIMING`** 마커 기록.

---

## 1. ⚠️ 확정/미확정 표시 (정직 고백)

**이 문서를 작성한 시점(Phase P9)에 Wave2/3 산출물(P2~P8)은 아직 저장소에 없다.**
저장소 전수 grep 결과 `E2E_TIMING` / `heartbeat` / `lines_per_second` / `log_lines`
문자열은 `.github/workflows/`, `scripts/ios/`, `docs/` 어디에도 **0건**이다.

따라서 아래 표기를 구분해서 읽어야 한다:

| 표기 | 의미 |
|------|------|
| **[확정]** | 현재 저장소 코드에 실제로 존재함을 직접 확인한 파일명/마커 |
| **[예정 · PLACEHOLDER]** | P2~P8이 만들 *예정*인 이름. 계획서 문구를 그대로 옮긴 것이며 실제 구현명과 다를 수 있음 |

> **P2~P8 구현자·후속 판독자에게**: **[예정 · PLACEHOLDER]** 로 표시된 이름은
> **P2~P8 산출물의 실제 마커명/파일명을 그대로 사용할 것**. 실제 이름이 이 문서와 다르면
> **이 문서의 이름을 실제 구현에 맞춰 1회 정정**하고, 정정했다는 사실을 §6에 기록한다.
> 판정 *논리*(§3의 분기 조건)는 이름이 바뀌어도 그대로 유지한다.

---

## 2. 판독 입력 — 어디를 보는가

### 2-1. 현재 존재가 확인된 것 [확정]

| 대상 | 실제 경로/문자열 | 비고 |
|------|------------------|------|
| 워치독 스크립트 | `scripts/ios/e2e_watchdog.sh` | 타임아웃 시 exit `124` |
| 워치독 타임아웃 콘솔 라인 | `[STEP] watchdog: command exceeded <N>s, sending SIGTERM` | stderr |
| 워치독 정상완료 콘솔 라인 | `[STEP] watchdog: command completed with exit code <rc>` | stdout |
| 워치독 GH 어노테이션 | `::error title=E2E_WATCHDOG_TIMEOUT::` | |
| 스텝 레벨 타임아웃 라인 | `WATCHDOG_TIMEOUT: the flutter test run for category ...` (simulator-e2e)<br>`WATCHDOG_TIMEOUT: the FLOW5 flutter test run exceeded ...` (flow05) | |
| simulator-e2e 로그 파일 (원본, 미업로드) | `$RUNNER_TEMP/e2e-verbose-<category>.log` | Wave3 이후 `E2E_WATCHDOG_LOG_FILE` 리다이렉션으로 생성(`2>&1 \| tee`는 제거됨) |
| simulator-e2e 로그 파일 (마스킹 tail, 아티팩트 업로드됨) | `$artifact_dir/flow-test-verbose-tail-<category>.log` (= `$RUNNER_TEMP/e2e-artifacts/flow-test-verbose-tail-<category>.log`) | `E2E_WATCHDOG_TAIL_FILE`로 생성, `scripts/ios/e2e_mask_secrets.sh` 적용 대상 |
| 요약 스크립트 | `scripts/ios/e2e_summarize.sh` | 아래 마커들을 이미 인식 |
| 빌드 완료 마커 | `Xcode build done` | 요약기가 `grep -nF` 로 위치 탐색 |
| 테스트 체크포인트 마커 | `[CHECKPOINT] <marker>` | 요약기가 마지막 1건 추출 |
| 설치/빌드 실패 마커 | `Unable to install` / `simctl install` / `BUILD FAILED` | |
| 진단 덤프 | `scripts/ios/e2e_diagnose_hang.sh` → `hang-diagnostics/`, `hang-diagnostics-flow05/`<br>(`processes.txt`, `simulator_log.txt`, `diagnose_manifest.txt`, `simctl_diagnose.log`) | |
| 현재 워치독 상한 | simulator-e2e: mainstream `1500`, 그 외 `900` / flow05: `780` | **이번 Phase에서 변경하지 않음** (§5) |

### 2-2. Wave1~3이 만들 예정인 것 [예정 · PLACEHOLDER]

| 대상 | 예정 이름 (계획서 문구) | 판정에서의 역할 |
|------|------------------------|-----------------|
| 타이밍 마커 | `E2E_TIMING category=<c> duration_seconds=<n> log_lines=<n> lines_per_second=<n> exit=<code>` | **분기 (i)/(ii) 판정의 1차 근거** |
| heartbeat 콘솔 라인 | 경과시간 + 누적 로그줄수 + 증가분 | 진행 정체 구간 위치 파악 |
| verbose 파일 전용 로그 | `$RUNNER_TEMP/e2e-verbose-<category>.log` (원본) / `$artifact_dir/flow-test-verbose-tail-<category>.log` (마스킹 tail, 확정) | 콘솔 tee 대체분. Wave3에서 실제로 이 경로들로 확정됨(구 `flow-test-output.log`는 제거됨) |
| 실패 시 tail | 로그 tail **2000줄** 콘솔 노출 | **분기 (iii) 판정의 1차 근거** |
| 마일스톤 grep | `Running Xcode build` / `Xcode build done` / `Installing` / `Launching` / `VM Service` 등 | 어느 단계까지 갔는지 |

### 2-3. ⚠️ flow05 leg의 구조적 제약 (판독 전 반드시 인지)

현재 flow05 job의 테스트 스텝은 **의도적으로 `tee`를 쓰지 않는다.**
(`.github/workflows/ios-simulator-e2e.yml`, `Run FLOW5 auth/backend integration test` 스텝의
`NOTE (secret safety)` 주석) — `E2E_REAL_BACKEND_TEST=1`일 때 명령줄에 실제 Supabase anon key와
테스트 계정 비밀번호가 실리고, `--verbose`가 전체 컴파일러 호출을 그대로 echo하는데,
**GitHub Actions는 콘솔 로그의 시크릿은 마스킹하지만 업로드된 아티팩트 파일 내용은 마스킹하지 않는다.**

→ 그래서 "verbose를 파일로만 기록"이라는 Wave1 방향은 **flow05에 그대로 적용하면 시크릿
노출 경로를 새로 여는 것**이다. Run#4 판독 시:

- flow05의 로그 파일이 **없거나 아티팩트에서 제외돼 있어도 그것은 결함이 아니다.**
  그 경우 flow05는 **콘솔 로그 + `E2E_TIMING` 마커만으로** 판정한다.
- flow05 로그 파일을 새로 만들었다면, 그 파일이 아티팩트 업로드 경로에서
  제외(`!` 부정 패턴)됐는지 **먼저** 확인한다. 제외돼 있지 않다면 그것 자체가
  판정보다 우선하는 **BLOCKER**다.

---

## 3. 판독 순서와 분기

### 3-0. 선행 게이트 — 어떤 종료 경로였는가

먼저 각 job에 대해 다음을 확정한다(분기 판정 전 필수):

1. **`E2E_TIMING` 라인이 존재하는가?** [예정 · PLACEHOLDER]
   - 없으면 → Wave3 계측 자체가 미배선/미발화. **분기 판정 불가.**
     "verbose 오버헤드 확정/부정" 어느 쪽으로도 결론 내리지 말고,
     계측 배선 실패로 기록하고 재실행한다.
     (이는 "만들어놨는데 연결이 안 됨" 패턴의 재발이므로, 배선 호출부를 grep으로 실측해 확인한다.)
2. **`E2E_TIMING` 의 `exit=` 값**
   - `exit=124` → 워치독 타임아웃 (여전히 상한 초과)
   - `exit=0` → 완주
   - 그 외 → 테스트 자체 실패 (hang과 구분해야 함)

> **주의**: `exit=0`이 아니라고 해서 자동으로 (ii)가 아니다.
> `duration_seconds`가 먼저이고 `exit`는 그다음이다 — 아래 분기 조건을 순서대로 적용한다.

---

### 분기 (i) — verbose 콘솔 스트리밍 오버헤드 **확정**

**판정 조건 (AND, 둘 다 충족해야 함)**

| # | 무엇을 보는가 | 조건 |
|---|---------------|------|
| i-1 | **`E2E_TIMING` 라인의 `duration_seconds` 필드** [예정 · PLACEHOLDER] | 값이 **400~525초대**로 복귀 (= Run#3 이전 non-verbose 실측 399.2s / 525.2s 대역) |
| i-2 | **verbose 로그 파일**(simulator-e2e는 `$RUNNER_TEMP/e2e-verbose-<category>.log`, 실패 시 마스킹 tail `$artifact_dir/flow-test-verbose-tail-<category>.log` [확정]) 안에서 테스트가 실제로 진행됨 | `Found <N> files which will be executed as Integration Tests` 문자열이 존재하고, **그 라인보다 뒤에** 실제 xcodebuild 컴파일/링크 단계 출력이 이어짐 |

> i-2를 "로그가 길다"로 대체하지 말 것. Run#3은 143,388줄이나 쌓였지만 전부
> `CreateBuildDirectory` 극초반이었다. **줄 수가 아니라 도달한 단계**로 판정한다.

**결론**: verbose 출력을 콘솔로 실시간 스트리밍하는 것이 지연의 원인임이 확정된다.
Run#3의 전 job 타임아웃은 hang이 아니라 **계측 도구 자체가 만든 인공 지연**이었다.

**다음 조치**
- 워치독 초는 **그 실측치를 기준으로만 재산정**한다.
  **이 문서에서 숫자를 미리 정하지 않는다** — 산정 원칙만 고정한다:
  > `새 워치독 초 = (Run#4에서 실측된 duration_seconds) + 여유`
  > 여유는 러너 변동(콜드 Flutter SDK 캐시, pod install/pub get 네트워크 지터)을 흡수할
  > 만큼만 잡고, 목표는 "hang을 여전히 잡아내되 정상 완주를 끊지 않는" 최소값이다.
  > 실측치 없이 "넉넉하게" 올리는 것은 hang을 덮는 행위이므로 금지.
- 기존 워치독 상한(1500/900/780)은 **이 실측이 나오기 전까지 건드리지 않는다**(§5).

---

### 분기 (ii) — 원인은 콘솔 스트리밍이 아니라 **verbose 자체의 생성/파일쓰기 비용**

**판정 조건**

| # | 무엇을 보는가 | 조건 |
|---|---------------|------|
| ii-1 | **`E2E_TIMING` 라인의 `duration_seconds` 필드** [예정 · PLACEHOLDER] | non-verbose 기준선(399.2s / 525.2s) 대비 **여전히 수 배** — 즉 콘솔 tee를 없앴는데도 빨라지지 않음 |
| ii-2 | **`E2E_TIMING` 라인의 `lines_per_second` / `log_lines` 필드** [예정 · PLACEHOLDER] | `log_lines`가 여전히 10만 줄 규모이고, 실행 시간 대부분이 로그 생성에 소모된 것으로 읽힘 |
| ii-3 | (보조) **heartbeat 라인의 증가분** [예정 · PLACEHOLDER] | 줄수 증가분은 계속 큰데 마일스톤은 진전이 없음 = 로그만 쏟아내고 있음 |

**결론**: 병목이 콘솔 출력 경로가 아니라 `--verbose` 로그의 **생성 자체**(및 파일 쓰기)에 있다.
파일로 돌려도 개선되지 않으므로 verbose를 유지한 채로는 계측이 성립하지 않는다.

**다음 조치 (실험 전환)**
- `--verbose`를 **제거**하고, 진행 신호는 **마일스톤 grep만으로** 얻는 방식으로 전환 검토.
  대상 마일스톤 패턴은 이미 계획된 것을 그대로 쓴다:
  `Running Xcode build` / `Xcode build done` / `Installing` / `Launching` / `VM Service`
  (+ 기존 `[CHECKPOINT] <marker>` [확정] — 이건 verbose와 무관하게 테스트 코드가 직접 찍으므로
  `--verbose` 제거 후에도 살아남는다. 이 점이 전환을 가능하게 하는 핵심 근거다.)
- 즉 "관측을 포기"하는 게 아니라 **관측 수단을 verbose에서 checkpoint/마일스톤으로 교체**하는 것이다.

---

### 분기 (iii) — Run#2의 원래 hang **확정 재현**

**판정 조건**

| # | 무엇을 보는가 | 조건 |
|---|---------------|------|
| iii-1 | **마일스톤 grep 출력** [예정 · PLACEHOLDER] 또는 로그 파일 [확정] | `Xcode build done` 문자열이 **등장함** (= 빌드는 정상 완주) |
| iii-2 | **실패 시 노출되는 로그 tail(2000줄)** [예정 · PLACEHOLDER] | tail의 **마지막 non-empty 라인**이 `Xcode build done` 이거나, `Xcode build done` 이후 라인이 워치독 자체 출력(`[STEP] watchdog:`, `WATCHDOG_TIMEOUT`)뿐임 — 즉 **빌드 직후 무출력으로 끝남** |
| iii-3 | (교차확인) `scripts/ios/e2e_summarize.sh` 의 post-build 라인 카운트 [확정] | `Xcode build done` 이후 유의미한 라인 수가 **0** (요약기가 `- Post-build 출력: "Xcode build done" 이후 유의미한 로그 라인 없음` 을 출력) |

> iii-3은 이미 저장소에 구현돼 있는 [확정] 경로다. iii-1/iii-2의 [예정] 마커가
> 이름 불일치로 못 읽히더라도 **iii-3만으로 (iii) 판정이 가능**하다. 이 분기는
> placeholder 위험이 가장 낮다.

**결론**: verbose 오버헤드를 제거하고 나니 원래 찾던 hang이 그대로 드러난 것.
Run#3의 타임아웃은 오버헤드에 가려져 있었고, 진짜 문제는 **빌드 완료 후 flutter tool이
침묵하는 구간**이다.

**다음 조치**
- `docs/ios/E2E_EXECUTION_PATH_COMPARISON.md` (**P10 산출물 — 이 문서 작성 시점에 아직 없음**)의
  **대안 실행 경로 검토를 "검토"에서 "실행" 단계로 승격**한다.
- 이 분기에서는 워치독 초를 올리지 않는다. 상한을 늘려도 침묵 구간이 길어질 뿐이며,
  이는 hang을 덮는 행위다.

---

### 3-4. 분기가 혼재하거나 어디에도 안 맞을 때

- **job마다 분기가 다를 수 있다** (simulator-e2e의 mainstream/small/large/ipad, flow05는
  워치독 상한·tee 여부·flow 파일 수가 전부 다르다). **job 단위로 각각 판정**하고,
  전체를 하나의 분기로 뭉뚱그리지 않는다.
- (i)의 i-1은 맞는데 i-2가 아니다(= 빨라졌는데 테스트 진행은 없다) → **(i)로 판정하지 않는다.**
  빌드가 조기 실패했을 가능성이 높으므로 `BUILD FAILED` / `Unable to install` / `simctl install`
  [확정] 마커를 먼저 확인한다.
- 어느 분기에도 안 맞으면 **억지로 배정하지 않는다.** "미분류"로 기록하고 관측된 값
  (`duration_seconds`, `log_lines`, 마지막 마일스톤, exit code)을 그대로 남긴다.

---

## 4. 판정 기록 양식

Run#4 판정 시 job별로 아래를 그대로 채운다(추론 금지, 실측값만).

```
job:                <simulator-e2e:mainstream | ... | flow05>
E2E_TIMING 존재:    <있음 | 없음>
duration_seconds:   <값 | 미기록>
log_lines:          <값 | 미기록>
lines_per_second:   <값 | 미기록>
exit:               <값>
마지막 마일스톤:     <문자열 | 없음>
Xcode build done:   <등장 | 미등장>
post-build 유의미라인: <n | 0>
판정:               <(i) | (ii) | (iii) | 미분류>
근거:               <위 필드 중 어느 것을 보고 그렇게 판정했는지>
```

---

## 5. 이번 Phase에서 **의도적으로 바꾸지 않는 것**

| 항목 | 현재 값/상태 | 안 바꾸는 사유 |
|------|--------------|----------------|
| **워치독 초 값** | simulator-e2e mainstream `1500` / 그 외 `900`, flow05 `780` | Run#4의 실측 `duration_seconds`가 나오기 전에 조정하면 **어느 분기인지 판정 자체가 불가능해진다**(빨라진 게 계측 변경 덕인지 상한 완화 덕인지 구분 불가). 재산정은 분기 (i) 확정 이후에만, 실측치 기준으로 한다. |
| **GitHub job timeout** (`timeout-minutes`) | simulator-e2e `45`, flow05 `35` | 워치독보다 바깥쪽 한계이며, 워치독이 먼저 발동해 진단 덤프를 남기도록 이미 여유를 두고 산정된 값이다(flow05 주석의 worst-case 합산 ~1515s). 지금 건드리면 그 산정 근거가 무효가 된다. 또한 job timeout을 늘리는 것은 hang을 덮는 전형적 회피다. |
| **device matrix 구성** | preflight가 생성, mainstream만 FLOW1-4,6-8 전체 실행 | 이번 조사 변수는 **로깅 방식 하나**다. matrix를 같이 바꾸면 Run#3 대비 비교가 성립하지 않는다(변수 2개 동시 변경). |
| **CocoaPods 캐시 도입** | 미도입 (커밋된 `ios/Podfile.lock`이 없어 캐시 키를 만들 수 없음) | 빌드 시간을 단축시키므로 **오버헤드 측정을 오염**시킨다. 분기 (i)/(ii) 판정 후 별도 최적화 항목으로 다룬다. |
| **FLOW5 Group A 실행 경로 전환** | 현행 유지 (fake 기반, placeholder dart-define) | 실행 경로 변경은 P10(`E2E_EXECUTION_PATH_COMPARISON.md`)의 검토 대상이며, **분기 (iii)이 확정된 뒤에야** 실행 단계로 승격된다. 판정 전에 미리 바꾸면 (iii)의 재현 자체가 불가능해진다. |
| **flow05의 tee 미사용(시크릿 안전)** | 콘솔 전용 유지 | §2-3 참조. 아티팩트 파일은 시크릿 마스킹 대상이 아니다. 이 제약을 푸는 것은 별도 승인이 필요한 보안 결정이지 로깅 최적화가 아니다. |

**공통 원칙**: 이번 조사의 조작 변수는 **로깅 경로(콘솔 tee → 파일 + heartbeat/tail/마일스톤)
하나뿐**이다. 다른 변수를 같이 바꾸면 Run#3 ↔ Run#4 비교가 무효가 되고, 어느 분기인지
판정할 수 없게 된다.

---

## 6. 알려진 한계 (정직 고백)

1. **[예정 · PLACEHOLDER] 마커명이 실제 구현과 다를 수 있다.** 이 문서 작성 시점에
   `E2E_TIMING` / heartbeat / `lines_per_second` / `log_lines` 는 저장소 전수 grep에서 **0건**이다.
   P2~P8 배선 후 실제 이름으로 **1회 정정**하고, 정정 이력을 아래에 남긴다.
   - (정정 이력: 아직 없음)
2. **비교 기준선(399.2s / 525.2s)은 Run#3 이전 non-verbose 실행 실측이다.** 러너 세대·캐시
   상태가 다르면 그 자체로 수십 초 편차가 날 수 있다. 분기 (i)의 "400~525초대"는
   **엄밀한 경계가 아니라 대역**으로 읽어야 하며, 경계 근처(예: 560s)라면
   "(i)에 가깝다"로 기록하되 `log_lines`/마일스톤 도달 단계로 교차 확인한다.
3. **`E2E_TIMING`이 안 찍히면 이 결정 트리는 대부분 작동하지 않는다.** 유일한 예외가
   분기 (iii)의 iii-3(요약 스크립트 post-build 카운트, [확정] 경로)이다. 계측 미발화는
   "분기 판정 불가"이지 "오버헤드 없음"이 아니다 — 혼동 금지.
4. **`docs/ios/E2E_EXECUTION_PATH_COMPARISON.md`(P10)는 이 문서 작성 시점에 존재하지 않는다.**
   분기 (iii)의 다음 조치는 그 문서가 만들어진 뒤에야 실행 가능하다.
5. **job별 분기가 갈릴 경우의 종합 판정 규칙은 정하지 않았다.** §3-4는 "job 단위로 각각
   판정한다"까지만 고정한다. 실제로 갈렸을 때 전체 결론을 어떻게 낼지는 그 데이터를 보고
   결정하는 것이 맞다고 판단했다(여기서 미리 정하면 근거 없는 규칙이 된다).

---

## 7. Run#4 판정 기록 (실측 완료)

### 7-1. 분기 판정 결과

**분기 (i)(콘솔 스트리밍 오버헤드 확정)와 (ii)(verbose 생성/파일쓰기 비용) 둘 다 기각한다.**

Run#4는 verbose 출력을 파일 리다이렉션으로만 기록하고 콘솔 tee를 제거한 상태로
실행됐음에도 불구하고, mainstream/small/ipad/flow05 4개 job이 **정확히 같은 지점**에서
정지했고, 정지 구간 내내 `delta=+0`(신규 로그 출력이 실제로 0줄)이었다. 즉 verbose
로그의 생성량·스트리밍 비용이 원인이었다면 파일 리다이렉션만으로도 진행이 있었어야
하는데, 로그 자체가 아예 늘지 않았다. 이는 로깅 방식과 무관한 **도구 레벨의 진짜 hang**
이라는 뜻이며, 애초에 조사 대상이던 분기 (iii)(빌드 완료 후 침묵)과도 다른, 더 이른
단계에서 발생하는 별도의 hang이다.

### 7-2. 새로 확정된 근본원인

**[확정]** 4개 job(mainstream/small/ipad/flow05) 전부 다음 지점에서 예외 없이 영구
정지했다(watchdog 상한까지 `delta=+0` 지속):

```
[STEP] watchdog: elapsed=Ns ... last=[ ] Waiting for VM Service port to be available...
```

`PLANFLOW_E2E_REAL_BACKEND_TEST=0`(real backend 비활성)인 순수 fake 테스트 job인 flow05
까지 동일 증상을 보였다는 것이 결정적이다 — 이는 테스트 코드나 백엔드 의존성이 원인이
아니라는 뜻이다. 즉 `flutter test -d <UDID>`가 시뮬레이터에 attach해 VM Service를
discovery하는 메커니즘 자체가 이 CI 환경에서 깨져 있는 것으로 확정한다.

나머지 1개 job(large)은 이 지점에도 도달하지 못했다 — 그보다 더 앞 단계인 SPM 해석
(`xcodebuild -clonedSourcePackagesDirPath`)에서 900초 워치독 상한 내내 벗어나지 못했다.
이는 별개/파생 이슈로 분리하며(§7-4 참조), 이번 근본원인 판정의 대상이 아니다.

### 7-3. 확정 사실 vs 가설 구분

| 구분 | 내용 |
|------|------|
| **[확정]** | VM Service discovery 영구 hang. 4/5 job에서 100% 재현. 테스트 코드·백엔드 의존성과 무관(fake-only job인 flow05도 동일 증상). |
| **[확정]** | `scripts/ios/simctl_discover.sh`가 `sort_by(.version) \| last`로 무조건 **최신 시뮬레이터 런타임**(iOS 26.5)을 선택한다. 워크플로 전체에 Xcode 버전을 고정하는 스텝은 존재하지 않는다(저장소 전수 grep 결과 0건). |
| **[가설]** | "러너 기본(구버전) Xcode 툴체인 × 최신(iOS 26.5) 시뮬레이터 런타임의 세대 불일치가 VM Service discovery 프로토콜을 깨뜨린다"는 것은 **메커니즘 설명이며, 이 저장소에서 런타임을 낮췄을 때 hang이 실제로 사라지는 대조실험은 아직 수행되지 않았다.** 정황 증거만 있다: `actions/runner-images` 이슈 #12862 / #12777 / #12948 — 동일한 macos-15+구Xcode 조합에서 시뮬레이터 연결이 불안정하다는 독립 보고들. |

이 가설을 (i)/(ii)/(iii)의 기존 분기 체계에 억지로 끼워 넣지 않는다 — §3-4의 원칙
("어느 분기에도 안 맞으면 억지로 배정하지 않는다")에 따라 **신규 근본원인**으로 별도
기록한다.

### 7-4. 적용한 수정 (별도 작업, 이 문서에는 요약만)

`scripts/ios/simctl_discover.sh`의 런타임 선택 로직을, 활성 Xcode가 실제로 지원하는
iphonesimulator SDK 상한(major 버전 비교) 이내로 제한하도록 수정 중이다. 버전
리터럴을 하드코딩하지 않고 `xcrun --sdk iphonesimulator --show-sdk-version` /
`xcodebuild -showsdks`의 동적 조회 결과로 상한을 계산한다. 이 가설이 틀렸을 경우를
대비해 대조실험용 우회 스위치 `SIMCTL_DISCOVER_ALLOW_ANY_RUNTIME=1`을 추가해, 다음
CI 실행에서 이 변경 전/후를 직접 비교 검증할 수 있게 했다.

### 7-5. 반증 시 다음 카드

이 수정을 적용한 뒤에도 `FLUTTER_ATTACH` 마커가 여전히 FAIL(evidence=`VM_SERVICE_WAIT_HANG`)
로 나오면, §7-3의 가설은 기각된 것으로 보고 다음 순서로 넘어간다:

1. `maxim-lobanov/setup-xcode@v1` + `latest-stable`로 Xcode 버전을 명시적으로 고정한다.
   단, 이것도 "움직이는 최신값"이라는 점에서 근본 해결이 아닐 수 있음을 인지한 채 진행한다.
2. `docs/ios/E2E_EXECUTION_PATH_COMPARISON.md`가 이미 정리해둔 **후보5(사이드카
   `simctl spawn log stream`)** 로 실행경로 자체 재검토를 승격한다.

### 7-6. 이번 Phase 범위에서 명시 제외 (후속 승격 조건 충족 시에만 재검토)

§5의 형식을 그대로 따라, 아래 3개 항목은 **이번 Phase 범위에서 손대지 않는다**:

| 항목 | 후속 승격 조건 | 안 바꾸는 사유 |
|------|----------------|----------------|
| **matrix 비용 재최적화** | Run#5에서 최소 mainstream+flow05가 green이고 실제 `duration_seconds`가 확보된 이후 | 지금 matrix 구성을 같이 바꾸면 이번 수정의 효과와 matrix 변경의 효과가 뒤섞여 판정이 불가능해진다. |
| **large job의 SPM 정체**(`-clonedSourcePackagesDirPath` 900초 초과) | 이번 수정 적용 후 재발 여부로 판단 | VM Service discovery hang과는 별개의 더 이른 단계 이슈일 가능성이 높다(네트워크/캐시 경합성 CI 변동성으로 추정 — 근거 약함, 확정 아님). 이번 근본원인 수정과 섞어서 판단하지 않는다. |
| **워치독 초 값**(1500/900/780) 재산정 | Run#5 실측 이후에만 | 지금 조정하면 개선이 이번 수정 덕인지 상한 완화 덕인지 구분할 수 없게 된다(§5의 기존 원칙과 동일 논리). |
