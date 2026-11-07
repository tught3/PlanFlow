# Guide QA bound detail — v7g 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7f 델타. 충돌 시 이 문서가 이긴다.

## CEO 승인 (2026-11-07, 옵션 1)
- `real_ui_guide_sessions`의 QA UID 세션 행 리셋: **Claude가 이미 수행 완료** (rows_before=1 → rows_after=0, 원격 DB에서 직접 확인). 다음 begin 호출은 새 세션(phase='create', expires_at=now()+60분)을 자동 생성해 'granted'를 반환해야 한다.
- 이에 따라 **begin 재호출 1회를 포함한 v7g 실행도 승인됨**(옵션 1의 목적 달성에 필수). events 소유 조회는 v7f에서 성공했으므로 **재호출 불필요 — 생략**.
- v7f begin의 'expired'는 서버 RPC의 created_at+7일 수명 규칙(Claude가 RPC 정의에서 확인) — 절차 오류가 아니었다.

## v7g 실행 절차 (세션 리셋 완료 상태에서 시작)
1. 큐 lease: SM-S918N + versionCode 198 1대 매칭(0 또는 2대 이상이면 BLOCKED). lease 직후 serial 지정 회전값 기록. 기기 get-state 확인까지 하고 서버 호출.
2. begin_real_ui_guide 1회: p_version='real_ui_v1', **새로운 p_request_id**(과거 사용한 것과 달라야 함 — request_replay_mismatch 방지). 기대 응답: status='granted', event_id=3389cdce-c632-42e2-a510-87bccf57711c, saved_local_date 존재. 응답은 즉시 파일 저장 후 파싱. status가 granted가 아니면 그 값·reason_code만 기록하고 BLOCKED(재호출 금지).
3. granted면 7키 영수증 작성(originalLedgerSha256은 보존 ledger 파일에서 직접 계산) → 5분 내 start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지, "Original ledger changed" 거부 시 우회 금지).
4. min(30분, 세션 잔여기간=60분) 창 내 탭 10회 이내: 상세 튜토리얼 스크린샷 + uiautomator dump. saved.summary/saved.departure 앵커·코치마크 확인. screen_evidence에 절대경로 기록.
5. 앱 files/에서 is_multi_day, start_at, saved_local_date, 실패 코드 값 요약 수집(H3~H6 판정 자료).
6. lease 반납, 회전값 0→0 확인, 상태 JSON 저장. 티켓·임시 파일 삭제가 정책에 막히면 경로만 보고(Claude가 정리).

## 불변
events 읽기 생략(완료됨). begin 1회(이번이 마지막). generate_link·verify 재호출 금지 — 세션 파일은 v7f에서 교체된 유효한 것 사용(잔여기간 재확인, 0 이하면 BLOCKED). 승인 A 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰·키·링크 값 출력 금지. 완료 판정은 폰 화면 증거로만 — 서버 granted만으로 불충분.
