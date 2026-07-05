# AGENTS.md 핵심 가이드라인 요약 (내부 참조용 기준 문서)

> **출처:** 프로젝트 루트 `AGENTS.md` + `CLAUDE.md` (AI_WIKI Source of Truth 파생)
> **생성 일시:** 2026-06-08
> **목적:** 이후 모든 Worker 서브태스크의 코딩·아키텍처·금지사항 기준 문서
> **원칙:** 원본 문서 수정 없음 — 본 파일은 읽기 전용 참조용 요약

---

## 1. 개발자 & 프로젝트 프로필

| 항목 | 내용 |
|------|------|
| 이름 | 엄대용 (Flux Studio, 1인 개발) |
| OS | Windows / PowerShell |
| 주력 언어 | Flutter(Dart), React/TypeScript |
| 플랫폼 | Android-first, **iOS 미지원** (SMS/알림 접근 제한) |
| DB | Supabase (PostgreSQL) |
| 배포 | Vercel (FinFlow), Supabase (PlanFlow) |
| 기본 언어 | 한국어 (대화·주석·커밋 메시지 모두) |

---

## 2. 코딩 컨벤션

### 2.1 공통 규칙
- **변수/함수명**: 영어, `camelCase`
- **주석**: 한국어 허용
- **파일 인코딩**: UTF-8 (한글 깨짐 절대 방지)
- **커밋 메시지**: `feat/fix/refactor/docs/chore: 한국어 설명`

### 2.2 Flutter (Dart)
| 항목 | 규칙 |
|------|------|
| 상태관리 | **Riverpod** (Provider 사용 금지) |
| 네비게이션 | **GoRouter** |
| STT | `onDevice: true` 필수 (음성 데이터 서버 전송 금지) |
| 비동기 | `async/await`, `Future` (callback hell 금지) |
| 위젯 분리 | 200줄 초과 시 별도 위젯으로 분리 |
| 모달/다이얼로그 버튼 | 액션 버튼 **가로 배치** (세로 금지). 취소 포함 **모든 버튼에 테두리(경계선) 필수**. 색상·간격·폰트·모서리는 기존 디자인 토큰 재사용 |

### 2.3 React / TypeScript
| 항목 | 규칙 |
|------|------|
| 상태관리 | **Zustand** (Redux 금지) |
| 스타일 | **Tailwind CSS** |
| API 호출 | **React Query** (useEffect 직접 fetch 금지) |
| 타입 | `any` 사용 금지, 명시적 타입 필수 |
| 컴포넌트 | 함수형만 (클래스 컴포넌트 금지) |

### 2.4 PowerShell
- 인코딩: UTF-8 명시 (`-Encoding UTF8` 또는 `[System.IO.File]` API)
- 경로: 하드코딩 금지, `_config.ps1` 변수 참조
- 오류 처리: `try/catch` 필수
- 로그: 색상 구분 (Red=오류, Green=성공, Cyan=정보)

---

## 3. 아키텍처 원칙

### 3.1 작업 프로세스 (예외 없이 적용)
```
STEP 0: 컨텍스트 압축 → STEP 1: 계획 수립 → STEP 2: 구현 → STEP 3: 검증(빌드+테스트+push)
```
- **계획 없이 코드 작성 금지**
- **계획 외 변경 발생 시 즉시 보고 후 승인**
- **검증 없이 완료 보고 금지** (불가능 항목은 이유 명시 후 skip)

### 3.2 모델 라우팅 (비단순 작업 필수 7단계)
```
1. FluxOS 파이프라인 등록
2. 계획 = Claude (상위 모델) — 범위·영향파일·리스크·검증기준
3. 구현 = GLM 주력, 난이도별 병렬 서브에이전트 위임 (파일 비중첩 시 동시 실행)
4. 별도 리뷰어(Claude) 전체 diff 리뷰 (구현 워커와 다른 세션)
5. 지적사항 수정 → 6. 재리뷰 → 7. 검증(analyze/test/build)·보고
```
- 메인(오케스트레이터) 세션은 **직접 구현하지 않음** — 계획·분배·검토·보고만
- 위 흐름 무시 시 **규약 위반**

### 3.3 작업 방식 핵심
- 기존 코드·문서·구조를 **먼저 확인** 후 작업
- 기존 Decision·Constitution·프로젝트 규칙 **우선** (임의 무시 금지, 변경 시 새 Decision 제안)
- 새 UI/기능 추가 전 기존 디자인 스타일·토큰·공용 컴포넌트 **반드시 확인**
- 기본 브라우저/프레임워크 스타일을 그대로 덧붙이지 않음
- 장시간 명령: 30초 이상 응답 없으면 즉시 상태 확인 (무한 대기 금지)
- 범위는 사용자 요청에 맞게 **좁게 유지**

### 3.4 FluxOS 잠금 & 큐 정책
- 같은 프로젝트에 active 작업이 있으면 FIFO 큐 대기
- 큐는 지시사항 단위 (파일 단위가 아님) — 앞 지시 전체 완료 후 다음 승격
- 서로 다른 프로젝트는 공용 자원 충돌 없으면 병렬 진행

