# Flux Studio 공용 iOS QA/Release 템플릿 (P10)

> 이 디렉토리는 **PlanFlow에서 실제로 구축·검증된 iOS Simulator E2E / 서명 릴리스 파이프라인**을
> 다른 Flux Studio Flutter 앱(FinFlow / HealthFlow / ValueFlow / MenuFlow / NexusFlow 등)이
> 그대로 재사용할 수 있도록 **앱 고유값을 전부 플레이스홀더로 치환한 템플릿**을 모아둔 곳이다.

## 이 디렉토리가 존재하는 이유

PlanFlow iOS 포팅에서 만든 자산(Simulator QA 분류 매트릭스, integration_test 하네스,
simctl 스크립트, 서명 릴리스 워크플로, 심사 준비 체크리스트)은 대부분 **앱 이름과 번들 ID만 다르고
구조는 동일**하다. 이걸 앱마다 처음부터 다시 설계하면 같은 함정(최소 iOS 버전 미확인, App Group 누락,
Widget 프로비저닝 프로파일 분리 실패, 시뮬레이터로 검증 불가능한 항목을 자동화하려다 낭비)을 반복하게 된다.

그래서 **재사용 가능한 부분만 뽑아 파라미터화**하고, 앱마다 다른 값은 파라미터 표 하나로 모았다.

## 무엇이 공통이고 무엇이 앱별인가

| 구분 | 항목 | 비고 |
|---|---|---|
| **공통 (템플릿으로 제공)** | 시뮬레이터 E2E 워크플로 골격(빌드 → simctl boot → integration_test → 아티팩트) | `workflow-templates/ios-simulator-e2e.yml.tmpl` |
| **공통** | App Store 심사 준비 체크리스트 구조 | `checklist-templates/app-store-readiness.md.tmpl` |
| **공통** | 신규 앱 iOS 착수 preflight 절차 | `checklist-templates/new-app-preflight.md.tmpl` |
| **공통** | fail-closed 게이트 패턴 (`::error title=BLOCKED_*::` + `exit 1`) | 아래 "설계 원칙" 참조 |
| **공통** | Runner / Widget 프로비저닝 프로파일을 절대 공유하지 않는 규칙 | 워크플로 템플릿에 내장 |
| **앱별 (파라미터)** | 번들 ID, App Group, URL scheme, 최소 iOS, Secret 접두어, 기능 플래그 | `PARAMETERS.md` |
| **앱별 (구현)** | 실제 integration_test 시나리오 코드, fake 주입 seam | 템플릿 제공 안 함 — 앱 도메인에 종속 |
| **앱별 (판정)** | 어떤 QA 항목이 SIMULATOR_FULL / SIMULATOR_PARTIAL / PHYSICAL_DEVICE_REQUIRED 인지 | 앱마다 재판정 필요 |

## 디렉토리 구조

```
docs/ios/templates/
├── README.md                                   # 이 문서
├── PARAMETERS.md                               # 파라미터 스키마 (이름/설명/필수여부)
├── planflow.values.md                          # PlanFlow 실제 값 참조표 (리터럴은 여기에만)
├── workflow-templates/
│   └── ios-simulator-e2e.yml.tmpl              # 시뮬레이터 E2E 워크플로 템플릿
└── checklist-templates/
    ├── app-store-readiness.md.tmpl             # 심사 제출 전 준비 체크리스트 템플릿
    └── new-app-preflight.md.tmpl               # iOS 포팅 착수 전 preflight 템플릿
```

## `.tmpl` 확장자를 쓰는 이유 (중요)

`workflow-templates/ios-simulator-e2e.yml.tmpl`은 **실행되는 워크플로가 아니다.**

- GitHub Actions는 `.github/workflows/` 아래의 `.yml` / `.yaml` 파일만 워크플로로 인식한다.
- 이 템플릿은 `docs/ios/templates/` 아래에 있고 확장자가 `.yml.tmpl`이므로 **절대 실행되지 않는다.**
- 플레이스홀더(`{{BUNDLE_ID}}` 등)가 그대로 남아 있어 YAML로도 유효하지 않다 — 실행되면 안 되는 게 정상이다.
- 이 파일을 `.github/workflows/` 로 복사할 때는 **반드시 모든 `{{...}}` 를 치환한 뒤** 확장자를
  `.yml`로 바꿔서 넣어야 한다. 치환하지 않고 옮기면 CI가 파싱 단계에서 실패한다.

## 신규 앱에 적용하는 절차

1. **preflight 먼저 실행한다.**
   `checklist-templates/new-app-preflight.md.tmpl`을 대상 앱 저장소의 `docs/ios/NEW_APP_IOS_PREFLIGHT.md`로
   복사하고 플레이스홀더를 치환한 뒤, 체크리스트를 **코드 한 줄 쓰기 전에** 끝낸다.
   특히 "앱 최소 iOS 버전 vs 보유 실기기 상한 대조" 항목을 건너뛰지 마라 —
   PlanFlow는 이 항목을 놓쳐서 개발 완료 후에야 실기기 QA가 불가능함을 발견했다.

