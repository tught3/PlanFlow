# PlanFlow iOS 출시 준비 기준

## 최종 판정 (iOS Release Closure Phase)

> **`APP_STORE_BLOCKED`**
> 차단 사유는 **단 하나**: `R1_UNDETERMINED` — 프로덕션 `Info.plist` 상태에서
> 앱이 실제로 부팅·생존한다는 **런타임 증거가 0건**이다.
> 상세: [`docs/ios/R1-admob-launch-risk.md`](R1-admob-launch-risk.md)
>
> **해제 조건**: `.github/workflows/ios-adsdk-launch-probe.yml`를
> `workflow_dispatch`로 1회 실행해 **세 스테이지가 모두** 아래를 만족해야 한다:
> `PROD_PLIST_APP_ALIVE` = PASS, `PROD_PLIST_ADS_INIT_REACHED` = PASS,
> `PROD_PLIST_NO_CRASH` = PASS. 이때만
> **`APP_STORE_READY_PENDING_USER_CONFIGURATION`으로 전환**되고,
> 그 시점부터 남는 것은 전부 App Store Connect 콘솔 입력(§남은 사용자 액션)뿐이다.
>
> **`PROD_PLIST_ADS_INIT_REACHED`가 왜 필수인가(리뷰 HIGH-1).** 생존(PASS)만으로는
> R1이 없다는 결론이 나오지 않는다 — 앱이 살아남은 이유가 (a) R1이 없어서인지
> (b) 조기 return 때문에 **R1 코드에 도달조차 못 해서**인지 구분되지 않기 때문이다.
> 도달이 입증되지 않으면(`UNDETERMINED`) 판정은 `R1_UNDETERMINED`로 **그대로 유지**된다.
> 상세와 이 스테이지의 실측된 한계는
> [`docs/ios/R1-admob-launch-risk.md`](R1-admob-launch-risk.md) §4-3.

### 왜 `APP_STORE_READY_PENDING_USER_CONFIGURATION`이 아닌가

"PENDING_USER_CONFIGURATION"은 *제품은 동작하는데 콘솔 값이 안 채워진 상태*를 뜻한다.
현재는 그 전제가 성립하지 않는다 — **이 앱이 iOS에서 출시 형상 그대로 부팅에 성공하는 것을
아무도 관측한 적이 없다.**

- 시뮬레이터 XCTest는 증거가 아니다. `scripts/ios/e2e_xctest_flow.sh:263`의 APP_LAUNCH는
  `simctl launch`의 spawn 종료코드만 보고, `scripts/ios/e2e_xctest_flow.sh:281`의 APP_READY는
  `scripts/ios/e2e_xctest_flow.sh:283`에서 시뮬레이터 launchd 서비스 생존만 확인한 뒤 앱을
  종료한다 — **앱 프로세스 생존을 한 번도 묻지 않는다.** 게다가
  `scripts/ios/e2e_xctest_flow.sh:121`이 테스트용 `GADApplicationIdentifier`를 주입해
  **프로덕션 plist 형상도 아니었다.**
- TestFlight 파이프라인(Build 16까지 PASS)은 서명·업로드·ingestion의 증거이지
  런타임 부팅의 증거가 아니다.
- FLOW1~FLOW8은 `integration_test/`에 코드가 실재하지만 **실행 증거 0건**이다
  (`docs/ios/XCTEST_STOP_LOSS_DECISION.md` §2.2).

이 문서는 이미 아래 기준을 스스로 선언하고 있다(§기능 분류):
`IMPLEMENTED`와 `LIVE VALIDATED`를 구분하며 **증거가 없으면 iOS 출시 PASS가 아니다.**
그 기준을 R1에만 예외 적용할 근거가 없다.

### 왜 `APP_STORE_BLOCKED`가 과하지 않은가

차단 비용이 작기 때문이다. 해제에 필요한 것은 **수동 워크플로 1회 실행(≤40분)**이며,
`R1_CLEARED`가 나오면 그 자리에서 판정이 올라간다. 반대로 이 확인을 건너뛰고 제출했을 때의
실패 모드는 **런치 크래시 → Guideline 2.1 리젝 → Build 17 재빌드**로 훨씬 비싸다.

---

## Physical iPhone 판정: `REQUIRED`

