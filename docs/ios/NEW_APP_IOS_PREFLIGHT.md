# 신규 앱 iOS 포팅 Preflight 체크리스트

> **이 문서는 새 iOS 포팅을 착수하기 "전"에 1회 실행하는 preflight다.**
> 개발을 다 끝낸 뒤에 확인하는 문서가 아니라, 착수 시점에 먼저 돌려서 뒤늦은 차단 요인을 미리 걸러내기 위한 문서다.

## 실제 겪은 실패 사례 (PlanFlow, 이 문서를 만들게 된 계기)

PlanFlow iOS 포팅을 진행하던 도중, 개발이 상당 부분 끝난 뒤에야 다음 사실을 발견했다:

- 앱이 실제로 요구하는 최소 지원 버전은 **iOS 15.0**이었다.
- 그런데 개발자가 실물 QA용으로 보유한 테스트 기기(iPhone 6)는 **iOS 12.x가 설치 가능한 상한**이었다.
- 즉 그 기기에는 iOS 15.0을 애초에 설치할 수 없어서, **실기기 QA 자체가 불가능한 상태로 개발이 끝나 있었다.**

이 문제는 개발 착수 시점에 "최소 iOS 버전이 몇인지"와 "보유 기기가 그 버전을 설치할 수 있는지"를 5분만 대조했어도 미리 알 수 있었던 것이다. 이 문서는 Flux Studio의 다른 Flutter 앱(FinFlow / HealthFlow / ValueFlow / MenuFlow / NexusFlow 등)이 iOS 포팅을 시작할 때 같은 실수를 반복하지 않도록, 착수 전에 순서대로 확인해야 할 항목을 체크리스트로 고정한다.

## 중요 원칙: 버전 숫자를 이 문서에 박아두지 않는다

이 체크리스트의 어떤 항목도 "iOS 15", "Xcode 16" 같은 구체적 버전 숫자를 정답으로 담고 있지 않다. Flutter SDK 정책, Apple 기기 지원 범위, GitHub Actions 러너의 Xcode 버전은 모두 시간이 지나면 바뀐다. 이 문서에 숫자를 하드코딩하면 그 숫자는 곧 stale해지고, 다음에 이 문서를 읽는 사람이 틀린 값을 그대로 믿게 된다. **모든 항목은 "확인 시점에 공식 소스에서 실측 조회"를 원칙으로 한다.**

---

## 체크리스트

### 1. Flutter SDK가 요구하는 최소 iOS 버전 확인

- [ ] `flutter doctor -v`로 현재 사용 중인 Flutter SDK 버전과 Xcode 연동 상태를 확인한다.
- [ ] 그 Flutter SDK 버전의 공식 릴리스 노트(flutter.dev release notes) 또는 `packages/flutter_tools`의 iOS 템플릿(`bin/cache/artifacts` 또는 `flutter create` 직후 생성되는 `ios/Podfile`의 기본 `platform :ios` 줄)에서 **Flutter 자체가 요구하는 최소 iOS deployment target**을 확인한다.
- [ ] 이 값은 프로젝트가 선언할 수 있는 최소값의 하한선이다 — 이보다 낮은 값을 선언하면 빌드 자체가 안 되거나 Flutter 엔진이 지원하지 않는다.
- [ ] 확인한 값과 확인 날짜를 프로젝트 내부 메모(예: `docs/ios/parity-matrix.md` 또는 이번 포팅 전용 노트)에 남긴다 — 이 문서에는 남기지 않는다.

### 2. 각 플러그인(pubspec.yaml)별 iOS deployment target 확인

- [ ] `pubspec.yaml`에 선언된 iOS 관련 플러그인을 전부 나열한다.
- [ ] `.pub-cache`(또는 `flutter pub get` 후 `ios/Pods` 하위)에서 각 플러그인의 `ios/*.podspec` 파일을 열어 `s.platform = :ios, 'X.Y'` 또는 `s.ios.deployment_target` 값을 확인한다.
- [ ] **플러그인 중 하나라도 앱 전체가 선언하려는 최소값보다 높은 iOS를 요구하면, 그 플러그인의 요구치가 앱의 실질적 최소 지원 버전이 된다.** (예: 앱은 iOS 13을 목표로 했는데 특정 플러그인이 iOS 15를 요구하면, 실제 최소는 iOS 15다.)
- [ ] 플러그인 중 요구치가 지나치게 높은 것이 있으면, 그 플러그인을 대체할지 앱의 최소 버전을 그에 맞춰 올릴지를 착수 전에 결정한다.

### 3. 앱 자체가 최종적으로 선언할 최소 iOS 버전 결정

