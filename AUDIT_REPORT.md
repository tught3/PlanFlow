# PlanFlow 프로젝트 감사 보고서

감사일: 2026-07-05
감사자: GLM Worker W01
기준 커밋: e9c2f2b (detached HEAD on fix/tmap-budget-gate)
main 최신: 7d36719 (Tester Dashboard for closed-test analytics)
버전: 1.1.1+77 (build)

---

## 1. 프로젝트 개요 및 기술 스택

제품명: PlanFlow (음성 기반 AI 개인/그룹 스케줄러)

기술 스택:
- 프레임워크: Flutter/Dart (>=3.3.0)
- 백엔드: Supabase (PostgreSQL + RLS + RPC + Realtime)
- 상태관리: Riverpod
- 라우팅: GoRouter
- 배포: Play Console alpha 채널
- 플랫폼: Android-first (iOS 미지원)
- STT: speech_to_text (on-device)
- TTS: flutter_tts
- 지도: flutter_naver_map, google_maps_flutter
- 알림: flutter_local_notifications, android_alarm_manager_plus
- 인증: google_sign_in, supabase_flutter auth
- Firebase: Crashlytics, Remote Config
- 홈위젯: home_widget

코드 규모:
- 서비스: 57개 파일 (lib/services/)
- 화면: 30+ 화면
- 그룹 기능: 10 모델, 7 리포지토리, 12 프로바이더, 4 위젯, 3 서비스, 10 화면
- 테스트: 85+ 테스트 파일
- Supabase 마이그레이션: 19개 파일

---

## 2. 현재 진행 상태 (완료된 주요 기능)

### 코어 스케줄링
- 음성 파이프라인: STT - GPT 구조화 - 확인 - 일정 생성 (15+ 음성 서비스)
- 일정 CRUD: 생성/조회/수정/삭제/상세
- 캘린더 뷰: 월간 그리드, day sheet
- 스마트 알람: 출발 알림, 준비 알림, 중요 알람 채널
- 브리핑: 아침/저녁 브리핑, 포그라운드 트리거

### 통합 및 서비스
- 네이버 캘린더: CalDAV 동기화, ICS 가져오기/내보내기, 자동 동기화
- 지도/위치: TMAP POI 검색, 네이버/구글 맵, 이동 시간 버퍼
- 홈 위젯: 일정 표시, 클릭 내비게이션
- 인증: 구글 로그인, OAuth, 세션 복구, 비밀번호 재설정
- 백업: 일일 자동 백업 스케줄러
- 앱 업데이트: 인앱 업데이트, 버전 추적
- 피드백: 인앱 피드백, 베타 설문

### 그룹 V2 (최근 병합)
- 그룹 생성 및 관리: 역할(leader/member), 권한 위임(delegation)
- 초대 시스템: invite_code, 이메일 초대, 링크 초대
- 그룹 일정: 생성/조회/상세/목록, 반복 일정, 댓글
- 캘린더 오버레이: 개인 + 그룹 일정 UI 병합 표시
- 그룹 백업: 아카이브 시 백업 생성

### 운영/인프라
- ApiUsageGuard: 슬라이딩 윈도우 회로 차단기 (TMAP 폭주 방지)
- Firebase Crashlytics: 에러 추적, 네트워크 에러 필터링
- Remote Config: 원격 설정
- Tester Dashboard: 관리자용 클로즈드 테스트 분석 (main에 있음, 현재 HEAD에 없음)

---

## 3. 미완료 작업 및 알려진 이슈

### 3.1 detached HEAD 및 main 분기
현재 detached HEAD(e9c2f2b)에 있으며, main이 1 커밋 앞서 있음(7d36719 Tester Dashboard).
HEAD에 없는 main 커밋의 내용:
- migration: 20260705143000_tester_dashboard.sql (337줄)
- ActivityTrackingService (154줄)
- AdminTesterDashboardScreen (691줄)
- tester_dashboard_provider.dart (223줄)
- tester_info_model.dart (330줄)
- tester_dashboard_repository.dart (204줄)
- schema.sql 314줄 추가
- auth_service.dart, app.dart, router.dart 등 연동 수정

### 3.2 추적되지 않은 파일 (git untracked)
- docs/audit/action_plan.md: W06 통합 액션 플랜
- docs/audit/test.md: 테스트 파일
- supabase/migrations/20260705140000_add_user_activity_tracking.sql: main의 20260705143000_tester_dashboard.sql로 대체됨 (삭제 대상)
- supabase/user_activity_tracking_patch.sql: 동일 내용 수동 패치 (삭제 대상)
- .planning/PROJECT_BACKLOG.md: 프로젝트 백로그
- .agents/AGENTS_GUIDELINES_SUMMARY.md: 에이전트 가이드라인
- scripts/_check_imports.py, _check_lock.py, _tmp_grep_todo.py: 임시 스크립트

### 3.3 문서 부재
- README.md 없음: 프로젝트 진입점 문서 미존재
- PROJECT_CONTEXT.md는 3줄로 극히 부실

