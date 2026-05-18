<!-- [WIKI:START] Personal Wiki Reference - 직접 수정 금지 -->
<!-- 생성: 2026-05-19 08:05 -->

# AI Behavior Rules
<!-- AI가 작업 시 반드시 따라야 할 행동 원칙. 모든 프로젝트에 공통 적용. -->

## 절대 금지
- 계획 없이 코드 먼저 작성
- 기존 동작 중인 코드를 이유 없이 리팩토링
- 승인 없이 아키텍처 변경
- 가격/구독 정책 임의 변경
- iOS 관련 코드 추가 (Android-only 프로젝트)
- 검증 없이 완료 보고
- 컨텍스트 압축 없이 작업 시작

## 필수 행동
- 작업 전: 컨텍스트 압축 -> 계획 제시 -> 승인 대기
- 작업 중: 계획 외 변경 발생 시 즉시 보고
- 작업 후: push -> 빌드 -> 실행 -> 테스트 순서로 검증
- 모르면 가정하지 말고 질문
- 난이도와 모델이 맞지 않으면 모델 변경 후 진행

## 응답 원칙
- 한국어로 응답
- 코드 변경 시 변경 전/후 명시
- 영향 범위 항상 명시 (어느 파일, 어느 기능)
- 에러 발생 시 원인 -> 해결책 -> 예방법 순서로 설명

# Anti-Patterns
<!-- 이미 실패했거나 기각된 접근법. AI에게 다시 제안하지 말 것. -->

## 전역 금지 패턴

### 상태관리
- Flutter에서 Provider 사용 -> Riverpod 사용
- React에서 Redux -> Zustand 사용

### 아키텍처
- React Native (Flutter 전환 완료, 롤백 금지)
- Firebase (Supabase로 확정, 변경 금지)
- iOS 빌드 시도 (SMS/알림 API 접근 불가)

### 코드 품질
- any 타입 남발
- useEffect 안에 직접 fetch 호출
- 하드코딩된 API 키/비밀값

## 프로젝트별 anti-patterns
-> 각 02_PROJECTS/[프로젝트].md 파일의 금지 패턴 섹션 참조

# PlanFlow

## 경로
E:\FluxStudio\planflow

## 현재 상태
- Stage: 아키텍처 확정, 구현 시작 단계

## 기술스택
- Framework: Flutter (Android-first)
- Backend: Supabase (PostgreSQL + Auth)
- AI: GPT-4o-mini
- STT: on-device (onDevice: true - 음성 절대 서버 전송 금지)
- TTS: flutter_tts

## DB 스키마
users, events, pre_actions, reminders, voice_logs,
location_history, user_settings, early_bird_emails

## 핵심 기능 (1차 배포)
- 음성 입력 -> AI 파싱 -> 확인 UI -> 저장 -> 알림
- 아침/저녁 브리핑
- 역산 알림 (pre-action reverse-calculation)
- 이동 시간 버퍼
- Google/Naver 캘린더 양방향 동기화
- 시스템 알람, 홈 위젯 (마이크 버튼)

## 핵심 기능 (2차 배포)
- KakaoTalk/SMS 일정 감지 (Notification Listener API)
- 통화 내용 일정 감지 (로컬 call-to-text)
- 위 기능: 명시적 온보딩 동의 + 개별 권한 토글 필수

## AI 작업 시 절대 금지
- onDevice: false 설정 (음성 서버 전송 절대 금지)
- 2차 배포 기능을 1차에 포함
- 유료화 코드를 1차 배포에 추가 (1차는 전체 무료)
- iOS 빌드 관련 코드

