# PlanFlow iOS 문서 인덱스 (P12)

이 디렉토리(`docs/ios/`)에는 PlanFlow iOS Simulator E2E Phase(P1~P12)에서 만들어진 문서가 모여 있다.
이 README는 각 문서가 무엇을 다루는지, 어떤 순서로 읽으면 되는지를 안내하는 인덱스다.

## 문서 목록

| 문서 | 무엇을 다루는가 | 만들어진 단계 |
|---|---|---|
| [`SIMULATOR_QA_MATRIX.md`](./SIMULATOR_QA_MATRIX.md) | iOS Simulator로 검증 가능/불가능한 QA 항목 37개 분류 매트릭스. 실측으로 정정된 사실(최소 iOS 버전, ATT 미구현, 딥링크 계약, env 폴백 등) 요약 포함. | P1 |
| [`parity-matrix.md`](./parity-matrix.md) | (기존) Android/iOS 기능 패리티 매트릭스 | 이전 Phase |
| [`privacy-surface-audit.md`](./privacy-surface-audit.md) | (기존) Privacy 관련 표면 감사 | 이전 Phase |
| [`app-store-metadata.md`](./app-store-metadata.md) | (기존) App Store 제출용 메타데이터 | 이전 Phase |
| [`apple-firebase-account-actions.md`](./apple-firebase-account-actions.md) | (기존) Apple/Firebase 계정 관련 액션 항목 | 이전 Phase |
| [`release-readiness.md`](./release-readiness.md) | (기존) 릴리스 준비 상태 | 이전 Phase |
| [`APP_STORE_READINESS.md`](./APP_STORE_READINESS.md) | App Store Connect 제출 전 체크리스트. 저장소 코드/설정에서 자동 확인 가능한 항목만 채웠고, 콘솔 접근이 필요한 "확인 필요" 항목은 추측하지 않고 그대로 남겨둠. Build 16까지 TestFlight 파이프라인(서명/IPA 메타데이터/privacy audit/BuildUpload/App Store ingestion) PASS 완료 사실 포함. | P11 |
| [`NEW_APP_IOS_PREFLIGHT.md`](./NEW_APP_IOS_PREFLIGHT.md) | **다른 Flux Studio Flutter 앱**(FinFlow/HealthFlow/ValueFlow/MenuFlow/NexusFlow 등)이 iOS 포팅을 새로 시작할 때, 착수 "전"에 1회 실행하는 preflight 체크리스트. 버전 숫자를 하드코딩하지 않고 항상 확인 시점 실측을 원칙으로 함. PlanFlow가 겪은 실패 사례(최소 iOS 15.0인데 보유 실기기가 iOS 12 상한)와 이번 Phase(P1~P11)에서 추가로 얻은 교훈 3건(지도 SDK arm64 슬라이스, 상태관리 seam 무력화, 전용 스테이징 백엔드 부재)을 9~11번 항목으로 반영. | 처음 작성은 이번 Phase 착수 직후, P12에서 9~11번 항목 보강 |
| [`templates/README.md`](./templates/README.md) | PlanFlow에서 구축·검증된 iOS Simulator E2E / 서명 릴리스 파이프라인을 다른 Flux Studio 앱이 재사용할 수 있도록 앱 고유값을 플레이스홀더로 치환한 템플릿 모음의 안내 문서. `templates/PARAMETERS.md`(파라미터 표), `templates/checklist-templates/`, `templates/workflow-templates/` 하위 디렉토리를 함께 참조. | P10 |

## 읽는 순서 (신규 앱이 이 자산을 재사용하려는 경우)

1. `NEW_APP_IOS_PREFLIGHT.md`로 착수 전 preflight를 먼저 끝낸다(1~11번 체크리스트).
2. `templates/README.md` → `templates/PARAMETERS.md`로 재사용 가능한 템플릿과 앱별로 채워야 할 값을 확인한다.
3. `SIMULATOR_QA_MATRIX.md`를 참고해 자기 앱의 QA 항목을 Simulator 가능/불가능으로 먼저 분류한다.
4. 릴리스 직전에는 `APP_STORE_READINESS.md` 구조를 참고해 자기 앱의 체크리스트를 만든다.

## 실측 정정 4건 (P1~P11 진행 중 사용자가 이전에 알고 있던 사실과 다르게 확인된 것)

이 절은 이번 Phase 도중 실제 코드/설정을 확인해 바로잡은 사실을 모아둔다. 추측이 아니라 저장소 파일을 직접 읽어 확인한 값만 적는다.

