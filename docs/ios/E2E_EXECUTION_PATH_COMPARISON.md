# iOS integration_test 실행 경로 비교 (historical evidence + final decision)

> **최종 결정 (Run #6 이후): XCTest host로 전환**
>
> 이 문서의 아래 후보 비교와 Run #2~#6 관찰은 보존된 조사 기록이다. 최신
> 결정은 [E2E_XCTEST_ARCHITECTURE.md](E2E_XCTEST_ARCHITECTURE.md)에 있다.
> `flutter test -d`는 다섯 CI leg에서 preflight 뒤 VM-service 대기 상태로
> watchdog에 의해 종료되었고, `flutter drive`도 같은 VM-service attach와
> 단일 target 제약을 갖는다. 따라서 둘 다 최종 simulator runner가 아니다.
> 공식 XCTest host는 `RunnerTests`가 integration_test native plugin 결과를
> 기다리므로 그 attach 경계를 제거하고 `.xcresult`를 남긴다.

> **이 문서의 지위 — 아래 문구는 Run #6 이전의 역사적 기록이다.**
>
> 이 문서의 본문에는 Run #2~#5 시점의 비교·판단 자료가 보존되어 있다. Run #6
> 이후의 현재 실행 경로는 위에서 확정한 공식 XCTest host이며, 현재 workflow가
> 이를 사용한다. 아래의 이전 승격 조건과 후보 순위는 당시 결정 트리를
> 설명하기 위한 기록이지 현재 실행 승인이 아니다.
>
> `E2E_RUN3_DECISION_TREE.md`를 포함한 아래의 과거 기록은 당시의 후보 승격
> 조건을 설명할 뿐이며, 현재 XCTest 경로를 되돌리는 지시가 아니다.
>
> 새 프레임워크(Patrol 등) 도입은 이 조사의 범위가 아니며 후보에 넣지 않았다.

---

## 0. 조사 방법과 신뢰 범위 (먼저 읽을 것)

### 0.1 실측 기준

아래 표의 모든 "확인" 항목은 **로컬에 설치된 Flutter SDK 소스를 직접
Read/Grep한 결과**다. 추측으로 채운 칸은 전부 `미확인`으로 표기했다.

| 항목 | 값 |
|---|---|
| 실측에 사용한 로컬 SDK | `C:\src\flutter` — **Flutter 3.41.9** (stable, framework `00b0c91f06`, Dart 3.11.5) |
| CI가 실제로 쓰는 버전 | **3.47.2** (`.github/workflows/ios-simulator-e2e.yml` L154, L506) |
| 호스트 OS | Windows (이 조사 세션) |

### 0.2 ⚠️ 가장 중요한 한계 — 버전 갭

**로컬 SDK(3.41.9) ≠ CI SDK(3.47.2).** 이 문서의 모든 소스 인용은 3.41.9
기준이며, **3.47.2에서 동일하다는 것은 검증하지 않았다.**

- 이 조사가 다루는 코드 경로(`integration_test_device.dart`,
  `drive_service.dart`, `simulators.dart`의 로그 리더 배선)는 수년째
  구조가 안정적인 영역이라 두 버전 사이에 바뀌었을 가능성은 낮다고
  **판단**하지만, 이건 판단이지 실측이 아니다.
- 실행 단계로 승격될 때 **가장 먼저 할 일**: macOS 러너 또는 3.47.2가
  설치된 환경에서 아래 3개 grep을 재실행해 이 문서의 전제를 재확인한다.

```bash
# (1) flutter test -d 경로에 로그 리더가 없는가 — 0건이어야 이 문서가 유효
grep -rn "DeviceLogReader\|getLogReader" \
  "$FLUTTER_ROOT/packages/flutter_tools/lib/src/test/" \
  "$FLUTTER_ROOT/packages/flutter_tools/lib/src/commands/test.dart"

# (2) flutter drive 경로에 로그 리더가 있는가 — 매치되어야 후보 2가 유효
grep -n "getLogReader\|logLines.listen" \
  "$FLUTTER_ROOT/packages/flutter_tools/lib/src/drive/drive_service.dart"

# (3) iOS 시뮬레이터 로그 리더가 log stream을 쓰는가 — 후보 5의 근거
grep -n "launchDeviceUnifiedLogging" -A 40 \
  "$FLUTTER_ROOT/packages/flutter_tools/lib/src/ios/simulators.dart"
```

### 0.3 그 외 미확인 항목 (정직 고백)

| # | 미확인 항목 | 왜 확인 못 했나 |
|---|---|---|
| U1 | 3.47.2에서 동일한 코드 구조인지 | 로컬에 3.41.9만 있음 (§0.2) |
| U2 | Dart `print()`가 iOS에서 실제로 unified logging(os_log)에 도달하는지 | 엔진(C++/ObjC) 소스가 로컬에 없음. **간접 근거는 강함** — `_IOSSimulatorLogReader`의 predicate가 `senderImagePath ENDSWITH "/Flutter"`를 명시적으로 포함하고(`simulators.dart:771`), `flutter run`이 iOS 시뮬레이터에서 Dart print를 보여주는 것이 바로 이 리더를 통해서다. 그러나 이 세션에서 macOS 실행으로 직접 관측하지는 못했다. |
| U3 | 각 경로의 실제 벽시계 비용(초) | macOS 러너에서 실행해봐야 알 수 있음. 표의 비용 칸은 **현재 워크플로 주석에 기록된 실측 추정치**(빌드 약 400s, flow 파일당 약 150s — 워크플로 L296~L305)에서 유도한 상대 비교일 뿐 절대값 측정이 아님 |
| U4 | 후보 4(XCTest)가 이 앱에서 실제로 빌드·통과하는지 | 아래 §5.4는 Run #6 이전 스냅샷이다. 현재 배선은 추가됐지만 Windows에서는 macOS의 Pod/XCTest 실행을 검증할 수 없다 |
| U5 | `flutter drive`가 iOS 시뮬레이터에서 hang 없이 도는지 | 현재 hang의 근본원인이 미확정이므로, 경로를 바꾸면 hang이 사라진다는 보장 자체가 없음 (§7.2) |

### 0.4 실측한 소스 파일 목록

| 파일 | 확인한 내용 |
|---|---|
| `flutter_tools/lib/src/test/integration_test_device.dart` (전체 156줄) | L18 `kIntegrationTestExtension`, L110–113 extension 이벤트 전용 구독, L75 주석 |
| `flutter_tools/lib/src/test/` 디렉터리 전체 + `commands/test.dart` | `DeviceLogReader`/`getLogReader` grep → **0건** |
| `flutter_tools/lib/src/drive/drive_service.dart` | L200 `start()`→`reuseApplication()`, **L233–235 로그 리더 배선**, L263 `_processUtils.stream` |
| `flutter_tools/lib/src/commands/drive.dart` | L102–109 `--driver` 옵션, L284–298 driver 파일 필수, L345/L363 서비스 호출, L352 `mainPath: targetFile`(**단수**), L484–523 driver 경로 유도 |
| `flutter_tools/lib/src/commands/test.dart` | L318 `_testFileUris`, L346 `argResults!.rest` → **다중 파일 허용** |
| `flutter_tools/lib/src/ios/simulators.dart` | L613–615 `getLogReader`→`_IOSSimulatorLogReader`, L758–793 `launchDeviceUnifiedLogging`, L766–779 NSPredicate 전문 |
| `flutter_tools/lib/src/commands/build_ios.dart` | L47–49 `--simulator` 플래그, L65, L957–966 |
| `packages/integration_test/ios/.../include/IntegrationTestIosTest.h` | `INTEGRATION_TEST_IOS_RUNNER` 매크로 전문 (Objective-C 전용) |
| `packages/integration_test/README.md` L268–340 | iOS XCTest 공식 절차 |
| (저장소) `.github/workflows/ios-simulator-e2e.yml` | L154/L506 버전, L248–259 flow 파일 배치, L325–345 실행 스텝 |
| (저장소) `scripts/ios/e2e_diagnose_hang.sh` | L67 `LOG_SHOW_WINDOW='10m'`, L145 `log show`(사후 회수) |
| (저장소) `scripts/ios/e2e_watchdog.sh` | 124/125 exit 계약, bash fallback |
| (저장소) `ios/Podfile`, `ios/Runner.xcodeproj/project.pbxproj`, `ios/RunnerTests/RunnerTests.swift` | RunnerTests 배선 상태 (§5.4) |
| (저장소) `test_driver/` | **디렉터리 자체가 없음** (후보 2의 선결 조건) |

---

## 1. 현재 상태 요약

```bash
# .github/workflows/ios-simulator-e2e.yml L347–369 (Wave3 이후, 콘솔 tee 제거됨)
verbose_log_file="$RUNNER_TEMP/e2e-verbose-${{ matrix.category }}.log"
verbose_tail_file="$artifact_dir/flow-test-verbose-tail-${{ matrix.category }}.log"

E2E_WATCHDOG_LOG_FILE="$verbose_log_file" \
E2E_WATCHDOG_HEARTBEAT_INTERVAL="$heartbeat_interval_seconds" \
E2E_WATCHDOG_TAIL_FILE="$verbose_tail_file" \
bash scripts/ios/e2e_watchdog.sh "$watchdog_seconds" \
  flutter test \
  --verbose \
  "${flow_files[@]}" \        # mainstream=7개, small/large/ipad=1개(flow08)
  -d "${{ steps.boot.outputs.udid }}" \
  --dart-define=E2E_MODE=1 ...
test_status=$?
```

- flow 파일 8개 (`flow01`~`flow08`), flow05는 별도 job
- `--verbose` **이미 적용 중** — 그런데도 앱 로그가 안 보인다는 것이 이 조사의 출발점
- Wave3부터 `2>&1 | tee "$artifact_dir/flow-test-output.log"`는 **제거**됐다. 자식 stdout/stderr는
  `scripts/ios/e2e_watchdog.sh`의 `E2E_WATCHDOG_LOG_FILE` 리다이렉션을 거쳐
  `$RUNNER_TEMP/e2e-verbose-<category>.log`(원본, 마스킹 없음, 아티팩트 업로드 대상 아님)에 기록되고,
  `E2E_WATCHDOG_TAIL_FILE`로 지정한 `$artifact_dir/flow-test-verbose-tail-<category>.log`(마스킹된 tail,
  아티팩트에 업로드됨)에 요약이 남는다(자세한 배경은 `docs/ios/E2E_RUN3_DECISION_TREE.md` 참조).
- 실패/타임아웃 시에만 `e2e_diagnose_hang.sh`가 `log show --last 10m`으로 **사후** 회수

### 1.1 이미 확정된 근본 사실 (P5에서 확정, 이번에 재검증)

`flutter test -d <UDID>` 경로는 **앱 프로세스 stdout을 CI 로그로 포워딩하는
채널이 아예 없다.** 버퍼링 문제가 아니라 배선이 없다.

`integration_test_device.dart` L110–113 — 구독하는 것은 오직 하나:

```dart
await vmService.service.streamListen(vm_service.EventStreams.kExtension);
final Stream<String> remoteMessages = vmService.service.onExtensionEvent
    .where((vm_service.Event e) => e.extensionKind == kIntegrationTestExtension)
    .map((vm_service.Event e) => e.extensionData!.data[kIntegrationTestData] as String);
```

그리고 L75 주석이 그 의도를 명시한다:

```dart
// No need to set up the log reader because the logs are captured and
// streamed to the package:test_core runner.
```

**이 "logs"는 `package:integration_test`의 결과 프로토콜(pass/fail JSON)을
가리키는 것이지 앱 코드의 임의 `print()`가 아니다.** 그 증거가 grep 0건이다:

```
grep -rn "DeviceLogReader|getLogReader" lib/src/test/ lib/src/commands/test.dart
→ 0 matches
```

즉 `--verbose`를 아무리 붙여도 그건 **flutter tool 자신의** 로그를 늘릴 뿐,
시뮬레이터 안 앱 프로세스의 출력은 원천적으로 안 나온다.

---

## 2. 후보 경로 5종 — 종합 비교표

| | ①앱 로그 가시성 | ②결정성 (hang 진단) | ③CI 배선 비용 | ④전환 리스크 (8개 flow 호환성) |
|---|---|---|---|---|
| **1. 현재 `flutter test -d`** | ❌ **없음** — 포워딩 채널 부재(§1.1, grep 0건) | △ tool 로그만. hang 시 "어느 flow의 어디"를 모름 | — (기준선) | — (기준선) |
| **2. `flutter drive`** | ✅ **있음** — `drive_service.dart:233-235`가 `DeviceLogReader` 부착 + `printStatus`로 CI stdout에 흘림 | ◎ 앱 로그가 실시간으로 CI 로그에 → 마지막 체크포인트 즉시 식별 | **대** — `test_driver/` 신설 + 워크플로 실행 스텝 재작성 + **파일당 1회 호출**(단수 target) | **중~대** — 테스트 파일 자체는 무수정이나 실행 단위가 7→7회 분리, 빌드 캐시/타이밍 특성이 달라짐 |
| **3. 수동 조합 (`build ios --simulator` + `simctl install/launch` + attach)** | ✅ 있음 (attach가 로그 리더 부착) | ○ 단계가 쪼개져 어디서 멈췄는지 명확 | **매우 대** — 테스트 하네스/결과 수집을 직접 배선해야 함 | **대** — `package:test` 러너 계약을 스스로 재구현하는 셈 |
| **4. Xcode/XCTest host** | ✅ 있음 — `xcodebuild` 출력에 NSLog/os_log 직결 | ◎ XCTest 타임아웃·`.xcresult` 번들·스크린샷 첨부 | **대** — Podfile 임베드 + RunnerTests Obj-C 전환 + build-for-testing 2단계 | **중** — 8개 파일을 1개 `--config-only` 타깃으로 합치는 진입점 필요 |
| **5. 사이드카 `simctl spawn log stream` (경로 유지)** | ✅ **있음** — Flutter 자신이 쓰는 것과 **동일한 메커니즘**을 병행 실행 | ◎ 현재 경로 그대로 + 실시간 앱 로그 | **소** — 워크플로에 백그라운드 스텝 1개 + 아티팩트 1개 | **없음** — 실행 경로·테스트 파일 **전부 무변경** |

**범례:** ◎ 매우 좋음 / ✅ 있음 / ○ 보통 / △ 미흡 / ❌ 없음

---

## 3. 후보 2 — `flutter drive` 상세

### 3.1 로그 포워딩이 실제로 있다 (핵심 대비점)

`flutter_tools/lib/src/drive/drive_service.dart` L232–235:

```dart
_vmService = await _vmServiceConnector(uri, device: _device, logger: _logger);
final DeviceLogReader logReader = await device.getLogReader(app: _applicationPackage);
logReader.logLines.listen(_logger.printStatus);   // ← CI stdout으로 직결
await logReader.provideVmService(_vmService);
```

이 `reuseApplication()`은 `start()` 마지막 줄(L200)에서 호출되므로 **정상
경로에서 항상 실행**된다. `drive.dart` L345가 `driverService.start(...)`를
부른다.

iOS 시뮬레이터에서 `device.getLogReader()`가 무엇을 반환하는지도 확인했다 —
`simulators.dart` L613–615 → `_IOSSimulatorLogReader`(L812) →
`launchDeviceUnifiedLogging()`(L758). 즉 **이것이 `flutter test -d`와
`flutter drive`를 가르는 유일하고 결정적인 차이**다.

### 3.2 선결 조건 — `test_driver/`가 없다

`drive.dart` L284–298: driver 파일이 없으면 `throwToolExit('Test file not found')`.
L484–523에서 `--driver` 미지정 시 `test_driver/<name>_test.dart`를 유도한다.

**실측: PlanFlow에 `test_driver/` 디렉터리가 존재하지 않는다.**
표준 3줄 드라이버를 신설해야 한다:

```dart
// test_driver/integration_test.dart (미존재 — 신설 필요)
import 'package:integration_test/integration_test_driver.dart';
Future<void> main() => integrationDriver();
```

### 3.3 ⚠️ 비용의 진짜 원인 — 단수 target

이것이 후보 2의 가장 큰 실무 비용이며 표의 "대"의 근거다.

| | 파일 인자 | 소스 근거 |
|---|---|---|
| `flutter test` | **다중 허용** | `test.dart` L346 `argResults!.rest.map(...)`, L318 `_testFileUris` (Set) |
| `flutter drive` | **단수** | `drive.dart` L352 `mainPath: targetFile` (String, 단수) |

현재 mainstream job은 **7개 flow 파일을 1회 호출**로 돌린다(워크플로
L248–254). `flutter drive`로 바꾸면 **7회 호출**이 되고, 각 호출이
`start()`에서 앱을 빌드·기동한다.

워크플로 주석(L296–305)에 기록된 실측 추정치 — 빌드 약 400s, flow 파일당
약 150s, mainstream 예산 1500s — 를 그대로 적용하면:

- 현재: `400 + 7×150 = 1450s`
- drive 순진 적용: `7 × (빌드 + 150)` → 빌드 비용이 7배로 곱해짐

완화책은 있다: `drive.dart` L361의 `--use-existing-app`(`_kUseExistingApp`)
으로 첫 회만 빌드·기동하고 이후 `reuseApplication()`으로 붙는 것.
다만 이건 **앱을 미리 띄우고 VM Service URI를 직접 관리**해야 해서
후보 3(수동 조합)에 가까워지고, 배선 복잡도가 다시 올라간다.
(이 완화책의 실제 동작은 **U3/미확인** — 측정 안 함.)

---

## 4. 후보 3 — 수동 조합 상세

`flutter build ios --simulator`는 실재한다(`build_ios.dart` L47–49):

```
'Build for the iOS simulator instead of the device.'
```

README(L289–293)가 제시하는 형태는 오히려 `--config-only`다:

```sh
flutter build ios --config-only integration_test/foo_test.dart
```

**로그 가시성**은 확보된다(attach 시 로그 리더 부착 — 후보 2와 동일 메커니즘).
그러나 **`package:test` 러너와 앱 사이의 결과 프로토콜 중계**(=
`integration_test_device.dart`가 해주던 일)를 직접 배선해야 한다. 그
프로토콜은 `Flutter.IntegrationTest` extension 이벤트 왕복(L110–128)이며,
이를 손으로 재구현하는 것은 이 조사의 목적(로그 가시성 확보)에 비해
투입 대비 효용이 나쁘다.

**결론: 후보 4가 이 경로의 "지원되는 버전"이므로, 후보 3을 직접 선택할
이유가 없다.** 후보 3은 비교를 위해 기재하며 권고하지 않는다.

---

## 5. 후보 4 — Xcode/XCTest host 상세

### 5.1 공식 지원됨 (확인)

`packages/integration_test/ios/integration_test/Sources/integration_test/include/IntegrationTestIosTest.h`에
`INTEGRATION_TEST_IOS_RUNNER(__test_class)` 매크로가 실재한다. 이 매크로는
Dart 테스트 하나하나를 **동적으로 Objective-C 메서드로 생성**해 XCTest
결과로 보고하고, 스크린샷이 있으면 `XCTAttachment`로 첨부한다:

```objective-c
+ (NSArray<NSInvocation *> *)testInvocations {
  FLTIntegrationTestRunner *integrationTestRunner = [[FLTIntegrationTestRunner alloc] init];
  ...
  [integrationTestRunner testIntegrationTestWithResults:^(SEL testSelector, BOOL success, NSString *failureMessage) {
    IMP assertImplementation = imp_implementationWithBlock(^(id _self) {
      XCTAssertTrue(success, @"%@", failureMessage);
    });
    class_addMethod(self, testSelector, assertImplementation, "v@:");
    ...
```

### 5.2 공식 절차 (README L268–340)

1. Xcode에서 `RunnerTests` Unit Testing Bundle 타깃 생성 (**언어는 Objective-C**)
2. Podfile에 `Runner` 안으로 임베드:
   ```ruby
   target 'Runner' do
     target 'RunnerTests' do
       inherit! :search_paths
     end
   end
   ```
3. `RunnerTests.m`:
   ```objective-c
   @import XCTest;
   @import integration_test;
   INTEGRATION_TEST_IOS_RUNNER(RunnerTests)
   ```
4. `flutter build ios --config-only integration_test/foo_test.dart`
5. `xcodebuild build-for-testing` → `xcodebuild test-without-building -destination id=<UDID>`

### 5.3 로그 가시성

XCTest 러너가 **호스트 프로세스로서** 앱을 in-process 구동하므로
`NSLog`/`os_log` 출력이 `xcodebuild` stdout에 직접 나온다.
`IntegrationTestIosTest.m`이 직접 `NSLog(@"==== Test Results ====")`를
찍는 것이 그 증거다. 추가로 `.xcresult` 번들이 생겨 사후 분석 자산이
현재보다 훨씬 풍부하다.

### 5.4 ⚠️ Run #6 이전 저장소 배선 스냅샷 (historical)

> 아래 표는 XCTest 배선을 추가하기 전의 상태를 기록한 것이다. 현재의 배선
> 결과와 실행 단계는 `E2E_XCTEST_ARCHITECTURE.md` 및 workflow를 기준으로 한다.

| 항목 | 실측 결과 | 필요 조치 |
|---|---|---|
| `ios/RunnerTests/` 디렉터리 | ✅ 존재 | — |
| Xcode 타깃 | ✅ 존재 — `project.pbxproj`에 `RunnerTests` 참조 **19건** | — |
| `RunnerTests.swift` | ⚠️ **빈 스텁** — `testExample()` 하나뿐, 매크로 미사용 | Obj-C `RunnerTests.m`로 전환 필요 (**매크로가 Obj-C 전용** — Swift에서 직접 사용 불가) |
| `ios/Podfile` 임베드 | ❌ **없음** — `target 'Runner' do`(L31)만 있고 중첩 `target 'RunnerTests'` 없음 | Podfile 수정 + `pod install` |
| 8개 flow 진입점 | ❌ 없음 | `--config-only`가 단일 타깃이므로 8개를 묶는 진입 dart 파일 필요 |

즉 **"RunnerTests가 이미 있다"는 것은 당시에는 껍데기만 있다는 뜻**이었다.
위 표는 현재 상태의 설명이 아니며, 실제 macOS 빌드·통과 여부는 여전히
GitHub macOS 실행에서 확인해야 한다.

---

## 6. 후보 5 — 사이드카 `log stream` (경로 무변경 절충안)

### 6.1 왜 이게 유력한가 — Flutter 자신이 쓰는 바로 그 방법

`simulators.dart` L758–793, `launchDeviceUnifiedLogging()`:

```dart
return globals.processUtils.start(<String>[
  ...globals.xcode!.xcrunCommand(),
  'simctl', 'spawn', device.id, 'log', 'stream',
  '--style', 'json',
  '--predicate', predicate,
]);
```

**즉 후보 2(`flutter drive`)가 제공하는 로그 가시성의 실체가 바로 이
`simctl spawn log stream`이다.** 후보 5는 그 동일한 프로세스를 워크플로가
직접 띄우는 것이므로, **실행 경로를 하나도 바꾸지 않고 후보 2의 핵심
이득만 가져온다.**

### 6.2 재사용할 NSPredicate (L766–779 원문 그대로)

직접 predicate를 발명하지 말 것 — Flutter가 이미 튜닝해 둔 것을 쓴다:

```
eventType = logEvent
AND processImagePath ENDSWITH "<appName>"
AND (senderImagePath ENDSWITH "/Flutter"
     OR senderImagePath ENDSWITH "/libswiftCore.dylib"
     OR processImageUUID == senderImageUUID)
AND NOT(eventMessage CONTAINS ": could not find icon for representation -> com.apple.")
AND NOT(eventMessage BEGINSWITH "assertion failed: ")
AND NOT(eventMessage CONTAINS " libxpc.dylib ")
```

`senderImagePath ENDSWITH "/Flutter"` 절이 **엔진이 중계하는 Dart 측 출력**을
잡는 부분이다(U2 참조 — 간접 근거이며 macOS 실측 미수행).

### 6.3 현재 진단과의 차이 — 이게 핵심

`e2e_diagnose_hang.sh`는 이미 unified logging을 쓰고 있다. 그러나 **성격이 다르다**:

| | 기존 `e2e_diagnose_hang.sh` L145 | 후보 5 사이드카 |
|---|---|---|
| 명령 | `log show --last 10m --style compact` | `log stream --style json --predicate ...` |
| 시점 | **사후** (테스트 종료/타임아웃 후) | **실시간** (테스트 진행 중 계속) |
| 트리거 | `steps.run_tests.outcome != 'success'`일 때만 | 항상 |
| 범위 | 최근 **10분**(`LOG_SHOW_WINDOW='10m'`, L67) | 부팅~종료 전 구간 |
| 필터 | 없음 (시스템 로그 전체) | Flutter/앱 한정 predicate |
| 한계 | **watchdog가 SIGKILL로 앱을 죽인 뒤** 찍으므로, 10분보다 먼저 멈춘 지점은 창 밖으로 밀려날 수 있음 | 멈춘 순간의 마지막 줄이 그대로 남음 |

mainstream watchdog가 **1500초(25분)** 인데 사후 회수 창이 **10분**이라는
점이 중요하다 — 빌드 직후(약 400s 시점) 멈춘 경우, 25분 뒤 찍는
`log show --last 10m`은 **그 시점을 이미 지나쳐 있다.** 실시간 스트림은
이 구조적 사각지대가 없다.

### 6.4 배선 스케치 (설계 메모 — 이번에 구현하지 않음)

- 시뮬레이터 boot 직후 ~ `flutter test` 시작 전에 백그라운드로 기동
- 출력은 `$artifact_dir/simulator-log-stream.log`
- **`e2e_mask_secrets.sh`를 반드시 경유** (기존 `log show` 경로가 지키는 규약과 동일 — 마스킹 미가용 시 쓰지 않고 SKIP)
- 종료: `always()` 스텝에서 PID로 정리. **`Stop-Process`/`taskkill`류 광범위 종료 금지**, 자기가 띄운 PID만
- 실패 시 fail-open (진단 보조가 본 테스트를 깨뜨리면 안 됨 — `e2e_diagnose_hang.sh`가 이미 "best-effort by contract, always exits zero"로 확립한 규약 재사용)

**남은 위험(정직 고백):** `log stream`은 장시간 돌면 출력이 커진다. 아티팩트
크기 상한과 러너 디스크를 고려한 회전/절단이 필요하며, 그 임계값은
**실측 없이 정하면 안 된다**(안전 게이트 임계값을 추측으로 정해 문제가 된
전례가 이 저장소 anti-patterns에 이미 있다).

---

## 7. Run #6 이전 권고 (historical)

> 이 절의 후보 순위와 승격 조건은 Run #6 이전 기록이다. 현재 실행 경로는
> 문서 상단의 최종 결정과 `E2E_XCTEST_ARCHITECTURE.md`를 따른다.

> 다시 강조: `E2E_RUN3_DECISION_TREE.md`의 **분기 (iii)** 에서만 유효하다.

### 7.1 권고 순서

**1순위 — 후보 5 (사이드카 `log stream`).**
근거: ④전환 리스크가 **유일하게 "없음"**이다. 실행 경로·8개 테스트 파일·
watchdog·exit code 계약 전부 무변경이고, ③배선 비용도 "소"다. 그러면서
①앱 로그 가시성은 후보 2와 **동일한 메커니즘**으로 확보된다(§6.1).
현재 hang의 근본원인이 아직 미확정인 상황에서 **변수를 하나만 추가하는**
선택이라 진단 목적에도 맞다.

**2순위 — 후보 4 (XCTest).**
근거: 가장 풍부한 진단 자산(`.xcresult`, XCTest 타임아웃, 스크린샷 첨부)을
주고 공식 지원 경로다. 다만 §5.4의 배선 4건이 선행되어야 하고, Obj-C
전환과 8-파일 진입점 문제가 남는다. **후보 5로 로그를 확보했는데도 원인이
안 잡힐 때** 다음 카드로 쓴다.

**3순위 — 후보 2 (`flutter drive`).**
근거: 로그 가시성은 확실하나(§3.1) **단수 target 때문에 빌드 비용이 파일
수만큼 곱해진다**(§3.3). 후보 5가 같은 로그를 비용 없이 주므로, 굳이
이쪽을 택할 이유가 약하다.

**권고하지 않음 — 후보 3.**
후보 4가 같은 것의 지원되는 버전이다(§4).

**현상 유지(후보 1)** 는 분기 (i)/(ii)에서의 기본값이다.

### 7.2 ⚠️ 권고에 딸린 필수 경고

**어떤 경로도 hang을 고친다고 보장하지 않는다.** 이 문서가 비교한 것은
**"멈췄을 때 어디서 멈췄는지 볼 수 있는가"**이지 **"안 멈추는가"**가 아니다.
경로를 바꾼 뒤 hang이 사라지면 그건 원인 해결이 아니라 **타이밍이 바뀌어
증상이 가려진 것**일 수 있다(U5). 경로 전환을 원인 규명의 대체물로 쓰지 말 것.

이것이 1순위를 후보 5로 둔 또 하나의 이유다 — **실행 경로를 안 바꾸므로,
로그를 얻어도 "경로가 바뀌어서 증상이 달라진 것 아니냐"는 교란이 없다.**

---

## 8. 한 줄 요약

`flutter test -d`에 앱 로그가 없는 것은 버그가 아니라 **설계상 로그 리더를
안 붙이는 것**이고(`integration_test_device.dart` L75 + grep 0건),
`flutter drive`가 보여주는 것은 결국 `xcrun simctl spawn <udid> log stream`
이다(`simulators.dart` L758–793). 그렇다면 **경로를 바꾸지 말고 그
`log stream`만 사이드카로 병행**하는 것이 가장 싸고 가장 안전하다.
