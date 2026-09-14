# PlanFlow 개인정보처리방침 보완 릴리스 노트

상태: PUBLICATION_VERIFIED

공개용 최종 문안은 [planflow-privacy-policy-final.md](./planflow-privacy-policy-final.md)이다. Flux Studio 사업자 정보, PlanFlow의 실제 계정·일정·그룹·음성 텍스트·위치·광고·진단 흐름을 반영했으며, 내부 저장소 경로·광고 단위 ID·비공개 연락처를 포함하지 않았다.

확정·반영 사항:

- 사업자명 Flux Studio, 주소 경기도 성남시 광명로 75 303호, 책임자 대표자, 문의 support@fluxstudio.co.kr.
- 만 14세 미만 대상 아님. 공개 UGC는 없고 인증된 그룹 내부 일정·댓글만 제한적으로 공유한다.
- iOS에는 `NSUserTrackingUsageDescription`이 남아 있지만 직접 ATT 요청·IDFA 접근은 없고, UMP 광고 동의는 ATT와 별개다. 인증된 AdMob Privacy & messaging 확인에서 iOS IDFA 메시지는 현재 `NOT_CONFIGURED`이고 tracking 값은 false로 확인됐다. 향후 IDFA 메시지가 DRAFT/ACTIVE로 바뀌면 `PRIVACY_CHANGE_REQUIRED`, `ATT_REASSESSMENT_REQUIRED`, `APP_PRIVACY_REASSESSMENT_REQUIRED`를 모두 재검토한다.
- 원시 음성은 기기 내 처리하고, 인식 텍스트만 서버/OpenAI 경로로 전달될 수 있다.
- 계정 삭제, 그룹 리더 제약, 개인 백업·복구 스냅샷 순환, 그룹 백업의 소유자 삭제 방식, Supabase 일본 리전 및 글로벌 제공자 처리 범위를 문안에 반영했다.

주요 외부 근거:

- [Apple App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Google Mobile Ads iOS IDFA/ATT](https://developers.google.com/admob/ios/privacy/idfa)
- [Google Mobile Ads iOS data disclosure](https://developers.google.com/admob/ios/privacy/data-disclosure)
- [Firebase privacy and security](https://firebase.google.com/support/privacy/)
- [Supabase regions](https://supabase.com/docs/guides/platform/regions)
- [OpenAI API data controls](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint)

게시 경계:

- 이 커밋은 공개 문안과 Store 프로필 근거만 준비한다.
- `https://fluxstudio.co.kr/privacy`는 Homepage production deployment `dpl_X4zgciGJUt3FNMwaW8pzTeNNaiZ4` 후 실제로 교체되었고, HTTP 200 및 PlanFlow 의미·금지문구 계약 readback을 통과했다. App Store Connect/Google Play 메타데이터와 App Privacy 답변에는 쓰기 변경을 하지 않았으며, Apple 수락도 주장하지 않는다.
- 현재 제출 중인 iOS Build23, Android 설정, iOS Rewarded 원격 설정은 변경하지 않는다.
