# 템플릿 파라미터 스키마

이 디렉토리의 모든 `.tmpl` 파일은 아래 파라미터를 `{{PARAM_NAME}}` 형태로만 참조한다.
템플릿 본문에는 특정 앱의 리터럴 값이 존재하지 않는다.

- **필수**: 값이 없으면 템플릿을 배치할 수 없다. 반드시 확정한 뒤 치환한다.
- **조건부**: 대응하는 기능 플래그가 `true`일 때만 의미가 있다. `false`면 해당 게이트/체크 블록을 삭제한다.
- **예시 값 컬럼**은 "이런 형태의 값이 들어간다"를 보여주기 위한 것이며, 정답이 아니다.
  각 앱의 확정 값은 별도 값 파일(예: `planflow.values.md`)에 기록한다.

## 식별자 파라미터

| 파라미터 | 설명 | 예시 값(PlanFlow) | 필수여부 |
|---|---|---|---|
| `APP_NAME` | 앱의 고유명사. 아카이브 파일명, 아티팩트 이름, 문서 제목에 쓰인다. Xcode scheme 이름(`Runner`)과는 다르다. | `PlanFlow` | 필수 |
| `BUNDLE_ID` | 앱 본체(Runner)의 canonical CFBundleIdentifier. 워크플로가 IPA/아카이브 메타데이터와 대조하는 기준값이다. | `com.fluxstudio.planflow` | 필수 |
| `WIDGET_BUNDLE_ID` | WidgetKit extension의 CFBundleIdentifier. 관례상 `<BUNDLE_ID>.<APP_NAME>Widget`. Runner와 **절대 같은 값이면 안 된다**. | `com.fluxstudio.planflow.PlanFlowWidget` | 조건부 (`HAS_WIDGET=true`) |
| `APP_GROUP` | Runner와 Widget이 `UserDefaults(suiteName:)`로 데이터를 공유하는 App Group 식별자. 프로비저닝 프로파일 entitlement와 정확히 일치해야 한다. | `group.com.fluxstudio.planflow` | 조건부 (`HAS_WIDGET=true`) |
| `URL_SCHEME` | 딥링크/OAuth 콜백에 쓰는 커스텀 URL scheme(`://` 제외). `simctl openurl` 검증과 `Info.plist`의 `CFBundleURLSchemes`에 동일하게 들어간다. | `planflow` | 필수 |
| `SECRET_PREFIX` | GitHub Actions Secret 이름의 앱별 접두어. 한 조직 계정에서 여러 앱의 서명 자산을 구분하기 위해 쓴다. 예: `<SECRET_PREFIX>_APPLE_TEAM_ID`. | `PLANFLOW` | 필수 |

## 빌드/타깃 파라미터

| 파라미터 | 설명 | 예시 값(PlanFlow) | 필수여부 |
|---|---|---|---|
| `MIN_IOS_VERSION` | 앱이 최종 선언하는 최소 iOS deployment target. `ios/Podfile`의 `platform :ios`와 Xcode의 `IPHONEOS_DEPLOYMENT_TARGET`이 동일해야 한다. preflight 1~3번 결과로 결정한다. | `15.0` | 필수 |
| `FLUTTER_VERSION` | CI에서 `subosito/flutter-action`에 고정할 Flutter SDK 버전. 러너 기본값에 의존하지 말고 명시 고정한다(빌드 재현성). | `3.47.2` | 필수 |
| `TARGETED_DEVICE_FAMILY` | Xcode 디바이스 패밀리 값. `1`=iPhone, `2`=iPad, `1,2`=범용. 회전/레이아웃 QA 범위를 결정하므로 시뮬레이터 매트릭스와 일치해야 한다. | `1,2` | 필수 |
| `BACKEND_KIND` | 백엔드 구성 유형. 허용값: `supabase-and-firebase` / `supabase-only` / `firebase-only` / `none`. 어떤 설정 파일 주입 게이트가 필요한지를 결정한다. | `supabase-and-firebase` | 필수 |

