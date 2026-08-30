# PlanFlow iOS 출시 준비 기준

## Phase 3 판정 상태

- `SOURCE_READY`: Flutter 공통 코드, iOS Runner 프로젝트/Podfile, WidgetKit 소스와 target wiring이 저장소에 있음
- `ACCOUNT_ACTION_REQUIRED`: provisional Bundle ID/App Group 확인, Firebase plist, Apple 팀·서명
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
의 provisional 값에서만 읽으며, Apple/Firebase 계정 확인 전 최종 ID나 signing-ready로
간주하지 않는다. CI는 CocoaPods 및 `flutter build ios --no-codesign`을 실행하고, 계정/구조가
불완전하면 fail-closed한다.

개인 위젯 저장소는 `HomeWidgetService`가 동일한 provisional App Group을 기본 주입하고,
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
| 홈 위젯 | `home_widget_service.dart`, `ios/PlanFlowWidget` | 공통 JSON·legacy dual-write와 WidgetKit target wiring, App Group은 계정 확인 필요 |
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

`firebase_options.dart`의 iOS bundle id(`com.planflow.app`)와 Android application id(`com.fluxstudio.planflow`)는 다르다. 이를 자동으로 합치거나 Firebase plist를 추정하지 않는다. 계정 담당자가 번들 ID와 Firebase iOS 앱 설정을 확정한 뒤 구성해야 한다.

## 기능 분류

- **1군 출시 필수:** 로그인/OAuth, 일정 CRUD, AI 일정대화, 음성, 알림, 지도, 광고 보상 흐름.
- **2군 출시 직후:** 개인 위젯, 외부 캘린더, 공유 수신, 백그라운드 갱신.
- **3군 별도 검토:** Android 전용 그룹 위젯의 WidgetKit 재구현과 고급 백그라운드 스케줄링.

`IMPLEMENTED`와 `LIVE VALIDATED`를 구분한다. macOS/실기기 증거가 없으면 iOS 출시 PASS가 아니다.

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
provisional App Group은 Apple Developer 확인 전에는 동작 보장으로 판정하지 않는다. iOS
WidgetKit의 timeline 갱신 주기와 Android 즉시 갱신은 동일하지 않다.
