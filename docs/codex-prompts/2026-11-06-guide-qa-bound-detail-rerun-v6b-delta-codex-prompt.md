# Guide QA bound detail — v6b 델타 지시 (2026-11-06, Claude 작성)

**정본**: v6 델타 (`docs/codex-prompts/2026-11-06-guide-qa-bound-detail-rerun-v6-delta-codex-prompt.md`) + v3~v5. 충돌 시 이 문서가 이긴다.

## v6 리뷰 판정 (Claude)
- BLOCKED 인정. generate_link 0회 — **재발급 승인 1회는 여전히 미소비·유효**. 큐 반납·회전값 0→0·ledger/APK 검증 양호.
- 원인: 프로젝트 키 조회 실패. Claude가 2026-11-06 직접 동일 조회를 검증한 결과 **정상 동작**(anon·service_role·default 2개 = 4키, 값 미출력). 즉 일시적 실패로 판단 → 단순 재실행.

## v6b 델타
1. **키 조회 방법 고정**: `supabase projects api-keys --project-ref xqvvfnvmytjlblcngipn --output json`에서 `service_role` 항목을 사용. (Supabase CLI 로그인 상태 유효 — Claude가 동일 호스트에서 성공 확인.) 조회는 Management API 호출로 **승인 카운트(server_calls)에 불산정**이며, 네트워크 오류 시 최대 3회 재시도(지수 백오프 5/15/30초) 가능.
2. 키 값은 변수에만 담고 파일·로그·상태 JSON 출력 금지(기존 규칙 유지).
3. 이후 절차는 v6 그대로: raw body 즉시 파일 저장 → `user.id`/`action_link` 파싱 → /verify 1회 → 승인 B → 라운드 → 30분 창 UI 증거 → lease 반납·회전값 0→0.
4. 기기가 2대로 보일 수 있음(v6 실측): 첫 회전 조회부터 **확인된 S23 Ultra serial을 지정**해 실행(모호 명령 실패 재발 방지).
5. 재발급 1회 소비 후 소실되면 재시도 없이 BLOCKED 보고(불변).