## AGENTS (Codex) 통합 규칙
- 기본 응답 언어는 한국어다.
- 비단순 작업은 계획 -> 병렬 작업자 -> 별도 리뷰어 -> 수정 -> 재리뷰 순서로 진행한다.
- 계획은 `gpt-5.5`, 단순 구현은 `gpt-5.3-codex-spark`, 조금 난이도 있는 구현은 `gpt-5.4-mini`, 리뷰/검토/검증은 `gpt-5.4-mini`를 우선한다.
- `gpt-5.3-codex-spark`가 한도에 닿으면 구현도 `gpt-5.4-mini`로 대체할 수 있다.
- 세션 시작 시 `.planning/STATE.md`, `.planning/context/ACTIVE_SUMMARY.md`, `node scripts/gsd-context-hygiene.mjs`를 확인한다.
- Flutter 명령은 가능하면 `scripts/flutter-local.ps1`를 통해 실행한다.
- `C:\PlanFlow`를 작업 루트로 두고, `E:\Project\PlanFlow`는 읽기 전용 참고 자료로만 본다.
- `supabase/schema.sql`이 스키마 기준이며, DB schema/migration/RLS 변경 전에는 사용자 확인을 받는다.
- `G:\AI-automatic-expense-tracker`는 수정하지 않는 참고 저장소다.
- 1차 출시 범위에는 billing, ads, reward ads, Kakao/SMS/call detection, TEAM/BUSINESS 기능을 넣지 않는다.
- Naver Calendar는 1차 기능으로 유지하고, OAuth consent/token/export 흐름은 검증 가능해야 한다.
- 완료 전에는 analyze, test, Android build 또는 run check, 가능한 경우 실제 실행 확인을 거친다.
- 완료 시 커밋과 푸시까지 마친다.


<!-- [WIKI:END] -->

# AGENTS.md for `C:\PlanFlow`

This file is the top-priority working rule for this repo.
Secondary detail sources: `CLAUDE.md` and `docs/agent-rules-*.md`.

## Default language
- Always respond in Korean.

## Default operating order
1. If a request has 2 or more issues, or spans multiple subsystems, plan first with the strongest planner available.
2. Use the plan to execute with worker agents, preferably in parallel when file scopes do not overlap.
3. Always run a separate review/verifier pass after implementation.
4. If review finds anything incomplete or risky, fix it and review again.
5. Only report completion when nothing is left to change.

## Model routing
- Default behavior: route work by task complexity automatically, even if the user names a model.
- Planner/Main for non-trivial work: `gpt-5.5`.
- Worker agents for simple implementation, code edits, and test updates: `gpt-5.3-codex-spark`.
- Slightly harder implementation, complex refactors, architecture changes, or hard bugs: `gpt-5.4-mini`.
- Review / verification: `gpt-5.4-mini`.
- If `gpt-5.3-codex-spark` is at capacity or the exact model cannot be selected in the current environment, keep the same role split and use `gpt-5.4-mini` as the fallback for implementation / review.
## Workflow rules
- Mandatory enforcement: for multi-issue or high-risk work, do not report completion unless context hygiene, role/model routing, worker delegation, reviewer verification, fix-after-review loop, tests/build, checkpoint, commit, push, and device run check have all been attempted and explicitly reported.
- Model routing is not advisory. Use `gpt-5.5` for planning, `gpt-5.3-codex-spark` for simple execution, and `gpt-5.4-mini` for review plus harder execution / fallback cases.
- When the user says "AGENTS.md대로" or asks for subagents/reviewer, treat worker and reviewer agents as required. If a tool/runtime limit blocks spawning, close completed agents and retry; if still blocked, report the blocker and continue with the closest safe fallback.
- Every task must begin with context hygiene: check `.planning/STATE.md`, check `.planning/context/ACTIVE_SUMMARY.md`, and run `node scripts/gsd-context-hygiene.mjs` when it exists. If the script is missing, explicitly record that it is missing and continue.
- Every completed task/logical change must end with verification, a planning-context checkpoint, a Git commit, and a push to the remote repository.
- Every completed task/logical change must also end with a fresh build and, when the target device is available, a real run/launch check before reporting completion.
- For any Flutter run/build/test command in this repo, prefer `scripts/flutter-local.ps1` so `env/local.json` and the local `--dart-define` set are injected automatically. Do not fall back to raw `flutter` unless the wrapper is missing or the user explicitly asks.
- Before starting work, check `.planning/STATE.md` and `.planning/context/ACTIVE_SUMMARY.md`.
- Run `node scripts/gsd-context-hygiene.mjs` at session start, before long work, and before final report. If the script is missing, record that and continue.
- After every completed logical change, update `.planning/context/ACTIVE_SUMMARY.md` with a short checkpoint.
- After every completed logical change, commit and push to the remote repository.
- Do not leave unused helper terminals or sessions open; close them when they are no longer needed.
- Do not commit unrelated or user-created untracked files unless explicitly requested.
- Prefer existing code, shared helpers, and existing docs before creating new structures.
- Create new code only when reuse is clearly worse.
- Do not delete unused code until implementation and verification are fully complete.
- ADB package-destructive commands (`adb uninstall`, `pm uninstall`, `pm clear`, broad app cleanup scripts) must target only this repo's package `com.planflow.app`. Never target FinFlow or other app package names from this workspace while working in PlanFlow, and never use wildcard/broad package deletion.
- For complex work, split into independent subagent tasks and run them in parallel when safe.
- When code changes are needed, prefer worker agents for implementation and a separate reviewer for verification.
- Completed worker/reviewer agents must be closed unless there is a specific reuse plan.
- Keep direct edits narrow; use them only for trivial fixes or repo settings/doc updates.
- If a request has 2 or more issues, the plan-review-implement-review loop is mandatory by default.
- Do not ask for permission between intermediate steps in the same batch unless a real decision is blocked.
- Answer all user questions that appear in the same request, even if they are separate from the code task.
- Do not modify tests unless the task explicitly asks for test changes or the implementation requires test updates.
- Keep the scope tight; do not add unrelated changes, and report known gaps instead.

