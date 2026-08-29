# iOS App Store 제출 초안 (계정 입력 전)

이 문서는 저장소에서 확인 가능한 기능과 SDK를 기준으로 만든 입력 초안이다.
실제 수집 여부·보관 기간·처리자·URL은 Apple/Firebase/Supabase/AdMob 계정과
개인정보처리방침을 확인한 뒤 확정한다. 계정 정보, 키, plist는 이 저장소에 넣지 않는다.

## 기본 입력

- 앱 이름: PlanFlow
- 부제목·설명·키워드: 제품 문구 확정 후 입력
- 카테고리·연령 등급: 운영자가 제품 정책에 따라 확정
- 지원 URL·개인정보처리방침 URL: 공개 URL 확정 전 보류
- 심사 연락처·테스트 계정: App Store Connect에서 별도 입력

## 코드에서 확인된 기능/SDK 인벤토리

| 영역 | 저장소 근거 | App Store Connect 검토 항목 |
|---|---|---|
| 계정·동기화 | `lib/services/auth_service.dart`, Supabase 초기화 | 계정 식별자, 사용자 제공 일정·그룹 데이터, 삭제 요청 절차 |
| AI 일정 정리·대화 | `lib/services/gpt_service.dart` 및 관련 화면 | 입력 텍스트가 외부 AI 처리로 전송되는지, 보관·제3자 처리자 고지 |
| 음성 입력·TTS | `speech_to_text`, `flutter_tts`, `ios/Runner/Info.plist` | 마이크·Speech 권한 문구와 음성 데이터 처리 여부 |
| 지도 | `google_maps_flutter` | 위치 권한을 실제 요청하는 경로와 위치 데이터 사용 여부 |
| 광고 | `google_mobile_ads` | 광고 식별자/추적 동의(ATT) 및 AdMob 데이터 처리 확인 |
| 진단 | Firebase Core/Crashlytics/Remote Config 사용 코드 | Crashlytics 진단 데이터와 Remote Config 통신의 수집·연결 여부 |
| 위젯·알림 | `home_widget_service.dart`, `notification_service.dart` | App Group 공유 데이터, 알림 payload, 백그라운드 갱신 고지 |

표의 항목은 “코드에서 사용 가능함”을 뜻하며 실제 개인정보 라벨 답변을 자동으로
결정하지 않는다. 각 제공자의 최신 데이터 처리 문서와 운영 설정을 대조해 최소 범위로
선언한다.

## 로그인 정책 결정

현재 Supabase OAuth provider는 Google·Kakao·Naver이며 Sign in with Apple 구현은 없다.
Apple 심사 예외 적용 가능 여부를 계정·정책 기준으로 확인하고, 필요하면 별도 승인된
Supabase nonce/account-linking 설계 후 구현한다. 이번 단계에서는 Apple capability나
인증 SDK를 추가하지 않는다.

## 제출 전 체크리스트

- [ ] Apple Developer Bundle ID와 Firebase iOS 앱 ID가 동일한지 확인
- [ ] `GoogleService-Info.plist`를 확정 ID로 다운로드해 macOS target에만 추가
- [ ] App Group 및 WidgetKit extension capability를 Apple 계정에 등록
- [ ] 개인정보처리방침·지원 URL과 삭제 요청 경로 공개
- [ ] App Privacy 답변을 실제 운영 설정과 대조
- [ ] 권한 설명, 광고 동의, 로그인/계정 삭제 흐름을 실기기에서 확인
- [ ] 심사 메모에 테스트 계정·AI/광고 동작·위젯 제한을 명시
