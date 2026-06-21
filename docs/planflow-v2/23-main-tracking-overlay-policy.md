# PlanFlow V2 Main Tracking Overlay Policy

## 원칙

PlanFlow V2는 독립 제품 분기가 아니라 `PlanFlow main`의 별도 설치 가능한 테스트 채널이다.
따라서 V2 기능과 직접 관련 없는 디버깅, 권한, 알림, 딥링크 처리, 공통 화면, 서비스 로직은 main을 기준으로 맞춘다.

## V2 Overlay 허용 목록

- Android `applicationId` / Gradle namespace: `com.fluxstudio.planflow.v2`
- Kotlin package/path: `com.fluxstudio.planflow.v2`
- 앱 라벨: `PlanFlow V2`
- 딥링크 scheme: `planflow-v2://`
- OAuth redirect URL: `planflow-v2://auth-callback`
- 홈 위젯 action namespace: `com.fluxstudio.planflow.v2.widget.*`
- Firebase 설정: V2 앱 등록 기준 `google-services.json`
- V2 팀/그룹 기능 자체와 그 기능에 필요한 파일

## Overlay 비허용 영역

- 권한 온보딩 구성과 요청 순서
- 알림 권한, 정확한 알람, 전체 화면 알림 설정 흐름
- OAuth callback 기본 로직과 pending state 복구
- `app.dart` 라우팅, 업데이트 오버레이, startup/deep-link 처리 구조
- 일반 화면, provider, service 로직
- 테스트 기준과 회귀 테스트 의미

## 동기화 절차

1. main 파일을 먼저 읽기 전용 기준으로 비교한다.
2. 차이를 `main 기준 동일`, `V2 overlay`, `V2 기능`으로 분류한다.
3. overlay가 아닌 차이는 main 파일을 기준으로 V2에 맞춘다.
4. overlay는 문자열/상수 수준으로만 다시 적용한다.
5. 동기화 후 diff에는 V2 package, label, scheme, action namespace 같은 허용 차이만 남겨야 한다.

## 이번 재정렬 기준

- 권한 온보딩과 `AppPermissionService`는 main과 동일하게 맞춘다.
- V2 딥링크와 OAuth callback은 `planflow-v2://`만 유지한다.
- Android `MainActivity`는 main 로직을 따르고 package만 V2로 유지한다.
- 홈 위젯 provider는 main 로직을 따르고 package, scheme, action namespace만 V2로 유지한다.
