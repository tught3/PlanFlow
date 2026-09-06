# PlanFlow App Store Readiness Checklist (P11)

이 문서는 실제 App Store Connect 콘솔에 접근하지 않고 저장소 코드/설정에서 확인 가능한 것만 자동 채웠다. "확인 필요" 항목은 추측으로 채우지 않았다.

배경 사실(확정): Build 16까지 TestFlight 파이프라인(서명/IPA 메타데이터/privacy audit/BuildUpload/App Store ingestion)이 전부 PASS로 완료되었다.

---

## 0. 최종 판정 (iOS Release Closure Phase)

> **`APP_STORE_BLOCKED`** — 차단 사유 **1건**: `R1_UNDETERMINED`.
> 프로덕션 `ios/Runner/Info.plist` 형상에서 앱이 실제로 부팅·생존한다는 **런타임 증거가 0건**이다.
> 판정 근거 전문: [`docs/ios/R1-admob-launch-risk.md`](R1-admob-launch-risk.md)
> 판정 맥락(QA 증거표·실기기 판정): [`docs/ios/release-readiness.md`](release-readiness.md)

**중요 — 이 판정은 아래 항목 1~18과 성격이 다르다.**
항목 1~18의 "확인 필요"는 *콘솔 데이터 입력 미완*(= configuration gap)이다.
`APP_STORE_BLOCKED`는 *제품이 iOS에서 뜨는지 자체가 미확인*(= runtime unknown)이라는 뜻이며,
콘솔을 아무리 채워도 해소되지 않는다.

**단일 해제 조건**
`.github/workflows/ios-adsdk-launch-probe.yml`를 GitHub Actions에서 `workflow_dispatch`로
1회 실행(≤40분) →
`PROD_PLIST_APP_ALIVE` = PASS **그리고** `PROD_PLIST_NO_CRASH` = PASS
→ 즉시 **`APP_STORE_READY_PENDING_USER_CONFIGURATION`**으로 전환되고,
그 뒤로는 이 문서의 항목 2~16, 18(콘솔 입력)만 남는다.
결과가 FAIL이면 `R1_CONFIRMED_BLOCKER`이며 **코드 수정 + Build 17**이 필요하다
(제안 패치는 R1 문서 §5, **미적용** 상태).

**Physical iPhone: `REQUIRED`** — 단, "제출 준비 완료" 시점이 아니라 **"공개 배포 승인" 시점**의
요건이다. 근거는 `docs/ios/release-readiness.md`의 Physical iPhone 판정 절 참조
(요약: 알림 실제 탭·딜리버리 타이밍·위젯 홈화면 렌더·ATT 프롬프트·STT 실품질은 시뮬레이터로
대체 불가이고, FLOW1~8 실행 증거가 0건이며, R1이 시뮬레이터에서 CLEAR돼도 GMA 네이티브
device 슬라이스 확인이 남는다).

**Build 16과의 관계**: Build 16까지의 PASS는 *빌드·서명·업로드·ingestion*의 증거이지
*런타임 부팅*의 증거가 아니다. 그 파이프라인에는 앱 프로세스를 띄워 생존을 확인하는 단계가
없다. 따라서 항목 18의 "Build 16 PASS"는 이 판정을 뒤집지 않는다.

---

## 1. 버전(빌드번호/버전명)

`.github/workflows/ios-release.yml`의 `env` 블록에 하드코딩되어 있다:

```yaml
IOS_BUILD_NUMBER: ${{ github.run_number }}
IOS_BUILD_NAME: 1.0.0
```

- `IOS_BUILD_NAME`(마케팅 버전, `CFBundleShortVersionString`)은 `1.0.0`으로 고정.
- `IOS_BUILD_NUMBER`(빌드 번호, `CFBundleVersion`)는 GitHub Actions `github.run_number`로 실행마다 자동 증가.

**상태**: [코드/설정에서 자동 확인 가능 — 값: 버전명 1.0.0 고정, 빌드번호는 workflow run_number 자동증가]

## 2. 앱 이름

`ios/Runner/Info.plist`:
```
CFBundleDisplayName = PlanFlow
CFBundleName = PlanFlow
```
단, App Store Connect의 "이름(Name)" 필드는 Info.plist와 별개로 콘솔에서 직접 등록하는 마케팅 표시명이며, 이 저장소 코드에는 등록 여부가 없다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요] (Info.plist상 표시명은 "PlanFlow"로 확인되나 콘솔 등록 앱 이름은 별도 확인 필요)

## 3. Subtitle

