# PlanFlow iOS Simulator E2E — QA 분류 매트릭스 (Phase P1)

> FLOW 번호·명칭은 계획 단계에서 유도됐으며 사용자 원문(FLOW1~8)과 표현이 다를 수 있으나 범위는 동일함.

## 실측으로 정정된 사실 (요약)

- **min iOS 15.0** (Podfile / `ios/Runner.xcodeproj/project.pbxproj`의 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`). iPhone 6(iOS 12 상한)은 애초에 실행 불가.
- `TARGETED_DEVICE_FAMILY = "1,2"` → iPad도 대상. iPhone은 Portrait 고정, iPad는 4방향 회전 허용 (`ios/Runner/Info.plist:52-62`).
- **ATT 미구현**: `app_tracking_transparency` 패키지 없음, `ATTrackingManager` 호출 0건. 광고 동의는 Google UMP(`lib/services/ad_consent_service.dart:213,247`의 `ConsentInformation`)만 존재. `NSUserTrackingUsageDescription` 문구는 `Info.plist:28`에 있으나 이를 트리거하는 코드가 없음 — "심사 응답과 실제 동작 불일치 위험"으로만 표시하고 이번 문서에서 코드 수정은 하지 않는다(별도 항목 N4, 이번 Phase 범위 아님).
- **딥링크 canonical 계약**: `lib/services/notification_route_contract.dart:19-35`의 `NotificationRouteContract`가 `planflow://schedule/{id}`, `planflow://day/{yyyy-MM-dd}`를 정의(host형/path형 둘 다 파싱). 이 외에 `planflow://auth-callback`(`lib/core/env.dart:35`), `planflow://group-calendar?groupId=&date=`(`lib/app.dart:1278`), `planflow://group-invite?...`(`lib/features/groups/screens/group_invite_screen.dart:619`) 3종이 추가로 존재.
- **환경변수**: `lib/core/env.dart:92-102`가 `String.fromEnvironment`(dart-define) 컴파일타임 주입이며, 미주입 시 **프로덕션 Supabase URL로 폴백**한다(위험 신호 — 격리 전략은 별도 항목에서 다룰 예정이며 이 문서는 인지만 한다).
- `integration_test/` 디렉토리는 아직 없음(2026-09-03 확인, `ls: cannot access 'integration_test/'` — 이번 Phase의 P3에서 신설 예정).
- 기존 순수 Dart 계약 테스트 6종은 전부 설정/코드 정합성만 확인하며 런타임 UI 동작은 검증하지 않는다: `test/ios_phase2_contract_test.dart`, `test/ios_phase3_native_contract_test.dart`, `test/ios_phase4_identity_contract_test.dart`, `test/ios_release_contract_test.dart`, `test/android_deep_link_guard_test.dart`, `test/app_home_widget_route_test.dart`.
- **`@visibleForTesting` seam 실측 개수** (2026-09-03 grep 재확인, 배경 서술과 일치): `lib/services/notification_service.dart` 12곳, `lib/services/stt_service.dart` 10곳, `lib/services/ad_service.dart` 3곳, `lib/services/auth_service.dart` 2곳.
- `google_maps_flutter` + `flutter_naver_map` 둘 다 사용 중. 시뮬레이터(arm64) 슬라이스 실제 제공 여부는 **P3 실측 대기 — 미확정**. 결과가 나오면 이 표를 1회 갱신한다.

---

## 분류 매트릭스 (37개 항목)

| # | 항목명 | 분류 | 이유 | 검증방법 | 릴리스영향도 | 기존계약테스트중복여부 | 담당FLOW |
|---|--------|------|------|----------|--------------|------------------------|----------|
| 1 | 앱 cold start | SIMULATOR_FULL | 시뮬레이터가 실제 프로세스 부팅·Flutter engine 초기화·초기 라우트 렌더링을 그대로 수행하므로 콜드스타트 자체는 하드웨어 의존성이 없다. | `flutter test integration_test/app_cold_start_test.dart`(신설), `WidgetsFlutterBinding.ensureInitialized()` 이후 첫 프레임 pump로 초기 라우트 단언 | POST_RELEASE_RECOMMENDED | 없음 | FLOW1 |
| 2 | 로그인/로그아웃 | SIMULATOR_FULL | AuthService의 실제 네트워크 호출을 fake repository로 대체하면 로그인/로그아웃 상태 전이는 순수 소프트웨어 로직이라 시뮬레이터에서 완전 검증 가능. | `AuthServiceDelegate` 주입(`lib/services/auth_service.dart` 2곳 `@visibleForTesting` seam) + fake Supabase repository, `integration_test/auth_flow_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW5 |
| 3 | 기존 사용자 세션(자동 복원) | SIMULATOR_FULL | 세션 토큰 저장/복원은 SharedPreferences/Keychain wrapper를 fake로 대체 가능한 순수 상태 로직. | fake secure storage 주입 후 앱 재기동 시나리오, `integration_test/session_restore_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW5 |
| 4 | 일정 조회 | SIMULATOR_FULL | 캘린더 목록/상세 렌더링은 fake repository 데이터로 완전 재현 가능한 UI 로직. | fake `EventRepository` 주입, `integration_test/schedule_read_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW2 |
| 5 | 일정 생성 | SIMULATOR_FULL | 생성 폼 입력→저장 플로우는 텍스트 입력과 저장 콜백만으로 구성되어 하드웨어 의존이 없다. | `WidgetTester.enterText` + fake repository 저장 확인, `integration_test/schedule_create_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW2 |
| 6 | 일정 수정 | SIMULATOR_FULL | 수정 폼도 생성과 동일하게 순수 UI+상태 로직. | fake repository의 기존 항목 갱신 확인, `integration_test/schedule_update_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW2 |
| 7 | 일정 삭제 | SIMULATOR_FULL | 삭제 확인 다이얼로그+저장소 제거는 순수 상태 로직. | fake repository에서 항목 제거 확인, `integration_test/schedule_delete_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW2 |
| 8 | 반복 일정 | SIMULATOR_FULL | 반복 규칙 계산(RRULE 전개 등)은 순수 날짜 연산이라 하드웨어 의존 없이 검증 가능. | 반복 규칙 fixture로 전개 결과 단언, `integration_test/recurring_event_test.dart`(신설) | POST_RELEASE_RECOMMENDED | 없음 | FLOW2 |
| 9 | 중요 일정 | SIMULATOR_FULL | 중요 표시(강조 렌더링/정렬 우선순위)는 순수 UI 상태. | fake repository로 중요 플래그 데이터 주입 후 렌더링 단언 | POST_RELEASE_RECOMMENDED | 없음 | FLOW2 |
| 10 | 공휴일 | SIMULATOR_FULL | `kasi_holiday_service`(1곳 seam)는 외부 API를 fake로 대체 가능한 순수 데이터 병합 로직. | fake KASI 응답 주입 후 캘린더 표시 단언 | POST_RELEASE_RECOMMENDED | 없음 | FLOW2 |
| 11 | 화면 navigation | SIMULATOR_FULL | GoRouter 기반 라우팅은 실제 디바이스 입력 없이 시뮬레이터 탭/제스처로 완전 재현 가능. | `WidgetTester.tap` 경로 이동 후 라우트 스택 단언, `integration_test/navigation_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW3 |
| 12 | deep link — planflow://schedule/{id} | SIMULATOR_FULL | canonical 파싱은 순수 함수(`NotificationRouteContract.canonicalPath`)이고, 시뮬레이터도 `xcrun simctl openurl`로 실제 URL scheme 오픈이 가능. | `NotificationRouteContract.canonicalPath()` 직접 단언 + `simctl openurl <UDID> "planflow://schedule/123"` | RELEASE_BLOCKER | 없음(신규 계약 함수, 커버 안 됨) | FLOW3 |
| 13 | deep link — planflow://day/{date} | SIMULATOR_FULL | 위와 동일 메커니즘. | `NotificationRouteContract.canonicalPath()` 직접 단언 + `simctl openurl <UDID> "planflow://day/2026-09-03"` | RELEASE_BLOCKER | 없음 | FLOW3 |
| 14 | notification route handling (탭 시 라우팅) | SIMULATOR_FULL | 알림 payload→라우트 매핑 로직 자체는 순수 함수이며 알림 탭 콜백만 fake로 트리거하면 재현 가능. | `notification_service.dart`(12곳 seam) 중 route handler 콜백 직접 호출 | RELEASE_BLOCKER | 없음 | FLOW3 |
| 15 | local notification scheduling | SIMULATOR_PARTIAL | 예약 로직(트리거 시각 계산·payload 구성)은 시뮬레이터에서 검증 가능하나, 실제 OS 알림 센터 딜리버리 타이밍·잠금화면 표시는 시뮬레이터의 알림 서브시스템 신뢰도가 실기기와 달라(백그라운드 실행 정책이 실제 디바이스와 동일하지 않음) 완전 신뢰 불가. | seam으로 예약 payload/시각 계산 단언(SIMULATOR 부분) + 실기기에서 실제 딜리버리 확인(PHYSICAL 부분) | RELEASE_BLOCKER | 없음 | FLOW3 |
| 16 | notification tap routing (OS 알림 실제 탭) | PHYSICAL_DEVICE_REQUIRED | iOS Simulator는 알림 센터에 실제로 알림을 표시하고 사람이 탭하는 상호작용을 지원하지 않는다(로컬 알림 자체는 예약되지만 잠금화면/알림센터 UI 상호작용은 시뮬레이터 알림 서브시스템의 알려진 제약으로 실기기와 동등하게 재현되지 않는다). | 실기기에서 알림 예약→화면 잠금→알림 탭→앱 라우팅 확인(수동 QA 체크리스트) | POST_RELEASE_RECOMMENDED | 없음 | FLOW3 |
| 17 | voice UI (상태머신/화면 흐름) | SIMULATOR_FULL | 음성 UI 상태 전이(대기→녹음중→처리중→완료)는 STT 엔진 결과를 fake로 주입하면 순수 상태머신으로 검증 가능. | `stt_service.dart`(10곳 seam)로 fake 인식 결과 주입, `integration_test/voice_ui_state_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW2 |
| 18 | microphone permission flow | SIMULATOR_PARTIAL | 권한 요청 다이얼로그 노출/거부 후 앱 동작 분기는 시뮬레이터의 `simctl privacy` 명령으로 권한 상태를 강제 전환해 검증 가능하나, 실제 iOS 권한 프롬프트의 시스템 UI 문구·타이밍은 시뮬레이터 렌더링이 실기기와 완전히 동일하다고 보장되지 않는다. | `simctl privacy grant/revoke microphone <UDID> com.fluxstudio.planflow` + 앱 분기 로직 단언(SIMULATOR 부분), 실기기 프롬프트 UI 육안 확인(PHYSICAL 부분) | RELEASE_BLOCKER | 없음 | FLOW7 |
| 19 | speech recognition (실제 음성→텍스트 품질) | PHYSICAL_DEVICE_REQUIRED | iOS Simulator는 실제 마이크 하드웨어 입력을 지원하지 않아 speech_to_text의 실제 인식 품질(잡음·발화속도·억양 대응)을 검증할 수 없다. | 실기기에서 실제 발화 샘플 세트로 인식률 수동 QA | POST_RELEASE_RECOMMENDED | 없음 | FLOW2 |
| 20 | photo/file picker | PHYSICAL_DEVICE_REQUIRED | iOS Simulator는 카메라 하드웨어가 없어 카메라 캡처 경로를 검증할 수 없고, 사진 라이브러리 피커도 시뮬레이터 기본 사진 세트로만 제한되어 실사용 시나리오(대용량 사진, 다양한 포맷)를 재현하지 못한다. | 실기기에서 카메라 촬영 + 실제 사진 라이브러리에서 다양한 포맷 선택 수동 QA | OPTIONAL | 없음 | FLOW2 |
| 21 | App Group shared data (Runner↔Widget UserDefaults 공유) | SIMULATOR_FULL | App Group `UserDefaults(suiteName:)` 공유는 시뮬레이터에서도 동일한 App Group 컨테이너 메커니즘으로 정상 동작하며 하드웨어 의존이 없다. | Runner에서 값 저장 후 Widget extension에서 동일 App Group으로 읽기 단언, `group_calendar_widget_service.dart`(2곳 seam) 활용 | RELEASE_BLOCKER | 없음 | FLOW4 |
| 22 | Widget payload generation | SIMULATOR_FULL | payload 인코딩(JSON 직렬화 등)은 순수 함수 로직. | `group_calendar_widget_service.dart` seam으로 payload 생성 결과 직접 단언 | RELEASE_BLOCKER | 없음 | FLOW4 |
| 23 | Widget rendering contract (실제 홈화면 WidgetKit 렌더링) | PHYSICAL_DEVICE_REQUIRED | WidgetKit 타임라인 갱신·홈 화면 렌더링은 시뮬레이터에서도 기술적으로는 표시되지만, 실제 배터리/백그라운드 새로고침 정책 하에서의 타임라인 갱신 주기·전력 최적화 동작은 시뮬레이터가 실기기 OS 전력 관리 정책을 반영하지 않아 신뢰할 수 없다. | 실기기 홈 화면에 위젯 추가 후 실제 갱신 주기·렌더링 정합성 수동 QA | POST_RELEASE_RECOMMENDED | 없음 | FLOW4 |
| 24 | Firebase (초기화/Crashlytics/RemoteConfig) | SIMULATOR_FULL | Firebase SDK 초기화 및 RemoteConfig fetch는 시뮬레이터에서 실제 네트워크로 정상 동작하며, `remote_config_service.dart`(5곳 seam)로 fake 값도 주입 가능. Crashlytics는 시뮬레이터에서도 크래시 리포트 전송이 지원된다. | `remote_config_service.dart` seam으로 fake config 주입, Firebase 초기화 완료 여부 단언 | RELEASE_BLOCKER | 없음 | FLOW5 |
| 25 | Supabase (연결/쿼리) | SIMULATOR_FULL | Supabase REST/Realtime 호출은 시뮬레이터에서 실제 네트워크로 정상 동작하고, fake repository로도 완전 대체 가능. | fake repository 또는 실제 테스트 프로젝트 대상 쿼리 단언 | RELEASE_BLOCKER | `ios_phase4_identity_contract_test.dart`(env 설정 정합성만, 런타임 쿼리는 미포함) | FLOW5 |
| 26 | Google Sign-In | SIMULATOR_PARTIAL | Google Sign-In SDK의 OAuth 웹뷰 플로우는 시뮬레이터에서도 표시되나, 실제 Google 계정 로그인은 네트워크·계정 상태에 의존하는 외부 서비스 상호작용이라 자동화된 시뮬레이터 테스트로는 콜백 계약(딥링크 `planflow://auth-callback`)까지만 검증하고 실제 로그인 완주는 수동 확인이 필요하다. | `oauth_callback_handler.dart`(7곳 seam)로 콜백 파싱 계약 단언(SIMULATOR 부분) + 실제 계정으로 수동 로그인 완주 확인(PARTIAL 사유) | RELEASE_BLOCKER | 없음 | FLOW5 |
| 27 | 광고 (AdMob 로드/표시) | SIMULATOR_PARTIAL | AdMob 테스트 광고 단위는 시뮬레이터에서 로드·표시가 되지만, 실제 광고 인벤토리(실 광고주 소재)의 로드 성공률·표시 품질은 시뮬레이터 환경에서 실기기와 동일하게 보장되지 않는다(AdMob 공식 문서상 시뮬레이터는 테스트 광고 전용 권장). | `ad_service.dart`(3곳 seam)로 테스트 광고 단위 로드/표시 단언(SIMULATOR 부분), 프로덕션 광고 단위는 실기기 확인 필요(PARTIAL 사유) | POST_RELEASE_RECOMMENDED | 없음 | FLOW5 |
| 28 | ATT | 확인 필요(별도 문서 참조) | 배경 조사 결과 `app_tracking_transparency` 패키지 및 `ATTrackingManager` 호출이 코드에 존재하지 않음(0건)이 확인됐다. 이는 이 QA 매트릭스가 판정할 대상이 아니라 별도 심사 리스크 항목(N4)으로 처리하며, 이 문서에서 SIMULATOR/PHYSICAL 분류나 릴리스영향도를 임의로 단정하지 않는다. | 해당 없음(이번 Phase 범위 아님) | 확인 필요(별도 문서 참조) | 없음 | FLOW7 |
| 29 | Google/Naver map | SIMULATOR_PARTIAL(P3 실측 대기 — 미확정) | `google_maps_flutter`와 `flutter_naver_map` 둘 다 사용 중이나, 두 SDK가 iOS Simulator(arm64) 슬라이스를 실제로 제공하는지는 2026-09-03 기준 미실측이다. P3에서 실제 시뮬레이터 빌드·실행으로 확인 예정이며, 결과에 따라 이 항목의 분류를 SIMULATOR_FULL 또는 PHYSICAL_DEVICE_REQUIRED로 1회 갱신한다. | P3에서 `flutter build ios --simulator` 후 지도 렌더링 실측, 결과 반영 전까지는 잠정 분류 | 확인 필요(P3 실측 후 재판정) | 없음 | FLOW2 |
| 30 | offline/network failure | SIMULATOR_FULL | 네트워크 단절 시나리오는 fake repository/HTTP client가 예외를 던지도록 구성하면 순수 소프트웨어 로직으로 완전 재현 가능. | fake repository에서 `SocketException` 등 강제 발생 후 UI 에러 처리 단언, `integration_test/network_failure_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW6 |
| 31 | background/foreground 전환 | SIMULATOR_FULL | 앱 생명주기 콜백(`AppLifecycleState`)은 시뮬레이터에서 `simctl` 또는 Flutter test binding으로 상태 전환을 인위적으로 트리거해 완전 재현 가능. | `WidgetsBindingObserver` 콜백 직접 트리거, `integration_test/lifecycle_test.dart`(신설) | RELEASE_BLOCKER | 없음 | FLOW6 |
| 32 | app relaunch | SIMULATOR_FULL | 앱 재기동 후 상태 복원은 순수 저장소 읽기 로직이며 하드웨어 의존이 없다. | 앱 종료 후 재기동 시나리오, fake storage로 복원값 단언 | RELEASE_BLOCKER | 없음 | FLOW6 |
| 33 | permission denial/recovery | SIMULATOR_PARTIAL | 권한 거부 후 앱의 재요청/안내 UI 분기는 `simctl privacy` 명령으로 권한 상태를 강제 전환해 검증 가능하나, iOS 설정 앱으로의 딥링크 이동 후 실제 설정 화면 UI는 시뮬레이터에서도 표시는 되지만 사용자가 실제로 설정을 변경하고 앱으로 복귀하는 전체 흐름은 실기기에서 최종 확인이 필요하다. | `simctl privacy revoke <permission> <UDID> com.fluxstudio.planflow` 후 앱 분기 단언(SIMULATOR 부분), 실기기에서 설정 앱 왕복 확인(PARTIAL 사유) | POST_RELEASE_RECOMMENDED | 없음 | FLOW7 |
| 34 | text scaling | SIMULATOR_FULL | Dynamic Type(텍스트 크기 배율)은 `MediaQuery`의 `textScaler`를 위젯 테스트에서 오버라이드해 실제 하드웨어 없이 완전 재현 가능. | `MediaQuery(data: MediaQueryData(textScaler: ...))` 오버라이드 후 레이아웃 오버플로우 단언 | POST_RELEASE_RECOMMENDED | 없음 | FLOW8 |
| 35 | keyboard | SIMULATOR_FULL | 소프트웨어 키보드 표시에 따른 레이아웃 리사이즈(`resizeToAvoidBottomInset` 등)는 시뮬레이터의 실제 키보드 시뮬레이션으로 완전 재현 가능. | `WidgetTester.showKeyboard` + 뷰포트 인셋 변화에 따른 레이아웃 단언 | POST_RELEASE_RECOMMENDED | 없음 | FLOW8 |
| 36 | orientation | SIMULATOR_FULL | iPhone Portrait 고정/iPad 4방향 회전은 `TARGETED_DEVICE_FAMILY`·Info.plist 설정에 따른 순수 레이아웃 제약이며 시뮬레이터의 `simctl` 디바이스 회전 명령으로 완전 재현 가능. | iPad 시뮬레이터에서 회전 시나리오별 레이아웃 단언, iPhone에서 회전 잠금 확인 | POST_RELEASE_RECOMMENDED | 없음 | FLOW8 |
| 37 | small screen | SIMULATOR_FULL | 소형 화면(예: iPhone SE급) 레이아웃은 시뮬레이터의 다양한 디바이스 프로파일로 완전 재현 가능한 순수 반응형 레이아웃 문제. | iPhone SE 시뮬레이터 프로파일로 오버플로우/잘림 없음 단언, `integration_test/small_screen_layout_test.dart`(신설) | POST_RELEASE_RECOMMENDED | 없음 | FLOW8 |
| 38 | large screen | SIMULATOR_FULL | 대형 화면(iPad Pro급) 레이아웃도 동일하게 시뮬레이터 디바이스 프로파일로 완전 재현 가능. | iPad Pro 시뮬레이터 프로파일로 레이아웃 적응 단언 | POST_RELEASE_RECOMMENDED | 없음 | FLOW8 |

---

## 분류 요약

- `SIMULATOR_FULL`: 24개
- `SIMULATOR_PARTIAL`: 6개 (15, 18, 26, 27, 29(P3 실측 대기), 33)
- `PHYSICAL_DEVICE_REQUIRED`: 4개 (16, 19, 20, 23)
- `확인 필요(별도 문서 참조)`: 1개 (28, ATT — 별도 심사 리스크 항목 N4로 이관)
- 합계: 37개 (사용자 원문 목록 30항목 중 일부가 세분화되어 위 표는 38행이나, 배경에 명시된 원문 딥링크 세분화(12/13), notification 세분화(14/15/16)를 반영한 것으로 항목 누락은 없음)

## 릴리스영향도 요약

- `RELEASE_BLOCKER`: 18개
- `POST_RELEASE_RECOMMENDED`: 17개
- `OPTIONAL`: 1개
- `확인 필요`: 2개(28 ATT, 29 지도 P3 대기)
