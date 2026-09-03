# PlanFlow — 템플릿 파라미터 실제 값

> 이 파일은 `PARAMETERS.md` 에 정의된 파라미터의 **PlanFlow 확정 값**을 모아둔 참조표다.
> **템플릿 본문(`.tmpl`)에는 이 값들이 리터럴로 존재하지 않는다** — 앱 고유값은 여기에만 있다.
> 다른 앱은 이 파일을 복사해 `<app>.values.md` 로 만들고 값을 자기 것으로 바꾼다.

## 값 표

| 파라미터 | PlanFlow 값 | 실측 근거(이 저장소 기준) |
|---|---|---|
| `APP_NAME` | `PlanFlow` | 저장소 루트명, `ios/Flutter/PlanFlow-Identity.xcconfig` |
| `BUNDLE_ID` | `com.fluxstudio.planflow` | `ios/Flutter/PlanFlow-Identity.xcconfig` (`PLANFLOW_IOS_BUNDLE_ID`) |
| `WIDGET_BUNDLE_ID` | `com.fluxstudio.planflow.PlanFlowWidget` | 같은 파일 (`PLANFLOW_IOS_WIDGET_BUNDLE_ID`) |
| `APP_GROUP` | `group.com.fluxstudio.planflow` | 같은 파일 (`PLANFLOW_IOS_APP_GROUP`) |
| `URL_SCHEME` | `planflow` | `ios/Runner/Info.plist` 의 `CFBundleURLSchemes` |
| `SECRET_PREFIX` | `PLANFLOW` | `.github/workflows/ios-release.yml` 의 `secrets.PLANFLOW_*` |
| `MIN_IOS_VERSION` | `15.0` | `ios/Podfile` (`platform :ios, '15.0'`), `IPHONEOS_DEPLOYMENT_TARGET = 15.0` |
| `FLUTTER_VERSION` | `3.47.2` | `.github/workflows/*.yml` 의 `flutter-version` |
| `TARGETED_DEVICE_FAMILY` | `1,2` (iPhone + iPad) | `ios/Runner.xcodeproj/project.pbxproj` |
| `BACKEND_KIND` | `supabase-and-firebase` | `pubspec.yaml` (`supabase_flutter`, `firebase_core`, `firebase_crashlytics`, `firebase_remote_config`) |
| `HAS_WIDGET` | `true` | WidgetKit extension(`PlanFlowWidgetExtension.appex`) 아카이브 게이트 존재 |
| `HAS_MICROPHONE` | `true` | `NSMicrophoneUsageDescription` in `ios/Runner/Info.plist` |
| `HAS_SPEECH` | `true` | `NSSpeechRecognitionUsageDescription` in `ios/Runner/Info.plist` |
| `HAS_PHOTOS` | `true` | `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` |
| `HAS_LOCATION` | `true` | `NSLocationWhenInUseUsageDescription` |
| `HAS_ADS` | `true` | `pubspec.yaml` 의 `google_mobile_ads`, `NSUserTrackingUsageDescription` |
| `HAS_MAP` | `true` | `pubspec.yaml` 의 `google_maps_flutter`(+ 네이버 지도) |
| `E2E_FLOWS` | `FLOW1 FLOW2 FLOW3 FLOW4 FLOW5 FLOW6 FLOW7 FLOW8` | `docs/ios/SIMULATOR_QA_MATRIX.md` 의 `담당FLOW` 컬럼 |

## FLOW 매핑 (PlanFlow 기준)

`docs/ios/SIMULATOR_QA_MATRIX.md` 의 `담당FLOW` 값과 동일하다.

| FLOW | 축 | PlanFlow 대표 항목 |
|---|---|---|
| `FLOW1` | 기동 | 앱 cold start |
| `FLOW2` | 핵심 도메인 | 일정 조회/생성/수정/삭제, 반복 일정, 공휴일, 음성 UI 상태머신 |
| `FLOW3` | 라우팅 | 화면 navigation, `planflow://schedule/{id}` / `planflow://day/{date}` 딥링크, 알림 라우팅 |
| `FLOW4` | 확장 | App Group 공유 데이터, 위젯 payload 생성 |
| `FLOW5` | 인증·백엔드 | 로그인/세션 복원, Firebase 초기화, Supabase 연결, Google Sign-In, 광고 |
| `FLOW6` | 복원력 | 오프라인/네트워크 실패, background↔foreground 전환, 앱 재기동 |
| `FLOW7` | 권한 | 마이크 권한 흐름, 권한 거부/복구 |
| `FLOW8` | 레이아웃 | 텍스트 배율, 키보드, 회전, 소형/대형 화면 |

## 주의 사항

- **`MIN_IOS_VERSION = 15.0` 은 실기기 QA 제약과 직결된다.** PlanFlow가 보유했던 실물 테스트 기기는
  iOS 12.x 가 설치 상한이라 15.0 을 설치할 수 없었고, 그 사실을 개발 종료 후에 발견했다.
  이것이 `NEW_APP_IOS_PREFLIGHT` 6번 항목이 존재하는 이유다.
- **`HAS_MAP = true` 이지만 시뮬레이터 지원 여부는 미확정이다.** 지도 SDK가 iOS Simulator(arm64)
  슬라이스를 제공하는지는 macOS 러너 1차 실행 전까지 실측되지 않았다(개발 환경이 Windows라 로컬 확인 불가).
  QA 매트릭스의 해당 항목은 잠정 분류이며 CI 1차 실행 후 1회 갱신해야 한다.
- **ATT는 이 표의 `HAS_ADS` 와 별개 항목이다.** 광고 SDK는 쓰지만 `app_tracking_transparency` 패키지와
  `ATTrackingManager` 호출은 코드에 존재하지 않는 것으로 확인됐다(0건).
  `NSUserTrackingUsageDescription` 키만 `Info.plist` 에 존재하는 상태이며,
  이는 별도 심사 리스크 항목으로 다뤄야 한다 — 이 표에서 단정하지 않는다.
- 이 표의 값은 **작성 시점 실측**이다. `FLUTTER_VERSION` 처럼 갱신되는 값은 워크플로를 고칠 때 함께 갱신한다.
