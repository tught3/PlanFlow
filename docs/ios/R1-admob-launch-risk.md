# R1 — iOS AdMob/UMP 초기화 런치 크래시 리스크 판정

> **판정: `R1_UNDETERMINED`**
> 근거: 이 리스크를 판별할 유일한 수단(프로덕션 plist 런치 프로브)이 **아직 한 번도 실행된 적이 없다.**
> 코드 정적 분석만으로는 크래시 여부를 **어느 쪽으로도** 확정할 수 없다(§2 참조).

이 문서는 저장소 코드를 직접 읽어 확인한 사실만 기재한다. 실행 증거가 없는 항목은
`UNVERIFIED`로 표기하고 추정을 확정으로 승격하지 않는다.

---

## 0. R1이란 무엇인가

**R1 = iOS에서 앱 부팅 시 AdMob(Google Mobile Ads) / UMP SDK 초기화 경로가
프로덕션 `Info.plist` 상태(= `GADApplicationIdentifier` 키 부재)와 만나
런치 크래시를 일으킬 가능성.**

Google Mobile Ads SDK는 iOS에서 `Info.plist`의 `GADApplicationIdentifier`가
없거나 형식이 잘못된 경우 초기화 시점에 assertion/예외로 프로세스를 중단시키는
동작이 문서화되어 있는 SDK다. PlanFlow의 프로덕션 `ios/Runner/Info.plist`에는
이 키가 **의도적으로 없고**(§1-3), 앱은 부팅 시 **플랫폼 분기 없이**
`AdService.initialize()`를 호출한다(§1-2). 이 두 사실의 조합이 R1이다.

---

## 1. 코드 실측 — 확정 사실

### 1-1. 두 개의 네이티브 진입점, 그리고 그 사이의 조기 return

`lib/services/ad_service.dart`의 `initialize()`에는 네이티브 SDK를 건드리는
지점이 **두 개**이며, UMP가 MobileAds보다 **먼저** 온다.

| 순서 | 위치 | 호출 |
|---|---|---|
| 1 | `lib/services/ad_service.dart:448` | `await _consentService.ensureReady(userInitiated: false);` (UMP) |
| — | `lib/services/ad_service.dart:453-454` | **조기 return 분기** |
| 2 | `lib/services/ad_service.dart:483` | `await MobileAds.instance.initialize();` |

조기 return 분기의 실제 코드(`:453-454`, `:468`):

```dart
if (!_consentService.isAvailable &&
    !(await _consentService.canRequestAdsLive)) {
  // ... logAdLoadFailed(reason: 'ump_unavailable') ...
  return;                                     // :468
}
```

**이 분기 때문에 코드 읽기만으로는 결론이 나지 않는다.**

- 만약 iOS에서 UMP가 unavailable로 판정되면 → `:468`에서 return하므로
  `:483`의 `MobileAds.instance.initialize()`에 **도달조차 하지 않는다.**
  이 경우 GAD ID 부재로 인한 MobileAds 크래시는 애초에 발생할 수 없다.
- 만약 UMP가 available이면 → `:483`에 도달하고, 그 시점에 GAD ID 부재가
  문제가 될 수 있다.
- 그리고 **UMP 자체(`:448`)가 GAD ID 부재 상태에서 어떻게 동작하는지**는
  별개의 미지수다. UMP도 네이티브 SDK 호출이며 MobileAds보다 먼저 실행된다.

즉 크래시 지점 후보가 2개이고, 그중 하나(UMP)의 결과가 다른 하나(MobileAds)의
도달 여부를 결정한다. **정적 분석은 여기서 멈춘다.**
`_consentService.isAvailable` / `canRequestAdsLive`의 런타임 값은
실제 iOS 프로세스에서 UMP SDK를 실행해봐야만 알 수 있다.

### 1-2. 부팅 경로에 플랫폼 분기가 없다

- `lib/main.dart:107` — `_primingAdService(firebaseReady),` (부팅 초기화 목록에 포함)
- `lib/main.dart:175` — `await AdService.instance.initialize();`

