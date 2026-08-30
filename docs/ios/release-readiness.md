# PlanFlow iOS 출시 준비 기준

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
