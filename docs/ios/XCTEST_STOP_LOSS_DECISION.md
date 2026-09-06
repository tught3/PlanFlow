# iOS Simulator XCTest — Stop-Loss 판정 (P3)

> **판정: `DEFER_XCTEST_POST_RELEASE` + `REPLACE_WITH_OTHER_PRE_RELEASE_QA` (병행)**
>
> 릴리스 전에 native XCTest discovery를 다시 뚫는 데 시간을 더 쓰지 않는다.
> 대신 **이미 저장소에 존재하지만 어떤 CI에서도 실행되지 않는 테스트 자산**을
> 릴리스 전 QA 게이트로 승격시킨다. XCTest는 재개 조건(아래 §5)이 충족될 때만 재시도한다.
>
> 작성일: 2026-09-06 / 기준 HEAD: `cbf8f4b6`

---

## 1. 왜 stop-loss인가 — 실패가 제품 결함 탐지기가 아니다

Run#18(`run_id=33978093334`, `head_sha=3415a195b92abd7009a99923bb39faf902cc3818`)의
실측 기록은 `.codex/tasks/planflow-ios-simulator-e2e-new-architecture-real-run-final-qa-20260905.json`
의 `run18_authenticated_evidence` 블록에 있다. 그 블록이 기록한 내용:

**PASS한 것** (`passes`):
- `preflight PASS`
- `flow05-host-fake PASS`
- small / large / iPad / mainstream 전부 `APP_BUILD`, `APP_INSTALL`, `APP_LAUNCH`, `APP_READY` PASS
- `RunnerTests.xctest build/link and bundle loading PASS`

**FAIL한 것** (`failures`):
- 4개 레그 전부 XCTest discovery 없음 / 완료 없음
- `xcodebuild test` **exit 65** — `Test runner never began executing tests after launching`
- 진단 로그: `Loading test suite...` 이후 **testmanagerd authorization 또는 daemon-connection 실패**, `simctl_diagnose` timeout

같은 파일이 남긴 판정:
- `classification: BLOCKED_RUNTIME_XCTEST`
- `confidence: about 80% environment or Xcode 16.4 simulator infrastructure; not a confirmed source defect`
- `source_patch_decision: NO_SOURCE_PATCH_JUSTIFIED`
- `flows_1_to_8: NOT_VERIFIED`

핵심은 **실패 지점의 위치**다. 앱은 빌드되고, 설치되고, 실행되고, ready 상태에 도달했다.
테스트 번들도 링크·로드에 성공했다. 실패는 그 다음, **테스트 러너가 시뮬레이터의
`testmanagerd`와 연결을 맺는 단계**에서 났다. 이 구간에서 나오는 신호는
"이 앱의 코드에 결함이 있다"가 아니라 "이 러너 이미지에서 XCTest 실행 인프라가 붙지 않는다"이다.

즉 **현재 XCTest 파이프라인은 제품 결함을 한 건도 탐지할 수 없는 상태**다.
탐지기가 아니라 인프라 진단기로 동작하고 있고, 진단 결과는 매번 같다.

### 1.1 Run13→18 진행은 "고칠 게 없어서" 멈춘 게 아니다

같은 파일의 run13/14/15/16 블록을 보면 매 회차마다 **실제 소스 결함이 하나씩 발견·수정**됐다:

| Run | 첫 실패 단계 | 기록된 root_cause | 성격 |
|---|---|---|---|
| 13 | `XCTEST_EXECUTION` | `COCOAPODS_RUNNERTESTS_LINK_GRAPH` | 소스 결함 (수정됨) |
| 14 | `POD_INSTALL` | integration_test pod 절대/상대 경로 중복 | 소스 결함 (수정됨) |
| 15 | `XCTEST_EXECUTION` | `COCOAPODS_TARGET_SUPPORT_XCCONFIG` | 소스 결함 (수정됨) |
| 16 | `XCTEST_EXECUTION` | `DUPLICATE_INTEGRATION_TEST_HOST_LINK` | 소스 결함 (수정됨) |
| 18 | `XCTEST_EXECUTION` | (기록 없음) `NO_SOURCE_PATCH_JUSTIFIED` | **소스 결함 아님** |

Run13~16은 고칠 것이 있었고 실제로 고쳤다. Run18에서 처음으로
"이 저장소에서 더 고칠 것을 찾지 못했다"가 나왔다. 그래서 지금이 stop-loss 지점이다 —
포기가 아니라 **투자 대비 수확이 0으로 떨어진 지점**이다.

---

## 2. 지금 실제로 통과 근거가 있는 것 vs 미실행

