# PlanFlow — App Store 심사 노트 + 반려 대응 초안

이 문서는 App Store Connect "심사 정보(App Review Information)" 섹션에 입력할
심사자용 노트와, 반려(submission 40f5613b-336b-4de8-9c92-b8741b5cf132,
Build23)에 대한 재제출 대응 초안을 담는다. **계정 자격증명·API 키·비밀번호·
실제 이메일 주소는 이 저장소 어디에도 절대 기재하지 않는다.**

## 1. 로그인/데모 계정

`lib/services/auth_service.dart`에서 확인: PlanFlow는 로그인 필수 앱이며
지원하는 로그인 방식은 Supabase OAuth 경유 **Google, Kakao, Naver,
Apple** 4종이다(`PlanFlowOAuthProvider` enum에 `apple` 포함,
commit ebb67f71에서 Sign in with Apple 심사 대응 완료).
`ios/Runner/PlanFlow.entitlements`에 `com.apple.developer.applesignin`이
선언되어 있다.

App Store 심사자는 이 앱을 실행하려면 로그인이 필요하므로 **심사용 데모 계정이
필수**다. 계정 아이디/비밀번호 값은:

```
심사용 계정: PENDING_USER_INPUT
```

App Store Connect 제출 직전 운영자가 직접 테스트 계정을 생성해 App Store
Connect의 "Sign-In required" 섹션에 입력해야 한다(이 문서·저장소에는 넣지
않는다).

## 2. 권한 요청과 실제 기능 매핑 (심사자 설명용)

`ios/Runner/Info.plist`에 선언된 권한 문구와 그 권한이 실제로 쓰이는 기능을
1:1로 매핑한다(commit 8efb6d46에서 `NSUserTrackingUsageDescription`가
Info.plist에서 **제거**되었으므로 이 표에 없다). 앱은 ATT
(`ATTrackingManager.requestTrackingAuthorization`)를 요청하지 않고 IDFA에
직접 접근하지 않는다(`lib/` 및 `ios/Runner` 전수 확인, 매치 없음).

| Info.plist 키 | 문구(원문) | 실제 사용 기능 |
|---|---|---|
| `NSMicrophoneUsageDescription` | "음성으로 일정을 입력하려면 마이크 권한이 필요합니다." | 음성으로 일정 입력(핵심 기능) |
| `NSSpeechRecognitionUsageDescription` | "음성을 일정 내용으로 변환하려면 음성 인식 권한이 필요합니다." | STT로 음성을 텍스트 일정으로 변환(기기 내 처리) |
| `NSLocationWhenInUseUsageDescription` | "일정 장소를 지도에서 찾고 출발지와 목적지를 확인하려면 위치 권한이 필요합니다." | 일정 장소 지도 검색, 이동시간 계산용 출발지 확인 |
| `NSPhotoLibraryUsageDescription` | "지도 SDK가 장소 사진을 표시할 수 있도록 사진 보관함 접근 권한이 필요합니다." | Info.plist에 선언된 실제 문자열; 과거 Maps/Photos signed-binary 심볼은 간접/진단 SDK 증거이며 PlanFlow의 직접 사진 선택·보관함 읽기·업로드·수집 경로 증거가 아님 |
| `NSPhotoLibraryAddUsageDescription` | "지도 SDK가 지도 관련 이미지를 사진 보관함에 저장할 수 있도록 사진 추가 권한이 필요합니다." | Info.plist에 선언된 실제 문자열; 과거 signed-binary 심볼은 간접/진단 SDK 증거이며 PlanFlow의 직접 사진 쓰기·업로드·수집 경로 증거가 아님 |

심사자 안내 문구 초안:

```
이 앱은 다음 권한을 요청합니다:
1) 마이크/음성인식 — 핵심 기능인 "말로 일정 입력"에 사용됩니다. 음성은 기기
   내에서만 처리되며 녹음 파일은 서버로 전송되지 않습니다.
2) 위치(사용 중) — 일정 장소를 지도에서 찾고 이동 시간을 계산하는 데
   사용됩니다.
3) 사진 보관함(읽기/추가) — 현재 PlanFlow 소스에는 사용자 사진 선택,
   사진 보관함 읽기·쓰기, 업로드 또는 수집 경로가 없습니다. 과거 Maps/Photos
   signed-binary 심볼은 간접/진단 SDK 증거이며 직접 사용을 입증하지 않습니다.
```

### 권한 거부 처리 (Guideline 5.1.1(iv))

commit 75504afe에서 반영: 권한이 거부되면 앱이 이를 존중하며, **설정 앱으로
자동 리다이렉트하지 않는다**. 설정 앱을 열기 전에는 반드시 사용자에게 명시적
확인을 받는다. 온보딩도 중립적(neutral)으로, 권한 허용을 강요하지 않는다.