**단, 요건이 걸리는 시점은 "제출 준비 완료"가 아니라 "공개 배포 승인"이다.**
실기기 없이도 (a) App Store Connect 메타데이터 입력, (b) TestFlight 내부 테스트 빌드 업로드,
(c) R1 프로브 실행은 모두 가능하다. 실기기가 필수가 되는 지점은 **일반 사용자에게 공개하는
결정**이다.

### 근거 1 — 시뮬레이터로 대체 불가능한 항목이 릴리스 영향도를 갖는다

| 항목 | 시뮬레이터 한계 | 릴리스 영향 |
|---|---|---|
| 알림 실제 탭 라우팅 | `docs/ios/SIMULATOR_QA_MATRIX.md`가 이 항목을 `PHYSICAL_DEVICE_REQUIRED`로 분류 | 알림이 핵심 기능(역산 알림)이므로 탭 경로가 깨지면 제품 가치 훼손 |
| 로컬 알림 딜리버리 타이밍 | 같은 문서에서 `SIMULATOR_PARTIAL` — 백그라운드 실행 정책이 실기기와 다름 | 동일 |
| 홈 화면 위젯 렌더 | WidgetKit timeline 갱신 주기는 실기기에서만 실제 동작 | 2군 기능, 리젝 요인은 아니나 심사 스크린샷/설명과 불일치 위험 |
| ATT 프롬프트 | `ios/Runner/Info.plist:28`에 `NSUserTrackingUsageDescription`이 있으나 실제 트리거 코드 부재(APP_STORE_READINESS 항목 10·12) | 문구-동작 불일치는 심사 지적 대상 |
| 음성 STT 실품질 / 마이크 UX | 시뮬레이터 오디오 입력은 호스트 마이크 경유로 실기기와 동등하지 않음 | 1군 핵심 기능 |
| AdMob/UMP 네이티브 슬라이스 | 시뮬레이터는 simulator 슬라이스, 실기기는 device 슬라이스 — SDK 초기화 동작이 다를 수 있음 | **R1이 시뮬레이터에서 CLEAR돼도 실기기 확인이 남는다**(R1 문서 §6-1) |

### 근거 2 — 현재 end-to-end 실행 증거가 문자 그대로 0건이다

FLOW1~FLOW8 전부 `NOT_VERIFIED`이고 XCTest 경로는 stop-loss로 중단됐다
(`docs/ios/XCTEST_STOP_LOSS_DECISION.md`). 즉 **시뮬레이터 경로에서도 확보된 통합 증거가 없다.**
이 상태에서 실기기까지 생략하면 "동작 확인 0"인 앱을 공개하는 것이 된다.

### 근거 3 — R1이 미확정이다

프로브가 `R1_CONFIRMED_BLOCKER`를 내면 실기기 재확인이 필수가 되고,
`R1_CLEARED`를 내도 근거 1의 마지막 행 때문에 실기기 확인이 남는다.
**어느 결과가 나와도 실기기 요건은 사라지지 않는다.**

---

## QA 증거 요약표

"근거 있음"으로 인정하는 것은 **CI에서 실제로 실행되는 것**뿐이다.
현재 그 조건을 만족하는 것은 **2가지**다.

### 실행 증거가 있는 것

| 대상 | 실행 위치 | 성격 | 판정 |
|---|---|---|---|
| `test/ios_phase2_contract_test.dart` 외 3개(`ios_phase3_native` / `ios_phase4_identity` / `ios_release`) | `.github/workflows/ios-readiness.yml:89-94` | 텍스트·파일 대조 계약 테스트 (제품 런타임 검증 아님) | `PARTIALLY_VERIFIED` |
| `test/ios_e2e_flow05_fake_test.dart` | `.github/workflows/ios-simulator-e2e.yml:126` | host fake (시뮬레이터 밖, 호스트 VM) | `PARTIALLY_VERIFIED` |

`.github/workflows/ios-readiness.yml:84`의 `flutter analyze`와 unsigned `xcodebuild` Runner
빌드도 실행된다 — 즉 **컴파일 가능성**은 검증된다(런타임 동작은 아님).

### 기능별 판정

