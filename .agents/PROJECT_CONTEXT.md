# PlanFlow 프로젝트 컨텍스트 (Worker 기준)
> 이 문서는 AGENTS.md, CLAUDE.md, pubspec.yaml, analysis_options.yaml, .planning/ 에서
> 추출한 핵심 규칙을 Worker 서브태스크가 즉시 참조할 수 있도록 정리한 것이다.
> 원본 변경 시 이 파일도 갱신해야 한다.

---

## 1. 프로젝트 정체

| 항목 | 값 |
|------|-----|
| 이름 | PlanFlow (`planflow`) |
| 버전 | 1.1.1+75 |
| 프레임워크 | Flutter (Dart ≥3.3.0 <4.0.0) |
| 플랫폼 | Android-first (iOS 미지원) |
| DB | Supabase (PostgreSQL, RLS 필수) |
| 배포 | Supabase (PlanFlow) |
| 담당자 | 엄대용 / Flux Studio (1인 개발) |
| 작업 경로 | `E:\FluxStudio\planflow` (현재 worktree) |

---

## 2. 코딩 표준

### 공통
- 변수/함수명: 영어, **camelCase**
- 주석: 한국어 허용
- 파일 인코딩: **UTF-8** (한글 깨짐 주의)
- 커밋 메시지: `feat/fix/refactor/docs/chore: 한국어 설명`

### Flutter (Dart) — 핵심 규칙
| 규칙 | 내용 |
|------|------|
| 상태관리 | **Riverpod** (Provider 사용 금지) |
| 네비게이션 | **GoRouter** (`lib/core/router.dart`) |
| STT | `onDevice: true` 필수 (음성 데이터 서버 전송 금지) |
| 비동기 | async/await, Future (callback hell 금지) |
| 위젯 분리 | 200줄 초과 시 별도 위젯으로 분리 |
| 모달/다이얼로그/바텀시트 | 액션 버튼 **가로 배치** 필수 (세로 금지). 모든 버튼에 **테두리(경계선) 필수**. 기존 디자인 토큰 재사용 |
| Lint | `flutter_lints ^5.0.0` 활성 (`analysis_options.yaml`) |

### Supabase
- RLS(Row Level Security) 항상 활성화
- 직접 SQL 수정 금지 → Migration 파일로 관리
- 민감 데이터 컬럼: 암호화 적용
- **스키마 변경 시 대용님 확인 필수**

---

## 3. 아키텍처 구조

```
lib/
├── app.dart                  # 앱 루트 (Crashlytics, 딥링크 방어)
├── main.dart                 # 엔트리포인트
├── core/                     # 코어 인프라 (constants, theme, router, env, diag_logger 등)
│   ├── router.dart           # GoRouter 라우트 정의
│   ├── theme.dart            # 앱 테마/디자인 토큰
│   ├── constants.dart        # 전역 상수
│   ├── diag_logger.dart      # 진단 로그
│   ├── runtime_error_filter.dart
│   └── supabase_client.dart
├── data/                     # 데이터 계층 (models, repositories)
├── features/                 # 기능별 모듈
│   ├── groups/
│   ├── plan/
│   └── task/
├── providers/                # Riverpod 프로바이더
├── screens/                  # UI 화면
├── services/                 # 비즈니스 로직 서비스 (60개 이상)
├── shared/                   # 공용 컴포넌트/유틸
└── widgets/                  # 재사용 위젯
```

### 주요 서비스 (services/)
- `alarm_service.dart` — 알람/알림 예약
- `gpt_service.dart` — GPT 기반 음성 일정 파싱
- `stt_service.dart` — On-device STT
- `tts_service.dart` — TTS
- `notification_service.dart` — 로컬 알림
- `calendar_sync_service.dart` / `device_calendar_service.dart` — 캘린더 동기화
- `briefing_scheduler_service.dart` — 브리핑 알람 스케줄링
- `smart_preparation_alarm_service.dart` — 스마트 준비/출발 알림
- `backup_service.dart` / `daily_backup_scheduler_service.dart` — 백업
- `auth_service.dart` — Supabase 인증
- `home_widget_service.dart` — 홈 위젯

### 핵심 의존성 (pubspec.yaml)
- `flutter_riverpod ^2.4.9` — 상태관리
- `go_router ^13.2.0` — 네비게이션
- `supabase_flutter ^2.0.0` — DB/Auth
- `speech_to_text ^7.3.0` — STT (onDevice 필수)
- `flutter_tts ^3.8.5` — TTS
- `flutter_local_notifications ^21.0.0` — 로컬 알림
- `android_alarm_manager_plus ^5.0.0` — 백그라운드 알람
- `firebase_crashlytics ^4.1.3` — 크래시 리포팅
- `google_maps_flutter ^2.10.1` / `flutter_naver_map ^1.4.4` — 지도
- `flutter_secure_storage ^9.2.4` — 보안 저장
- `home_widget ^0.9.1` — 홈 위젯
- `ical_parser ^1.2.0` — ICS 파싱

---

## 4. 작업 프로세스 (예외 없이 적용)

### STEP 0 — 컨텍스트 압축
- 이전 대화/작업 내용 핵심 압축 후 시작
- 현재 상태, 완료/남은 것 명확히 파악

### STEP 1 — 계획 수립
- 작업 범위, 영향 파일, 순서, 리스크 먼저 제시
- **계획 없이 코드 먼저 작성 금지**