이 저장소의 `.github/workflows/`에는 워크플로 8개가 존재하며, 그중
`pull_request` / `push`로 **자동 실행**되는 것은 iOS 전용 워크플로들뿐이다.

**중요 — 이 절은 작성 도중 갱신됐다.** 최초 조사 시점(기준 HEAD `cbf8f4b6`)에는
iOS 전용 워크플로 6개만 존재했으나, 작성 중 커밋 `f29f9a24`가
`flutter-test-baseline.yml`과 `ios-adsdk-launch-probe.yml` 2개를 추가했다.
아래 서술은 `f29f9a24` 반영 기준이다.

- `flutter-test-baseline.yml`은 **`workflow_dispatch` 전용**(자동 트리거 없음)이고
  테스트 스텝이 `continue-on-error: true`인 **비차단 측정용** 워크플로다.
- 따라서 "157개 테스트가 **자동으로** 실행되는 CI는 없다"는 진술은 **여전히 유효**하다.
- 다만 "전체 스위트를 돌릴 수단이 저장소에 전혀 없다"는 진술은 **더 이상 사실이 아니다.**
  수단은 생겼고, **아직 실행되지 않았을 뿐**이다(§4-1 참조).

### 2.1 통과 근거가 있는 것

| 항목 | 실행 위치 | 성격 | 제품 런타임 검증? |
|---|---|---|---|
| `test/ios_phase2_contract_test.dart` | `.github/workflows/ios-readiness.yml:90` | 텍스트·파일 대조 계약 테스트 | **아니오** |
| `test/ios_phase3_native_contract_test.dart` | 같은 곳 `:91` | 동상 | **아니오** |
| `test/ios_phase4_identity_contract_test.dart` | 같은 곳 `:92` | 동상 | **아니오** |
| `test/ios_release_contract_test.dart` | 같은 곳 `:93` | 동상 | **아니오** |
| `test/ios_e2e_flow05_fake_test.dart` | `.github/workflows/ios-simulator-e2e.yml:126` | host fake (시뮬레이터 밖) | 부분 (호스트 VM) |

`ios-readiness.yml`은 이 외에 `flutter analyze`(`:87` 직전 스텝)와
unsigned `xcodebuild` Runner 빌드를 돌린다 — 즉 **컴파일 가능성**은 검증된다.

### 2.2 통과 근거가 없는 것

| 항목 | 상태 | 근거 |
|---|---|---|
| FLOW1 ~ FLOW8 (8개 전부) | **NOT_VERIFIED** | Run#18 `flows_1_to_8: "NOT_VERIFIED"` |
| `test/` 아래 `_test.dart` **157개** | **어떤 CI에서도 자동 실행 안 됨** | `.github/workflows/ios-readiness.yml:89-94`이 4개만 명시 실행. 전체 스위트를 돌리는 `flutter-test-baseline.yml`은 `workflow_dispatch` 전용 + `continue-on-error: true`라 자동 실행·차단 모두 하지 않는다 |
| `integration_test/flow01` 세션 복원 시나리오 | **영구 skip** | `integration_test/flow01_cold_start_test.dart:90` `skip: true` |

`integration_test/` 에는 flow01~flow08 파일 8개가 실재한다.
즉 **시나리오 코드는 이미 작성돼 있는데 실행 경로만 막혀 있다.**

### 2.3 미실측 주장 (그대로 인용하지 말 것)

`.github/workflows/ios-readiness.yml:85-88` 주석은 다음과 같이 주장한다:

> The full repository suite runs in the Android/feature CI and currently contains
> unrelated environment-sensitive failures (for example Naver/voice integration
> fixtures) that must not mask native iOS compilation.

이 주석은 **두 가지를 주장하는데 둘 다 이 저장소에서 확인되지 않는다**:
1. "Android/feature CI가 전체 스위트를 돌린다" → 그런 **자동 실행** 워크플로가 **없다**.
   (`flutter-test-baseline.yml`은 수동 dispatch 전용이며 이 주석보다 나중에 생겼다.)
2. "환경 민감 실패가 있다" → **실측된 적이 없다. `UNVERIFIED`.**

157개 테스트가 실제로 몇 개 통과하는지는 **아직 아무도 모른다.**
측정 수단(`flutter-test-baseline.yml`)은 `f29f9a24`로 생겼지만
**실행 결과가 없다** — 수단의 존재는 측정이 아니다.
이것이 §4의 첫 단계가 "수정"이 아니라 "측정"인 이유다.

### 2.4 `flow01` skip이 드러내는 별개 격차

