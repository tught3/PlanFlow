# PlanFlow 개인정보처리방침 보완 초안

이 문서는 스토어 제출 전에 공개 개인정보처리방침을 보완하기 위한 **검토용 초안**이다. 게시된 법적 고지나 App Store Connect 답변을 대신하지 않는다. 아래에서 코드와 공급자 문서로 확인한 사실, 그리고 사업자가 확정해야 할 사실을 분리한다.

## 현재 소스에서 확인한 처리

- 계정: 이메일/사용자 ID를 인증과 계정 연결에 사용한다 (`lib/services/auth_service.dart`).
- 일정/그룹: 사용자가 입력한 일정, 그룹 댓글 등 사용자 콘텐츠를 Supabase에 저장한다 (`lib/data/repositories/event_repository.dart`, `lib/features/groups/repositories/group_event_comment_repository.dart`).
- 위치: 일정 이동시간 계산에서 기기의 위도·경도를 Tmap/Naver로 보내며, 필요할 때 Google Maps API로 대체한다 (`lib/services/travel_time_buffer_service.dart`, `lib/services/map_service.dart`).
- 음성/텍스트: 음성 인식 결과와 사용자가 입력한 일정 텍스트는 일정 생성 기능을 위해 서버 기능으로 전송될 수 있다 (`lib/services/gpt_service.dart`). 원시 음성 파일을 저장·전송한다는 소스 근거는 확인하지 못했다.
- 광고: iOS 운영 빌드는 Remote Config의 `rewarded_ad_unit_id_ios`가 유효할 때만 보상형 광고를 요청한다. Google Mobile Ads SDK가 광고 요청·노출 과정에서 처리할 수 있는 정보는 [AdMob iOS 데이터 공개 문서](https://developers.google.com/admob/ios/privacy/data-disclosure)를 기준으로 별도 확인해야 한다. 광고 데이터의 App Privacy 추적(ATT/IDFA) 답변은 아직 확정하지 않았다.
- 진단/원격 설정: Firebase Crashlytics와 Remote Config가 사용된다. Firebase의 제품별 처리 설명은 [Firebase 개인정보 보호 및 보안](https://firebase.google.com/support/privacy/)을 참조한다. 설치 ID, 오류·성능 정보의 실제 보관기간은 Firebase 공급자 문서와 PlanFlow 운영 설정을 함께 확인해야 한다.
- 사진: 현재 확인한 공유 수신 경로는 `.ics` 캘린더 파일만 허용한다 (`lib/app.dart:648-707`, `lib/services/naver_ics_share_store.dart`). 사진을 수집한다는 소스 근거는 확인하지 못했다.

## 공개 정책에 넣을 최소 항목

위 사실을 바탕으로 공개 정책에는 수집 항목별 목적, 처리 방법, 제3자/수탁자, 국외 이전, 보관기간, 이용자 권리, 책임자 연락처를 표로 명시해야 한다. 특히 광고·위치·음성/텍스트·일정/그룹 콘텐츠·계정·진단 데이터가 현재의 실제 동작과 일치해야 한다.

## 게시 전 사업자 확인 필요

다음 값은 저장소나 공개 공급자 문서만으로 결정하지 않는다.

1. 각 데이터 종류의 정확한 보관기간과 삭제 시점(계정 삭제·탈퇴 후 백업 포함).
2. Supabase, OpenAI, Tmap, Naver, Google Maps, Google Mobile Ads, Firebase 각각의 수탁/공동·독립 처리 지위와 국외 이전 국가·일시·방법.
3. 개인정보처리자 법인명, 주소, 개인정보보호책임자와 문의 이메일/전화.
4. 광고 식별자/추적(ATT) 사용 여부와 사용한다면 동의·거부 후 동작.
5. 아동 대상 여부, 그룹 콘텐츠 신고·차단·삭제 절차, 법정 보존 의무.

이 값들이 확정되기 전에는 이 초안을 `READY_TO_PUBLISH` 또는 법률 검토 완료로 표시하지 않는다. 현재 Store qualification의 `PRIVACY_POLICY_MISMATCH`는 유지한다.

## 제출 전 대조 체크

- 공개 URL이 PlanFlow 전용 정책으로 연결되는가.
- App Store Connect App Privacy 답변에 위 처리자와 데이터 유형이 모두 반영되는가.
- 광고 데이터의 추적 여부는 ATT 구현 및 실제 운영 결정을 확인한 뒤 답했는가.
- 정책 공개 이후에만 스토어 메타데이터를 갱신하는가.
