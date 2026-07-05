# PlanFlow

음성 기반 AI 개인/그룹 스케줄러 — Android-first Flutter 앱.

## 개요

PlanFlow는 음성으로 일정을 말하면 AI가 구조화하여 자동으로 캘린더에 등록하는 스케줄링 앱입니다.
개인 일정뿐 아니라 그룹 일정 관리(역할·권한·초대·댓글)를 지원합니다.

| 항목 | 내용 |
|------|------|
| 제품명 | PlanFlow |
| 버전 | 1.1.1+77 |
| 플랫폼 | Android-first (iOS 미지원) |
| 프레임워크 | Flutter/Dart (>=3.3.0) |
| 백엔드 | Supabase (PostgreSQL + RLS + RPC + Realtime) |
| 상태관리 | Riverpod |
| 라우팅 | GoRouter |
| 배포 | Google Play Console (alpha 채널) |

## 주요 기능

### 코어 스케줄링
- **음성 파이프라인**: STT(on-device) → GPT 구조화 → 확인 화면 → 일정 생성
- **일정 CRUD**: 생성/조회/수정/삭제/상세
- **캘린더 뷰**: 월간 그리드, 일일 시트
- **스마트 알람**: 출발 알림, 준비 알림, 중요 알람 채널
- **브리핑**: 아침/저녁 자동 브리핑, 포그라운드 트리거

### 통합 서비스
- **네이버 캘린더**: CalDAV 동기화, ICS 가져오기/내보내기, 자동 동기화
- **지도/위치**: TMAP POI 검색, 네이버/구글 맵, 이동 시간 버퍼 계산
- **홈 위젯**: 다음 일정 표시, 클릭 내비게이션
- **인증**: 구글 로그인, OAuth, 세션 복구, 비밀번호 재설정
- **백업**: 일일 자동 백업 스케줄러
- **앱 업데이트**: 인앱 업데이트, 버전 추적
- **피드백**: 인앱 피드백, 베타 설문

### 그룹 V2
- 그룹 생성 및 관리: 역할(leader/member), 권한 위임(delegation)
- 초대 시스템: invite_code, 이메일 초대, 링크 초대
- 그룹 일정: 생성/조회/상세/목록, 반복 일정, 댓글
- 캘린더 오버레이: 개인 + 그룹 일정 UI 병합 표시

### 관리 도구
- **Tester Dashboard**: 관리자용 클로즈드 테스트 분석 (활동 추적, 통계)
- **ApiUsageGuard**: 슬라이딩 윈도우 회로 차단기 (TMAP POI 폭주 방지)
- **Crashlytics**: 에러 추적, 네트워크 에러 필터링
- **Remote Config**: 원격 설정

## 아키텍처

```
lib/
├── main.dart                 # 앱 진입점, 서비스 초기화 (Firebase, Supabase, Naver Map)
├── app.dart                  # PlanFlowApp 루트 위젯
├── core/                     # 공통 인프라
│   ├── env.dart              # 환경 변수 로드 (AppEnv)
│   ├── router.dart           # GoRouter 라우트 정의
│   ├── theme.dart            # Material 테마 토큰
│   ├── constants.dart        # 상수 정의
│   ├── diag_logger.dart      # 진단 로거
│   └── ...
├── data/                     # 데이터 계층
│   ├── models/               # 도메인 모델
│   └── repositories/         # Supabase 쿼리 래퍼
├── providers/                # Riverpod 프로바이더
├── screens/                  # UI 화면
│   ├── auth/                 # 로그인/회원가입
│   ├── calendar/             # 캘린더 뷰
│   ├── event/                # 일정 상세/편집
│   ├── voice/                # 음성 입력/확인
│   ├── briefing/             # 브리핑
│   ├── settings/             # 설정
│   └── ...
├── features/                 # 기능별 모듈
│   ├── admin/                # 관리자 (Tester Dashboard)
│   └── groups/               # 그룹 V2
├── services/                 # 비즈니스 로직 (57개 서비스)
│   ├── gpt_service.dart      # AI 일정 구조화
│   ├── stt_service.dart      # 음성 인식 (on-device)
│   ├── auth_service.dart     # 인증
│   ├── alarm_service.dart    # 알람 스케줄링
│   ├── api_usage_guard.dart  # API 예산 게이트
│   └── ...
├── widgets/                  # 재사용 위젯
└── l10n/                     # 다국어 리소스
```