### STEP 2 — 구현
- 계획에 맞게 단계별 진행
- 계획 외 변경 발생 시 즉시 보고 후 승인

### STEP 3 — 검증 (완료 후 필수)
- `flutter analyze` 통과
- `flutter test` 통과 (가능한 범위)
- `flutter build apk --release` 확인
- Git push
- 불가능한 항목은 이유 명시 후 skip

### 검증 스크립트 패턴 (기존 작업 기준)
```powershell
# Test
scripts\flutter-local.ps1 test <test_file> --no-pub -r compact
# Analyze
scripts\flutter-local.ps1 analyze <lib_file> <test_file> --no-pub
# Build
scripts\flutter-local.ps1 build apk --release --no-pub
```

---

## 5. 금지사항

| 항목 | 금지 내용 |
|------|-----------|
| 상태관리 | Provider 사용 (Riverpod만 허용) |
| 네비게이션 | Navigator.push 직접 사용 (GoRouter만) |
| STT | 서버 전송 (onDevice: true 필수) |
| 비동기 | callback hell (async/await 사용) |
| 위젯 | 200줄 초과 단일 위젯 |
| 모달 | 세로 버튼 배치, 테두리 없는 버튼 |
| Supabase | 직접 SQL 수정 (Migration만), RLS 미사용 |
| PowerShell | `&&` 사용 (세미콜론/분리 실행), `type`/`more`/`echo >`로 한글 읽기/쓰기 |
| 범위 | 관련 없는 파일 수정/삭제, 사용자 변경 되돌리기 |
| 검색 | `node_modules`, `.git`, `build`, `.dart_tool`, `.gradle` 폴더 포함 |

---

## 6. UI/디자인 규칙

- **새 UI 추가 전 반드시 기존 디자인 스타일, CSS, 테마, 토큰, 공용 컴포넌트 확인**
- 기존 앱 스타일과 시각 언어에 맞춰 통일
- 기본 브라우저/프레임워크 스타일 덧붙이기 금지
- 버튼, 카드, 입력창, 모달, 색상, 간격, 폰트, 아이콘, 상태 표시 → 기존 구현 방식 우선 재사용
- 테마/토큰: `lib/core/theme.dart` 참조

---

## 7. FluxOS 파이프라인 규칙

- 비단순 작업은 FluxOS 파이프라인 등록 후 진입
- 표준 흐름: `Claude Code 계획 → GLM 구현 → Claude Code 리뷰 → CEO 보고`
- 메인(오케스트레이터) 세션은 직접 구현하지 않고 계획·분배·검토·보고만 담당
- 구현은 GLM 주력, 난도 높은 구현/리뷰는 Claude 우선
- 파일 비중첩 시 병렬 실행
- AGENTS.md/CLAUDE.md 직접 재생성 금지 (AI_WIKI 원본만 수정 후 doc-generate 큐 적재)
- Supabase 스키마 변경 시 대용님 확인 필수

---

## 8. 모델 라우팅 기준

| 작업 유형 | 모델 | 교체 기준 |
|-----------|------|-----------|
| 계획/아키텍처/전략 | 최상급(Claude) | 아키텍처 결정 포함 시 반드시 전환 |
| 역할 배분/리뷰/감독 | 중간급 | 2회 이상 같은 실수 → 상위 모델 |
| 단순 코드/반복 구현 | 경량(GLM) | 단순 작업에 고급 모델 사용 중 → 경량으로 |

---

## 9. 환경 특이사항

- **에뮬레이터**: `flux_phone` / `emulator-5554` (한 번에 1세션만, FIFO 큐)
- **실기기**: S23 Ultra 자동 연결 (`ADB_MDNS_AUTO_CONNECT=1`, mDNS 자동 감지)
- **ADB 래퍼**: `E:\AI_WIKI\scripts\adb-single-device.ps1` 자동 호출 (S23만 유지)
- **로컬 AI**: Hermes `http://127.0.0.1:8645/v1` (key: `hermes-local`)
- **Docker**: FluxOS 공용 lease 명령으로만 관리 (직접 start/stop 금지)
- **Windows 개발**: iOS/Xcode MCP 자동 실행 금지

---

## 10. 최근 작업 맥락 (ACTIVE_SUMMARY 요약)

- **2026-06-30**: 설정 화면 UI 정리 (시간 표시 형식, 진단 로그 위치, 음성 진입 버튼, 공통 교정 문구)
- **2026-06-30**: 음성 확인 화면 자동 확장 억제 (memo-only는 접힌 상태)
- **2026-06-30**: 음성 확인 저장 후 알림 예약 실패 노출
- **2026-06-29**: 음성 입력 뒤로가기 후 STT 복구, 브리핑 알람 진단 로그 보강
- **2026-06-29**: 오전/오후 모호 시간 보정, ConfirmScreen 저장 후 이동
- **2026-06-29**: Crashlytics 딥링크/네트워크 방어, 출발 알림 fallback
- **2026-06-29**: 포그라운드 브리핑 모달 SharedPreferences 브리지 보강

> 현재 작업: Worker 컨텍스트 로드 (W01) — 이 문서 생성

---

_생성일: 2026-06-30 / 소스: AGENTS.md, CLAUDE.md, pubspec.yaml, analysis_options.yaml, .planning/_
