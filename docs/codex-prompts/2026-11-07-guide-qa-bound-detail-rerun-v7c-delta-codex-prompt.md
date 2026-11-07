# Guide QA bound detail — v7c 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7b 델타. 충돌 시 이 문서가 이긴다.

## CEO 신규 승인 (2026-11-07)
- **generate_link 재발급 + 즉시 verify: 최종 1회 허용.** 이번이 마지막이다. 발급 후 verify 실패·소실 시 추가 재발급 없이 BLOCKED 보고.
- **시간 강제 조건**: generate_link 응답 수신부터 /verify 호출 시작까지 **5분 이내**. 초과 예상 시(lease 지연, 기기 문제 등으로 서버 호출 순서가 꼬일 경우) generate_link을 호출하기 전에 중단한다. v6b 링크가 OTP 만료(otp_expired, 403)로 죽은 원인이 하루 경과였으므로, 이번엔 같은 실행 안에서 발급→사용한다.

## 실행 순서 (v7b에서 바뀐 부분만, 나머지는 v7b 그대로)
1. v7b 순서대로 lease 획득 → 회전값 기록까지 먼저 완료한다(기기 준비가 선행 — 서버 발급을 기기 문제로 날리지 않게).
2. 승인 B(소유 조회 1회)까지 끝낸 뒤, 마지막에 generate_link을 발급한다. 키 조회 방법은 v6b 방식(`supabase projects api-keys --project-ref xqvvfnvmytjlblcngipn`, network 오류 시 3회 백오프).
3. generate_link 1회 호출: 원문 즉시 파일 write → 최상위 id == QA UID 2cc42b8e-fe6c-4812-894a-ab81605275d3 검증(불일치 시 즉시 BLOCKED) → action_link 확보. 값 출력 금지.
4. **5분 내** /auth/v1/verify 1회. 토큰 수신 즉시 파일 write → 검증 → 원자적 교체. session_remaining_seconds > 0 기록.
5. 세션 교체 성공 후 잔여기간 확인 → 30분 창(min(30분, 잔여기간)) 안에서 라운드 시작 → 스크린샷 + uiautomator dump 수집, screen_evidence 기록.
6. lease 반납, 회전값 0→0 확인, 상태 JSON 저장. 티켓 파일 삭제가 정책에 막히면 경로만 보고(Claude가 정리).

## 불변
- verify 1회, events 읽기 1회, begin 1회, generate_link 1회(이번이 최종). 초과 시 즉시 중단.
- 승인 A 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰·키·링크 값 출력 금지.
- 완료 판정은 폰 화면 증거로만. 실측값(is_multi_day, start_at, saved_local_date, 실패 코드)을 상태 JSON에 기록.
