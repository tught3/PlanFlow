# App Store Connect — App Privacy 설문 답변 매핑 (초안)

> **상태: 초안(DRAFT). 제출용 확정 답변이 아니다.**
>
> 이 문서는 App Store Connect의 *App Privacy* 설문에 답하기 위한 **근거 정리표**다.
> 각 항목은 **근거(파일:줄)** 또는 **`UNVERIFIED`** 중 하나를 반드시 가진다.
> 근거 없는 칸은 비워두지 말고 `UNVERIFIED`로 남긴다 — 추측을 답변으로 승격시키지 않기 위해서다.
>
> 작성일: 2026-09-06 / 기준 HEAD: `cbf8f4b6` / 조사 범위: 이 저장소 소스만

---

## 0. 이 문서를 읽는 법

Apple의 App Privacy 설문은 데이터 **유형(type)** 별로 세 가지를 묻는다:

1. 이 데이터를 **수집(collect)** 하는가?
2. 수집한다면 **앱 기능(App Functionality) / 분석 / 제품 개인화 / 광고** 중 어떤 목적인가?
3. 사용자 **신원과 연결(linked to identity)** 되는가? **추적(tracking)** 에 쓰는가?

여기서 "수집"은 **앱 자신이 서버로 보내는 것뿐 아니라 앱에 포함된 서드파티 SDK가
보내는 것도 포함**한다. 이것이 §3의 광고 SDK 항목이 코드 검색만으로 확정될 수 없는 이유다.

---

## 1. 앱이 처리하는 데이터 항목 (본문 방침 기준)

아래는 `docs/privacy-policy.md`의 "수집하는 정보" / "외부 서비스 전송" 섹션에서 매핑했다.

| 데이터 유형(Apple 분류 후보) | 항목 | 근거 | 신원 연결 | 목적 후보 |
|---|---|---|---|---|
| Contact Info — Email Address | 계정 이메일 | `docs/privacy-policy.md` "계정 정보" | 예 | App Functionality |
| User Content — Other User Content | 일정 제목/시간/장소/메모/준비물 | 같은 곳 "일정 정보" | 예 | App Functionality |
| User Content — Audio Data | **음성 파일은 전송하지 않음.** 변환된 **텍스트만** 사용 | 같은 곳 "음성 데이터 처리" 섹션 | 예(텍스트) | App Functionality |
| Location — Precise / Coarse | 장소 검색·이동시간·출발 알림용 위치 | 같은 곳 "위치 정보 사용" | 예 | App Functionality |
| User Content — Other | 연동 동의한 Google/Naver/기기 캘린더 일정 | 같은 곳 "캘린더 정보" | 예 | App Functionality |
| Usage Data / Other Data | 알림·브리핑 시간, 이동수단, 연결 상태 등 설정 | 같은 곳 "설정 정보" | 예 | App Functionality |
| User Content — Other | 백업 스냅샷 | 같은 곳 "백업 정보" | 예 | App Functionality |

### 1.1 데이터 전송처

| 전송처 | 전송 내용 | 근거 |
|---|---|---|
| Supabase | 계정, 일정, 설정, 백업, 캘린더 연결 상태 | `docs/privacy-policy.md` "외부 서비스 전송" |
| OpenAI API | 일정 파싱·브리핑용 **STT 변환 텍스트** | 같은 곳 |
| Google Calendar API | 동의 시 일정 읽기/쓰기 | 같은 곳 |
| Naver Calendar/CalDAV, 지도 API | 연동·장소/이동시간 사용 시 요청 | 같은 곳 |
| TMAP / Google / Naver 지도 API | 장소 검색, 경로·이동시간 계산 | 같은 곳 |

> **주의**: 음성 **파일**은 외부 전송하지 않는다는 것이 방침의 명시적 선언이다
> (`docs/privacy-policy.md` "음성 데이터 처리"). 다만 STT 변환 **텍스트**는
> OpenAI로 전송된다. 설문에서 이 둘을 뭉뚱그리면 사실과 달라진다 — 반드시 구분해서 답한다.

### 1.2 Firebase 계열

