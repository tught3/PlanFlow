# AGENTS.md 핵심 가이드라인 요약

> **출처**: `AGENTS.md`, `CLAUDE.md`(Coding Standards 섹션), `analysis_options.yaml`  
> **프로젝트**: PlanFlow (Flutter/Dart, Supabase)  
> **생성 목적**: 후속 작업(구현·리뷰·테스트)의 기준점  
> **생성일**: GLM Worker W01 작업 산출물

---

## 1. 코딩 컨벤션

### 공통
| 항목 | 규칙 |
|------|------|
| 변수/함수명 | 영어, `camelCase` |
| 주석 | 한국어 허용 |
| 파일 인코딩 | UTF-8 (한글 깨짐 방지 필수) |
| 커밋 메시지 | `feat/fix/refactor/docs/chore: 한국어 설명` |

### Flutter (Dart)
| 항목 | 규칙 |
|------|------|
| 상태관리 | **Riverpod** (Provider 사용 ❌ 금지) |
| 네비게이션 | **GoRouter** |
| STT | `onDevice: true` 필수 (음성 데이터 서버 전송 ❌) |
| 비동기 | `async/await`, `Future` (callback hell ❌) |
| 위젯 분리 | **200줄 초과 시 별도 위젯으로 분리** |
| 모달/다이얼로그 | 액션 버튼 **가로 배치**(세로 ❌); 모든 버튼(취소 포함)에 **테두리(경계선) 필수**; 기존 디자인 토큰·스타일 재사용 |
| Lint | `flutter_lints/flutter.yaml` 기반 (`public_member_api_docs: false`) |

### React / TypeScript (참고 — PlanFlow 본체는 Flutter)
- 상태: Zustand, 스타일: Tailwind CSS, API: React Query, 함수형 컴포넌트만

### PowerShell
- UTF-8 인코딩 명시 (`Get-Content -Encoding UTF8`, `Set-Content -Encoding UTF8` 등)
- 경로 하드코딩 ❌, `_config.ps1` 변수 참조
- `&&` 사용 ❌ (세미콜론 + `$LASTEXITCODE` / `if ($?)` 사용)
- try/catch 필수

---

## 2. 아키텍처 원칙

1. **기존 우선**: 새 방법이 좋아 보여도 기존 Decision·Constitution·프로젝트 규칙을 먼저 확인하고 우선. 변경 필요 시 새 Decision(05_Decisions) 제안.
2. **Android-first**: iOS 미지원 (SMS/알림 접근 제한).
3. **Supabase (PostgreSQL)**: RLS 항상 활성화, 직접 SQL 수정 ❌ → Migration 파일 관리, 민감 데이터 컬럼 암호화.
4. **AI 호출**: 로컬 개발은 Hermes(`http://127.0.0.1:8645/v1`, key: `hermes-local`) 우선; 배포/릴리즈는 OpenAI 배포 경로.
5. **UI 일관성**: 새 UI 추가 전 기존 디자인 스타일·CSS·테마·토큰·공용 컴포넌트·레이아웃 패턴 확인 후 통일.
6. **범위 최소**: 관련 없는 파일 수정/삭제 ❌; 사용자가 만든 변경 되돌리기 ❌.

### 모델 라우팅 (비단순 작업 필수 워크플로우 — 7단계)
```
1. FluxOS 파이프라인 등록 (run.py pipeline)
2. 계획 = Claude (상위 모델)
3. 구현 = GLM 주력, 난이도별 병렬 서브에이전트 위임
4. 별도 리뷰어 = Claude (전체 diff 리뷰)
5. 수정 → 6. 재리뷰 → 7. 검증(analyze/test/build)·보고
```
- 메인(오케스트레이터) 세션은 직접 구현하지 않고 **계획·분배·검토·보고만 담당**.
- 파일/모듈 비중첩 시 워커 동시 실행. 완료된 서브에이전트는 즉시 닫기.

---

## 3. 디렉토리 구조 규칙

### lib/ 구조
```
lib/
├── app.dart                  # 앱 엔트리 ( MaterialApp / 라우팅 설정 )
├── main.dart                 # 진입점
├── core/                     # 인프라 (router, theme, env, constants, supabase_client, ...)
├── data/                     # 데이터 레이어 (모델, 리포지토리)
├── features/                 # 기능별 모듈
│   ├── groups/
│   ├── plan/
│   └── task/
├── providers/                # Riverpod Provider 정의
├── screens/                  # 화면(페이지) 위젯
├── services/                 # 외부 서비스 연동
├── shared/                   # 공용 재사용 자원
│   ├── constants/
│   ├── extensions/
│   ├── utils/
│   └── widgets/
├── widgets/                  # 전역 공용 위젯
├── firebase_options.dart
└── l10n/                     # 국제화 리소스
```