## 3. 홈 화면 위젯 사용법 (심사자용 안내)

`ios/PlanFlowWidget/`(WidgetKit extension, `.entitlements` 포함)가 저장소에
존재함을 확인했다. 위젯의 정확한 표시 데이터·상호작용 로직(`PlanFlowWidget.swift`
전체)까지는 이번 조사에서 코드를 정독하지 않았으므로, 아래는 Play Store 설명
문구(`docs/play-store-listing.md:50-51`)에 근거한 **일반적인 사용법 안내**다:

```
홈 화면 위젯 추가 방법:
1) 홈 화면을 길게 눌러 편집 모드로 진입합니다.
2) 좌측 상단 "+" 버튼을 눌러 위젯 갤러리를 엽니다.
3) "PlanFlow"를 검색해 원하는 크기의 위젯을 홈 화면에 추가합니다.

위젯에 표시되는 내용:
- 다가오는 일정 목록 또는 월간 달력 뷰(위젯 종류에 따라 다름)
- 위젯에서 바로 음성으로 새 일정을 등록할 수 있는 버튼(앱 실행 후 음성 입력
  화면으로 연결)
```

**PENDING(새 빌드 검증 필요)**: 위젯 extension의 아카이브 레벨 embedding/
signing은 새 빌드에서 확인 전이다. 위 사용법도 `PlanFlowWidget.swift`를 직접
열어 위젯 크기/타임라인이 정확히 일치하는지 재검증해야 한다.

## 4. Rejection response draft (submission 40f5613b-336b-4de8-9c92-b8741b5cf132, Build23 → new build)

영문 그대로 App Review에 제출할 항목별 응답 초안. **[PENDING BUILD VERIFICATION]
표시 항목은 새 빌드 아카이브에서 확인되기 전까지 제출 금지** — 운영자가
readback 후 표시를 제거해야 한다.

### Guideline 4.8 — Sign in with Apple

> Sign in with Apple is now implemented. The app offers Google, Kakao, Naver,
> and Apple as equivalent sign-in options on the login screen. Sign in with
> Apple is fully supported on iOS using the native flow, and the
> `com.apple.developer.applesignin` entitlement is included in the app.

### Guideline 5.1.1(iv) — Permission denial / Settings redirection

> The app respects permission denials and remains fully functional with
> reduced functionality when a permission is declined. The app never
> automatically redirects the user to the Settings app; opening Settings
> requires an explicit user confirmation step each time. The onboarding flow
> is neutral and does not pressure users into granting permissions.

### Guideline 4 (Design) — Maps

> On iOS the app now offers Apple Maps as an option in the external map
> picker (in addition to the existing map provider), so map launching follows
> the native iOS experience.

### ATT / Guideline 2.1 — Tracking

> The app does not request App Tracking Transparency authorization
> (`ATTrackingManager.requestTrackingAuthorization` is never called) and does
> not access the IDFA. The `NSUserTrackingUsageDescription` key has been
> removed from Info.plist in the new build. App Privacy declarations in App
> Store Connect are being updated accordingly (Device ID / Advertising Data
> — tracking purpose: No) to match actual app behavior.
>
> **[PENDING — operator action in App Store Connect, until readback]**:
> App Privacy 변경은 아직 완료로 표기하지 않는다. 운영자가 App Store Connect에서
> 선언을 수정하고 readback으로 확인한 후에야 "corrected"로 말할 수 있다.

### Widget / Guideline 2.1

> The app includes a home screen widget (WidgetKit extension). Reviewer steps:
>
> 1. Long-press the home screen to enter edit mode.
> 2. Tap the "+" button in the top-left corner to open the widget gallery.
> 3. Search for "PlanFlow" and add the widget in the desired size.
>
> The widget shows upcoming schedules / a monthly calendar view, per the
> widget size.
>
> **[PENDING BUILD VERIFICATION]**: 새 빌드 아카이브에서 widget extension의
> embedding/signing이 확인되기 전까지 이 문단을 제출하지 않는다.

## 5. 검증

이 파일에 실제 자격증명(비밀번호·API 키 등)을 넣지 않았음을 커밋 전
재확인한다. 확인 명령의 리터럴 패턴 문자열이 이 문서 자체에 포함되지 않도록
별도 문서(`docs/ios/README.md` 또는 작업 로그)에서 실행한다 — 검증 명령
문자열을 이 파일 안에 그대로 적으면 그 명령 자체가 자기 자신과 매치되어
거짓 양성(self-match)이 발생한다.
