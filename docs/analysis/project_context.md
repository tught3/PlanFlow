# PlanFlow 프로젝트 컨텍스트 분석

> 생성: 2026-07-08 · GLM Worker W01
> 소스: AGENTS.md, CLAUDE.md, pubspec.yaml, lib/ 소스 구조, docs/, supabase/

---

## 1. 프로젝트 개요

| 항목 | 내용 |
|------|------|
| **프로젝트명** | PlanFlow |
| **버전** | 1.1.1+75 |
| **설명** | Flutter 기반 일정/캘린더 관리 앱 (Android-first) |
| **개발자** | 엄대용 (Flux Studio, 1인 개발) |
| **작업 경로** | `E:\FluxStudio\planflow` (현재 worktree: `planflow-task-20260705-081341`) |
| **배포 플랫폼** | Android 우선, iOS 미지원 (SMS/알림 접근 제한) |
| **배포 방식** | Supabase (PlanFlow 백엔드), Play Store (앱) |

---

## 2. 기술 스택

### 2.1 클라이언트 (Flutter)

| 카테고리 | 기술 | 비고 |
|----------|------|------|
| **프레임워크** | Flutter (Dart ≥3.3.0 <4.0.0) | Material Design |
| **상태관리** | flutter_riverpod ^2.4.9 | Provider 사용 금지 |
| **라우팅** | go_router ^13.2.0 | |
| **국제화** | flutter_localizations, intl ^0.20.2 | `l10n.yaml` 기반, 한국어 우선 |
| **알림** | flutter_local_notifications ^21.0.0 | 정확 알람, 풀스크린 인텐트 |
| **알람** | android_alarm_manager_plus ^5.0.0 | 백그라운드 알람 콜백 |
| **TTS** | flutter_tts ^3.8.5 | 브리핑 음성 안내 |
| **STT** | speech_to_text ^7.3.0 | `onDevice: true` 필수 (음성 데이터 서버 전송 금지) |
| **지도** | flutter_naver_map ^1.4.4, google_maps_flutter ^2.10.1 | 출발 시간 계산 |
| **위젯** | home_widget ^0.9.1 | 홈 화면 위젯 |
| **보안 스토리지** | flutter_secure_storage ^9.2.4 | |
| **로컬 저장** | shared_preferences ^2.3.3 | |
| **인증** | google_sign_in ^6.2.1, supabase_flutter ^2.0.0 | |
| **캘린더 연동** | googleapis ^12.0.0, googleapis_auth ^1.4.1, ical_parser ^1.2.0 | Naver CalDAV, Google Calendar |
| **딥링크** | app_links ^7.0.0 | `planflow://` 스킴 |
| **공유 수신** | receive_sharing_intent ^1.8.1 | ICS 파일 공유 받기 |
| **파일 선택** | file_picker ^11.0.2 | |
| **리뷰** | in_app_review ^2.0.9 | |
| **업데이트** | in_app_update ^4.2.3 | 인앱 업데이트 |
| **QR** | qr_flutter ^4.1.0 | 그룹 초대 |

### 2.2 백엔드 (Supabase)

| 항목 | 내용 |
|------|------|
| **DB** | PostgreSQL (Supabase) |
| **인증** | Supabase Auth (Google OAuth, Naver 커스텀 프로바이더, 이메일/비밀번호) |
| **보안** | RLS(Row Level Security) 항상 활성화 — 사용자별 행 분리 |
| **마이그레이션** | 직접 SQL 수정 금지 → Migration 파일로 관리 (`supabase/migrations/`) |
| **Edge Functions** | `supabase/functions/` — Naver geocode 프록시, GPT 호출 등 |
| **프로젝트 URL** | `https://xqvvfnvmytjlblcngipn.supabase.co` (기본값, env로 오버라이드 가능) |

### 2.3 Firebase

| 기능 | 패키지 |
|------|--------|
| 코어 | firebase_core ^3.6.0 |
| 크래시 리포트 | firebase_crashlytics ^4.1.3 |
| 원격 설정 | firebase_remote_config ^5.1.0 |

---

## 3. 아키텍처

### 3.1 디렉토리 구조

