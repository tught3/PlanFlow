# Guide QA bound detail — v7 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v6b 델타. 충돌 시 이 문서가 이긴다.

## v6b 리뷰 판정 (Claude, 원문 직접 검증 — 값 미출력)
저장된 응답(SHA-256 `68823E6E4D189835…`, 1635바이트)은 **필수 필드를 전부 갖고 있다**:
- 최상위에 `action_link`(170자), `hashed_token`, `email_otp`, `verification_type`, `redirect_to` 존재.
- 사용자 식별자는 `user.id` 중첩이 아니라 **최상위 `id`**(평탄화 스키마). `identities[].user_id`도 존재.
- v6b의 "필수 키 구성이 없다"는 판정은 스키마 변형(중첩 vs 평탄화) 미반영 오류. **/verify 진행 가능. 재발급 재호출은 금지(소비 완료, 불필요).**

## Step C-1 (v5 문서의 그것, 아래로 교체)
1. 원문에서 `action_link`을 읽는다(값 출력 금지).
2. 검증 게이트(전부 통과해야 진행):
   - 최상위 `id`가 인수인계 문서의 QA UID(`2cc42b8e-fe6c-4812-894a-ab81605275d3`)와 **문자열 일치** — 불일치면 즉시 BLOCKED(타 계정 링크 절대 사용 금지).
   - `verification_type`이 magiclink 계열인지 확인.
   - `user_metadata.purpose`/`qa`가 QA 세션 관련임을 표시하는지(값 출력 없이 boolean만 상태 JSON에).
3. `/auth/v1/verify` 1회 호출. 토큰/링크 값 출력 금지, 리다이렉트 추적 금지. 응답 토큰은 수신 즉시 파일 write → 검증 → 원자적 교체.
4. 교체 후 `session_remaining_seconds > 0`을 상태 JSON에 기록. 남는 유효기간이 30분 QA 창보다 짧으면 그 사실을 명시하고 라운드 창을 토큰 만료 이내로 제한.

## Step B / Step R
v6b 그대로: 승인 B(소유 조회 1회 → begin RPC 1회 → 영수증 5분) → S23 Ultra serial 지정, lease 직후 회전값 읽기(전후 0→0) → `start-bound-detail-round.ps1` 직접 실행 → 30분 창 내 탭 10회 이내, 스크린샷 + uiautomator dump 수집, `screen_evidence`에 경로 기록.

## 불변
- generate_link 재호출 금지(소비 완료). verify 1회, events 읽기 1회, begin 1회 상한.
- 서버/폰 호출 전부 공용 큐·승인 기록 범위 내. 증거 없는 완료 판정 금지.
