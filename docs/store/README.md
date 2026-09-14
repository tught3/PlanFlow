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

## 2026-09-13 사용자 확인 iOS 제출 기준선

- 제출 상태: `STORE_APPLIED / SUBMITTED`이며 Apple 심사 통과(`STORE_ACCEPTED`)는 아닙니다.
- 가격: Free, primary category: `PRODUCTIVITY` (CONFIGURED, authenticated GET readback), secondary category: `UTILITIES` (CONFIGURED, authenticated GET readback), support URL: `https://fluxstudio.co.kr/planflow-support`.
- privacy policy URL: `https://fluxstudio.co.kr/privacy` (2026-09-13 Homepage production deployment `dpl_X4zgciGJUt3FNMwaW8pzTeNNaiZ4` 후 HTTPS HTTP 200 및 PlanFlow 의미·금지문구 계약 확인). 공개 페이지는 `planflow-privacy-policy-final.md` SHA-256 `2CFB3EFA21B5EF041E383C1CB76CA292AD255665924F115F7A1798AC9421924F`에 바인딩된 PlanFlow 정책을 제공한다. 이는 공개 콘텐츠 정합화 증거이며 Apple 수락 또는 Store 쓰기 결과는 아니다.
- App Privacy 설문이 콘솔에서 완료됐다는 사용자 확인은 개별 데이터 유형·추적 답변의 source/SDK 검증을 대체하지 않습니다. 알려진 광고·ATT·위치 관련 의사결정은 계속 `REVIEW_REQUIRED`입니다.

이 기준선 기록은 현재 심사 제출을 변경하지 않았으며, App Store Connect 또는 Google Play에 쓰기 요청을 보내지 않았습니다.

### iOS native screenshot qualification (2026-09-14)

`docs/screenshots/app-store/native-ios/`에 iPhone 6.9" 3장(1320×2868)과 iPad 13" 2장(2064×2752)을 추가했습니다. Run `34795713111`의 iOS native simulator 산출물이며, 알파 제거만 적용한 RGB PNG입니다. 모든 자산은 `LOCAL_QUALIFIED`, `NOT_UPLOADED`, visual/PII review `PASS`입니다. Store mutation은 0건입니다.

전체 task change-set의 impact는 `SCREENSHOT_IMPACT=PARTIAL`입니다. Home·calendar·voice의 screenshot-linked feature 경로가 변경되어 `SCREENSHOT_FEATURE_CHANGED`가 발생했지만, `lib/core/theme.dart` global visual path는 변경되지 않았습니다. 표준 실행 `python -m fluxstore impact --project-root E:\FluxStudio-worktrees\planflow\planflow-ios-native-screenshot-baseline-20260913 --json`은 exit 0으로 `METADATA_CHANGE`, `PRIVACY_CHANGE`, `SCREENSHOT_CHANGE`를 반환했습니다.

### Rewarded production acceptance

`Rewarded=EXTERNAL_DEPENDENCY_HOLD`이며 `CURRENT_PRODUCTION_FEATURE_ACCEPTANCE=BLOCKED`입니다. Build25에서 `RewardedAd.load code=1 (No ad to show)`가 관찰됐지만 광고 serving을 입증하지 않습니다. Owner는 외부 AdMob serving/fill availability이고, exact unblock은 승인된 실기기에서 production rewarded 광고의 load/show/reward를 성공 관찰한 뒤 release acceptance를 재실행하는 것입니다.

---

## 차단 사유 (blockers)

배포 진행 전 반드시 해결해야 할 항목입니다. (총 5건; privacy publication으로 1건, local native baseline으로 2건 해소)

