# Guide QA bound detail — v6 델타 지시 (2026-11-06, Claude 작성)

**정본**: v3 + v4 + v5 델타 (`docs/codex-prompts/2026-11-06-guide-qa-bound-detail-rerun-v{3,4-delta,5-delta}-codex-prompt.md`). 충돌 시 이 문서가 이긴다.

## 승인 상태 변화 (이 문서의 핵심)
- **generate_link 재발급 1회: CEO 승인됨(2026-11-06, v4 원문 소실에 한정).** 승인 C의 총 재발급 한도는 딱 1회 — 이번 호출이 마지막 기회다. 재발급이 또 파싱/소실되면 추가 재발급 없이 BLOCKED 보고.
- /verify: 이번 재발급 응답의 action_link으로 1회 (승인 C 나머지 절반).
- 승인 B: 미사용·유효. 승인 A: 소비됨, 절대 금지.

## 실행 순서

### Step C-2: generate_link 재발급 1회 (소실 방지 절차 강제)
1. **호출 전** 응답 저장 파일 경로를 정하고, PowerShell에서 `Invoke-RestMethod` 대신 **원문(raw body)을 받자마자 `Set-Content -Encoding UTF8`로 파일 write** → 그 후에 파싱한다. 파싱은 StrictMode 유지하되 기대 키를 실제 Supabase 스키마에 맞춘다: 최상위 `action_link`, `email`, `hashed_token`, `redirect_to`; 사용자 식별자는 **`user.id`(중첩)**. `user_id`라는 최상위 키는 존재하지 않는다.
2. 원문 저장 성공 후 키 존재 확인(값 출력 금지 — 길이/해시만) → 상태 JSON에 파일 경로·SHA-256 기록.
3. `action_link` 확보 즉시 Step C-1(v5 문서): `/auth/v1/verify` 1회, 토큰 수신 즉시 파일 write → 검증 → 원자적 교체 → `session_remaining_seconds > 0` 기록.

### Step B / Step R
v5 문서 그대로: 승인 B(소유 조회 1회 → begin RPC 1회 → 영수증 5분) → `start-bound-detail-round.ps1` 직접 실행 → 30분 창 내 탭 10회 이내, 스크린샷 + uiautomator dump, `screen_evidence`에 경로 기록. lease 직후 첫 adb 명령은 회전값 읽기(전후 0→0).

## 불변 규칙
- 재발급 응답도 소실 시 재발급 재시도 금지 — 즉시 BLOCKED 보고.
- 모든 응답의 토큰/링크 값 출력 금지(키 존재·길이·SHA만).
- 완료 판정은 폰 화면 증거로만. 서버 200·failed=false 불충분.