`integration_test/flow01_cold_start_test.dart:82-90` 주석은
`authProvider`가 교체 가능한 전역이 아니라 "기존 세션으로 부팅"을 앱 프로세스 안에서
재현할 DI seam이 없다고 기록한다. 이건 XCTest 인프라와 **무관한 프로덕션 코드 격차**다.
XCTest가 내일 고쳐져도 이 시나리오는 여전히 실행되지 않는다.

---

## 3. 판정과 근거

**`DEFER_XCTEST_POST_RELEASE` + `REPLACE_WITH_OTHER_PRE_RELEASE_QA`**

`CONTINUE_XCTEST_BEFORE_RELEASE`를 택하지 않는 이유:
1. Run18 실패는 이 저장소가 통제하지 못하는 러너 이미지 계층에 있다
   (`confidence: about 80% environment or Xcode 16.4 simulator infrastructure`).
2. `NO_SOURCE_PATCH_JUSTIFIED` — 다음에 시도할 소스 수정 후보가 특정돼 있지 않다.
   목표 없는 재시도는 회차당 비용만 확정이고 수확은 기대값이 없다.
3. XCTest를 뚫어도 얻는 것은 FLOW1~8인데, 그중 일부(flow01 세션 복원)는
   프로덕션 DI 격차 때문에 어차피 실행되지 않는다(§2.4).

`REPLACE`를 **병행**하는 이유:
`DEFER`만 하면 릴리스 전 QA가 "4개 계약 테스트 + 1개 host fake"로 남는다.
그건 텍스트 대조라 제품 회귀를 못 잡는다. 반면 157개 테스트 자산은
**이미 작성돼 있고 macOS 시뮬레이터도 필요 없다** — 실행 경로만 없다.
탐지력 대비 비용이 XCTest 재시도보다 압도적으로 낫다.

**한계 (정직 고백)**: 이 판정은 "XCTest가 불필요하다"는 뜻이 **아니다.**
native XCTest만이 검증할 수 있는 것(실제 시뮬레이터 프로세스 안에서의 위젯 렌더링,
App Group 실물 왕복, 권한 다이얼로그 분기)은 §4의 대체 QA로 **커버되지 않는다.**
그 항목들은 대체가 아니라 **미검증 상태로 릴리스에 넘어간다.** 이 사실을 릴리스
판정에 그대로 반영해야 한다 — "대체 QA를 했으니 동등하다"고 쓰면 안 된다.

---

## 4. 대체 QA — 릴리스 전에 할 것

**순서를 지켜라. 1번은 수정이 아니라 측정이다.**

1. **[측정] 157개 테스트의 실제 현황을 확정한다. — 수단 있음, 실행 필요**
   `flutter-test-baseline.yml`(커밋 `f29f9a24`로 추가됨)을 **`workflow_dispatch`로 1회 실행**하고
   업로드되는 `flutter-full-suite-baseline` 아티팩트(`full-suite-output.log`)에서
   pass/fail/skip 수를 기록한다.
   `.github/workflows/ios-readiness.yml:85-88`의 "environment-sensitive failures" 주장이
   사실인지, 사실이면 몇 건인지를 먼저 숫자로 만든다.
   **이 측정 없이 다음 단계로 가지 마라** — 워크플로가 존재한다는 사실은
   측정 결과가 아니다. 실행 로그가 나오기 전까지 §2.2는 그대로 미확정이다.

2. **[분류] 실패를 두 종류로 가른다.**
   - (a) 환경 의존 실패(네트워크·픽스처·로케일) → 격리하거나 명시 skip + 사유 기록
   - (b) 실제 제품 결함 → 릴리스 블로커 후보

3. **[게이트] 통과 집합을 차단 게이트로 승격한다.**
   현재 `flutter-test-baseline.yml`은 의도적으로 **비차단**(`continue-on-error: true`,
   수동 트리거)이다 — 측정 전용이라 그렇게 설계된 것이 맞다.
   1·2번으로 통과 집합이 확정된 뒤에야 (a)를 제외한 나머지를
   **자동 트리거 + 차단** 게이트로 올린다. 이것은 별도의 의도적 변경이다.
   `ios-readiness.yml`은 **수정하지 않는다** — 그 파일의 역할(iOS 네이티브 계약)은
   그대로 두고 별도 워크플로로 유지한다.
   fail-closed 원칙(`docs/ios/templates/README.md` "설계 원칙")을 따른다.