| Code | Platform | 내용 | 사람 결정 필요 |
|------|----------|------|----------------|
| ANDROID_TABLET_LIVE_PII_REPLACEMENT_REQUIRED | android | 현재 live 7-inch asset에 실제 일정/업무 내용이 노출되고 두 live tablet asset에 system/DeX chrome 및 16:10 비표준 비율이 남아 있어 별도 승인된 Play metadata 변경으로 교체/삭제 필요 | O |
| DATA_SAFETY_DOC_STALE_AD_ID | android | docs/play-console-data-safety.md에 AD_ID/Advertising ID/AdMob 언급 없음. 그러나 코드의 AD_ID 권한 및 AdMob SDK 활성 상태 확인됨 (commit aaf1bfed, android/app/src/main/AndroidManifest.xml:4, lib/services/ad_service.dart:491) | O |
| IOS_SCREENSHOTS_ANDROID_CAPTURE_2_3_10 | ios | local native iOS baseline 3+2는 준비됐지만 업로드되지 않음. 보호된 Build23 현재 제출이 기존 Android-derived 자산을 사용했는지는 App Store Connect readback 전까지 미확인; 현재 제출 변경/교체는 범위 밖 | O |
| APP_PRIVACY_COMPARE_UNAVAILABLE | ios | 현재 App Privacy data-type 답변은 공개 API로 field-by-field readback 불가하며 USER_CONFIRMED/SUBMITTED 상태만 확인됨. Build23 review 후 source-derived expected values와 수동 비교 필요 | O |
| IOS_STORE_READBACK_NOT_ACCEPTED | ios | GET-only readback run 34744489714에서 app 6806790412, bundle com.fluxstudio.planflow, Build23 WAITING_FOR_REVIEW, mutationCount=0 확인. STORE_ACCEPTED가 아니므로 acceptedSnapshots에 추가하지 않음 | N |

---

## 사용자 결정 필요 (decisionsRequired)

스토어 정책 확인 및 설정 확인이 필요한 항목입니다. (총 8건)

| Code | Platform | 질문 |
|------|----------|------|
| ANDROID_AD_ID_SHARING | android | Data Safety에서 기기 ID의 광고 목적 공유를 어떻게 선언할 것인가 |
| PRECISE_LOCATION_COLLECTION | both | GPS 좌표를 Google Maps Distance Matrix API로 외부 전송하는지 확정 필요 |
| EXPORT_COMPLIANCE_CONFIRM | ios | ITSAppUsesNonExemptEncryption=false(Info.plist)를 법적 수출 규정 준수 선언으로 승인할 것인지 확정 필요 |
| PRIVACY_POLICY_CANONICAL_URL | android | iOS 제출 URL은 사용자 확인과 공개 readback으로 `https://fluxstudio.co.kr/privacy`로 확인됨. Google Play에 실제 입력된 URL은 별도 readback이 없어 확정 필요 |
| BINARY_RELEASE_GATE_ENFORCE | both | binaryReleaseGate를 'advisory'에서 'enforce'로 전환할 시점을 언제로 할 것인가 |
| SCREENSHOT_V3_TRACKING | both | `docs/screenshots/store_final_v3/` 후보 세트의 Git 추적/재생성 정책을 확정할 것인가 |

---

## 기준선(baseline) 현황

스토어 배포 영향도를 추적하기 위한 기준선 정보입니다.

### 스토어 상태 기준선 (acceptedSnapshots)

| Platform | Snapshot | Release | 상태 | 연락처 |
|----------|----------|---------|------|--------|
| Android | `config/store/snapshots/android-readback-2026-09-11.json` | production 1.1.1(164) | completed | presence-only로 저장 (`redaction.piiPresenceOnly`) |
| iOS | 없음 | — | — | — |

**의미**: 스토어 현재 게시 상태를 정본으로 등록했습니다. iOS의 `LOCAL_QUALIFIED` native screenshot baseline은 별도 계보이며, App Store Connect accepted readback은 아직 없습니다.

### 소스 Fingerprint 기준선 (acceptedFingerprints)

| Platform | Fingerprint | Commit | Version | Platform-scoped | Store Acceptance |
|----------|-------------|--------|---------|-----------------|------------------|
| Android | `config/store/baselines/android-fingerprint-2026-09-11.json` | `18075eda` | 1.1.1+164 | true | STORE_ACCEPTED |
| iOS | 없음 | — | — | — | — |

**의미**: Android 1.1.1(164) 빌드의 코드 및 메타데이터 상태를 기준선으로 등록했습니다. 다음 Android 릴리스부터 이 기준선과의 diff를 비교해 다음 항목의 변경을 추적합니다:
- 의존성 변경 (DEPENDENCY)
- 권한/SDK 추가·제거 (PERMISSION, SDK, MONETIZATION)
- 스토어 메타데이터 변경 (STORE_PROFILE)
- 스크린샷 feature 변경 (SCREENSHOT_FEATURE)

iOS는 App Store 승인/readback 후 accepted fingerprint 기준선을 등록할 예정입니다. 현재는 스토어 기준선은 없지만, native screenshot baseline의 feature impact는 별도 계약으로 계산됩니다.

