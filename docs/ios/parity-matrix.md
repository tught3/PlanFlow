# Android → iOS 기능 동등성 매트릭스 (Phase 3)

상태는 다음 다섯 가지로만 표시한다: `WINDOWS_DONE`, `ACCOUNT_ACTION_REQUIRED`,
`CLOUD_MACOS_REQUIRED`, `PHYSICAL_IPHONE_REQUIRED`, `MAC_PURCHASE_REQUIRED`.

| 기능 | 근거 | 판정 |
|---|---|---|
| 앱 진입·딥링크 | `ios/Runner/Info.plist`, `lib/app.dart`, `notification_route_contract.dart` | WINDOWS_DONE |
| 로그인·OAuth | `lib/services/auth_service.dart`, `firebase_options.dart` | ACCOUNT_ACTION_REQUIRED |
| 음성 입력·TTS | `lib/screens/voice`, speech/TTS 플러그인 | PHYSICAL_IPHONE_REQUIRED |
| 일정 CRUD·AI 정리 | `lib/features`, `lib/services` | CLOUD_MACOS_REQUIRED |
| 지도·광고 | `google_maps_flutter`, `google_mobile_ads` | ACCOUNT_ACTION_REQUIRED |
| 로컬 알림 | `notification_service.dart` | PHYSICAL_IPHONE_REQUIRED |
| 개인 위젯 | `widget_schedule_contract.dart`, `ios/PlanFlowWidget`, Xcode target | CLOUD_MACOS_REQUIRED |
| 그룹 달력 위젯 | `group_calendar_widget_service.dart` | CLOUD_MACOS_REQUIRED |
| 외부 캘린더 | `calendar_auto_sync_service.dart` | ACCOUNT_ACTION_REQUIRED |

## 위젯 계약

앱 달력과 위젯의 날짜·일정 정렬·색상·폰트 규칙은 공통 데이터 계약으로 유지한다. Android 위젯이 iOS WidgetKit을 자동으로 대체한다고 가정하지 않는다. WidgetKit timeline provider와 App Group 저장소는 source/target 구조까지 연결했으며, CocoaPods·실제 timeline refresh와 iOS 기기 캡처는 `CLOUD_MACOS_REQUIRED`/`PHYSICAL_IPHONE_REQUIRED`다.

인증서·키·Firebase plist는 저장소에 추가하지 않으며, Windows 결과로 macOS/실기기 PASS를 표시하지 않는다.

## 렌더러 동등성 표기

- `EXACT_PARITY`: 동일한 입력 계약과 시각 규칙이 양쪽 구현에서 검증된 경우
- `NEAR_PARITY`: 사용자 경험은 대응하지만 플랫폼의 갱신·권한 차이가 남는 경우
- `IOS_LIMITATION`: iOS 시스템 제약으로 Android와 동일한 보장을 할 수 없는 경우
- `NOT_SUPPORTED`: 해당 iOS 기능을 아직 구현하지 않은 경우

현재 판정은 공통 Flutter 일정 projection과 색상 계약이 `EXACT_PARITY` 입력을
제공하고, Android 기존 위젯은 이를 계속 소비한다는 수준이다. WidgetKit source와
Xcode target wiring은 `NEAR_PARITY` 준비 상태지만 macOS compile 전에는 실제 렌더러로
판정하지 않는다.
Android 전용 그룹 위젯은 iOS에서 `NOT_SUPPORTED`, WidgetKit timeline 갱신 주기는
`IOS_LIMITATION`으로 기록한다.

## 공통 위젯·딥링크 계약

`WidgetSchedulePayload`는 `schemaVersion`, UTC `generatedAt`, 일정 필드, 날짜별 개수,
공휴일 순서와 날짜별 공휴일 맵(`holidayDates`)을 포함한다. 앱과 Android 위젯의 기존
동작을 대체하지 않고 iOS 소비자를 추가할 때 사용할 정규 JSON이다. `NotificationRouteContract`는 기존 `planflow://` 스킴을
보존하면서 `schedule/{id}`와 `day/{yyyy-MM-dd}`를 각각 기존 Flutter 경로로 변환한다.

## 실제 사용 Firebase 제품

코드에서 확인되는 Firebase 제품은 Core, Crashlytics, Remote Config이다. 인증·소셜 로그인은
Supabase Auth provider(Google·Kakao·Naver) 설정을 사용한다. iOS `GoogleService-Info.plist`는 Firebase Console에서
확정된 bundle ID로 내려받아 macOS에서 추가해야 한다.
