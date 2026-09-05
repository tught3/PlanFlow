# PlanFlow 개인정보처리방침 초안

PlanFlow는 사용자의 일정을 음성으로 등록하고, 캘린더 연동과 알림을 제공하기 위해 필요한 최소한의 정보만 처리합니다.

## 수집하는 정보

- 계정 정보: 이메일 주소, 로그인 제공자 정보
- 일정 정보: 제목, 시간, 장소, 메모, 준비물, 중요 일정 여부
- 음성 입력 텍스트: 기기에서 음성을 텍스트로 변환한 결과
- 위치 정보: 장소 검색, 이동시간 계산, 출발 알림 계산에 필요한 위치 정보
- 캘린더 정보: 사용자가 연동에 동의한 Google, Naver, 휴대폰 내부 캘린더 일정
- 설정 정보: 알림 시간, 브리핑 시간, 이동수단, 캘린더 연결 상태
- 백업 정보: 사용자가 백업한 일정과 설정 스냅샷

## 음성 데이터 처리

PlanFlow는 음성 파일을 외부 서버로 전송하지 않습니다. 음성 인식은 기기 내 STT 기능을 우선 사용하며, 일정 파싱에는 STT로 변환된 텍스트만 사용합니다.

## 외부 서비스 전송

- Supabase: 계정, 일정, 설정, 백업, 캘린더 연결 상태 저장
- OpenAI API: 일정 파싱과 브리핑 생성을 위한 STT 변환 텍스트 전송
- Google Calendar API: 사용자가 Google Calendar 연동에 동의한 경우 일정 읽기/쓰기
- Naver Calendar/CalDAV 및 지도 API: 사용자가 연동하거나 장소/이동시간 기능을 사용할 때 필요한 요청
- TMAP/Google/Naver 지도 API: 장소 검색, 경로 및 이동시간 계산

## 위치 정보 사용

위치 정보는 장소 선택, 현재 위치 기반 이동시간 계산, 출발 알림 제공을 위해 사용됩니다. PlanFlow는 사용자의 위치를 불필요하게 장기간 추적하지 않으며, 일정 기능 제공에 필요한 범위에서만 처리합니다.

## 데이터 보관 및 삭제

사용자 일정, 설정, 백업 데이터는 사용자가 앱을 사용하는 동안 보관됩니다. 사용자는 앱 내 삭제 기능 또는 계정 삭제 요청을 통해 관련 데이터 삭제를 요청할 수 있습니다.

## 문의

개인정보 처리, 데이터 삭제 요청, Play Store 문의는 아래 공식 이메일로 문의해 주세요.

공식 이메일: contact@fluxstudio.co.kr

마지막 업데이트: 2026-05-10

---

# [초안 — 미확정 / 미적용] 광고 SDK 관련 추가 예정 섹션

> **이 선 아래 내용은 아직 방침의 일부가 아니다.**
>
> - 상태: **DRAFT (미적용)** — 법무 검토 및 사용자(대표) 확정 전이다.
> - 위 "마지막 업데이트: 2026-05-10" 기준 본문이 **현재 유효한 방침**이며,
>   이 초안은 그 본문을 대체하거나 수정하지 않는다.
> - 확정 시에는 이 블록을 본문 해당 섹션으로 **이동·병합**하고 이 경고 문단을 제거한다.
> - 작성일: 2026-09-06 / 기준 HEAD: `cbf8f4b6`

## 왜 이 초안이 필요한가 (실측 근거)

현재 유효한 본문에는 `광고` / `AdMob` / `광고 식별자` 관련 문구가 **한 건도 없다**
(이 문서 본문 전수 확인, 2026-09-06). 그러나 저장소 실측상 광고 SDK는 이미 포함돼 있다:

| 사실 | 근거 (파일:줄) |
|---|---|
| AdMob SDK 의존성 선언 | `pubspec.yaml:49` — `google_mobile_ads: ^5.2.0` |
| 앱 기동 시 광고 SDK 초기화 호출 | `lib/main.dart:175` — `await AdService.instance.initialize();` (`lib/main.dart:172` `_primingAdService`) |
| Google UMP(동의 관리) 구현체 존재 | `lib/services/ad_consent_service.dart:12` — "Google UMP(User Messaging Platform) 동의 관리", `:62` `ConsentInformation.instance.canRequestAds()` |
| iOS 추적 권한 문구 선언 | `ios/Runner/Info.plist:28-29` — `NSUserTrackingUsageDescription` |

이 결손은 이미 내부 감사에서 지적된 바 있다:

- `docs/privacy-audit-2026-08-04.md:63` — "AdMob SDK가 AAB에 포함되어 있으면 Data Safety 섹션에
  광고 관련 데이터 수집 선언 필수 (앱이 광고를 실제로 띄우지 않아도 SDK 포함 = 선언 대상)"