2. **파라미터 값을 확정한다.**
   `PARAMETERS.md`의 표를 대상 앱 기준으로 채워 `docs/ios/templates/<app>.values.md` 같은 파일로 남긴다.
   (PlanFlow 예시는 `planflow.values.md` 참조.)
   이 시점에 `HAS_WIDGET` / `HAS_MICROPHONE` 등 기능 플래그를 정확히 판단해야 이후 게이트가 과대/과소해지지 않는다.

3. **identity xcconfig를 만든다.**
   번들 ID / 위젯 번들 ID / App Group을 하드코딩으로 흩뿌리지 말고,
   `ios/Flutter/<App>-Identity.xcconfig` 같은 단일 소스 파일 하나에 상수로 선언한 뒤 참조한다.
   워크플로의 canonical 검증 게이트가 이 값과 대조한다.

4. **QA 분류 매트릭스를 앱 기준으로 다시 만든다.**
   PlanFlow의 `docs/ios/SIMULATOR_QA_MATRIX.md`를 구조 참고용으로 보되, **판정 결과를 복사하지 마라.**
   앱마다 쓰는 플러그인과 하드웨어 의존성이 달라 SIMULATOR / PHYSICAL 판정이 달라진다.
   판정 축은 그대로 재사용한다: `분류 / 이유 / 검증방법 / 릴리스영향도 / 기존계약테스트중복여부 / 담당FLOW`.

5. **워크플로 템플릿을 치환해 배치한다.**
   `workflow-templates/ios-simulator-e2e.yml.tmpl` → 모든 `{{...}}` 치환 → `.github/workflows/ios-simulator-e2e.yml`.
   치환 누락이 없는지 배치 직후 `grep -n '{{' .github/workflows/ios-simulator-e2e.yml` 로 확인한다(0건이어야 한다).

6. **심사 준비 체크리스트를 배치한다.**
   `checklist-templates/app-store-readiness.md.tmpl` → 치환 → `docs/ios/release-readiness.md`.

7. **첫 CI 실행 결과로 잠정 판정을 1회 갱신한다.**
   Windows 로컬에서는 `flutter build ios` 자체가 불가능하므로, 지도 SDK의 시뮬레이터 슬라이스 제공 여부 같은
   항목은 macOS 러너 1차 실행 전까지 실측할 수 없다. 잠정 분류로 두고 1차 실행 후 확정한다.

## 설계 원칙 (템플릿을 고칠 때도 지켜야 하는 것)

- **fail-closed가 기본이다.** 값 없음 / 파싱 실패 / 아티팩트 부재는 전부 차단(`exit 1`)이다.
  "없으면 건너뛴다"로 만들면 게이트가 조용히 죽어도 아무도 모른다.
- **차단 사유는 기계 판독 가능한 라벨로 낸다.** `::error title=BLOCKED_<사유>::` 형식을 유지해야
  로그에서 실패 원인을 문자열로 집계할 수 있다.
- **성공 신호도 명시적으로 찍는다.** `<GATE_NAME>_PASS: PASS` 형태로 남겨야
  "조용히 통과"와 "실제로 검증하고 통과"를 사후에 구분할 수 있다.
- **비밀값은 절대 로그에 찍지 않는다.** 존재 여부(`yes`/`no`), 길이, SHA-256만 출력한다.
- **버전 숫자를 문서에 하드코딩하지 않는다.** Flutter SDK / Xcode / 러너 이미지 / Apple 기기 지원 범위는
  전부 시간이 지나면 바뀐다. 파라미터로 빼거나 실행 시점 동적 조회로 처리한다.
- **앱 고유 리터럴을 템플릿 본문에 남기지 않는다.** 남기면 다음 앱이 그대로 복사해 잘못된 번들 ID로 빌드한다.

## 알려진 한계 (정직 고백)

- 이 템플릿은 **PlanFlow 한 앱의 실측 경험에서 추출**한 것이라, 다른 앱에서 처음 적용할 때
  이 템플릿이 다루지 않는 항목(예: 결제/StoreKit, HealthKit, 백그라운드 위치 상시 추적)이 나올 수 있다.
  그 경우 템플릿을 무리하게 우겨넣지 말고 해당 앱에서 추가 게이트를 만든 뒤, 재사용 가치가 확인되면
  그때 이 템플릿에 역이식한다.
- `ios-simulator-e2e.yml.tmpl`은 **P8이 만들 실제 워크플로보다 먼저 작성된 초안**이다.
  실제 워크플로가 확정되면 이 템플릿과의 구조 드리프트를 1회 점검해야 한다.
- 플레이스홀더 치환은 **수동 절차**다. 치환 자동화 스크립트는 제공하지 않는다 —
  앱마다 치환 대상이 파일 몇 개뿐이고, 자동화 스크립트가 오히려 검증되지 않은 죽은 코드가 되기 쉽다.
  대신 배치 직후 `grep '{{'` 로 치환 누락을 확인하는 절차를 위 5번에 명시했다.
