# PlanFlow Store Profile 현황

## 개요

이 문서는 PlanFlow 앱의 스토어 배포 정보를 정리한 **profile이 정본**이다. PlanFlow는 단독 프로젝트로 다른 프로젝트가 상속할 수 없다. 정본 파일: `config/store/store-profile.json`

**현재 상태**
- `storeProfileStatus`: `DRAFT`
- `qualificationMode`: `true` (읽기 전용 검증 중)
- `binaryReleaseGate`: `advisory` (권고 모드, 바이너리 배포 차단 없음)

---

## 보호 대상

배포 중 쓰기 금지 대상입니다.

| Platform | Target | Mode | Reason |
|----------|--------|------|--------|
| ios | current_submission:1.1.1(23) | READ_ONLY_PROTECTED | iOS App Store 첫 제출 대기 중 (사용자 공식 선언 2026-09-11); Store Intelligence 검증 중 쓰기 금지 |
| android | production_track | READ_ONLY_PROTECTED | 검증 목적 읽기/드라이런만 허용 |

---

## 차단 사유 (blockers)

배포 진행 전 반드시 해결해야 할 항목입니다.

| Code | Platform | 내용 | 사람 결정 필요 |
|------|----------|------|----------------|
| PRIVACY_POLICY_MISMATCH | both | https://fluxstudio.co.kr/privacy (FluxStudio/HealthFlow 공용 페이지, PlanFlow 데이터 수집 미명시) vs https://tught3.github.io/PlanFlow/privacy-policy.html (PlanFlow 전용, 2026-05-10 업데이트, AdMob 미언급) 두 URL이 다른 내용을 가지고 있으며 실제 스토어 등록 값 미확인 | O |
| IPHONE_69_ASSET_MISSING | ios | 6.9" iPhone 스크린샷 누락. 기존 '스크린샷 아이폰/세로' 자산은 1242x2688 (6.5" iPhone 규격)이지 1260x2736 (6.9") 규격이 아님 | N |
| DATA_SAFETY_DOC_STALE_AD_ID | android | docs/play-console-data-safety.md에 AD_ID/Advertising ID/AdMob 언급 없음. 그러나 코드의 AD_ID 권한 및 AdMob SDK 활성 상태 확인됨 (commit aaf1bfed, android/app/src/main/AndroidManifest.xml:4, lib/services/ad_service.dart:491) | O |
| IOS_ADMOB_NATIVE_INIT_UNKNOWN | ios | lib/services/ad_runtime_policy.dart:5-8에서 Dart 레벨 iOS 보상형 광고 경로 비활성화, 하지만 ios/Runner/Info.plist:7에 GADApplicationIdentifier 존재로 인해 네이티브 Google Mobile Ads SDK가 Dart 게이트 무시하고 자동 초기화될 가능성 | O |
| ASC_APP_ID_UNKNOWN | ios | binding.storeAppIds.ios가 null — iOS App Store Connect 값 읽기 대기 중; 이 검증 단계에서 스토어 쓰기 금지 | N |
| STORE_BASELINE_NOT_CAPTURED | both | acceptedSnapshots 비어있음 — 아직 승인된 스토어 상태 기준선 없음 | N |
| REVIEW_CREDENTIAL_NOT_PROVISIONED | ios | gh secret list --repo tught3/PlanFlow에서 PLANFLOW_REVIEW_DEMO_USERNAME / PLANFLOW_REVIEW_DEMO_PASSWORD 시크릿 없음 (E2E 테스트용 계정 시크릿 PLANFLOW_E2E_TEST_ACCOUNT_EMAIL/PASSWORD는 존재하나 리뷰 데모용 지정 아님) | N |

---

## 사용자 결정 필요 (decisionsRequired)

스토어 정책 확인 및 설정 확인이 필요한 항목입니다.

| Code | Platform | 질문 |
|------|----------|------|
| IOS_ADS_TRACKING_ANSWER | ios | iOS App Privacy에서 광고 데이터·추적 답변을 어떻게 선언할 것인가 (네이티브 AdMob SDK가 GADApplicationIdentifier로 자동 초기화될 가능성 포함) |
| ANDROID_AD_ID_SHARING | android | Data Safety에서 기기 ID의 광고 목적 공유를 어떻게 선언할 것인가 |
| PRECISE_LOCATION_COLLECTION | both | GPS 좌표를 Google Maps Distance Matrix API로 외부 전송하는지 확정 필요 |
| CHILD_DIRECTED | both | PlanFlow가 아동 대상 앱인지 여부를 확정해야 함 |
| UGC_MODERATION | both | 그룹 댓글(UGC)에 신고·차단 기능이 있는지 확정 필요 |
| EXPORT_COMPLIANCE_CONFIRM | ios | ITSAppUsesNonExemptEncryption=false(Info.plist)를 법적 수출 규정 준수 선언으로 승인할 것인지 확정 필요 |
| PRIVACY_POLICY_CANONICAL_URL | both | https://fluxstudio.co.kr/privacy 와 https://tught3.github.io/PlanFlow/privacy-policy.html 중 어느 것을 스토어 공식 URL로 확정할 것인가 |
| BINARY_RELEASE_GATE_ENFORCE | both | binaryReleaseGate를 'advisory'에서 'enforce'로 전환할 시점을 언제로 할 것인가 |

---

## 값 출처 요약

Profile의 모든 정보 필드(source 키 포함)를 재귀 조회한 결과입니다.

| 출처 | 개수 |
|------|------|
| CODE_EVIDENCE | 38 |
| REPO_DOC | 2 |
| REPO_DOC_STALE | 5 |
| USER_STATED | 6 |
| UNKNOWN | 18 |

**해석**
- **CODE_EVIDENCE**: 소스 코드/매니페스트 직독
- **REPO_DOC**: 저장소 문서 (현행)
- **REPO_DOC_STALE**: 저장소 문서 (구 버전 대비 오래됨)
- **USER_STATED**: 사용자 진술
- **UNKNOWN**: 값이 null이거나 출처 불명확

---

## 모르는 값 (UNKNOWN)

다음 필드들이 null이거나 source가 UNKNOWN으로 표시됩니다 (219개 경로).

**대표 카테고리**:

### Store Metadata
- `storeMetadata.android.category.value` (Play 카테고리는 API 읽기 불가)
- `storeMetadata.android.privacyPolicyUrl.value`
- `storeMetadata.android.marketingUrl.value`
- `storeMetadata.android.copyright.value`
- `storeMetadata.android.shortDescription.value`
- `storeMetadata.android.description.value`
- `storeMetadata.ios.privacyPolicyUrl.value`
- `storeMetadata.ios.marketingUrl.value`
- `storeMetadata.ios.copyright.value`
- `storeMetadata.ios.subtitle.value`
- `storeMetadata.ios.description.value`
- `storeMetadata.ios.keywords.value`
- `storeMetadata.ios.promotionalText.value`
- `storeMetadata.ios.secondaryCategory.value`

### Privacy Data Types
- `privacy.android.dataTypes.preciseLocation.collected.value`
- `privacy.android.dataTypes.crashData.linkedToUser.value`
- `privacy.ios.dataTypes.advertisingData.collected.value`
- `privacy.ios.dataTypes.photos.collected.value`
- `privacy.ios.dataTypes.crashData.linkedToUser.value`

### Content & Monetization
- `content.ageRating.android.value`
- `content.ageRating.ios.value`
- `content.childDirected.value`
- `content.ads.value` (Android/iOS 불일치로 단일 값 불가)
- `monetization.model.value` (Android/iOS 불일치)
- `monetization.ads.value`

※ 전체 219개 경로 목록은 `config/store/store-profile.json`의 `null` 값 및 `source=UNKNOWN` 필드를 직접 참조하세요.

---

> 이 문서는 profile의 요약이다. 값이 다르면 profile이 정본이다.
