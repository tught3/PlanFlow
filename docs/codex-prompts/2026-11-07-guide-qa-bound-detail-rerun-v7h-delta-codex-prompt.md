# Guide QA bound detail — v7h 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7g 델타. 충돌 시 이 문서가 이긴다.

## CEO 승인 (2026-11-07, 최종)
- **generate_link 재발급 + verify + begin + 라운드: 하나의 실행 안에서 연쇄, 최종 1회.** 발급 후 5분 내 verify(v7e에서 이 조합 성공 증명). 이번이 정말 마지막 — 실패 시 재발급 없이 BLOCKED 보고로 종료.
- 서버 세션 행 리셋은 v7g 전에 완료됨(1→0행) — 다음 begin은 새 세션을 생성해 granted 반환.

## v7h 실행 절차 (단일 실행 연쇄)
1. 큐 lease: SM-S918N + versionCode 198 1대 매칭(0 또는 2대 이상이면 BLOCKED). lease 직후 serial 지정 회전값 기록, get-state=device 확인.
2. 기기 준비 확인 후 서버 연쇄 시작(기기 문제가 확인되면 발급 전에 중단 — 발급을 날리지 않게):
   a. 키 조회(v6b 방식, 네트워크 오류 3회 백오프).
   b. generate_link 1회 → 원문 즉시 파일 write → 최상위 id == 2cc42b8e-fe6c-4812-894a-ab81605275d3 검증(불일치 즉시 BLOCKED) → action_link 확보. 값 출력 금지(길이·해시만).
   c. **5분 내** /auth/v1/verify 1회 → 토큰 수신 즉시 파일 write → 검증 → 원자적 교체 → session_remaining_seconds > 0 기록.
   d. **세션 교체 직후 즉시** begin_real_ui_guide 1회: p_version='real_ui_v1', 새로운 p_request_id(과거 사용분과 달라야 함). 기대: status='granted', event_id=3389cdce-c632-42e2-a510-87bccf57711c, saved_local_date 존재. 응답 즉시 파일 저장 후 파싱. granted 아니면 status·reason_code 기록 후 BLOCKED(재호출 금지).
3. granted면 7키 영수증 작성(originalLedgerSha256은 보존 ledger에서 직접 계산) → 5분 내 start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지, "Original ledger changed" 거부 시 우회 금지).
4. min(30분, 세션 잔여기간) 창 내 탭 10회 이내: 상세 튜토리얼 스크린샷 + uiautomator dump. saved.summary/saved.departure 앵커·코치마크 확인. 절대경로를 screen_evidence에 기록.
5. 앱 files/에서 is_multi_day, start_at, saved_local_date, 실패 코드 값 요약 수집(H3~H6 판정 자료).
6. lease 반납, 회전값 0→0 확인, 상태 JSON 저장. 티켓·임시 파일 삭제가 정책에 막히면 경로만 보고(Claude가 정리).

## 불변
generate_link 1회(최종), verify 1회, begin 1회, events 읽기 생략(v7f 성공분 재사용 — 필요하면 begin granted 응답의 event_id·saved_local_date로 대체 검증). 승인 A 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰·키·링크 값 출력 금지. 호스트 파일 작업 막히면 기록만 보고. 완료 판정은 폰 화면 증거로만 — granted만으로 불충분. 실측값 상태 JSON 기록.