- `docs/privacy-audit-2026-08-04.md:64` — 1차 출시 AAB에서 SDK 완전 제거 검토 **또는**
  "광고" 데이터 유형 선언 추가 권고
- `docs/privacy-audit-2026-08-04.md:140` — "`google_mobile_ads`: **SDK만 포함돼도 선언 대상**
  (실제 광고 표시 여부 무관)"

**주의 — 위 감사 문서의 일부는 현재 소스와 어긋난다.**
`docs/privacy-audit-2026-08-04.md:154`는 "AdMob UMP 코드 없음"이라고 기록하지만,
2026-09-06 실측상 `lib/services/ad_consent_service.dart`가 실재하며 UMP를 사용한다.
감사 문서가 작성된 2026-08-04 이후에 추가된 것으로 보인다(파일 mtime 2026-08-21).
따라서 감사 문서의 UMP 관련 결론(§4.2)은 stale로 간주하고 재검토가 필요하다.

## (초안) 광고 및 광고 식별자

PlanFlow는 서비스 운영을 위해 Google AdMob 광고 SDK를 앱에 포함합니다.

- **SDK 포함 사실**: 앱에 Google AdMob SDK가 포함되어 있으며, 앱 실행 시 초기화됩니다.
  광고의 실제 노출 여부는 원격 설정(Remote Config)으로 제어됩니다.
- **광고 SDK가 처리할 수 있는 정보**: 광고 SDK는 광고 요청 및 빈도 제어를 위해
  기기 식별자, 대략적인 기기·네트워크 정보를 자체적으로 처리할 수 있습니다.
  이 정보는 PlanFlow 서버에 저장되지 않으며, 광고 제공자(Google)의 정책에 따라 처리됩니다.
- **PlanFlow가 광고 목적으로 별도 수집하는 정보는 없습니다.** 앞의 "수집하는 정보" 항목
  외에 광고를 위해 추가로 수집·저장하는 개인정보는 없습니다.

> **미확정 항목(확정 전 이 표기를 지우지 말 것)**: 광고 SDK가 자체적으로 수집·전송하는
> 데이터 항목의 정확한 목록은 이 저장소 코드만으로는 확정할 수 없다. Google의
> AdMob/UMP 공식 데이터 공개 문서를 근거로 확정해야 한다. **`UNVERIFIED`.**

## (초안) 광고 개인 맞춤 설정 동의 (UMP)

PlanFlow는 Google User Messaging Platform(UMP)을 사용하여 광고 개인 맞춤 설정에 대한
동의를 관리합니다.

- 동의 대상 지역 판단은 UMP SDK 내부 로직에 위임합니다
  (`lib/services/ad_consent_service.dart:18`).
- 동의 결과는 PlanFlow가 별도로 저장하지 않으며, UMP SDK 자체 저장소에 보관됩니다
  (`lib/services/ad_consent_service.dart:19`).
- 원격 설정에서 광고가 비활성화된 경우 동의 요청 화면을 표시하지 않습니다
  (`lib/services/ad_consent_service.dart:17`).

## (초안) 앱 추적 투명성(ATT) — iOS

- iOS 앱에는 `NSUserTrackingUsageDescription` 권한 문구가 선언되어 있습니다
  (`ios/Runner/Info.plist:28-29`).
- 다만 **2026-09-06 실측 기준, `lib/` 전체에서 ATT 권한을 실제로 요청하는 코드는
  발견되지 않았습니다**(`ATTracking` / `app_tracking_transparency` /
  `requestTrackingAuthorization` / `advertisingIdentifier` / `AdSupport` 검색 결과 0건).
- 이 키가 유지되는 이유는 릴리스 CI 게이트 요구 때문이며(상세: `docs/ios/app-privacy-answers.md`),
  "앱이 추적을 수행한다"는 의미가 아닙니다.

> **미확정 항목**: 광고 SDK가 자체적으로 IDFA에 접근하거나 추적에 해당하는 행위를 하는지는
> 코드 검색만으로 단정할 수 없다. App Store Connect 설문 최종 답변은 이 초안이 아니라
> Google의 공식 SDK 데이터 공개를 근거로 확정한다. **`UNVERIFIED`.**

## 확정 전 남은 작업

1. Google AdMob / UMP 공식 데이터 수집 공개 문서로 위 `UNVERIFIED` 항목 확정
2. `docs/privacy-audit-2026-08-04.md` §4.2(UMP 코드 없음)의 stale 서술 갱신
3. 법무 검토 후 이 블록을 본문으로 이동·병합, "마지막 업데이트" 날짜 갱신
4. Play Console Data Safety / App Store Connect App Privacy 답변과의 정합성 대조
