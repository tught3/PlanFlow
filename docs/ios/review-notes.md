# PlanFlow — App Store 심사 노트 초안

이 문서는 App Store Connect "심사 정보(App Review Information)" 섹션에 입력할
심사자용 노트 초안이다. **계정 자격증명·API 키·비밀번호·실제 이메일 주소는
이 저장소 어디에도 절대 기재하지 않는다** — 아래 검증 명령으로 확인했다.

## 1. 로그인/데모 계정

`lib/services/auth_service.dart:13-16`에서 확인: PlanFlow는 로그인 필수 앱이며
지원하는 로그인 방식은 Supabase OAuth 경유 **Google, Kakao, Naver** 3종이다
(`PlanFlowOAuthProvider` enum). 게스트/비로그인 사용 경로는 이번 조사에서
확인되지 않았다(UNVERIFIED — 별도 로컬 전용 모드가 있는지는 미조사).

App Store 심사자는 이 앱을 실행하려면 로그인이 필요하므로 **심사용 데모 계정이
필수**다. 계정 아이디/비밀번호 값은:

```
심사용 계정: PENDING_USER_INPUT
```

App Store Connect 제출 직전 운영자가 직접 테스트 계정을 생성해 App Store
Connect의 "Sign-In required" 섹션에 입력해야 한다(이 문서·저장소에는 넣지
않는다).

## 2. Sign in with Apple 미구현 — 가이드라인 4.8 리스크

`docs/ios/app-store-metadata.md`의 "로그인 정책 결정" 섹션과 동일한 근거:
현재 Supabase OAuth provider는 Google·Kakao·Naver뿐이고 **Sign in with Apple은
구현되어 있지 않다**(`auth_service.dart` 전수 확인, `OAuthProvider.apple`
참조 없음).

Apple App Store Review Guideline 4.8("Sign in with Apple")은 제3자 소셜
로그인(Google 등)을 제공하는 앱은 원칙적으로 Sign in with Apple도 동등하게
제공해야 한다고 요구한다. 예외 조건(예: 기업 전용 계정, 특정 교육/기업
백엔드 전용 앱 등)에 해당하지 않는 한 **이 상태로 제출하면 4.8 사유로
반려될 위험이 있다.**

이번 작업 범위에서는 Sign in with Apple을 구현하지 않는다(오케스트레이터
지시 범위 밖 — Apple/Firebase 설정 변경 금지). 심사 노트에는 이 리스크를
명시적으로 남기고, 필요 시 운영자가 제출 전 구현 여부를 별도 결정해야 한다.

## 3. 권한 요청과 실제 기능 매핑 (심사자 설명용)

`ios/Runner/Info.plist`에 선언된 권한 문구와 그 권한이 실제로 쓰이는 기능을
1:1로 매핑한다(파일 직접 확인, `docs/ios/privacy-surface-audit.md`의 Evidence
matrix와 교차 일치):

| Info.plist 키 | 문구(원문) | 실제 사용 기능 |
|---|---|---|
| `NSMicrophoneUsageDescription` | "음성으로 일정을 입력하려면 마이크 권한이 필요합니다." | 음성으로 일정 입력(핵심 기능) |
| `NSSpeechRecognitionUsageDescription` | "음성을 일정 내용으로 변환하려면 음성 인식 권한이 필요합니다." | STT로 음성을 텍스트 일정으로 변환(기기 내 처리) |
| `NSLocationWhenInUseUsageDescription` | "일정 장소를 지도에서 찾고 출발지와 목적지를 확인하려면 위치 권한이 필요합니다." | 일정 장소 지도 검색, 이동시간 계산용 출발지 확인 |
| `NSPhotoLibraryUsageDescription` | "지도 SDK가 장소 사진을 표시할 수 있도록 사진 보관함 접근 권한이 필요합니다." | 지도 SDK(Google Maps) 내부 장소 사진 표시 — 앱이 직접 사진을 읽지는 않음 |
| `NSPhotoLibraryAddUsageDescription` | "지도 SDK가 지도 관련 이미지를 사진 보관함에 저장할 수 있도록 사진 추가 권한이 필요합니다." | 지도 SDK 내부 이미지 저장 |
| `NSUserTrackingUsageDescription` | "관련 광고를 제공하고 서비스 이용을 개선하기 위해 기기 식별자 사용 권한이 필요합니다." | 광고(Google Mobile Ads) 식별자 기반 맞춤 광고 동의(ATT) |

심사자 안내 문구 초안:

```
이 앱은 다음 권한을 요청합니다:
1) 마이크/음성인식 — 핵심 기능인 "말로 일정 입력"에 사용됩니다. 음성은 기기
   내에서만 처리되며 녹음 파일은 서버로 전송되지 않습니다.
2) 위치(사용 중) — 일정 장소를 지도에서 찾고 이동 시간을 계산하는 데
   사용됩니다.
3) 사진 보관함(읽기/추가) — 앱이 직접 사진을 열람하지 않으며, 지도 SDK가
   내부적으로 장소 사진을 표시/저장하는 데만 사용됩니다.
4) 광고 추적(ATT) — 관련성 있는 광고 제공에 사용되며, 거부해도 앱 기능에는
   영향이 없습니다.
```

## 4. 홈 화면 위젯 사용법 (심사자용 안내)

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

**TODO(사람 확인 필요)**: 위 사용법은 Android 버전 설명 문구를 참고한
일반적 서술이며, iOS WidgetKit 구현이 정확히 어떤 위젯 크기/타임라인을
제공하는지는 `PlanFlowWidget.swift`를 직접 열어 재검증해야 한다(이번 조사는
파일 존재만 확인).

## 5. 검증

이 파일에 실제 자격증명(비밀번호·API 키 등)을 넣지 않았음을 커밋 전
재확인한다. 확인 명령의 리터럴 패턴 문자열이 이 문서 자체에 포함되지 않도록
별도 문서(`docs/ios/README.md` 또는 작업 로그)에서 실행한다 — 검증 명령
문자열을 이 파일 안에 그대로 적으면 그 명령 자체가 자기 자신과 매치되어
거짓 양성(self-match)이 발생한다.
