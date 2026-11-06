# Guide QA bound detail — v5 델타 지시 (2026-11-06, Claude 작성)

**정본은 v3 + v4 델타**: `docs/codex-prompts/2026-11-06-guide-qa-bound-detail-rerun-v3-codex-prompt.md`, `…-v4-delta-codex-prompt.md`. 이 문서는 v4에서 멈춘 승인 C 응답 처리를 푸는 게 목적. 충돌 시 이 문서가 이긴다.

## v4 결과 리뷰 요지 (Claude 판정)
- generate_link 응답은 서버에서 **성공**이었다. 멈춘 이유는 파서가 최상위 `user_id`를 기대했기 때문 — Supabase admin generate_link 응답의 사용자 정보는 **`user.id`로 중첩**되어 있고(`action_link`, `email`, `hashed_token`, `redirect_to` 등은 최상위), 키 이름 불일치일 뿐 응답 자체는 정상일 가능성이 높다.
- v4 상태 JSON에 응답 원문 저장 경로가 기록되지 않았다. 원문이 살아 있으면 재호출이 필요 없다.

## 실행 순서 (v5)

### Step C-0: 응답 원문 존재 확인 (서버 호출 없음)
1. v4 실행 당시 generate_link 응답을 파일로 저장했다면 그 경로를 상태 JSON에 기록한다. 저장 안 했으면 대화 로그/스크래치패드에서 원문을 찾아 복구를 시도한다.
2. 찾았으면: 파일에 `action_link`이 있는지 **키 존재만** 확인(값 출력 금지). 있으면 Step C-1로. `action_link`이 없는 원문이면 Step C-2로.
3. 못 찾았으면: BLOCKED 보고하고 **재발급은 호출하지 말고** 사용자에게 "generate_link 재발급 1회 승인 필요"만 요청한다. 재시도 금지 규칙은 유지.

### Step C-1: /verify 1회 (승인 C 범위 내 — 원래 승인된 나머지 절반)
1. 저장된 `action_link`으로 `/auth/v1/verify` 1회 호출. 이것은 v4에서 미실행한 승인 C의 나머지 절반이며 새 승인 불필요.
2. 응답 토큰은 **수신 즉시 파일 write → 파싱 검증 → 원자적 교체**(v2/v4 소실·파싱 사고 재발 방지). StrictMode 유지하되 기대 키는 `user.id` 등 실제 Supabase 스키마에 맞춘다.
3. 세션 파일 교체 후 `session_remaining_seconds > 0` 확인을 상태 JSON에 기록.

### Step B: 승인 B (미사용·유효)
v3/v4 순서대로: 저장 일정 소유 조회 읽기 1회 → `begin_real_ui_guide` 1회 → 영수증 발급(5분 유효).

### Step R: 라운드 시작 + UI 증거
- `start-bound-detail-round.ps1` 직접 실행(래퍼 금지 유지), 30분 QA 세션 창 안에서 탭 10회 이내로 스크린샷 + uiautomator dump 수집, `screen_evidence`에 파일 경로 기록.
- lease 획득 직후 첫 adb 명령은 회전값 읽기(전후 0→0 기록) — v4 유지.

## 불변 규칙 (재확인)
- 승인 A: 소비됨, 재시도 절대 금지.
- 승인 C 재발급(새 generate_link): **v5에서 자동 실행 금지** — 원문을 못 찾은 경우에만 사용자 승인을 요청할 것.
- generate_link·verify 응답의 토큰/링크 값 출력 금지. 키 존재·길이·해시만 기록.
- 서버 호출 상한: verify 1회, events 읽기 1회, begin RPC 1회.ADB는 공용 큐 경유.
- 완료 판정은 폰 화면 증거(스크린샷+dump)로만. 서버 200·failed=false만으로 완료 아님.