| SDK | 상태 | 근거 |
|---|---|---|
| `firebase_crashlytics` | 포함. 감사 문서가 **선언 대상**으로 분류 (Crash logs, Diagnostics) | `docs/privacy-audit-2026-08-04.md:139` |
| Firebase Remote Config | 광고 활성화 제어에 사용 | `lib/services/ad_consent_service.dart:17` |

> Crashlytics가 실제로 어떤 진단 필드를 전송하는지의 상세 목록은 이 저장소 코드로
> 확정할 수 없다. **`UNVERIFIED`** — Firebase 공식 데이터 공개 문서로 확정할 것.

---

## 2. 광고 SDK

| 사실 | 근거 |
|---|---|
| `google_mobile_ads: ^5.2.0` 의존성 | `pubspec.yaml:49` |
| 앱 기동 시 초기화 호출 | `lib/main.dart:175` (`AdService.instance.initialize()`), 진입점 `lib/main.dart:172` |
| Google UMP 동의 관리 구현 | `lib/services/ad_consent_service.dart:12`, `:62` (`ConsentInformation.instance.canRequestAds()`) |
| 동의 결과를 앱이 저장하지 않음 | `lib/services/ad_consent_service.dart:19` |
| Remote Config OFF면 UMP 미표시 | `lib/services/ad_consent_service.dart:17` |
| 광고 노출 실패를 앱이 흡수 | `lib/main.dart:177`, `:181`, `:190` |

**감사 문서의 확정 판단**:
- `docs/privacy-audit-2026-08-04.md:63` — SDK가 포함돼 있으면 실제 광고 표시 여부와 무관하게 선언 대상
- `docs/privacy-audit-2026-08-04.md:140` — `google_mobile_ads`는 "SDK만 포함돼도 선언 대상"

**감사 문서 stale 경고**: `docs/privacy-audit-2026-08-04.md:154`는 "AdMob UMP 코드 없음"이라
기록하지만 2026-09-06 실측상 `lib/services/ad_consent_service.dart`가 실재한다
(파일 mtime 2026-08-21 — 감사 작성일 이후). 그 문서 §4.2는 재검토 대상이다.

> **설문 답변 확정 불가 항목**: AdMob SDK가 실제로 어떤 데이터 유형을
> (Device ID / Usage Data / Coarse Location 등) 수집하는지는 **이 저장소 코드로
> 확정할 수 없다.** Google이 공개하는 AdMob 데이터 공개 문서를 근거로 채워야 한다.
> **`UNVERIFIED`.**

---

## 3. 추적(Tracking) 및 ATT — 가장 주의할 항목

### 3.1 코드 실측 결과

2026-09-06, `lib/` 전체를 대상으로 다음 패턴을 검색한 결과 **0건**이다:

```
ATTracking | app_tracking_transparency | requestTrackingAuthorization
| advertisingIdentifier | AdSupport
```

즉 **PlanFlow의 Dart 코드는 ATT 권한을 요청하지 않고 IDFA에 직접 접근하지 않는다.**

같은 사실이 별도 경로로도 기록돼 있다:
`docs/ios/templates/planflow.values.md` "주의 사항" — "광고 SDK는 쓰지만
`app_tracking_transparency` 패키지와 `ATTrackingManager` 호출은 코드에 존재하지 않는 것으로
확인됐다(0건)."

### 3.2 그럼에도 "추적하지 않음"으로 단정하면 안 되는 이유

Apple의 *tracking* 정의는 **앱 자신의 코드뿐 아니라 앱에 포함된 SDK의 행위**를 포함한다.
`google_mobile_ads`가 내부적으로 IDFA를 조회하거나 데이터를 광고 목적으로 제3자와
연결하면, Dart 코드에 ATT 호출이 없어도 설문상 "추적"에 해당할 수 있다.

**따라서 이 문서는 답변 후보만 제시하고 최종 답변을 단정하지 않는다.**

| 설문 항목 | 답변 후보 | 확정 여부 |
|---|---|---|
| "Do you or your third-party partners use data for tracking?" | (후보) No — 앱 코드 ATT/IDFA 호출 0건 | **`UNVERIFIED` — SDK 자체 동작 미확인** |
| ATT 프롬프트를 표시하는가 | (사실) 현재 코드로는 표시하지 않음 | 확정 (§3.1 근거) |
| `NSUserTrackingUsageDescription` 존재 | 존재함 | 확정 — `ios/Runner/Info.plist:28-29` |

