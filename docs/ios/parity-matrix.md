# Android → iOS 기능 동등성 매트릭스

| 기능 | 근거 | 판정 |
|---|---|---|
| 앱 진입·딥링크 | `ios/Runner/Info.plist`, `lib/app.dart` | 공통 코드 / iOS URL scheme 확인 필요 |
| 로그인·OAuth | `lib/services/auth_service.dart` | 공통 코드 / iOS redirect 구성 필요 |
| 음성 입력·TTS | `lib/screens/voice`, speech/TTS 플러그인 | 권한·기기 확인 필요 |
| 일정 CRUD·AI 정리 | `lib/features`, `lib/services` | 공통 코드 / iOS 네트워크 확인 필요 |
| 지도·광고 | `google_maps_flutter`, `google_mobile_ads` | iOS 키·광고 설정/기기 확인 필요 |
| 로컬 알림 | `notification_service.dart` | iOS 권한·스케줄 확인 필요 |
| 개인 위젯 | `home_widget_service.dart` | App Group/WidgetKit 구성 필요 |
| 그룹 달력 위젯 | `group_calendar_widget_service.dart` | Android 전용, iOS 재구현 필요 |
| 외부 캘린더 | `calendar_auto_sync_service.dart` | OAuth·백그라운드 확인 필요 |

## 위젯 계약

앱 달력과 위젯의 날짜·일정 정렬·색상·폰트 규칙은 공통 데이터 계약으로 유지해야 한다. Android 위젯이 iOS WidgetKit을 자동으로 대체한다고 가정하지 않는다. WidgetKit timeline provider, App Group 저장소, refresh 정책은 별도 설계 후 iOS 기기 캡처로 검증한다.

인증서·키·Firebase plist는 저장소에 추가하지 않으며, Windows 결과로 macOS/실기기 PASS를 표시하지 않는다.