```
lib/
├── main.dart                  # 앱 진입점 — Firebase/NaverMap/Supabase 병렬 초기화
├── app.dart                   # PlanFlowApp — 라이프사이클, 딥링크, 위젯 클릭, 브리핑 처리
├── core/                      # 핵심 유틸리티
│   ├── env.dart               # 환경 변수 관리 (compile-time + 런타임 기본값)
│   ├── router.dart            # GoRouter 설정 (인증 가드, 라우트 테이블)
│   ├── theme.dart             # Material 테마
│   ├── constants.dart         # AppRoutes 등 상수
│   ├── supabase_auth_options.dart
│   ├── startup_route_gate.dart
│   ├── responsive.dart
│   ├── time_format_controller.dart
│   ├── diag_logger.dart       # 진단 로그
│   └── ...
├── data/
│   ├── models/                # 데이터 모델 (event, calendar, settings, feedback 등)
│   └── repositories/          # Supabase 데이터 액세스 레이어
├── features/
│   └── groups/                # V2 팀/그룹 기능 (feature module)
│       ├── models/
│       ├── providers/
│       ├── repositories/
│       ├── screens/
│       ├── services/
│       └── widgets/
├── providers/
│   ├── auth_provider.dart     # ChangeNotifier 기반 인증 상태
│   └── settings_provider.dart
├── services/                  # 비즈니스 로직 서비스 (60+ 서비스 클래스)
│   ├── alarm_service.dart
│   ├── auth_service.dart
│   ├── notification_service.dart
│   ├── gpt_service.dart       # AI 음성 명령 처리
│   ├── calendar_sync_service.dart
│   ├── briefing_scheduler_service.dart
│   ├── voice_command_pipeline.dart
│   ├── home_widget_service.dart
│   ├── naver_caldav_service.dart
│   └── ...
├── screens/                   # UI 화면
│   ├── auth/                  # 로그인, 비밀번호 재설정
│   ├── onboarding/
│   ├── splash/
│   ├── event/                 # 이벤트 상세, 편집
│   ├── calendar/
│   ├── briefing/              # 모닝/이브닝 브리핑
│   ├── voice/                 # 음성 입력, 대화, 확인
│   ├── home/
│   ├── location/
│   ├── settings/
│   ├── shell_screen.dart      # BottomNavigationBar 셸
│   └── placeholder_screen.dart
├── widgets/                   # 공용 위젯
└── l10n/                      # 국제화 리소스
```

### 3.2 주요 아키텍처 패턴

- **상태 관리**: Riverpod 중심. `auth_provider`와 `settings_provider`는 `ChangeNotifier`로 구현되어 GoRouter의 `refreshListenable`과 연동.
- **네비게이션**: GoRouter 단일 라우터(`appRouter`) + 인증 기반 리다이렉트 로직. 라우트 게이트(`startupRouteGate`)로 세션 복구/초기 해상 대기.
- **데이터 계층**: `data/models` + `data/repositories` 패턴. 각 리포지토리가 Supabase 테이블과 매핑.
- **서비스 계층**: `services/`에 60개 이상의 서비스 클래스 — 알람, 캘린더 동기화, 음성 명령, 위젯, 위치, TTS/STT 등.
- **V2 그룹 기능**: `features/groups/`에 feature-module 패턴으로 격리 — 개인 MVP 코드에 영향 없음.

### 3.3 핵심 기능 요약

| 기능 영역 | 설명 |
|-----------|------|
| **캘린더 동기화** | Naver CalDAV, Google Calendar API, ICS 가져오기/내보내기, 자동 일일 동기화 |
| **음성 명령** | STT(on-device) → GPT 파이프라인 → 일정 구조화 → 확인/편집 플로우 |
| **스마트 알람** | 정확 알람, 풀스크린 인텐트, 출발 알림, 준비 알림, 채널 마이그레이션 |
| **브리핑** | 모닝/이브닝 음성 브리핑, 포그라운드/백그라운드 트리거 |
| **홈 위젯** | Android 홈 화면 위젯, 딥링크 연동 |
| **그룹/팀 (V2)** | 그룹 생성, 초대(QR/링크), 그룹 이벤트, 대시보드 — feature module로 격리 |
| **위치/지도** | Naver Map, Google Maps, 출발 시간 계산, 위치 조회 |
| **인증** | Google, Naver(커스텀), 이메일/비밀번호, 세션 복구, 재인증 배너 |

---

## 4. 코딩 규칙 (CLAUDE.md / AGENTS.md 요약)

### 4.1 공통