### 3.5 에뮬레이터 / 디바이스 정책
- Flutter 실행 시 `flutter devices`로 먼저 확인
- 항상 동일 AVD `flux_phone` → `emulator-5554`에서 `flutter run -d emulator-5554`
- `flux_phone`/`emulator-5554`는 **동시 1세션만** (충돌 시 FIFO 큐)
- 실기기 무선 디버깅: S23(S23 Ultra) 자동 연결만 기본 (`ADB_MDNS_AUTO_CONNECT=1`)
- `adb-single-device.ps1`가 S23 이외 기기 자동 disconnect

---

## 4. 금지사항 (Prohibitions)

### 4.1 코딩 금지
- ❌ Flutter에서 Provider 사용 (Riverpod만)
- ❌ Flutter에서 callback hell (async/await 필수)
- ❌ React에서 Redux 사용 (Zustand만)
- ❌ React에서 useEffect 직접 fetch (React Query만)
- ❌ React에서 `any` 타입 사용
- ❌ React에서 클래스 컴포넌트
- ❌ 모달 버튼 세로 배치 (가로 배치 필수)
- ❌ 버튼 테두리 생략 (모든 버튼 경계선 필수)
- ❌ 기본 프레임워크/브라우저 스타일 그대로 사용 (디자인 토큰 재사용)
- ❌ 위젯 200줄 초과 분리 안 함

### 4.2 작업 프로세스 금지
- ❌ 계획 없이 코드 작성
- ❌ 계획 외 변경을 승인 없이 진행
- ❌ 검증 없이 완료 보고
- ❌ 관련 없는 파일 수정/삭제
- ❌ 사용자가 만든 변경 되돌리기
- ❌ 컨텍스트 압축 없이 작업 진입

### 4.3 PowerShell / 인코딩 금지
- ❌ PowerShell에서 `&&` 사용 (세미콜론 + `$LASTEXITCODE` 사용)
- ❌ `cmd /c`, `bash -lc`로 우회한 파일 작업
- ❌ `type`, `more`, `echo > file`로 한글 파일 읽기/쓰기
- ❌ 기본 인코딩 Get-Content/Set-Content로 한글 처리
- ❌ 글자가 깨진 상태로 저장 (즉시 중단 후 UTF-8 재확인)

### 4.4 인프라 / 환경 금지
- ❌ Docker 세션별 직접 start/stop (FluxOS lease 명령만 사용)
- ❌ 실행 중인 컨테이너가 있으면 Docker 함부로 종료
- ❌ Windows에서 iOS/Xcode 전용 MCP 자동 실행
- ❌ `node_modules`, `.git`, `build`, `dist`, `.dart_tool` 등 검색 포함
- ❌ STT 음성 데이터 서버 전송

---

## 5. Supabase 정책

| 항목 | 정책 |
|------|------|
| RLS | **Row Level Security 항상 활성화** |
| SQL 수정 | 직접 SQL 수정 **금지** → Migration 파일로 관리 |
| 스키마 변경 | **대용님(엄대용) 확인 필수** |
| 민감 데이터 | 암호화 적용 |

---

## 6. FluxOS 파이프라인 정책

- FluxStudio 계열 비단순 지시는 **반드시 FluxOS 파이프라인** 우선
- 표준 흐름: `Claude Code 계획 → GLM 구현 → Claude Code 리뷰 → CEO 보고`
- 진입 명령: `python E:\FluxStudio\.fluxos\run.py pipeline "<지시>" --project <Project> --source <session>`
- 진행 확인: `python E:\FluxStudio\.fluxos\run.py pipeline-audit [TASK_ID]`
- Claude Code 실패 시: Codex-only fallback 사용 + 최종 보고에 사유 명시
- 긴급 단순 수정 생략 시: 생략 사유, 변경 범위, 검증 결과를 보고에 필수 기재
- 세션 시작: `run.py session start` 또는 `session attach`로 FluxOS 메타 부착

---

## 7. AI 호출 정책

- 로컬 개발/디버그: **Hermes 로컬 경로 우선** (`http://127.0.0.1:8645/v1`, key: `hermes-local`)
- 배포/릴리즈: **OpenAI 배포 경로 우선** (127.0.0.1 접근 불가 환경)
- FLUXSTUDIO 계열 공용 AI 호출: Hermes 기본 경로 사용
- PlanFlow: 자동 전환 범위에서 **제외** (별도 관리)

---

## 8. Worker 서브태스크 체크리스트 (빠른 참조)

구현 작업 시 아래 항목을 매번 확인:

- [ ] 기존 코드/구조 확인했는가?
- [ ] 기존 디자인 토큰/공용 컴포넌트 재사용하는가?
- [ ] Flutter: Riverpod + GoRouter + async/await 준수?
- [ ] 위젯 200줄 초과 시 분리?
- [ ] 모달 버튼 가로 배치 + 테두리?
- [ ] 범위를 좁게 유지했는가? (관련 없는 파일 건드리지 않았는가?)
- [ ] 파일 인코딩 UTF-8?
- [ ] 빌드/테스트 검증 후 완료 보고?
- [ ] Supabase 스키마 변경 시 대용님 확인?

---

*본 문서는 AGENTS.md 및 CLAUDE.md의 요약 참조용이며, 원본 규칙이 우선합니다.*
*원본 변경이 필요한 경우 AI_WIKI Source of Truth를 수정 후 doc-generate로 파생 파일을 갱신합니다.*