### 3.3 `NSUserTrackingUsageDescription`이 유지되는 진짜 이유 — 삭제 금지

이 키는 **코드에서 쓰이지 않는데도 반드시 남아 있어야 한다.** 릴리스 CI가 그것을 강제한다:

`.github/workflows/ios-release.yml`의 세 지점이 이 키의 존재를 검사한다:
- `:52` — 소스 `Info.plist` privacy key 루프에 포함
- `:212` — 동일 검사 (별도 단계)
- `:270` — 동일 검사 (별도 단계)

누락 시 `:55`가 다음을 출력하고 빌드가 **실패**한다:

```
::error title=BLOCKED_RUNNER_PRIVACY_SOURCE::Runner Info.plist is missing $privacy_key.
```

또한 purpose string 누락은 실제 업로드 실패로 이어진 이력이 있다:
`docs/ios/privacy-surface-audit.md:3` — "Build 13/14/15에서 Apple BuildUpload가
`90683 Missing purpose string`" (관련 task 기록:
`.codex/tasks/planflow-ios-90683-final-release-20260902.json` 외 2건).

> **정리**: 이 키의 존재는 "추적한다"의 증거가 **아니다**. 심사 담당자에게 그렇게 읽힐
> 위험이 있으므로, 만약 최종 설문 답변이 "추적 안 함"으로 확정되면 심사 노트에
> 이 키가 CI 게이트/이전 90683 이력 때문에 유지된다는 설명을 넣는 것을 검토한다.
>
> **어떤 경우에도 `ios/Runner/Info.plist`에서 이 키를 임의로 삭제하지 마라** —
> 릴리스가 즉시 차단된다.

### 3.4 Android 쪽 대조 (참고)

- `AndroidManifest.xml`에 `com.google.android.gms.permission.AD_ID` 선언 **없음**
  (`docs/privacy-audit-2026-08-04.md:56`)
- 감사 문서는 2차 출시(광고 도입) 시 복원 및 Data Safety 광고 ID 선언을 예정으로 기록
  (`docs/privacy-audit-2026-08-04.md:55`, `:82`)

즉 **iOS는 ATT 문구가 있고 Android는 AD_ID 권한이 없는 비대칭 상태**다.
플랫폼별 설문 답변이 서로 모순되지 않도록 확정 시 함께 검토한다.

---

## 4. 확정 전 반드시 해야 할 일

1. **Google AdMob 공식 데이터 공개 문서**로 §2·§3의 `UNVERIFIED`를 확정한다.
   (코드 검색으로는 확정 불가 — 이것이 이 문서의 가장 큰 공백이다.)
2. **Firebase Crashlytics 데이터 공개 문서**로 §1.2의 `UNVERIFIED`를 확정한다.
3. `docs/privacy-audit-2026-08-04.md` §4.2(`:154` "UMP 코드 없음")의 stale 서술을 갱신한다.
4. `docs/privacy-policy.md` 하단의 광고 초안 블록을 법무 검토 후 본문으로 승격한다.
5. Play Console Data Safety 답변과 App Store Connect App Privacy 답변의
   **모순 여부를 1회 대조**한다(§3.4 비대칭 주의).
6. 설문 제출 후 이 문서의 "초안" 표기를 제거하고 **실제 제출 답변**으로 갱신한다.

---

## 5. 이 문서의 한계 (정직 고백)

- 조사 범위는 **이 저장소의 소스뿐**이다. 서드파티 SDK의 런타임 네트워크 동작은
  관측하지 않았다(실기기 트래픽 캡처 미수행).
- 따라서 이 문서는 **"앱 코드가 무엇을 하는가"** 는 근거로 답할 수 있지만
  **"앱 바이너리 전체가 무엇을 전송하는가"** 는 답하지 못한다.
- App Privacy 설문은 후자를 묻는다. 그 간극을 §4의 1·2번이 메워야 한다.
- 이 문서의 어떤 표도 그 자체로 제출 답변이 아니다.
