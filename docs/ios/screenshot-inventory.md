# PlanFlow iOS 스크린샷 인벤토리 (실측)

이 문서는 저장소에 실재하는 이미지 파일의 경로·픽셀 치수만 기록한다. 값은 전부
`ls`로 파일 존재를 확인하고 PNG 헤더(IHDR)를 파싱해 얻었다 — **픽셀 내용(화면에
찍힌 UI/텍스트)은 판독하지 않았다.**

## 1. App Store 6.9" iPhone 후보 (Required, 1260×2736)

| 파일 | 치수 | Apple 요구사항 충족 여부 |
|---|---|---|
| `스크린샷 아이폰/세로/PlanFlow_screenshot_1.png` ~ `_8.png` (8장) | 1242×2688 | **결손** — 6.5" iPhone 규격이지 6.9" 규격이 아니다 |

`.agents/skills/aso-audit/references/apple-specs.md:29`에 따르면 6.9" iPhone
스크린샷은 **Required**, 요구 치수는 **1260×2736**이다. 저장소에 있는 8장은
1242×2688로, 이는 iPhone 11 Pro Max/XS Max 세대의 6.5" 규격이다. **6.9" 규격
스크린샷은 저장소에 존재하지 않는다 → 신규 캡처 또는 리사이즈 작업 필요.**

## 2. App Store 13" iPad 후보 (Required, 2064×2752)

| 파일 | 치수 | Apple 요구사항 충족 여부 |
|---|---|---|
| `스크린샷 아이폰/가로/PlanFlow_tablet_landscape_1.png`, `_2.png` (2장) | 2064×2752 | **정확히 일치** |

`apple-specs.md:30`의 13" iPad 요구 치수(2064×2752)와 픽셀 단위로 정확히
일치한다. 단, 파일명이 `_landscape_`인데 실측 치수(2064×2752)는 세로가 긴
**portrait 방향**이다 — 파일명과 실제 방향이 어긋난다(이름의 신뢰성에 주의).

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

## 6. 미확인/사람 확인 필요 (TODO)

- **픽셀 내용 미검사**: 이 조사는 PNG 헤더만 읽었다. 스크린샷 안에 Android
  전용 UI(예: 뒤로가기 버튼, 상태바 아이콘 모양)나 PII(실제 사용자 이메일·
  전화번호·이름)가 노출되는지는 **육안으로 반드시 재확인해야 한다.**
- **6.9" iPhone 스크린샷 부재**: 현재 1242×2688(6.5") 8장만 있고 1260×2736
  (6.9") 세트가 없다. App Store Connect가 6.5" 자산을 6.9" 슬롯에 그대로
  받아줄지, 신규 캡처가 필요한지는 Apple 정책 확인이 필요하다(Apple은
  "auto-scales from required base sizes to smaller devices"라고만 명시하며
  6.5"→6.9" 업스케일을 보장한다는 근거는 이번 조사에서 찾지 못했다).
- **`가로` 폴더 명명 오류**: `PlanFlow_tablet_landscape_*.png`가 실제로는
  portrait 치수(2064×2752)다. 업로드 시 슬롯 오분류 위험이 있으니 파일명
  정정 또는 업로드 담당자에게 별도 안내 필요.