### 3.4 V2 그룹 기능 미검증 항목
- 실DB 배포 미확인: V2 스키마가 라이브 Supabase에 배포되었는지 미확인
- RLS 실DB 테스트 미수행: 6개 그룹 테이블 RLS가 실제로 차단하는지 검증 필요
- 실기기 smoke test 미수행: 11단계 가이드 있으나 수행 기록 없음
- QA 결론: main merge candidate이나 실DB 검증 전 final merge ready 아님

### 3.5 스테일 브랜치 과다
고정 브랜치 30+개 (대부분 1회성):
- salvage/auto-* 14개
- fluxos/planflow/* 8개
- task/TASK_* 5개
- backup/* 2개, codex/* 1개, claude/* 2개

### 3.6 코드 품질
- TODO/FIXME/HACK 주석: 코드 내 명시적 것 없음 (VTODO는 iCal 표준)
- 테스트 환경 제약: 현재 환경에서 flutter/dart가 PATH에 없어 테스트 실행 불가

---

## 4. 추천하는 다음 구현 우선순위

### 우선순위 1: main 동기화 및 파일 정리
- 복잡도: LOW
- 설명: detached HEAD를 main으로 동기화. 중복 마이그레이션(20260705140000) 삭제. 유효한 미추적 파일(action_plan.md, PROJECT_BACKLOG.md) 검토 후 커밋.
- 관련 파일: 전체 저장소 (git 작업)
- 근본원인: detached HEAD에서 작업하며 main이 앞서 나감. 재발 방지: 작업 시작 전 항상 git checkout main - git pull 후 브랜치 생성.

### 우선순위 2: V2 스키마 실DB RLS 배포 검증
- 복잡도: MEDIUM
- 설명: docs/planflow-v2/24-v2-deploy-status-check.md의 읽기 전용 SQL을 라이브 Supabase에서 실행하여 V2 스키마(테이블/RPC/트리거/RLS) 배포 여부 확인. MISSING이 있으면 21-v2-existing-supabase-apply-plan.md 절차로 적용.
- 관련 파일: supabase/schema.sql, supabase/migrations/*, docs/planflow-v2/24-v2-deploy-status-check.md
- 검증: 배포 상태 SQL 결과 전부 OK/RLS_ON, 실기기 smoke test STEP 6(Outsider 차단) PASS

### 우선순위 3: README.md 작성
- 복잡도: LOW
- 설명: 프로젝트 개요, 기술 스택, 로컬 설정, 실행 방법, 테스트 방법, 아키텍처, 주요 디렉토리 구조를 포함한 README.md 작성.
- 관련 파일: README.md (신규), pubspec.yaml, lib/main.dart 참조

### 우선순위 4: 스테일 브랜치 정리
- 복잡도: LOW
- 설명: 30+개 고정 브랜치 중 병합 완료/폐기된 것을 일괄 삭제. main과 backup/*는 보존.
- 관련 파일: git 작업만

### 우선순위 5: V2 그룹 실기기 E2E Smoke Test
- 복잡도: MEDIUM
- 설명: docs/planflow-v2/22-v2-real-device-smoke-test.md의 11단계를 최소 2기기(Leader + Member)에서 수행. Outsider 차단, 권한 위임, 캘린더 오버레이 검증.
- 관련 파일: lib/features/groups/*, test/features/groups/*
- 검증: smoke test PASS 기준(11단계) 충족

### 우선순위 6: Supabase 스키마 문서화 및 감사
- 복잡도: MEDIUM
- 설명: 19개 마이그레이션과 schema.sql이 지속 성장 중. 전체 테이블/RLS/RPC 목록 종합 문서 작성. Tester Dashboard 마이그레이션 후 users 테이블 변화 추적.
- 관련 파일: supabase/schema.sql, supabase/migrations/*, docs/maintenance-data-structure.md

---

## 5. 감사 방법론 및 한계

수행한 조사:
1. AGENTS.md, CLAUDE.md 전문 읽기 (프로젝트 규칙, 코딩 표준)
2. pubspec.yaml 읽기 (의존성, 버전)
3. git log/status/branch 실행 (변경사항, 브랜치 상태)
4. lib/ 디렉토리 트리 전수 조사 (모듈 식별)
5. TODO/FIXME/HACK 검색 (git grep)
6. supabase/migrations/ 확인 (스키마 현황)
7. test/ 디렉토리 확인 (테스트 커버리지)
8. docs/ 문서 확인 (V2 기획, QA 체크리스트, 배포 가이드)

한계:
- flutter test 실행 불가 (PATH에 flutter/dart 없음)
- Supabase 라이브 DB 접근 불가 (실DB 배포 검증은 별도 수행 필요)
- 실기기 테스트 불가 (별도 기기 필요)

---

최종 결론: PlanFlow는 기능적으로 성숙 단계(음성 스케줄링, 그룹 V2 병합, 관리 도구)에 있으며, 가장 시급한 작업은 detached HEAD 해소 및 main 동기화(LOW), V2 스키마 실DB RLS 배포 검증(MEDIUM, 보안상 중요), README.md 작성(LOW)입니다.