## 로컬 설정

### 필수 요구사항
- Flutter SDK >=3.3.0
- Dart SDK >=3.3.0
- Android Studio 또는 VS Code (Flutter 플러그인)
- Supabase 프로젝트

### 환경 변수

`.env.example`을 참고하여 `.env` 파일을 생성합니다:

```bash
cp .env.example .env
```

필수 항목:
- `SUPABASE_URL` — Supabase 프로젝트 URL
- `SUPABASE_ANON_KEY` — Supabase anon key
- `OPENAI_API_KEY` — GPT 일정 구조화용 API 키
- `NAVER_MAP_CLIENT_ID` — 네이버 맵 클라이언트 ID

### 의존성 설치

```bash
flutter pub get
```

## 실행

### 에뮬레이터

```bash
flutter devices              # 연결된 장치 확인
flutter run -d emulator-5554 # flux_phone AVD에서 실행
```

### 릴리즈 빌드

```bash
flutter build apk --release
```

### 에뮬레이터/디바이스 정책
- 표준 에뮬레이터: `flux_phone` (AVD) → `emulator-5554` (동시 1세션)
- 실기기 무선 디버깅: S23 자동 연결 (`ADB_MDNS_AUTO_CONNECT=1`)

## 테스트

```bash
flutter test                                    # 전체 테스트
flutter test test/path/to_test.dart             # 개별 파일
flutter test --plain-name "테스트명"             # 이름으로 필터
flutter analyze                                 # 정적 분석
```

## 기술 스택 상세

| 카테고리 | 패키지 |
|-----------|--------|
| 상태관리 | `flutter_riverpod` |
| 라우팅 | `go_router` |
| 백엔드 | `supabase_flutter` |
| 음성 인식 | `speech_to_text` (on-device) |
| TTS | `flutter_tts` |
| 알림 | `flutter_local_notifications`, `android_alarm_manager_plus` |
| 지도 | `flutter_naver_map`, `google_maps_flutter` |
| 홈위젯 | `home_widget` |
| 인증 | `google_sign_in` |
| Firebase | `firebase_core`, `firebase_crashlytics`, `firebase_remote_config` |
| 캘린더 동기화 | `ical_parser`, CalDAV |
| 원격 설정 | `firebase_remote_config` |
| 앱 업데이트 | `in_app_update` |

## 코딩 컨벤션

- **상태관리**: Riverpod만 사용 (Provider 사용 금지)
- **네비게이션**: GoRouter
- **STT**: `onDevice: true` 필수 (음성 데이터 서버 전송 금지)
- **비동기**: `async/await` 사용 (callback hell 금지)
- **위젯 분리**: 200줄 초과 시 별도 위젯으로 분리
- **모달/다이얼로그 버튼**: 가로 배치, 모든 버튼에 테두리 필수, 기존 디자인 토큰 재사용
- **파일 인코딩**: UTF-8
- **커밋 메시지**: `feat/fix/refactor/docs/chore: 한국어 설명`

## Supabase

- **RLS**: Row Level Security 항상 활성화
- **마이그레이션**: `supabase/migrations/` 디렉터리에서 관리
- **스키마 변경**: 대용님 확인 필수, 직접 SQL 수정 금지

## 개발자

- **엄대용** (Flux Studio, 1인 개발)
- 연락처: 010-2422-3224

## 관련 문서

- [감사 보고서](AUDIT_REPORT.md) — 프로젝트 전체 감사 결과
- [통합 액션 플랜](docs/audit/action_plan.md) — 감사 기반 액션 플랜
- [프로젝트 백로그](.planning/PROJECT_BACKLOG.md) — 백로그 및 컨텍스트
- [에이전트 가이드라인](.agents/AGENTS_GUIDELINES_SUMMARY.md) — AI 작업 규칙 요약