`lib/main.dart`에는 `Platform.isIOS` / `defaultTargetPlatform` 분기가 **한 건도 없다**
(grep 실측: `_primingAdService` 3건 외 플랫폼 분기 매칭 0건).
따라서 iOS에서도 Android와 동일하게 무조건 이 경로를 탄다.

단, `_primingAdService`는 `try/catch`로 감싸여 있다(`lib/main.dart:189` `} catch (error, stack) {`).
**Dart 예외는 여기서 잡힌다. 그러나 네이티브(Objective-C/Swift) assertion이나
`NSException` 계열 중단은 Dart `catch`로 잡히지 않는다** — 그래서 이 try/catch의
존재가 R1을 해소하지 않는다.

### 1-3. 프로덕션 plist에 `GADApplicationIdentifier`가 없고, 그 부재가 강제된다

- `ios/Runner/Info.plist` — `grep GADApplicationIdentifier` **매칭 0건 (exit 1)**. 부재 확인.
- `scripts/ios/tests/e2e_admob_contract.sh:24-25` — 그 부재를 계약으로 강제:

```sh
printf '%s' "$plist_text" | grep -qF -- 'GADApplicationIdentifier' && \
  fail 'production Runner Info.plist contains GADApplicationIdentifier'
```

즉 키 부재는 사고가 아니라 **의도된 상태**이며, 키를 추가하려는 변경은 이 계약 테스트에
막힌다. (참고: `ios/Runner/Info.plist:28`에 `NSUserTrackingUsageDescription`은 존재한다.)

### 1-4. iOS 광고 단위 ID는 Remote Config에 존재하지 않는다

`lib/services/remote_config_service.dart`의 광고 단위 ID 키는 **Android 하나뿐**이다:

- `lib/services/remote_config_service.dart:125` — `static const String _kRewardedAdUnitIdAndroid = 'rewarded_ad_unit_id_android';`
- `lib/services/remote_config_service.dart:434` — `static String get rewardedAdUnitIdAndroid =>`

(`grep -n "adUnit\|ad_unit\|rewarded"` 실측 결과 iOS 전용 광고 단위 키는 **0건**.)

그리고 `AdService._resolveAdUnitId()`는 플랫폼 무관하게 그 Android 키를 읽는다:

```dart
// lib/services/ad_service.dart:507-512
String _resolveAdUnitId() {
  return resolveRewardedAdUnitIdFor(
    useTestUnit: kDebugMode || kProfileMode,
    configured: RemoteConfigService.rewardedAdUnitIdAndroid,   // :510
  );
}
```

**따라서 iOS release 빌드에서 광고를 로드하려 하면 Android 광고 단위 ID를 쓰게 되며,
정상적인 iOS 광고 서빙은 애초에 성립하지 않는다.** 이것은 §5의 제안 패치가
"기능 손실 0"이라고 주장할 수 있는 근거다.

---

## 2. Run #18(iOS Simulator XCTest)은 R1의 증거가 아니다