1. **min iOS는 15.0이다.** 이전에 "iOS 16"으로 알려져 있었으나, `ios/Podfile`과 `ios/Runner.xcodeproj/project.pbxproj`의 `IPHONEOS_DEPLOYMENT_TARGET`을 직접 확인한 결과 **15.0**이 실제 값이다. 다만 이 정정이 결론 자체를 바꾸지는 않는다 — iPhone 6(iOS 12가 설치 상한)는 15.0이든 16.0이든 어느 쪽 기준으로도 실행 불가능하므로, "보유 실기기로는 QA 불가능"이라는 결론은 그대로 유효하다.
2. **`NSUserTrackingUsageDescription` 문구는 있으나 실제 ATT 트리거 코드가 없다.** `Info.plist`에 해당 usage description 문자열은 존재하지만, `app_tracking_transparency` 패키지도 없고 `ATTrackingManager` 호출도 코드베이스에 0건이다(광고 동의는 Google UMP `ConsentInformation`만 사용 중). 이는 "심사 응답 문구와 실제 앱 동작이 불일치할 위험"이 있다는 뜻이며, 이번 Phase는 이 사실을 발견·기록만 하고 코드 수정은 하지 않았다 — ATT를 실제로 구현할지, 아니면 트래킹을 안 하므로 문구 자체를 제거할지는 사용자 판단이 필요한 별도 결정 사항이다.
3. **`lib/core/env.dart`가 Supabase dart-define 미주입 시 프로덕션 프로젝트로 폴백한다.** 즉 dart-define을 명시적으로 넘기지 않고 그냥 빌드/실행하면 프로덕션 Supabase에 연결된다. 이번 Phase의 iOS Simulator E2E는 이 폴백 경로를 그대로 타면 테스트 트래픽이 프로덕션으로 새어나갈 위험이 있어, 이를 피하기 위한 격리 전략(빌드 전 dart-define 주입 여부를 검증하는 게이트)을 별도로 만들어 대응했다.
4. **Riverpod `ProviderScope`는 있지만 실질적인 provider 기반 상태관리는 아니다.** 앱이 `ProviderScope`로 감싸져 있어 겉보기엔 Riverpod 아키텍처처럼 보이지만, 실제 코드에서 `ref.watch` 사용례를 grep하면 0건이다. `authProvider` 등 핵심 서비스는 전역 싱글턴으로 구현돼 있다. 그 결과 이번 Phase에서 테스트 목적으로 만든 `runPlanFlowApp(overrides:)` 진입점 주입 seam은, 현재 구조상 인증 상태를 실제로 바꿔 넣는 데는 실질적 효과가 없다. 이 seam이 의미를 가지려면 앱 전체를 실제로 Riverpod 기반(핵심 서비스를 provider로 노출하고 화면이 `ref.watch`로 구독)으로 마이그레이션해야 하며, 이번 Phase 범위에는 그 마이그레이션이 포함되지 않는다.

## 정정 제안 (이 저장소에서 직접 고치지 않음)

프로젝트 `CLAUDE.md`에는 "iOS 관련 코드 추가 금지 (Android-only 프로젝트)"라는 조항이 있다. 그러나 실제로는 이번 Phase(P1~P12) 전체가 iOS Simulator E2E 파이프라인·서명 릴리스 워크플로·`docs/ios/` 문서군을 대량으로 추가했고, `docs/ios/APP_STORE_READINESS.md`에 따르면 Build 16까지 TestFlight 파이프라인이 이미 PASS로 완료되어 있다. 즉 이 조항은 현재 코드베이스 실태와 불일치하는 stale 상태로 보인다.

다만 이 조항의 실제 소스는 이 저장소가 아니라 `E:\AI_WIKI`의 공용 문서 원본(`agents-common.md`/`anti-patterns.md` 등, PlanFlow의 `CLAUDE.md`는 그 원본에서 자동 생성된 사본)이다. 그래서 이 README에서 그 조항을 임의로 고치거나 이 저장소의 `CLAUDE.md`를 직접 편집하지 않는다 — 그렇게 하면 다음 자동 재생성 시 덮어써지거나, 여러 Flux Studio 프로젝트가 공유하는 원본과 이 저장소 사본이 어긋나게 된다. 이 조항을 실제로 정정하려면 AI_WIKI 원본 문서를 고친 뒤 PlanFlow의 `CLAUDE.md` 재생성 절차를 거쳐야 하며, 그 결정은 이 Phase의 범위 밖이므로 여기서는 "정정이 필요해 보인다"는 제안만 남긴다.