- [ ] 1번(Flutter SDK 하한)과 2번(플러그인별 요구치) 중 **가장 높은 값**을 앱의 최종 최소 지원 버전으로 정한다.
- [ ] `ios/Podfile`의 `platform :ios, 'X.Y'`에 그 값을 명시한다.
- [ ] Xcode 프로젝트 설정(`ios/Runner.xcodeproj`)의 `IPHONEOS_DEPLOYMENT_TARGET`도 동일한 값으로 맞춘다(Podfile과 Xcode 프로젝트 설정이 서로 다르면 빌드 경고 또는 런타임 불일치가 생길 수 있다).
- [ ] 이 값을 6번 항목(보유 실기기 대조)에서 그대로 사용한다.

### 4. Apple이 현재 판매/지원 중인 기기와 각 기기의 최신 지원 가능 iOS 버전 확인

- [ ] Apple 공식 "iOS와 호환되는 기기" 페이지(Apple 지원 사이트에서 검색)를 확인 시점에 직접 열어, 현재 최신 iOS가 어떤 기기까지 지원하는지 확인한다.
- [ ] 특정 기기 모델(예: iPhone SE 1세대, iPhone 6, iPhone 7 등)이 몇 버전까지 업그레이드 가능한지도 같은 페이지 또는 Apple의 기기별 사양 페이지에서 확인한다.
- [ ] 이 값을 이 문서나 다른 정적 문서에 옮겨 적지 않는다 — 매번 그 시점의 공식 페이지에서 재확인한다.

### 5. CI(GitHub Actions `macos-latest`)에 설치된 Xcode 버전과 지원 iOS Simulator runtime 확인

- [ ] 로컬 macOS 또는 실제 CI 실행 환경에서 다음 명령으로 현재 설치된 Xcode와 SDK 목록을 확인한다:
  - `xcrun xcodebuild -showsdks`
  - `xcrun simctl list runtimes`
- [ ] `macos-latest` 러너가 어떤 Xcode 버전을 기본으로 쓰는지는 GitHub Actions의 `runner-images` 저장소 문서(현재 시점의 macOS 이미지 릴리스 노트)에서 확인한다.
- [ ] CI에서 필요한 iOS Simulator runtime이 기본 이미지에 없으면, 워크플로에 `xcodebuild -runFirstLaunch` 또는 runtime 설치 스텝이 필요한지 검토한다.
- [ ] 이 값 역시 특정 버전 번호로 문서에 고정하지 않는다 — 워크플로가 돌 때마다 실제 이미지가 갱신될 수 있으므로 항상 그 시점의 동적 조회를 원칙으로 한다.

### 6. 보유한 실물 테스트 기기의 iOS 버전 상한과 앱 최소 버전 대조 (★ PlanFlow가 놓친 항목)

- [ ] 현재 QA에 쓸 수 있는 실물 iPhone/iPad 기기 목록을 만든다.
- [ ] 각 기기의 모델명으로 "그 기기가 설치 가능한 iOS 최신 버전"을 4번에서 확인한 Apple 공식 페이지로 대조한다.
- [ ] **3번에서 정한 앱의 최소 지원 버전을 그 기기가 설치할 수 있는지 반드시 확인한다.**
- [ ] 설치 불가능한 기기만 있다면, 착수 전에 다음 중 하나를 결정한다:
  - [ ] (a) Xcode Simulator 기반 QA로 대체 가능한 범위를 먼저 파악하고, 어떤 항목이 Simulator로 충분하고 어떤 항목이 실기기가 꼭 필요한지 구분한다(예: 카메라, NFC, 생체인증, 백그라운드 위치, 푸시 알림 실기기 수신 등은 Simulator로 재현 불가능하거나 제한적이다).
  - [ ] (b) 실기기가 꼭 필요한 항목만 최소화해서 정리한다.
  - [ ] (c) (a)(b)로도 부족하면 요구 iOS 버전을 설치 가능한 중고/신품 기기 구매 등 대안을 개발 착수 "전"에 미리 결정한다.
- [ ] 이 대조 작업은 코드를 한 줄도 쓰기 전에 끝내야 한다 — 개발 완료 후에 발견하면 PlanFlow처럼 QA 자체가 막힌 채로 개발이 끝나 있는 상황이 재발한다.

### 7. Widget / App Extension이 있으면 별도 최소 iOS와 App Group 요구사항 확인

- [ ] 프로젝트가 홈 화면 위젯(WidgetKit), 알림 확장, 기타 App Extension을 계획하고 있는지 확인한다.
- [ ] 계획 중이라면 해당 Extension이 요구하는 최소 iOS 버전을 별도로 확인한다(WidgetKit 자체의 최소 지원 버전, 그리고 사용하려는 구체적 API가 그보다 더 높은 버전을 요구하는지까지 확인 — 예를 들어 특정 위젯 인터랙션 API는 WidgetKit 최초 지원 버전보다 더 높은 iOS를 요구할 수 있다).
- [ ] Extension이 앱 본체와 데이터를 공유하려면 App Group 설정(Xcode Capabilities → App Groups)이 필요하다는 점을 확인하고, 이를 개발자 계정의 App ID 설정에도 미리 반영해야 하는지 확인한다.
- [ ] Extension의 최소 버전이 3번에서 정한 앱 본체의 최소 버전보다 높으면, 3번 값을 그에 맞춰 다시 올릴지 검토한다.