---

## 값 출처 요약

**집계 규칙**: provenance 노드 = `source` 키와 `value` 키를 둘 다 가진 dict. 아래 개수는 provenance 노드만 센 것이며, 하위 non-provenance 필드(예: `evidence`, `note` 자체, `review.usernameRef` 등 source/value 쌍이 없는 필드)는 세지 않는다. 총 provenance 노드 수: **77개**.

| 출처 | 개수 |
|------|------|
| CODE_EVIDENCE | 41 |
| UNKNOWN | 19 |
| USER_STATED | 8 |
| STORE_READBACK | 3 |
| REPO_DOC_STALE | 3 |
| DERIVED | 3 |

**해석**
- **CODE_EVIDENCE**: 소스 코드/매니페스트 직독
- **STORE_READBACK**: Google Play Developer API readback(--live-read)으로 직접 읽은 현재 게시 값 (`storeMetadata.android.name`/`shortDescription`/`description`, 2026-09-11 android-readback 스냅샷 기준)
- **REPO_DOC_STALE**: 저장소 문서 (구 버전 대비 오래됨)
- **USER_STATED**: 사용자 진술
- **DERIVED**: 다른 확인된 사실로부터 유도
- **UNKNOWN**: source 자체가 UNKNOWN으로 표시된 노드 (아래 UNKNOWN 목록과는 집계 기준이 다름 — 이 표는 순수 `source` 문자열 카운트)

---

## 모르는 값 (UNKNOWN)

**집계 규칙**: profile의 provenance 노드 중 `value is null` 또는 `source == "UNKNOWN"`인 노드를 dotted path로 나열합니다. 값이 확인된 노드(예: iOS `UTILITIES`, privacy URL, iOS advertising collected, photos, childDirected, iOS ads/monetization)는 포함하지 않습니다.

총 **23개**입니다. 아래 목록은 `config/store/store-profile.json`에서 현재 값과 source를 직접 계산한 결과입니다.

- `storeMetadata.android.category` (source: UNKNOWN)
- `storeMetadata.android.privacyPolicyUrl` (source: UNKNOWN)
- `storeMetadata.android.marketingUrl` (source: UNKNOWN)
- `storeMetadata.android.copyright` (source: UNKNOWN)
- `storeMetadata.ios.marketingUrl` (source: UNKNOWN)
- `storeMetadata.ios.copyright` (source: UNKNOWN)
- `storeMetadata.ios.subtitle` (source: REPO_DOC_STALE, value: null)
- `storeMetadata.ios.description` (source: REPO_DOC_STALE, value: null)
- `storeMetadata.ios.keywords` (source: REPO_DOC_STALE, value: null)
- `storeMetadata.ios.promotionalText` (source: UNKNOWN)
- `privacy.android.dataTypes.androidAdvertisingId.collected` (source: CODE_EVIDENCE, value: null)
- `privacy.android.dataTypes.androidAdvertisingId.purposes` (source: CODE_EVIDENCE, value: null)
- `privacy.android.dataTypes.androidAdvertisingId.shared` (source: DERIVED, value: null)
- `privacy.ios.dataTypes.preciseLocation.collected` (source: CODE_EVIDENCE, value: null)
- `content.ageRating.android` (source: USER_STATED, value: null)
- `content.ageRating.ios` (source: USER_STATED, value: null)
- `content.ads.android` (source: CODE_EVIDENCE, value: null)
- `content.medicalClaims` (source: UNKNOWN)
- `content.encryption` (source: UNKNOWN)
- `content.traderStatus` (source: UNKNOWN)
- `monetization.model.android` (source: CODE_EVIDENCE, value: null)
- `monetization.ads.android` (source: CODE_EVIDENCE, value: null)
- `releasePolicy.android.release` (source: UNKNOWN)

참고: `storeMetadata.ios.category`/`secondaryCategory`와 `storeMetadata.ios.privacyPolicyUrl`은 authenticated GET readback 또는 공개 publication evidence로 확인되어 이 목록에서 제외합니다. `fluxstore resolve`의 외부 linked-worktree 결과는 별도 실행 상태이며 이 정적 profile 요약에 섞지 않습니다.

※ 전체 목록은 `config/store/store-profile.json`을 직접 참조하세요.

---

> 이 문서는 profile의 요약이다. 값이 다르면 profile이 정본이다.