App Store Connect 전용 메타데이터 필드로, 이 저장소 어디에도 값이 존재하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 4. Keywords

App Store Connect 전용 메타데이터 필드로, 이 저장소 어디에도 값이 존재하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 5. Category

App Store Connect 전용 메타데이터 필드로, 이 저장소 어디에도 값이 존재하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 6. Screenshots

App Store Connect에 업로드하는 마케팅 자산으로, 이 저장소에는 스크린샷 생성/제출 파이프라인이 없다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 7. 앱 아이콘

App Store Connect의 마케팅 아이콘(1024x1024)은 Xcode 프로젝트 내 `AppIcon` 에셋과는 별개로 콘솔에 노출되는 값이며, 실제 게시용 아이콘이 최종 확정됐는지는 이 세션에서 확인할 수 없다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 8. Support URL

App Store Connect 전용 메타데이터 필드로, 이 저장소 어디에도 값이 존재하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 9. Privacy Policy URL

App Store Connect 전용 메타데이터 필드로, 이 저장소 어디에도 값이 존재하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 10. App Privacy 답변(데이터 수집 항목별)

App Store Connect의 "App Privacy" 설문(Nutrition Label)은 콘솔에서 직접 답변하는 항목이며 코드에서 자동 생성되지 않는다.

**ATT 불일치 위험**: `Info.plist`에 `NSUserTrackingUsageDescription` 문구가 존재하지만(항목 17 참조), 실제 앱 코드에는 `ATTrackingManager.requestTrackingAuthorization` 트리거가 없고 `app_tracking_transparency` 패키지도 `pubspec.yaml`에 설치되어 있지 않다(grep 결과 0건). 광고 동의 관련 코드는 `lib/services/ad_consent_service.dart`의 Google UMP(User Messaging Platform) 흐름만 존재한다. 이는 "트래킹 목적 사용" 설문 답변과 실제 동작이 불일치할 위험이 있다 — 이 문서에서 임의로 답을 확정하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요] (ATT 코드-문구 불일치 위험 있음, 판단 필요)

## 11. Age Rating

App Store Connect 전용 설문(콘텐츠 등급) 항목으로, 이 저장소 어디에도 값이 존재하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 12. 광고추적 고지

항목 10과 동일한 근거로, `NSUserTrackingUsageDescription` 문구는 Info.plist에 있으나(값: "관련 광고를 제공하고 서비스 이용을 개선하기 위해 기기 식별자 사용 권한이 필요합니다.") 이를 실제로 트리거하는 `ATTrackingManager.requestTrackingAuthorization` 호출 코드가 앱에 존재하지 않는다(`app_tracking_transparency` 패키지 미설치, `pubspec.yaml` grep 0건). 즉 문구만 선언되어 있고 실제 트래킹 권한 요청 플로우는 구현되어 있지 않다. App Store Connect의 "광고 추적" 관련 고지/설문에 이 상태를 어떻게 반영할지는 사용자 판단이 필요하다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요] (실제 ATT 트리거 코드 부재 — 문구만 있고 요청 로직 없음)

## 13. Export Compliance

App Store Connect 제출 시 암호화 사용 여부를 묻는 설문 항목으로, 콘솔에서 직접 답변한다. 이 저장소 코드에는 표준 HTTPS(Supabase Auth/REST) 외의 커스텀 암호화 구현이 발견되지 않았으나, 최종 답변(예: exempt 여부)은 콘솔에서 확정해야 한다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 14. Review Notes

App Store Connect 제출 시 리뷰어에게 남기는 자유 서술 텍스트로, 이 저장소에는 값이 존재하지 않는다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요]

## 15. 계정 로그인 심사지침(데모 계정)

PlanFlow는 Supabase Auth를 사용하며 이메일/비밀번호 로그인과 Google/Kakao/Naver OAuth 소셜 로그인을 지원한다(코드 확인: 인증 방식이 Supabase Auth 기반). Apple 심사 가이드라인상 로그인이 필요한 앱은 통상 심사용 데모 계정(이메일/비밀번호)을 App Store Connect의 "App Review Information"에 제출해야 한다. 이 세션에서는 그런 데모 계정이 실제로 준비·등록되어 있는지 확인할 수 없다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요] (Supabase Auth 이메일/비밀번호 + OAuth 사용 확인됨, 심사용 데모 계정 준비 여부는 별도 확인 필요)

## 16. Widget 설명 필요 여부