## Repo-specific rules
- Work from `C:\PlanFlow` unless the user explicitly changes the working path.
- `E:\Project\PlanFlow` is a read-only reference source for files that previously worked, especially login and app flow.
- `G:\AI-automatic-expense-tracker` is reference-only and must not be modified.
- PlanFlow product scope is defined by `PlanFlow_Codex_Prompt_v3.md`.
- Supabase schema source of truth is `supabase/schema.sql`.
- Because of NexusFlow integration, stop and get explicit user confirmation before any DB schema, migration, or RLS change.
- Treat future Flow Core/shared-core files as cross-project contracts for NexusFlow and related apps. If `packages/`, `flow_core/`, shared domain models, shared repositories, shared parsing/routing services, or other Flow Core extraction targets are created or modified, stop first and get explicit user confirmation unless the user has directly requested that exact change.
- For 1st release, do not implement billing, ads, reward ads, Kakao/SMS/call detection, or TEAM/BUSINESS features.
- Naver Calendar is now a 1st-release working feature. Keep OAuth consent, token handling, and calendar export behavior visible and testable.
- Keep all user-facing UI text Korean unless a platform/provider brand requires otherwise.
- If Korean text appears broken/mojibake in terminal output, re-read the file or output explicitly as UTF-8 before interpreting or editing it. Do not make decisions from broken Korean text.
- Voice files must never be sent to external servers. Only STT text may be stored or sent for parsing.
- `speech_to_text` must use `SpeechListenOptions(onDevice: true)` for STT.
- If ADB screenshots or mirroring are black, ask the user to turn on the phone screen before visual verification.
- Keep the PlanFlow Home UI close to the compact card-based reference: clean Korean schedule cards, no large blank first viewport.

## Project structure

```text
lib/
├── core/                # env, routing, theme, constants
├── data/                # models and Supabase repositories
├── providers/           # app/auth/event/settings state
├── screens/             # Flutter screens
├── services/            # STT, GPT, calendar, notification, widget, backup
└── widgets/             # shared UI widgets
android/                 # Android app, widget, manifest
supabase/schema.sql      # DB schema and RLS source of truth
```

## Deployment structure
- Android first for 1st release.
- Supabase: Auth, PostgreSQL, RLS, backup/restore RPC.
- Google Cloud: Google Calendar OAuth and Google Maps travel-time API.

## Detail references
- Workflow details: `docs/agent-rules-workflow.md`
- Validation details: `docs/agent-rules-validation.md`
- Operations details: `docs/agent-rules-operations.md`