| 기능 | 판정 | 릴리스 분류 | 근거 |
|---|---|---|---|
| 컴파일·서명·IPA 생성·TestFlight ingestion | `VERIFIED` | — | Build 16까지 파이프라인 PASS(확정 사실) |
| iOS 네이티브 계약(plist 키·identity·deeplink 문자열) | `VERIFIED` | — | `.github/workflows/ios-readiness.yml:89-94` 계약 테스트 |
| **앱 런치 생존(프로덕션 plist)** | **`NOT_VERIFIED`** | **`RELEASE_BLOCKER`** | R1. 프로브 미실행 |
| 인증/세션(FLOW5) | `PARTIALLY_VERIFIED` | `RELEASE_BLOCKER` | host fake만 실행(`.github/workflows/ios-simulator-e2e.yml:126`), 실백엔드·시뮬레이터 실행 없음 |
| 콜드스타트(FLOW1) | `NOT_VERIFIED` | `RELEASE_BLOCKER` | 코드는 `integration_test/flow01_cold_start_test.dart`에 있으나 미실행. 세션복원 시나리오는 `integration_test/flow01_cold_start_test.dart:90`에서 영구 `skip: true` |
| 일정 CRUD(FLOW2) | `NOT_VERIFIED` | `RELEASE_BLOCKER` | 미실행 |
| 라우팅·딥링크(FLOW3) | `NOT_VERIFIED` | `RELEASE_BLOCKER` | 미실행 |
| 알림(FLOW4) | `NOT_VERIFIED` | `RELEASE_BLOCKER` | 미실행 + 실제 탭은 실기기 필요 |
| 음성·권한(FLOW6) | `NOT_VERIFIED` | `RELEASE_BLOCKER` | 미실행 + 실품질은 실기기 필요 |
| 위젯·App Group(FLOW7) | `NOT_VERIFIED` | `POST_RELEASE_RECOMMENDED` | 미실행. 2군 기능 |
| 복원력·접근성(FLOW8) | `NOT_VERIFIED` | `POST_RELEASE_RECOMMENDED` | 미실행 |
| 광고 보상 흐름(iOS) | `NOT_VERIFIED` | `OPTIONAL` | iOS 광고 단위 ID가 Remote Config에 부재(`lib/services/remote_config_service.dart:125`는 android 키뿐) → iOS 광고는 현재 기능적으로 비활성 |
| 그룹 달력 위젯(iOS) | `NOT_VERIFIED` | `OPTIONAL` | Android 전용, iOS 미구현(§현재 기능 상태) |
| 전체 `test/` 스위트(157개) | `NOT_VERIFIED` | `POST_RELEASE_RECOMMENDED` | 측정 수단(`.github/workflows/flutter-test-baseline.yml`)은 생겼으나 `workflow_dispatch` 전용 + `continue-on-error` — **실행 결과 없음** |

> 표의 `RELEASE_BLOCKER`는 "이 항목이 검증되지 않으면 공개 배포하면 안 된다"는 뜻이며,
> 최상단 `APP_STORE_BLOCKED` 판정의 **단일 차단 사유는 R1 하나**다. 나머지
> `RELEASE_BLOCKER` 행들은 실기기 QA(위 `REQUIRED` 판정)로 해소할 대상이다.

---

## 남은 사용자 액션 (우선순위 순)

AI가 대신할 수 없고 **사용자만 할 수 있는 것**만 남겼다.

| # | 액션 | 왜 사용자만 가능한가 | 막고 있는 것 |
|---|---|---|---|
| 1 | **R1 프로브 1회 실행** — GitHub Actions → `iOS AdSDK launch probe (production plist)` → `Run workflow` | macOS runner 필요 + 이 세션 호스트는 Windows, `gh` 미인증 | `APP_STORE_BLOCKED` 해제 |
| 2 | Privacy Policy URL / Support URL **게시** | 도메인·호스팅 소유 | App Store Connect 필수 필드 (항목 8·9) |
| 3 | App Store Connect 메타데이터 입력 (이름·Subtitle·Keywords·Category·연령등급·Export Compliance) | 콘솔 접근 | 제출 (항목 2~5, 11, 13) |
| 4 | 심사용 **데모 계정** 생성 후 App Review Information에 등록 | 실계정 생성·자격증명 | 로그인 필수 앱 심사 요건 (항목 15) |
| 5 | 6.9" iPhone 스크린샷 생성·업로드 | 실기기/시뮬레이터 캡처 + 마케팅 판단 | 제출 (항목 6). 후보는 `docs/ios/screenshot-inventory.md` |
| 6 | 스크린샷 **육안 검수** (한국어 문구·개인정보 노출·최신 UI 여부) | 사람 판단 | 심사 리젝 예방 |
| 7 | **실기기 iPhone 확보 후 FLOW QA** | 하드웨어 | 공개 배포 승인 (위 `REQUIRED` 판정) |
| 8 | App Privacy(Nutrition Label) 답변 확정 — 특히 ATT 문구-동작 불일치 처리 | 법적·사업적 판단 | 제출 (항목 10·12). 초안: `docs/ios/app-privacy-answers.md` |

