# PlanFlow iOS E2E 최종 실행 구조

## 결정

Run #6에서 preflight는 통과했지만 mainstream, small, large, iPad, FLOW5의
`flutter test -d` 실행이 각각 1500/900/900/900/780초 watchdog에서 종료됐다.
이 증거를 기준으로 현재 device runner는 `CURRENT_RUNNER_UNSUITABLE`로
판정한다. `flutter drive`도 VM Service attach가 필요하고 한 번에 하나의
target만 받으므로 이 문제의 안정적인 해결책으로 채택하지 않는다.

최종 simulator 경로는 Flutter가 공식 문서로 제공하는 iOS
`integration_test` XCTest host다. `RunnerTests.m`의
`INTEGRATION_TEST_IOS_RUNNER(RunnerTests)`가 앱의 integration plugin 결과를
XCTest 결과와 `.xcresult`로 변환한다. 따라서 Widget extension을 테스트
대상으로 선택하거나 VM Service port를 발견할 필요가 없다.

## 단계와 경계

각 flow는 `scripts/ios/e2e_xctest_flow.sh`가 다음 순서로 실행한다.

```text
SIMULATOR_BOOT
  -> APP_BUILD (flutter config-only + xcodebuild build-for-testing)
  -> APP_INSTALL (simctl install Runner.app)
  -> APP_LAUNCH (simctl launch Runner bundle)
  -> APP_READY (simulator launch service probe)
  -> TEST_DRIVER_ATTACH (RunnerTests XCTest host)
  -> TEST_DISCOVERY (XCTest case/suite discovery)
  -> FLOW_EXECUTION (XCTest pass/fail)
  -> TEARDOWN
```

각 외부 명령은 `e2e_watchdog.sh`로 bounded되고, flow별 derived data와
`.xcresult`는 별도 artifact 디렉터리에 둔다. 실패 시 stage log와 기존
`simctl diagnose`, process snapshot, masking 진단은 유지한다. Windows에서는
shell contract까지만 검증할 수 있고, 실제 XCTest pass는 macOS Actions
evidence로만 판정한다.

## FLOW5 격리

FLOW5 Group A는 `test/ios_e2e_flow05_fake_test.dart`에서 일반
`flutter_test` host test로 실행한다. FakeAuthService와 순수 OAuth callback
분기만 검증하며 `E2E_REAL_BACKEND_TEST=0` 및 placeholder defines를 고정한다.
실제 Supabase Group B, 계정 secret, production project는 이 workflow에
전달하지 않는다. Group B는 post-release/manual recommended 범위다.

## Flow evidence 분류

Canonical physical-device classification is `PHYSICAL_DEVICE_REQUIRED`; the
flows below use `SIMULATOR_PARTIAL` where only the hardware-dependent tail
remains outside the simulator evidence.

| Flow | 실행 분류 | 이번 경로에서 증명하는 범위 | 실기기 한계 |
|---|---|---|---|
| FLOW1 cold start | SIMULATOR_FULL | 실제 Runner 부팅과 첫 라우트 | 없음 |
| FLOW2 schedule CRUD | SIMULATOR_FULL | fake 데이터 기반 CRUD UI/상태 | 실제 사진/음성 입력은 별도 |
| FLOW3 navigation | SIMULATOR_FULL | 라우팅과 순수 deep-link 계약 | 외부 앱에서의 완전한 전달은 별도 |
| FLOW4 notifications | SIMULATOR_PARTIAL | payload/route와 예약 로직 | 실제 알림센터 탭은 실기기 권장 |
| FLOW5 auth | HOST_TEST | fake 세션 상태와 OAuth 오류 분기 | non-production backend Group B는 별도 |
| FLOW6 voice/permission | SIMULATOR_PARTIAL | fake voice 상태와 permission 분기 | 실제 마이크/STT 품질은 실기기 |
| FLOW7 Widget/App Group | SIMULATOR_PARTIAL | 공유 payload와 계약 | WidgetKit 갱신/렌더 최종 확인은 실기기 권장 |
| FLOW8 resilience/a11y | SIMULATOR_LAYOUT | 레이아웃, text scale, resilience, a11y | 설정 앱 왕복/OS 정책은 실기기 권장 |

Mainstream은 FLOW1-4,6-8을 실행하고, small/large/iPad는 FLOW8만 실행해
대표 geometry를 확인한다. 전체 matrix는 flow body evidence가 없는
단일 25분 attach 대기가 아니라 flow별 stage evidence를 남긴다.

## 보호 범위

이 구조는 production `ios-release.yml`, privacy audit/signing, Runner
UsageDescription, Widget production target, GitHub Secrets, App Store
Connect/TestFlight, Build 16, Android를 변경하지 않는다. App Store upload
명령은 simulator E2E workflow에 없다.