앱은 `PlanFlowWidgetExtension`(bundle ID `com.fluxstudio.planflow.PlanFlowWidget`)이라는 WidgetKit 확장을 포함하고 있으며(`ios-release.yml`에서 아카이브에 `PlanFlowWidgetExtension.appex` 존재를 강제 검증), App Group `group.com.fluxstudio.planflow`를 통해 Runner 앱과 데이터를 공유한다. App Store Connect 메타데이터/스크린샷에 위젯 기능을 별도로 설명해야 하는지는 콘솔 정책·심사팀 판단 영역이다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요] (위젯 확장 존재는 코드로 확인됨, 콘솔상 별도 설명 필요 여부는 확인 필요)

## 17. 권한 설명 6종

`ios/Runner/Info.plist`에서 확인한 실제 한국어 문구:

| 키 | 문구 |
|---|---|
| `NSMicrophoneUsageDescription` | 음성으로 일정을 입력하려면 마이크 권한이 필요합니다. |
| `NSSpeechRecognitionUsageDescription` | 음성을 일정 내용으로 변환하려면 음성 인식 권한이 필요합니다. |
| `NSUserTrackingUsageDescription` | 관련 광고를 제공하고 서비스 이용을 개선하기 위해 기기 식별자 사용 권한이 필요합니다. |
| `NSLocationWhenInUseUsageDescription` | 일정 장소를 지도에서 찾고 출발지와 목적지를 확인하려면 위치 권한이 필요합니다. |
| `NSPhotoLibraryUsageDescription` | 지도 SDK가 장소 사진을 표시할 수 있도록 사진 보관함 접근 권한이 필요합니다. |
| `NSPhotoLibraryAddUsageDescription` | 지도 SDK가 지도 관련 이미지를 사진 보관함에 저장할 수 있도록 사진 추가 권한이 필요합니다. |

이 6개 키는 `ios-release.yml`의 preflight/archive/export 단계에서 각각 빈 값이 아닌지 3중으로 게이트 검증된다(`BLOCKED_RUNNER_PRIVACY_SOURCE`, `BLOCKED_ARCHIVE_PRIVACY`, `BLOCKED_IPA_PRIVACY`).

**상태**: [코드/설정에서 자동 확인 가능 — 값: 위 표의 6개 문구, Info.plist에 실제 존재 확인 및 CI 게이트로 누락 시 빌드 실패 처리됨]

## 18. Build 16 연결 확인

Build 16까지 TestFlight 파이프라인(서명 → IPA 메타데이터 검증 → privacy audit → BuildUpload → App Store Connect ingestion)이 전부 PASS로 완료된 것으로 확인되었다(대화 배경상 확정 사실). App Store Connect 앱 레코드에 해당 빌드가 실제로 "제출 가능한 빌드"로 선택·연결되어 있는지는 콘솔에서 최종 확인이 필요하다.

**상태**: [사용자가 App Store Connect에서 직접 확인 필요] (Build 16까지 TestFlight PASS는 확정 사실, 콘솔상 심사 제출용 빌드 연결 여부는 별도 확인 필요)

---

## 요약

- 자동확인(코드/설정 기반): 2개 (항목 1, 17)
- 확인필요(App Store Connect 콘솔): 16개 (항목 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18)
- **콘솔 외 차단 사유: 1개 (R1 — §0)**

### 초안이 준비된 콘솔 항목 (작성이 아니라 확인·복사 수준)

| 항목 | 초안 위치 |
|---|---|
| 3 Subtitle / 4 Keywords / 5 Category / 설명 | `docs/ios/app-store-metadata.md` |
| 6 Screenshots (후보 자산 인벤토리) | `docs/ios/screenshot-inventory.md` |
| 9 Privacy Policy URL (게시할 본문) | `docs/privacy-policy.md` |
| 10 App Privacy 답변 / 12 광고추적 고지 | `docs/ios/app-privacy-answers.md` |
| 14 Review Notes / 15 데모 계정 / 16 위젯 설명 | `docs/ios/review-notes.md` |

### 사용자 액션 우선순위

1. **R1 프로브 실행** (§0) — 유일한 차단 사유 해소
2. Privacy Policy / Support URL 게시 (항목 8·9)
3. 콘솔 메타데이터 입력 (항목 2~5, 11, 13)
4. 심사용 데모 계정 등록 (항목 15)
5. 6.9" 스크린샷 생성·업로드 (항목 6) 및 육안 검수
6. 실기기 FLOW QA (공개 배포 승인 요건)
7. App Privacy 답변 확정 — ATT 문구-동작 불일치 처리 (항목 10·12)

전체 목록과 "왜 사용자만 가능한가"는 `docs/ios/release-readiness.md`의
남은 사용자 액션 절에 정리돼 있다.