3·4·5·8의 입력 초안은 `docs/ios/app-store-metadata.md`와 `docs/ios/review-notes.md`에 준비돼 있어
**작성이 아니라 확인·복사 수준**이다.

---

## 이번 Phase 산출물

| 산출물 | 위치 | 성격 |
|---|---|---|
| R1 판정 문서 | `docs/ios/R1-admob-launch-risk.md` | 판정 + 프로브 실행/해석 절차 + 미적용 패치 제안 |
| XCTest stop-loss 판정 | `docs/ios/XCTEST_STOP_LOSS_DECISION.md` | DEFER + REPLACE 병행 |
| 스크린샷 인벤토리 | `docs/ios/screenshot-inventory.md` | 실측 자산 목록 |
| 심사 노트 초안 | `docs/ios/review-notes.md` | 데모계정·권한 매핑·위젯 안내 |
| App Store 등록정보 초안 | `docs/ios/app-store-metadata.md` | iOS 초안 포함 |
| App Privacy 답변 매핑 | `docs/ios/app-privacy-answers.md` | ATT 항목 포함 |
| privacy-surface audit | `docs/ios/privacy-surface-audit.md` | Build16 서술 범위 정정 |
| 개인정보처리방침 광고 섹션 | `docs/privacy-policy.md` | 초안 |
| 릴리스 템플릿 세트 | `docs/ios/templates/` | 파라미터화 완료 |
| 프로덕션 plist 런치 프로브 | `scripts/ios/prod_plist_launch_probe.sh` | R1 판별 수단 (미실행) |
| 프로브 정적 계약 | `scripts/ios/tests/prod_plist_launch_probe_contract.sh` | 비-macOS에서도 실행 가능 |
| 프로브 워크플로 | `.github/workflows/ios-adsdk-launch-probe.yml` | `workflow_dispatch` 전용 |
| 전체 스위트 베이스라인 워크플로 | `.github/workflows/flutter-test-baseline.yml` | 비차단 측정용 (미실행) |
| 템플릿 파라미터 검증 | `scripts/verify-template-parameters.sh` | |
| 문서 참조 정합성 검증 | `scripts/verify-docs-consistency.sh` | `docs/ios/**`의 `파일:줄` 참조 실재 검증 |

---

## Phase 4 판정 상태

- `ACCOUNT_CONFIGURED_CLOUD_BUILD_PENDING`: Firebase iOS 앱과 Apple identity/App Group 설정값 반영 완료, 실제 macOS 빌드 증거 대기
- `IOS_UNSIGNED_BUILD_PASS`: macOS에서 plist·Pods·Runner unsigned compile이 실제 성공한 경우에만 부여
- `WIDGET_EXTENSION_BUILD_PASS`: macOS에서 WidgetKit target compile이 실제 성공한 경우에만 부여
- `BLOCKED_APPLE_SIGNING`: unsigned build 이후 signing/Team/profile이 필요한 단계에서만 사용

Phase 4의 저장소 통합은 canonical identity drift 검사, Firebase plist fail-closed 검사,
Apple account action 문서, Runner·WidgetKit macOS build gate를 포함한다. 현재 Windows에서는
실제 plist는 로컬/CI secret에서만 사용하며 macOS/Xcode 결과가 없으면 PASS로 표시하지 않는다.

## Phase 3 판정 상태