## 기능 플래그 파라미터

값은 `true` / `false` 중 하나다. `false`면 템플릿에서 해당 블록을 **삭제**한다(주석 처리로 남기지 않는다 — 죽은 게이트가 된다).

| 파라미터 | 설명 | 예시 값(PlanFlow) | 필수여부 |
|---|---|---|---|
| `HAS_WIDGET` | WidgetKit extension 존재 여부. `true`면 위젯 전용 프로비저닝 프로파일 / App Group / 아카이브 내 `.appex` 존재 게이트가 활성화된다. | `true` | 필수 |
| `HAS_MICROPHONE` | 마이크 사용 여부. `true`면 `NSMicrophoneUsageDescription` 필수 게이트와 `simctl privacy microphone` 검증이 활성화된다. | `true` | 필수 |
| `HAS_SPEECH` | 음성 인식(Speech framework) 사용 여부. `true`면 `NSSpeechRecognitionUsageDescription` 게이트가 활성화된다. 실제 인식 품질은 시뮬레이터로 검증 불가(실기기 항목). | `true` | 필수 |
| `HAS_PHOTOS` | 사진 라이브러리 읽기/쓰기 사용 여부. `true`면 `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` 게이트가 활성화된다. | `true` | 필수 |
| `HAS_LOCATION` | 위치 사용 여부. `true`면 `NSLocationWhenInUseUsageDescription` 게이트가 활성화된다. 상시 위치(`Always`)를 쓰면 별도 키가 추가로 필요하므로 이 플래그만으로 부족하다. | `true` | 필수 |
| `HAS_ADS` | 광고 SDK(AdMob 등) 사용 여부. `true`면 추적 권한 관련 키와 테스트 광고 단위 사용 확인 항목이 활성화된다. 시뮬레이터는 테스트 광고 전용이다. | `true` | 필수 |
| `USES_TRACKING` | 앱이 **실제로 ATT 권한을 요청**하는지 여부(`ATTrackingManager` / `app_tracking_transparency` 호출 존재). `HAS_ADS`와 **별개 질문**이다 — 아래 주의 참조. | `false` | 필수 |
| `HAS_MAP` | 지도 SDK 사용 여부. `true`면 해당 SDK가 iOS Simulator(arm64) 슬라이스를 제공하는지 **CI 1차 실행에서 실측**해야 한다(로컬 Windows에서는 확인 불가). | `true` | 필수 |
| `REVIEW_ACCOUNT_REQUIRED` | 심사자가 앱의 주요 화면에 도달하려면 **로그인이 필요한지** 여부. `true`면 App Store Connect 심사 노트에 데모 계정(ID/PW, 필요 시 우회 코드) 제공이 필수 게이트가 된다. 로그인 필요 앱인데 계정 미제공은 흔한 반려 사유다. | `true` | 필수 |

### `HAS_ADS` vs `USES_TRACKING` — 반드시 구분할 것

두 플래그는 자주 혼동되지만 서로 다른 것을 묻는다.

| | 질문 | 판정 방법 |
|---|---|---|
| `HAS_ADS` | 광고 SDK가 앱에 **포함**되는가? | 의존성 선언(`pubspec.yaml`) 확인 |
| `USES_TRACKING` | 앱이 ATT 권한을 **직접 요청**하는가? | `ATTracking` / `app_tracking_transparency` / `requestTrackingAuthorization` / `advertisingIdentifier` / `AdSupport` 코드 검색 |

**`HAS_ADS=true` 이면서 `USES_TRACKING=false` 인 조합이 실제로 존재한다**(PlanFlow가 그 경우다).
이 조합에서도 `NSUserTrackingUsageDescription` 키는 **삭제하면 안 된다** —
릴리스 워크플로 게이트가 이 키를 요구하고, 키 없이 업로드하면 Apple이
`90683 Missing purpose string`으로 거부한 이력이 있다.

