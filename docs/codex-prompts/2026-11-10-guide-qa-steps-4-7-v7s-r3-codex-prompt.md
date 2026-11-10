# v7s-r3 델타 지시 — QA 전용 제출 보류·AI 상한 강제 구현 (2026-11-10, Claude 작성)

**정본**: v7s-r2 델타. **Codex 판정 인정 — 부분 전사 자동 제출로 사전 확인 지점이 없다. 따라서 QA 트리 코드 수정으로 "제출 보류 + 상한 강제"를 만든다(v7k/v7q/v8b-r3 선례). 폰 라운드는 그 뒤 별도 지시(v7s-r4).**

## 설계 (Claude 확정 — 이대로 구현)
1. **AI 상한 강제(fence 레벨, 최후 방어)**: `integration_test/support/real_ui_guide_native_environment.dart`의 `_BudgetClient` — AI 분석 요청 전달 직전 `ledger.aiRequests >= 5`면 **전달 금지(fail-closed)**: records에 `denyReason:'ai_cap_exceeded'`, journal `AI_CAP_EXCEEDED`, run latch(더 이상 진행 불가 — 이때만 BLOCKED 보고로 이어지는 정상 경로). 이걸로 "한도 보장 불가" 문제는 기술적으로 종결.
2. **제출 보류(소비 최소화)**: QA 전용 플래그 `qaVoiceSubmitHold`(manual guide 환경 기본 true) 도입:
   - `voice_input_screen.dart` **부분 전사 자동 분석 경로(L1681 부근)** — hold 활성 시 자동 분석 시작 금지(전사 텍스트는 유지).
   - `voice_input_screen.dart` **완료 자동 제출 경로(L559 `_continueWithRawText`)** — hold 활성 시 자동 제출 금지, 전사 유지.
   - `voice_conversation_screen.dart` `initialText` 자동 제출(`_submitInitialTextIfNeeded`) — hold 활성 시 금지.
   - 해제 메커니즘: 기존 CONTINUE 제어 파일과 동일한 패턴으로 guide 디렉터리에 `native-guide-ai-submit-permit` 파일(내용 `CONTINUE`만 허용, 길이·서식 검증은 기존 구현 재사용) — **파일이 있으면 다음 제출 1회 허용 후 자동 소멸(1회용)**. 러너/Codex가 전사 확인 후 파일을 써서 제출시킨다. 플래그 와이어링은 env.manualGuideSnapshot 패턴과 동일 계열로.
   - hold는 **QA 환경에서만** 켠다. 본앱 경로 변경 아님 — 게이트는 화면 코드에 있지만 QA 플래그가 false면 기존 동작 그대로(회귀 없음).
3. **테스트**: ① BudgetClient cap — 6번째 AI 요청 deny·`AI_CAP_EXCEEDED` 기록 검증 ② permit 파일 1회용 소멸 검증 ③ hold=false일 때 기존 자동 제출 유지 검증. 기존 native_guide 계약 테스트 스위트 통과 유지.
4. **빌드·설치**: QA 트리 전체 타깃 테스트 통과 후 APK 재빌드·재설치(versionCode 198 유지, v7q-r2 절차). SHA256 기록. 설치 확인(dumpsys)까지만 — **라운드 실행은 v7s-r4에서.**
5. 보고: 결과 한 줄 / diff 요약(파일·핵심 로직) / 테스트 증거 / APK 경로·SHA256·설치 확인 / 잔여 경로.

## 불변
수정은 위 3영역(fence·voice 2화면·테스트)만. 메인 앱 lib 터치 금지(QA 트리만). 폰은 설치까지만(라운드·서버 호출 금지 — refresh 보존분 유지). monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰 출력 금지. 커밋은 QA 트리 브랜치(fix/voice-first-tour-20261017)에 push(훅 지연 감안 — 완료까지 대기, stale lock은 경로 보고). 호스트 파일 작업 막히면 경로 보고(Claude 정리).