- `SOURCE_READY`: Flutter 공통 코드, iOS Runner 프로젝트/Podfile, WidgetKit 소스와 target wiring이 저장소에 있음
- `ACCOUNT_ACTION_REQUIRED`: Apple 팀·서명 등 계정별 값이 아직 필요한 경우에만 사용
- `CLOUD_MACOS_REQUIRED`: CocoaPods 해석과 unsigned Runner/WidgetKit 실제 컴파일
- `PHYSICAL_IPHONE_REQUIRED`: 권한·알림·딥링크·위젯·지도·광고 실기기 확인
- `MAC_PURCHASE_REQUIRED`: `MAC_OPTIONAL` (GitHub Actions macOS 또는 대여 Mac으로 진행 가능)

이번 Phase는 Windows에서 생성·검증 가능한 소스/구조를 통합했다. macOS/Xcode가 없는
환경에서 unsigned build나 WidgetKit compile을 성공으로 표시하지 않는다.

## Phase 2 판정 상태

- `WINDOWS_DONE`: 계약·정적 테스트·CI 보호 게이트·WidgetKit 소스 스캐폴드
- `ACCOUNT_ACTION_REQUIRED`: Apple Developer/App Store Connect 팀, bundle ID, Firebase iOS 앱, Sign in with Apple 및 OAuth redirect
- `CLOUD_MACOS_REQUIRED`: Xcode 프로젝트/Podfile, WidgetKit extension/App Group 연결, archive
- `PHYSICAL_IPHONE_REQUIRED`: 권한·음성·알림·지도·광고·딥링크·위젯 실기기 확인
- `MAC_PURCHASE_REQUIRED`: 자체 Mac이 없을 때의 유지보수/서명 경로 결정(공용 macOS CI는 빌드용)

현재 Flutter 공통 코드와 저장소에 존재하는 iOS 파일을 기준으로 작성한 준비 기준이다. Windows에서는 Xcode, CocoaPods, Apple 서명, TestFlight 및 실기기 검증을 수행할 수 없으므로 해당 항목은 성공으로 표시하지 않는다.

현재 `ios/Runner.xcodeproj`, `ios/Runner.xcworkspace`, `ios/Podfile`과 WidgetKit extension
타깃을 source-controlled 구조로 추가했다. 빌드 설정은 `ios/Flutter/PlanFlow-Identity.xcconfig`
의 canonical 값에서 읽으며 CI secret의 plist와 함께 검증한다. signing-ready와 macOS 빌드
성공은 별도 외부 증거가 필요하다.

개인 위젯 저장소는 `HomeWidgetService`가 동일한 canonical App Group을 기본 주입하고,
`--dart-define=PLANFLOW_IOS_APP_GROUP=...`로 계정 확정값을 교체할 수 있다. WidgetKit은
versioned payload의 날짜별 공휴일(`holidayDates`)과 오늘 일정만 읽으며, 6개 초과 일정은
`+N개 더보기`로 축약한다. 이 연결은 소스/계약 수준이며 macOS 빌드와 iPhone 갱신 확인 전
운영 동작으로 판정하지 않는다.

## 현재 기능 상태

| 영역 | 근거 | iOS 판정 |
|---|---|---|
| 인증·Supabase | `supabase_flutter`, `lib/services/auth_service.dart` | 공통 코드, OAuth 설정·기기 확인 필요 |
| 음성 일정 입력 | `speech_to_text`, `flutter_tts` | 권한 설명 추가, iOS 기기 품질 확인 필요 |
| 일정·AI 대화 | Flutter 화면/서비스 | 공통 코드, iOS 네트워크 확인 필요 |
| 지도·광고 | Google Maps/Ads 플러그인 등록 | iOS 키·AdMob ID·실기기 검증 필요 |
| 알림 | `flutter_local_notifications` | iOS 권한·스케줄 검증 필요 |
| 홈 위젯 | `home_widget_service.dart`, `ios/PlanFlowWidget` | 공통 JSON·legacy dual-write와 WidgetKit target wiring, macOS/iPhone 검증 필요 |
| 그룹 달력 위젯 | `group_calendar_widget_service.dart` | 현재 Android 전용, iOS 재구현 필요 |

## Windows에서 가능한 게이트