4. **[유지] host-runnable E2E는 계속 쓴다.**
   `test/ios_e2e_flow05_fake_test.dart`는 이미 CI에서 통과한다
   (`.github/workflows/ios-simulator-e2e.yml:126`). 같은 host-fake 패턴으로 커버 가능한
   FLOW를 추가 이식하는 것이 시뮬레이터 안으로 들어가는 것보다 싸다.

5. **[기록] 커버되지 않는 항목을 명시적으로 남긴다.**
   `docs/ios/SIMULATOR_QA_MATRIX.md`에서 이번 대체 QA로도 검증되지 않는 항목을
   `NOT_VERIFIED`로 표시하고 릴리스 영향도를 적는다. **조용히 넘어가지 마라.**

---

## 5. 재개 조건 (trigger)

아래 중 **하나라도** 성립하면 XCTest를 다시 시도한다. 성립 전에는 재시도하지 않는다.

| # | 조건 | 확인 방법 |
|---|---|---|
| T1 | GitHub Actions `macos-15` 이미지의 Xcode 기본 버전이 16.4에서 올라감 | 러너 릴리스 노트 / 워크플로 첫 스텝의 `xcodebuild -version` |
| T2 | `macos-15` 이후 이미지(`macos-26` 등)가 벤더드 Swift pod 링크를 지원 | Run#8/#9가 기록한 `swiftCompatibility56` / `swiftCompatibilityConcurrency` / `swiftCompatibilityPacks` / `CoreAudioTypes` / `UIUtilities` 심볼 누락이 재현되지 않는지 1회 실측 |
| T3 | Apple/커뮤니티가 `Test runner never began executing tests after launching` + testmanagerd 연결 실패의 확정 원인을 공개 | 원인이 이 저장소 소스에 있다고 지목되면 즉시 재개 |
| T4 | 릴리스 후 실제 사용자 결함이 FLOW1~8 축에서 발생 | 그 FLOW를 우선순위로 재개 (비용 정당화됨) |

### 5.1 재시도 방법 (재개 시)

1. **바꾸는 변수는 한 번에 하나.** Run13~16의 각 수정이 실패 단계를 뒤로 밀었기 때문에
   원인 귀속이 가능했다. 여러 개를 동시에 바꾸면 그 추적성이 사라진다.
2. **최소 재현부터.** 전체 FLOW 매트릭스가 아니라 `XCTAssertTrue(true)` 하나짜리
   테스트 메서드 1개로 discovery가 개시되는지부터 확인한다
   (Run18 `next_gate`가 지목한 "minimal native XCTest isolation").
   discovery가 안 되면 앱 코드는 원인이 아니다.
3. **`.github/workflows/ios-simulator-e2e.yml:37-39`의 macos-15 핀은 유지한다.**
   그 주석이 기록한 대로 `macos-latest`(Xcode 26)는 이 앱의 벤더드 Swift pod를
   링크하지 못한다. 이 핀을 풀면 실패 단계가 XCTest보다 앞으로 되돌아간다.
4. **`ios-release.yml` / privacy / signing 경로는 건드리지 않는다.**
   Run13~18 전 회차에서 `production_release_privacy_signing: PROTECTED`가 유지됐다.

### 5.2 유지되는 자산 (재개 시 다시 만들지 말 것)

Run13~16에서 해결한 것들은 현재 소스에 남아 있고 재개 시 재사용된다:
- RunnerTests CocoaPods 격리 토폴로지 — `ios/Podfile:31,37-38`
  (top-level `target 'Runner'` + nested `target 'RunnerTests'` with `inherit! :search_paths`)
- 타깃 전용 xcconfig — `ios/Flutter/RunnerTests-Debug.xcconfig`,
  `RunnerTests-Profile.xcconfig`, `RunnerTests-Release.xcconfig`
- `integration_test` pod 상대 경로(`.symlinks/plugins/integration_test/ios`) 수정 (Run14)

---

## 6. 이 문서의 범위

- 이 문서는 **판정 기록**이다. 코드·워크플로를 변경하지 않았다.
- §4의 대체 QA는 **아직 실행되지 않았다.** 별도 작업으로 진행해야 한다.
  1번(측정)의 **수단**은 `f29f9a24`로 생겼으나 **실행 결과는 없다.**
- Run#18 이후의 새 XCTest 실행 근거는 없다 — 이 문서의 모든 시뮬레이터 실행 사실은 Run#18까지다.
- 기준 HEAD는 `cbf8f4b6`이나, 작성 중 병행 커밋 `f29f9a24`가 워크플로 2개를 추가해
  §2·§4를 그에 맞춰 갱신했다. 그 이후의 저장소 변경은 반영돼 있지 않다.
