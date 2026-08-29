# PlanFlow iOS 출시 준비 기준

현재 Flutter 공통 코드와 저장소에 존재하는 iOS 파일을 기준으로 작성한 준비 기준이다. Windows에서는 Xcode, CocoaPods, Apple 서명, TestFlight 및 실기기 검증을 수행할 수 없으므로 해당 항목은 성공으로 표시하지 않는다.

현재 `ios/Runner.xcodeproj`, `ios/Runner.xcworkspace`, `ios/Podfile`이 저장소에 없다. 임시 Flutter 템플릿 생성은 성공했지만, 템플릿의 bundle identifier와 기존 Firebase iOS bundle identifier가 달라 자동 병합하지 않았다. Apple bundle ID 결정 후 macOS에서 `flutter create --platforms=ios` 산출물을 검토해 추가해야 한다. 따라서 CI의 `flutter build ios --no-codesign`은 이 blocker를 조기에 드러내는 보호 게이트다.

## 현재 기능 상태

| 영역 | 근거 | iOS 판정 |
|---|---|---|
| 인증·Supabase | `supabase_flutter`, `lib/services/auth_service.dart` | 공통 코드, OAuth 설정·기기 확인 필요 |
| 음성 일정 입력 | `speech_to_text`, `flutter_tts` | 권한 설명 추가, iOS 기기 품질 확인 필요 |
| 일정·AI 대화 | Flutter 화면/서비스 | 공통 코드, iOS 네트워크 확인 필요 |
| 지도·광고 | Google Maps/Ads 플러그인 등록 | iOS 키·AdMob ID·실기기 검증 필요 |
| 알림 | `flutter_local_notifications` | iOS 권한·스케줄 검증 필요 |
| 홈 위젯 | `home_widget_service.dart` | App Group/WidgetKit extension 미구성 |
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