- Flutter 분석·Dart 테스트와 iOS 파일/딥링크/권한 정적 계약 테스트
- macOS CI workflow 경로·비밀 참조 검토
- Android 회귀 검증 및 Android 배포 설정 보존

## macOS 및 Apple 계정이 필요한 게이트

- `Podfile`, `Runner.xcodeproj`, workspace 및 CocoaPods 해석
- Apple 팀/Bundle ID/인증서/프로비저닝/서명
- Firebase iOS plist와 Google Maps iOS 키
- WidgetKit extension/App Group entitlement
- iOS 시뮬레이터·실기기, TestFlight, App Store 제출

`firebase_options.dart`의 iOS bundle id(`com.fluxstudio.planflow`)와 Android application id(`com.fluxstudio.planflow`)는 canonical release identity를 사용한다. Firebase plist는 저장소에 포함하지 않고 보호된 CI secret에서 주입한다.

## 기능 분류

- **1군 출시 필수:** 로그인/OAuth, 일정 CRUD, AI 일정대화, 음성, 알림, 지도, 광고 보상 흐름.
- **2군 출시 직후:** 개인 위젯, 외부 캘린더, 공유 수신, 백그라운드 갱신.
- **3군 별도 검토:** Android 전용 그룹 위젯의 WidgetKit 재구현과 고급 백그라운드 스케줄링.

`IMPLEMENTED`와 `LIVE VALIDATED`를 구분한다. macOS/실기기 증거가 없으면 iOS 출시 PASS가 아니다.

## GitHub Actions signed release

`.github/workflows/ios-release.yml`은 `workflow_dispatch` 전용 TestFlight 경로다.
`ios-readiness.yml`의 Firebase 주입·unsigned Runner/WidgetKit 경로는 계속 별도로
실행할 수 있다. signed workflow는 다음 repository secrets가 모두 있어야 시작되며,
하나라도 없으면 `BLOCKED_APPLE_SIGNING`으로 실패한다.

- `PLANFLOW_APPLE_TEAM_ID`
- `PLANFLOW_IOS_DISTRIBUTION_CERTIFICATE_BASE64` 및 `PLANFLOW_IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `PLANFLOW_IOS_RUNNER_PROVISIONING_PROFILE_BASE64`, `PLANFLOW_IOS_WIDGET_PROVISIONING_PROFILE_BASE64`
- `PLANFLOW_IOS_GOOGLE_SERVICE_INFO_PLIST_BASE64`
- `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8`

App Store Connect API key는 업로드 인증만 제공하며, distribution certificate나
provisioning profile을 생성하지 않는다. 인증서·두 프로파일을 별도로 발급해 secret으로
등록해야 한다. workflow는 secret을 로그에 출력하지 않고 임시 keychain/profile/plist/
API key를 `always()` cleanup 단계에서 제거한다. Runner archive 안에
`PlanFlowWidgetExtension.appex`가 없으면 export/upload를 진행하지 않는다.
빌드 이름과 번호는 해당 iOS workflow의 run number로만 주입하며 Android pubspec은
변경하지 않는다. TestFlight 업로드 수락은 배포 완료나 실기기 `LIVE VALIDATED` 증거가 아니다.

## App Store 준비 초안

세부 입력표와 코드 근거 인벤토리는 [`app-store-metadata.md`](app-store-metadata.md)에
정리했다.

필요 작업은 App Store Connect 앱 생성, 개인정보처리방침 URL, 지원 URL, 연령 등급,
스크린샷/설명/키워드/심사 메모, 데이터 수집 선언, Apple 로그인(사용 가능한 제3자
로그인이 있는 경우 포함) 검토다. 계정·팀·인증서·개인키는 저장소나 CI 로그에 넣지 않는다.
`ios/Runner/PlanFlow.entitlements.template`는 placeholder일 뿐 실제 entitlement가 아니다.

## 알림·위젯 제한

현재 공통 Flutter 코드는 로컬 알림을 제공하지만 iOS 알림 권한, 시간대, 백그라운드 실행은
실기기 검증이 필요하다. WidgetKit extension target과 App Group 설정은 저장소에 연결했지만,
App Group source wiring은 완료됐지만 iOS
WidgetKit의 timeline 갱신 주기와 Android 즉시 갱신은 동일하지 않다.