**한계(정직 고백)**: `USES_TRACKING=false`는 "앱 코드가 ATT를 호출하지 않는다"까지만 보장한다.
Apple의 *tracking* 정의는 앱에 포함된 **서드파티 SDK의 행위**도 포함하므로,
이 플래그만으로 App Privacy 설문의 "추적하지 않음"을 확정하지 마라.
설문 답변은 각 SDK 공급자의 공식 데이터 공개 문서를 근거로 확정한다.

## 시나리오 파라미터

| 파라미터 | 설명 | 예시 값(PlanFlow) | 필수여부 |
|---|---|---|---|
| `E2E_FLOWS` | 이 앱에 적용할 E2E FLOW 식별자 목록(공백 구분). 워크플로의 매트릭스 축과 QA 분류 매트릭스의 `담당FLOW` 컬럼이 같은 값을 써야 한다. | `FLOW1 FLOW2 FLOW3 FLOW4 FLOW5 FLOW6 FLOW7 FLOW8` | 필수 |

### FLOW 식별자 관례

> **⚠️ FLOW 번호 ↔ 축 매핑은 앱마다 다르다. 이 표를 정본으로 삼지 마라.**
>
> 아래 표는 **참고용 축 목록**이지 고정 번호 규약이 아니다.
> 각 앱은 자기 저장소의 E2E 정의 문서(예: `docs/ios/E2E_XCTEST_ARCHITECTURE.md`)와
> QA 매트릭스(`docs/ios/SIMULATOR_QA_MATRIX.md`)의 `담당FLOW` 컬럼을 **단일 소스**로 삼고,
> 값 파일(`<app>.values.md`)에 자기 앱의 실제 매핑을 적는다.
>
> **왜 이 경고가 있는가(실측)**: 과거 이 표는 `FLOW6=복원력` / `FLOW7=권한` /
> `FLOW4=확장(Extension)`으로 적혀 있었지만, PlanFlow의 실제 정의는
> `docs/ios/E2E_XCTEST_ARCHITECTURE.md:60-62` 기준으로
> `FLOW6=voice/permission` / `FLOW7=Widget·App Group` / `FLOW8=resilience·a11y`였다.
> 즉 **템플릿 관례표와 실제 앱이 이미 어긋나 있었다.** 이걸 모르고 표를 복사하면
> 다음 앱이 "FLOW7 통과"를 서로 다른 의미로 해석하게 된다.

**앱 간 비교가 필요하면 번호가 아니라 "축 이름"으로 비교하라.** 아래는 축 후보 목록이다.

| 축 | 대표 항목 | PlanFlow에서의 번호 |
|---|---|---|
| 기동 | cold start, 첫 프레임 렌더링 | `FLOW1` |
| 핵심 도메인 | 도메인 객체 CRUD, 입력 UI | `FLOW2` |
| 라우팅 | 화면 이동, 딥링크, 알림 라우팅 | `FLOW3` |
| 알림 | 알림 payload/route, 예약 로직 | `FLOW4` |
| 인증·백엔드 | 로그인/세션, 백엔드 연결, 외부 SDK 초기화 | `FLOW5` |
| 권한·음성 | 권한 요청/거부/복구 분기, 음성 상태 | `FLOW6` |
| 확장(Extension) | App Group 공유, 위젯 payload | `FLOW7` |
| 복원력·접근성·레이아웃 | 오프라인, 생명주기 전환, 텍스트 배율, 회전, a11y | `FLOW8` |

> "PlanFlow에서의 번호" 컬럼은 **예시**다. 다른 앱이 같은 축에 다른 번호를 붙여도 되고,
> 축을 합치거나 나눠도 된다. 다만 **한 저장소 안에서는** 워크플로 매트릭스 축,
> QA 매트릭스 `담당FLOW`, `integration_test/` 파일명이 **모두 같은 매핑**을 써야 한다.
> 셋 중 하나라도 어긋나면 어떤 시나리오가 실제로 돌았는지 사후에 알 수 없다.