### 8. Privacy-sensitive 의존성 목록화와 Privacy Manifest 필요 여부 확인

- [ ] 앱이 사용하는 privacy-sensitive 기능/의존성을 전부 나열한다(마이크, 음성인식, 위치, 사진/카메라, 광고 SDK, 트래킹, 연락처, 캘린더 등).
- [ ] 각 항목이 `Info.plist`에 요구하는 Usage Description 키(예: `NSMicrophoneUsageDescription`, `NSLocationWhenInUseUsageDescription` 등)를 확인하고 목록화한다.
- [ ] Apple이 App Store 제출 심사에서 특정 API 카테고리(예: 사용자 기본 설정 읽기, 디스크 공간 확인, 파일 타임스탬프 접근 등)에 대해 Privacy Manifest(`PrivacyInfo.xcprivacy`) 제출을 요구하는지, 확인 시점의 Apple 공식 문서(App Store Connect 심사 가이드라인 / Privacy Manifest 관련 공지)로 재확인한다 — 이 요구사항은 시점에 따라 대상 API 카테고리가 확대될 수 있으므로 특정 iOS 버전 기준으로 이 문서에 고정하지 않는다.
- [ ] 이 확인은 개발 착수 시점에 끝내야, 나중에 심사 반려로 인한 재작업을 피할 수 있다.

### 9. 지도/지도 유사 SDK가 있으면 iOS Simulator(arm64) 슬라이스 제공 여부를 착수 전에 확인 (PlanFlow iOS Simulator E2E Phase에서 실제로 겪은 항목)

- [ ] `pubspec.yaml`에 `google_maps_flutter`, `flutter_naver_map` 같은 지도 SDK 플러그인이 있으면, 그 플러그인의 iOS 배포 아티팩트(대개 `.xcframework` 또는 CocoaPods vendored framework)가 **iOS Simulator arm64 슬라이스를 실제로 포함하는지**를 CI를 처음 돌리기 전에 확인한다.
- [ ] 확인 방법 예시: 플러그인 저장소의 iOS 배포 노트/이슈 트래커에서 "Simulator" 또는 "arm64" 관련 known-issue를 검색하거나, `.pub-cache`에 받아진 `.xcframework`/`.framework` 안에 `ios-arm64-simulator` 슬라이스 디렉토리가 실제로 존재하는지 `lipo -info` 또는 디렉토리 나열로 직접 확인한다.
- [ ] **왜 착수 전에 확인해야 하는가**: PlanFlow는 `google_maps_flutter`와 `flutter_naver_map`을 함께 쓰고 있었는데, 이 슬라이스 제공 여부는 CI(GitHub Actions macOS 러너)에서 실제 빌드를 1차로 돌려보기 전까지는 확정할 수 없었다 — 로컬 문서 검토만으로는 최종 확인이 안 됐다. 즉 이 항목은 "완벽히 사전 차단 가능"하지는 않지만, 최소한 **알려진 문제가 있는지 사전 검색**은 착수 전에 반드시 하고, CI 1차 실행 결과를 이 문서가 아니라 프로젝트 포팅 노트에 즉시 기록해 다음 앱이 같은 조사를 처음부터 반복하지 않게 한다.
- [ ] Simulator에서 특정 지도 SDK가 동작하지 않는 것으로 확인되면, 그 SDK가 관련된 QA 항목은 "Simulator 불가 — 실기기 전용"으로 분류하고(6번 항목의 실기기 QA 범위에 편입), 자동화 E2E 커버리지에서 제외한다.

### 10. 상태관리 아키텍처를 처음부터 일관되게 적용하지 않으면 테스트 주입 seam이 무력화될 수 있음 (PlanFlow iOS Simulator E2E Phase 실제 사례)