`docs/ios/XCTEST_STOP_LOSS_DECISION.md`가 다루는 XCTest 실행(Run #13~#18)은
겉보기에 "시뮬레이터에서 앱이 떴다"는 증거처럼 보이지만, 스테이지 구현을 직접 읽으면
**R1을 검증할 수 없는 구조**임이 드러난다. 이유는 두 가지이며 각각 독립적으로 치명적이다.

### 2-1. APP_LAUNCH / APP_READY 어느 쪽도 "앱 프로세스 생존"을 확인하지 않는다

**APP_LAUNCH — `scripts/ios/e2e_xctest_flow.sh:263`**

```sh
run_bounded APP_LAUNCH xcrun simctl launch "$udid" "$bundle_id"
```

이 스테이지의 PASS 조건은 `xcrun simctl launch`의 **종료 코드**뿐이다.
`simctl launch`는 프로세스 **spawn 성공** 시점에 0을 반환한다 —
그 직후 앱이 SDK 초기화 중 크래시로 죽어도 이 명령의 종료 코드는 이미 0이다.
즉 **런치 크래시를 원리적으로 탐지할 수 없는 스테이지다.**

**APP_READY — `scripts/ios/e2e_xctest_flow.sh:281-285`**

```sh
run_bounded APP_READY bash -c '
  set -euo pipefail
  xcrun simctl spawn "$E2E_UDID" launchctl print system >/dev/null    # :283
  xcrun simctl terminate "$E2E_UDID" "$E2E_BUNDLE_ID" >/dev/null 2>&1 || true
'
```

`launchctl print system`은 **시뮬레이터의 launchd 서비스**가 응답하는지만 확인한다.
이는 앱과 무관하게 시뮬레이터가 부팅되어 있으면 항상 성공한다.
그리고 곧바로 앱을 `terminate` 한다 — 즉 **앱 프로세스가 살아 있는지를 한 번도 묻지 않는다.**
(`:281` 위 주석 자체가 "launchctl is queried only to prove the simulator service remains
responsive"라고 명시한다.)

**결론: 앱이 부팅 직후 크래시했더라도 APP_LAUNCH·APP_READY는 둘 다 PASS로 나온다.**

### 2-2. 애초에 프로덕션 plist 상태가 아니었다

같은 스크립트가 빌드 전에 GAD ID를 **주입**하고 끝나면 복원한다:

- `scripts/ios/e2e_xctest_flow.sh:115` — `cp -p -- "$runner_plist" "$runner_plist_backup" || return 1`
- `scripts/ios/e2e_xctest_flow.sh:121` — `/usr/libexec/PlistBuddy -c "Add :GADApplicationIdentifier string $E2E_ADMOB_TEST_APP_ID" "$runner_plist"`
- `scripts/ios/e2e_xctest_flow.sh:125` — `restore_runner_plist() {`

즉 XCTest 레그가 실행한 앱의 plist에는 **테스트용 GAD ID가 들어 있었다.**
R1은 "GAD ID가 **없는**" 상태의 리스크이므로, 이 실행은 R1이 묻는 조건을
**한 번도 재현한 적이 없다.**

> 두 결함이 곱해진 결과: XCTest가 100번 PASS해도 R1에 대해 알려주는 것은 **0**이다.

---

## 3. 판정: `R1_UNDETERMINED`

가능한 판정값은 셋이다.

| 판정 | 의미 | 채택 여부 |
|---|---|---|
| `R1_CLEARED` | 프로덕션 plist 상태에서 앱이 정상 부팅·생존함이 **실측**됨 | ✗ 실측 없음 |
| `R1_CONFIRMED_BLOCKER` | 프로덕션 plist 상태에서 런치 크래시가 **실측**됨 | ✗ 실측 없음 |
| **`R1_UNDETERMINED`** | 판별 수단은 존재하나 **아직 실행되지 않음** | **✔ 채택** |

### 왜 `R1_CLEARED`가 아닌가

"Build 16까지 TestFlight 파이프라인이 PASS했다"는 사실은 **빌드·서명·업로드·ingestion**의
증거이지 **런타임 부팅**의 증거가 아니다. 그 파이프라인 어디에도 앱 프로세스를 띄워
생존을 확인하는 단계가 없다. §2에서 본 대로 시뮬레이터 XCTest도 증거가 아니다.
실기기 실행 증거(FLOW1~8 등)는 `docs/ios/XCTEST_STOP_LOSS_DECISION.md` §2.2 기준
**전부 `NOT_VERIFIED`**다.

### 왜 `R1_CONFIRMED_BLOCKER`도 아닌가

§1-1의 조기 return(`ad_service.dart:453-454`) 때문이다. iOS에서 UMP가 unavailable이면
`MobileAds.instance.initialize()`(`:483`)에 도달하지 못하므로 GAD ID 부재로 인한
MobileAds 크래시는 발생하지 않는다. `_consentService.isAvailable`의 iOS 런타임 값을
모르는 상태에서 크래시를 단정하면 그것도 미실측 주장이다.

### 판별 수단이 아직 실행되지 않았다는 사실의 근거

- `.github/workflows/ios-adsdk-launch-probe.yml`은 `on: workflow_dispatch:` **전용**이다
  (`push`/`pull_request` 트리거 없음). 즉 **사람이 수동으로 돌리기 전에는 절대 실행되지 않는다.**
- 이 프로브는 커밋 `f29f9a24`(그룹 C 산출물)로 **이번 Phase에 처음 만들어졌다.**
- 프로브 실행에는 macOS runner가 필요하다(`runs-on: macos-15`). **이 작업 호스트는
  Windows(`uname -s` = `MINGW64_NT-10.0-26200`)이므로 로컬 실행이 불가능하다.**
- GitHub Actions run 이력 조회도 불가능하다: `gh auth status` 실측 결과
  `You are not logged into any GitHub hosts.` — **gh CLI 미인증.**

따라서 "실행됐는지"를 확인할 수단조차 없고, workflow_dispatch 전용 + 방금 생성이라는
두 사실을 합치면 **실행된 적 없음**이 합리적 결론이다. 그러나 이것도 직접 관측이 아니라
**추론**이므로, 사용자는 아래 §4-0을 먼저 확인하기 바란다.

---

## 4. R1을 확정하는 방법 (사용자 액션)

### 4-0. (선택) 정말 실행된 적 없는지 먼저 확인

GitHub 웹에서 `Actions` → 좌측 워크플로 목록 →
**`iOS AdSDK launch probe (production plist)`** 선택 → run 이력이 비어 있으면
`R1_UNDETERMINED` 판정의 전제가 확인된 것이다.

### 4-1. 프로브 실행 절차 (workflow_dispatch)

1. GitHub 저장소 → **Actions** 탭
2. 좌측에서 **`iOS AdSDK launch probe (production plist)`** 선택
3. 우측 **`Run workflow`** 버튼 클릭
4. 입력값(둘 다 기본값 사용 권장):
   - `wait_seconds` — 기본 `20`. 런치 후 생존/크래시를 판정하기까지 대기할 초.
     UMP 네트워크 왕복이 느릴 수 있으므로 1차 결과가 애매하면 `45`로 올려 재실행한다.
   - `stage_timeout_seconds` — 기본 `900`. 각 build/install/launch 스테이지 상한.
5. 브랜치는 `main`(이 커밋 이후) 선택
6. 소요: macOS runner 빌드 포함 `timeout-minutes: 40` 이내

CLI를 쓴다면(사전에 `gh auth login` 필요):

```bash
gh workflow run ios-adsdk-launch-probe.yml --ref main
gh run watch
```

### 4-2. 결과 해석 — 스테이지 조합별 판정표

프로브의 스테이지는 `scripts/ios/prod_plist_launch_probe.sh:54-62`에 정의된 7개다:
`SIMULATOR_BOOT` → `APP_BUILD` → `APP_INSTALL` → `APP_LAUNCH` →
`PROD_PLIST_APP_ALIVE` → `PROD_PLIST_NO_CRASH` → `TEARDOWN`.

R1 판정에 쓰는 것은 뒤의 **두 개**다.

- **`PROD_PLIST_APP_ALIVE`** (`prod_plist_launch_probe.sh:307-315`) —
  `wait_seconds` 대기 후 `launchctl list`에 해당 bundle id의 **live job**이 있는지 확인.
  FAIL 메시지: `no live launchctl job found for ... the app likely crashed or exited`.
  → **앱 프로세스 생존 여부.** §2-1에서 XCTest에 없다고 지적한 바로 그 확인이다.
- **`PROD_PLIST_NO_CRASH`** (`prod_plist_launch_probe.sh:365-368`) —
  런치 이후 새로 생긴 네이티브 crash report를 `~/Library/Logs/DiagnosticReports`와
  그 `Retired` 하위에서 탐색. 새 리포트가 있으면 FAIL이며 아티팩트로 복사된다.
  이 스테이지는 `PROD_PLIST_APP_ALIVE`가 이미 실패했더라도 **건너뛰지 않고 실행된다**
  (스크립트 `:327` 주석: 크래시를 진단 가능하게 하기 위함).

| `APP_ALIVE` | `NO_CRASH` | 해석 | R1 판정 |
|---|---|---|---|
| PASS | PASS | 프로덕션 plist 상태에서 앱이 부팅 후 생존했고 네이티브 크래시 리포트도 없다 | **`R1_CLEARED`** |
| FAIL | FAIL | 앱이 죽었고 그 원인인 crash report가 실제로 생성됐다 — 가장 명확한 확정 | **`R1_CONFIRMED_BLOCKER`** |
| FAIL | PASS | 앱이 사라졌으나 crash report는 없다. 크래시가 아니라 정상 종료/`exit()`거나, 리포트 생성 지연일 수 있다. `wait_seconds`를 45~60으로 올려 재실행하고, 그래도 같으면 crash가 아닌 조기 종료로 보아 **블로커로 취급하되** 원인은 별도 조사 | `R1_CONFIRMED_BLOCKER` (조건부) |
| PASS | FAIL | 앱은 살아 있는데 새 crash report가 있다 — Runner 본체가 아니라 **다른 프로세스**(예: Widget extension)의 리포트일 수 있다. 아티팩트 `prod-plist-launch-probe`에 복사된 리포트의 프로세스명을 확인해 Runner 것이 아니면 R1과 무관 | 리포트 확인 후 재판정 |
| 그 이전 스테이지에서 FAIL | — | `APP_BUILD`/`APP_INSTALL` 실패는 R1이 아니라 빌드 환경 문제 | `R1_UNDETERMINED` 유지 |

아티팩트는 `prod-plist-launch-probe` 이름으로 14일간 보관된다
(`.github/workflows/ios-adsdk-launch-probe.yml`의 `Upload probe artifacts` 스텝).

---

## 5. 미적용 패치 제안 — `R1_CONFIRMED_BLOCKER`인 경우에만

> **이 절은 제안이다. 코드는 적용하지 않았다.**
> `lib/` 아래 파일은 이번 작업에서 **한 줄도 수정되지 않았다.**
> 프로브가 `R1_CONFIRMED_BLOCKER`를 내지 않는 한 이 패치를 적용해서는 안 된다.

### 5-1. 제안 내용

`lib/main.dart`의 `_primingAdService`(또는 `AdService.initialize()` 진입부)에서
**iOS일 때 초기화를 스킵**한다. 개략:

```dart
// 제안 (미적용) — lib/main.dart _primingAdService 내부
await firebaseReady;
if (!kIsWeb && Platform.isIOS) {
  // R1: 프로덕션 Info.plist에 GADApplicationIdentifier가 없고
  //     (scripts/ios/tests/e2e_admob_contract.sh:24-25가 그 부재를 강제),
  //     iOS 광고 단위 ID도 Remote Config에 존재하지 않는다
  //     (remote_config_service.dart:125는 android 키뿐).
  //     따라서 iOS에서 AdService 초기화는 얻는 것이 없고 런치 크래시 위험만 있다.
  return;
}
await AdService.instance.initialize();
```

정확한 구현 위치·방식(진입부 가드 vs `AdService.initialize()` 내부 가드)과
관련 계약 테스트 갱신은 실제 적용 시점에 별도 판단한다.

### 5-2. 기능 손실이 0인 근거

§1-4에서 확인한 대로 **iOS 전용 광고 단위 ID가 Remote Config에 아예 없고**
(`remote_config_service.dart:125`의 `rewarded_ad_unit_id_android` 하나뿐),
`_resolveAdUnitId()`(`ad_service.dart:507-512`)는 그 Android 키를 그대로 쓴다.
따라서 iOS에서 광고는 **현재도 정상 서빙될 수 없는 상태**다.
초기화를 스킵해도 잃는 기능이 없다.

### 5-3. 이 패치의 비용 — 반드시 사용자 승인 필요

- **Build 17을 요구한다.** 이 변경은 Dart 코드 변경이므로 새 아카이브·새 빌드번호로
  TestFlight를 다시 올려야 한다. 현재 확정 사실인 "Build 16까지 파이프라인 PASS"는
  이 패치에 적용되지 않는다.
- **사용자 승인 필요.** 프로덕션 동작(광고 초기화 경로)을 바꾸는 변경이며,
  이 문서의 작성 세션은 `lib/` 수정 권한이 없다.
- 적용 시 `test/ios_admob_contract_test.dart` / `scripts/ios/tests/e2e_admob_contract.sh`와의
  정합성을 재확인해야 한다.

### 5-4. 대안 (참고, 검토 안 됨)

`ios/Runner/Info.plist`에 실제 iOS `GADApplicationIdentifier`를 추가하는 방향도
이론적으로는 R1을 해소한다. 그러나 (a) `e2e_admob_contract.sh:24-25`가 그 키의 부재를
**계약으로 강제**하고 있어 계약 자체를 뒤집어야 하고, (b) iOS 광고 단위 ID가 없어
광고가 서빙되지도 않으며, (c) 실제 AdMob iOS 앱 등록이 선행돼야 한다.
**이번 Phase 범위 밖이며 검토하지 않았다.**

---

## 6. 한계 (정직 고백)

1. **시뮬레이터 생존 ≠ 실기기 생존.** 프로브는 iOS Simulator에서 돌며
   (`.github/workflows/ios-adsdk-launch-probe.yml`의 `simctl` 경로),
   시뮬레이터는 x86_64/arm64 시뮬레이터 슬라이스를, 실기기는 device 슬라이스를 쓴다.
   Google Mobile Ads SDK는 두 슬라이스에서 초기화 assertion 동작이 다를 수 있다.
   따라서 `R1_CLEARED`가 나오더라도 그것은 **시뮬레이터 한정 clear**이며
   실기기 확인을 대체하지 않는다.
2. **GMA 네이티브 SDK 버전 미확인.** `pubspec.lock`의 Dart 플러그인은
   `google_mobile_ads 5.3.1`로 고정돼 있으나, 실제 크래시 동작을 결정하는 것은
   CocoaPods로 해석되는 **네이티브 `Google-Mobile-Ads-SDK` 버전**이다.
   `ios/Podfile.lock`이 저장소에 **존재하지 않아**(`ios/.gitignore:3`이 `Pods/`를 제외)
   그 버전을 저장소에서 확정할 수 없다. 즉 CI가 `pod install` 할 때마다 다른 네이티브
   SDK 버전이 들어올 수 있고, R1의 결론이 시점에 따라 달라질 수 있다.
3. **UMP 경로는 프로브로도 완전히 갈라지지 않는다.** 프로브는 "앱이 죽었는가"를
   측정하지 crash가 UMP(`ad_service.dart:448`)에서 났는지 MobileAds(`:483`)에서 났는지
   구분하지 않는다. 구분이 필요하면 아티팩트의 crash report 스택을 읽어야 한다.
4. **프로브 미실행 사실 자체가 추론이다.** §3에서 밝힌 대로 gh CLI 미인증으로
   run 이력을 직접 조회하지 못했다. workflow_dispatch 전용 + 방금 생성이라는
   두 사실에 근거한 추론이다.

---

## 7. 참조

- `docs/ios/XCTEST_STOP_LOSS_DECISION.md` — XCTest 중단 판정, §2.1/2.2 통과 근거 인벤토리
- `docs/ios/release-readiness.md` — 최종 App Store 판정과 R1 반영
- `docs/ios/APP_STORE_READINESS.md` — 콘솔 항목별 준비 상태
- `scripts/ios/prod_plist_launch_probe.sh` — 프로브 본체
- `scripts/ios/tests/prod_plist_launch_probe_contract.sh` — 프로브 정적 계약(비-macOS에서도 실행 가능)
- `.github/workflows/ios-adsdk-launch-probe.yml` — 수동 실행 워크플로
