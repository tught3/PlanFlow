# PlanFlow iOS 스크린샷 인벤토리 (실측)

이 문서는 저장소에 실재하는 이미지 파일의 경로·픽셀 치수와 검수 상태를 기록한다.
신규 native baseline 5장은 화면을 육안 검수하고 PII를 확인했다. 기존 후보 자산은
역사적 기록으로 PNG 헤더(IHDR)와 치수만 측정했으며 화면 내용은 판독하지 않았다.

## 1. App Store 6.9" iPhone native baseline (Required)

| 파일 | 치수 | Apple 요구사항 충족 여부 |
|---|---|---|
| `docs/screenshots/app-store/native-ios/iphone-6.9/` (3장) | 1320×2868 | **LOCAL_QUALIFIED** — iPhone 16 Pro Max native simulator capture |

Apple 허용 해상도 중 1320×2868을 사용했다. 기존 1242×2688 Android-derived
8장은 REJECTED로 보존한다.

## 2. App Store 13" iPad native baseline (Required, 2064×2752)

| 파일 | 치수 | Apple 요구사항 충족 여부 |
|---|---|---|
| `docs/screenshots/app-store/native-ios/ipad-13/` (2장) | 2064×2752 | **LOCAL_QUALIFIED** — iPad Pro 13-inch (M4) native simulator capture |

13" iPad baseline은 2064×2752와 픽셀 단위로 일치하는 portrait native capture다.
기존 Android-derived 후보는 REJECTED로 보존한다.

## 3. Play Store 전용 (App Store 미사용)

| 파일 | 치수 | 용도 |
|---|---|---|
| `app_icon_512.png` | 512×512 | Google Play 아이콘 규격. App Store는 별도로 `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png`(1024×1024, 존재 확인됨)를 쓴다 |
| `feature-graphic-a.png`, `_b.png`, `_c.png`, `_d.png` | 1024×500 (a안 실측) | Google Play 전용 "피처 그래픽" — Apple App Store Connect에는 이 자산 슬롯이 없다 |
| `feature_graphic_1024x500.png` | 1024×500 | 위와 동일 성격, Play 전용 |

## 4. Android 전용 (docs/screenshots/ 이하)

`docs/screenshots/` 아래에는 Android(Play Store) 전용 자산이 별도로 존재한다.
치수가 App Store 6.9"/13" 요구 치수와 다르므로 **App Store 제출에 그대로 재사용
불가**:

| 파일/디렉터리 | 치수(실측 샘플) | 비고 |
|---|---|---|
| `docs/screenshots/01_home.png` | 1080×2316 | Android 폰 |
| `docs/screenshots/tablet_10inch_home.png` | 2560×1600 | Android 10" 태블릿, landscape |
| `docs/screenshots/store_final_v3/phone_1080x1920/PlanFlow_screenshot_1.png` | 1080×1920 | Android 폰(Play용 완성본) |
| `docs/screenshots/store_final_v3/tablet_1200x1920/PlanFlow_tablet_landscape_1.png`, `_2.png` | **2560×1600** | Android 태블릿(Play용 완성본), landscape |

**중요한 실측 발견**: `docs/screenshots/store_final_v3/tablet_1200x1920/` 아래의
`PlanFlow_tablet_landscape_1.png`/`_2.png`는 iOS 후보 폴더(`스크린샷 아이폰/가로/`)
의 **동일 파일명**을 갖고 있지만, 실측 치수는 서로 다르다(Android 쪽 2560×1600
vs iOS 후보 쪽 2064×2752). 즉 **같은 이름이라도 서로 다른 파일이며, iOS 후보가
Android 캡처를 단순 리사이즈한 파생물이라는 근거는 이번 조사에서 확인되지 않았다**
(반증도 하지 못했다 — 원본 생성 이력을 추적하지 않았으므로 UNVERIFIED로 남긴다).

## 5. App Icon (READY)

`ios/Runner/Assets.xcassets/AppIcon.appiconset/`에 `Contents.json`과 함께
`Icon-App-1024x1024@1x.png`를 포함한 전 규격 아이콘 세트가 존재함을 `ls`로
확인했다. 이 항목은 App Store 제출 관점에서 **READY**로 판단한다(개별 규격별
치수 재검증은 이번 조사 범위 밖 — 파일 존재만 확인).

## 6. 검수 및 운영 상태

Run 34795713111 native simulator capture에서 5장 모두 runtime/widget 검증,
visualReview PASS, PII review PASS로 확인했다. PNG는 raw RGBA(알파 255)에서
RGB로 알파만 제거했으며 resize/crop/frame은 없고 RGB 픽셀은 byte-equivalent다.
`storeUploadState=NOT_UPLOADED`이며 App Store Connect mutation은 수행하지 않았다.