### 핵심 원칙
- **Feature-first + Layered 하이브리드**: `features/` 하위에 도메인별로 그룹핑, `core/`/`shared/`/`providers/`/`data/` 등 레이어 분리.
- **core/**: 인프라·설정 (router, theme, env, supabase, analytics, constants, logger, responsive 등).
- **shared/**: 범용 재사용 (상수, 확장, 유틸, 공용 위젯).
- **providers/**: Riverpod 프로바이더 중앙 관리.

### 테스트 디렉토리
```
test/
├── core/          # core 레이어 테스트
├── data/          # 데이터 레이어 테스트
├── features/      # 기능별 테스트
├── providers/     # 프로바이더 테스트
├── screens/       # 화면 테스트
├── services/      # 서비스 테스트
├── supabase/      # Supabase 통합 테스트
├── widgets/       # 위젯 테스트
└── *.dart         # 통합/라우팅 테스트 (deep_link_guard, app_home_widget_route)
```
- `test/` 구조는 `lib/` 구조를 미러링.

---

## 4. 상태관리 전략

| 레이어 | 기술 | 비고 |
|--------|------|------|
| 앱 상태 | **Riverpod** | Provider 패키지 ❌ 금지 |
| 프로바이더 위치 | `lib/providers/` | 중앙 관리 |
| 화면 상태 | Riverpod (StateNotifier / Notifier) | 비동기는 async/await |

**금지 사항:**
- `setState` 남용 ❌ (Riverpod로 상태 관리)
- Provider 패키지(`package:provider`) 사용 ❌
- callback hell ❌

---

## 5. 명명 규칙

| 대상 | 규칙 | 예시 |
|------|------|------|
| 변수 / 함수 | 영어 `camelCase` | `getUserPlan`, `taskCount` |
| 클래스 | 영어 `PascalCase` | `PlanGroup`, `TaskCard` |
| 파일명 | `snake_case.dart` | `task_card.dart`, `plan_repository.dart` |
| 주석 | 한국어 허용 | `// 사용자의 활성 그룹을 가져온다` |
| 커밋 | `type: 한국어 설명` | `feat: 그룹 홈 화면 추가` |
| 폴더명 | `snake_case` 또는 단어 | `features/plan/`, `shared/widgets/` |

---

## 6. 테스트 정책

### 구조
- `test/` 디렉토리는 `lib/` 디렉토리 구조를 미러링.
- 레이어별, 기능별 테스트 파일 배치.

### 검증 기본 원칙 (STEP 3 — 작업 완료 후 필수)
1. **빌드 확인** (flutter build / flutter analyze)
2. **실행 확인** (flutter run on `emulator-5554` / `flux_phone`)
3. **테스트** (가능한 범위 내 최대한 실행)
4. **Git push**
5. 불가능한 항목은 **이유 명시 후 skip**

### 에뮬레이터 규칙
- AVD: `flux_phone`, 대상: `emulator-5554`
- 한 번에 **하나의 세션만** 사용 (중복 시 FIFO 큐).
- 실기기: S23 Ultra mDNS 자동 연결 (`ADB_MDNS_AUTO_CONNECT=1`).

### 분석 (analyze)
```bash
flutter analyze   # flutter_lints 기반, public_member_api_docs 비활성
```

---

## 7. 작업 프로세스 원칙

### STEP 0 — 컨텍스트 압축 (작업 시작 전 필수)
이전 대화/작업 내용 핵심 압축 → 현재 상태, 완료된 것, 남은 것 명확화.

### STEP 1 — 계획 수립
작업 범위, 영향 파일, 순서, 예상 리스크 제시 → 승인 후 구현.

### STEP 2 — 구현
계획에 맞춰 단계별 진행. 계획 외 변경 발생 시 즉시 보고 후 승인.

### STEP 3 — 검증 (위 6. 테스트 정책 참조)

---

## 8. FluxOS 파이프라인 & 협업 규칙

### FluxOS Pipeline Gate
- 비단순 작업 시 먼저 `run.py pipeline` 등록 또는 `pipeline-audit` 확인.
- 표준 흐름: **Claude Code 계획 → GLM 구현 → Claude Code 리뷰 → CEO 보고**.
- 긴급 단순 수정으로 생략 시: 생략 사유, 변경 범위, 검증 결과를 보고에 필수 기재.

### 잠금 & 큐
- 파일 수정 전 FluxOS 잠금 상태 확인.
- 같은 프로젝트에 active 작업 있으면 FIFO 큐에 적재 (파열 단위가 아닌 지시사항 단위).
- 다른 프로젝트는 공용 자원 충돌 없으면 병렬 진행.

### Docker
- 직접 start/stop ❌; FluxOS 공용 lease 명령으로만 관리.
- active lease 남아 있으면 다른 세션은 대기.

### 문서 생성
- `AGENTS.md`, `CLAUDE.md`는 AI_WIKI 파생 파일 → 직접 수정 ❌.
- 원본은 AI_WIKI에서 수정 후 doc-generate 작업을 큐에 적재.

---

## 9. 개발자 프로필 요약

| 항목 | 값 |
|------|-----|
| 이름 | 엄대용 (Flux Studio, 1인 개발) |
| 배경 | 제약영업 15년 → 앱 개발 |
| 주력 | Claude Code(계획/리뷰), GLM(구현) |
| OS | Windows / PowerShell |
| 언어 | Flutter(Dart), React/TS |
| DB | Supabase (PostgreSQL) |
| Deploy | Supabase (PlanFlow), Vercel (FinFlow) |
| 작업 스타일 | 한국어, vibe coding, 단계별 정확한 수정, 자동화 지향 |

---

## 10. 후속 작업 체크리스트 (Quick Reference)

구현/리뷰 작업 시 반드시 확인:

- [ ] Riverpod 사용 (Provider ❌)
- [ ] GoRouter 사용
- [ ] 위젯 200줄 초과 시 분리
- [ ] 모달 버튼 가로 배치 + 테두리 필수
- [ ] UTF-8 인코딩 (한글 깨짐 방지)
- [ ] 파일명 `snake_case`, 변수/함수 `camelCase`
- [ ] 기존 디자인 토큰·스타일 재사용
- [ ] `flutter analyze` 통과
- [ ] 테스트 코드는 `lib/` 구조 미러링
- [ ] Supabase RLS 활성화, Migration 파일로 스키마 관리
- [ ] 범위 최소 — 관련 없는 파일 수정 ❌