- [ ] 프로젝트가 Riverpod(또는 다른 DI/상태관리 프레임워크)를 `pubspec.yaml`에 의존성으로 넣고 `ProviderScope` 같은 최상위 wrapper를 쓰고 있다고 해서, **실제로 모든 핵심 서비스가 그 프레임워크의 provider를 통해 주입되고 있는지**는 별개로 확인해야 한다.
- [ ] 확인 방법: 핵심 서비스(인증, 네트워크 클라이언트 등)가 `ref.watch`/`ref.read`로 provider를 통해 접근되는지, 아니면 전역 싱글턴(top-level 변수, static 필드, 별도 singleton 클래스)으로 직접 접근되는지 실제 코드에서 grep으로 확인한다.
- [ ] **왜 중요한가**: 테스트(특히 integration_test로 특정 인증 상태를 주입해 화면을 검증하려는 E2E 테스트)는 대개 "앱 진입점에 provider overrides를 주입하면 그 상태로 앱이 뜬다"는 전제로 설계된다. 그런데 실제 서비스가 provider가 아니라 전역 싱글턴이면, provider overrides를 아무리 정교하게 만들어도 앱의 실제 동작에는 아무 영향이 없다 — 테스트 seam이 있는 것처럼 보이지만(코드가 존재하지만) 실질적으로는 무력하다.
- [ ] PlanFlow 실제 사례: `ProviderScope`는 최상위에 있었으나 앱 전체에서 `ref.watch` 사용례가 0건이었고, `authProvider` 등 핵심 서비스가 전역 싱글턴으로 구현돼 있었다. 그 결과 진입점에 만든 `runPlanFlowApp(overrides:)` 같은 주입 지점이 인증 상태 주입에는 실질적 효과가 없었다(향후 Riverpod로 실제 마이그레이션하지 않는 한 해소되지 않는 구조적 한계).
- [ ] 착수 전에 이 사실을 확인해두면, "provider override로 테스트 상태를 주입한다"는 계획을 세우기 전에 그게 실제로 가능한 아키텍처인지 미리 판별할 수 있다. 이미 전역 싱글턴 구조인 앱이라면 테스트 격리 전략을 처음부터 다른 방식(예: 환경변수 기반 분기, 별도 테스트 빌드 flavor, 싱글턴 자체에 테스트 전용 setter 추가)으로 설계해야 한다.

### 11. E2E/QA 격리를 위한 전용 스테이징 백엔드 프로젝트를 처음부터 만들어두지 않으면 나중에 격리가 복잡해짐 (PlanFlow iOS Simulator E2E Phase 실제 사례)

- [ ] 앱이 Supabase 같은 BaaS를 쓰고 dart-define(컴파일타임 환경변수)으로 URL/키를 주입하는 구조라면, **그 값이 미주입 상태일 때 어디로 폴백하는지**를 착수 전에 확인한다.
- [ ] PlanFlow 실제 사례: `lib/core/env.dart`가 Supabase dart-define이 주입되지 않으면 **프로덕션 프로젝트로 그대로 폴백**하는 구조였다. 즉 E2E 테스트를 아무 조치 없이 그냥 돌리면 프로덕션 데이터베이스에 테스트 트래픽이 그대로 들어갈 위험이 있었다. 이 문제를 피하려고 별도의 게이트(빌드 시점에 dart-define이 실제로 주입됐는지 검증하는 단계)를 나중에 추가해야 했다.
- [ ] **착수 전에 해야 할 일**: (a) 프로덕션과 완전히 분리된 전용 스테이징/테스트 Supabase(또는 동급 BaaS) 프로젝트를 처음부터 만들어둔다. (b) dart-define 미주입 시 프로덕션으로 폴백하는 대신 명시적으로 실패하거나 스테이징으로 폴백하도록 설계한다. (c) CI의 E2E 워크플로가 항상 스테이징 dart-define을 명시적으로 주입하도록 강제하고, 이 주입 여부를 빌드 전 단계에서 검증한다.
- [ ] 이 항목을 착수 전에 결정해두지 않으면, 나중에 "테스트가 실수로 프로덕션을 건드리지 않는지" 검증하는 별도 안전장치를 사후에 덧붙여야 하고, 그 사이 기간 동안 프로덕션 오염 위험이 존재한다.

---

## 이 문서 사용 방법

1. 새 Flutter 앱의 iOS 포팅을 시작하기로 결정한 시점에 이 문서를 연다.
2. 위 1~11번 항목을 순서대로 실행한다(순서가 중요하다 — 3번의 최소 버전 결정은 1, 2번 결과에 의존하고, 6번의 실기기 대조는 3, 4번 결과에 의존한다. 9~11번은 지도 SDK/상태관리 프레임워크/BaaS를 실제로 쓰는 앱에만 해당하며, 해당 사항이 없으면 건너뛴다).
3. 모든 체크박스를 완료한 뒤에만 실제 코드 작업(Podfile 수정, 플러그인 iOS 구현 시작 등)에 착수한다.
4. 확인한 구체적 버전 값(Flutter 최소, 플러그인별 최소, 앱 최종 최소, 보유 기기 상한 등)은 이 문서가 아니라 해당 프로젝트의 포팅 진행 노트에 기록한다 — 이 문서는 항상 버전 중립적인 템플릿으로 유지한다.