- 변수/함수명: 영어 camelCase
- 주석: 한국어 허용
- 파일 인코딩: UTF-8 (한글 깨짐 주의)
- 커밋 메시지: `feat/fix/refactor/docs/chore: 한국어 설명`

### 4.2 Flutter (Dart)

- **상태관리**: Riverpod만 사용 (Provider 사용 금지)
- **네비게이션**: GoRouter
- **STT**: `onDevice: true` 필수 (음성 데이터 서버 전송 금지)
- **비동기**: async/await, Future (callback hell 금지)
- **위젯 분리**: 200줄 초과 시 별도 위젯으로 분리
- **모달/다이얼로그/바텀시트**: 액션 버튼 가로 배치, 취소 포함 모든 버튼에 테두리 필수, 기존 디자인 토큰 재사용

### 4.3 Supabase

- RLS(Row Level Security) 항상 활성화
- 직접 SQL 수정 금지 → Migration 파일로 관리
- 민감 데이터 컬럼: 암호화 적용
- **Supabase 스키마 변경 시 대용님 확인 필수**

### 4.4 환경 변수

- 런타임 `.env` 읽기 없음 → `--dart-define-from-file=env/local.json` 사용
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`는 공개 클라이언트 설정 (RLS로 보호)
- service_role, OpenAI API 키, OAuth 시크릿은 앱 설정에 넣지 않음
- 서버 전용 키는 `.env.local`의 `OPENAI_API_KEY`로 Supabase Edge Function secrets에 동기화

### 4.5 Windows / PowerShell 환경

- 한글 파일 읽기/쓰기 시 UTF-8 인코딩 명시 필수
- PowerShell에서 `&&` 사용 금지 — 세미콜론 + `$LASTEXITCODE` / `if ($?)` 사용
- `type`, `more`, `echo > file`, 기본 인코딩 Get-Content/Set-Content 사용 금지
- iOS/Xcode MCP 자동 실행 금지 (Windows 환경)

### 4.6 FluxOS 파이프라인 규칙

- 비단순 작업(개발/수정/분석/리뷰)은 FluxOS 파이프라인 우선 등록
- 표준 흐름: `Claude Code 계획 → GLM 구현 → Claude Code 리뷰 → CEO 보고`
- 같은 프로젝트 active 지시 1개 + FIFO 큐
- 이 프로젝트 폴더만 수정, 다른 프로젝트 접근 금지
- 완료 시 빌드 확인, 커밋, 푸시 수행

---

## 5. V2 팀 기능 확장 현황

`docs/planflow-v2/`에 24개 설계 문서 존재. 핵심 내용:

- **Group Tree** 기반 V2 통합 설계 (그룹 생성/초대/이벤트)
- ERD, RLS 정책, 스키마 SQL 최종 초안 완료 (`16-v2-schema-sql-final-draft.md`)
- Flutter module 구조 설계 완료 (`14-v2-flutter-module-plan.md`)
- `lib/features/groups/`에 이미 구현 진행 중 (screens, providers, models, repositories)
- 개인 MVP 안정성 유지, 팀 기능은 별도 모듈로 격리 — 1차 배포 코드/DB/RLS에 영향 없음

---

## 6. 현재 작업 환경 메모

- **개발 OS**: Windows + PowerShell
- **에뮬레이터**: `flux_phone` / `emulator-5554` (한 번에 1세션만)
- **실기기**: S23 Ultra 무선 디버깅 (`ADB_MDNS_AUTO_CONNECT=1`, mDNS 자동 연결)
- **로컬 AI**: Hermes `http://127.0.0.1:8645/v1` (PlanFlow는 자동 전환 제외)
- **Docker**: FluxOS 공용 lease 명령으로만 관리
- **FluxOS 루트**: `E:\FluxStudio\.fluxos\`

---

## 7. 주의사항 및 위험 요소

1. **Supabase 스키마 변경**: 반드시 대용님 확인 필요 — Migration 파일로만 관리
2. **음성 데이터**: STT on-device 필수 — 서버 전송 금지 (프라이버시)
3. **RLS**: 모든 테이블에 활성화 필수 — 사용자별 행 분리 없으면 보안 사고
4. **한글 인코딩**: Windows 환경에서 UTF-8 미명시 시 한글 깨짐 발생 위험
5. **iOS 미지원**: Android-first 정책 — iOS 전용 코드/도구 불필요
6. **V2 격리**: 팀 기능이 개인 MVP에 영향 주지 않도록 feature module 경계 유지
