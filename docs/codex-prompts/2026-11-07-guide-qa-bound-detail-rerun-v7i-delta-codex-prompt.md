# Guide QA bound detail — v7i 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7h 델타. 충돌 시 이 문서가 이긴다.

## v7h 리뷰 판정 (Claude)
**BLOCKED 기각 — 과잉 중단.** begin의 `granted, phase=create, event_id=null, saved_local_date=null`은 **정상**이다. RPC 정의상 granted 응답은 세션 행의 현재 상태를 그대로 반환하며, 새로 생성된 세션의 초기 phase는 'create'이고 바인딩(event_id·saved_local_date)은 라운드 진행 중 채워진다. v3가 기대한 `phase=saved, event_id 존재`는 "이미 바인딩된 기존 세션"의 모습이었을 뿐, 새 세션의 성공 조건이 아니다.
- 세션: v7h에서 교체된 유효 세션을 그대로 사용(재발급·verify 금지). 잔여기간 재확인 — 라운드 창(min 30분)보다 짧으면 그만큼 창을 줄이고, 0 이하면 BLOCKED.
- 영수증 7키는 모두 확보된 값으로 채운다: `at`=현재시각, `uid`=QA UID, `savedEventUid`/`savedEventId`/`guideSavedEventId`=3389cdce-c632-42e2-a510-87bccf57711c, `guideSavedDetailVerified`=true(begin granted + v7f 소유 조회로 검증됨), `originalLedgerSha256`=보존 ledger 파일에서 직접 계산.
- 이벤트 바인딩은 라운드 진행 중 이뤄지는 것이 정상 흐름 — begin에 event_id가 없다고 중단하지 말 것.

## v7i 실행 절차 (v7h의 3~6단계만)
1. 세션 잔여기간 확인(0 이하면 BLOCKED 보고 — 이 경우 재발급 승인 여부를 사용자에게 문의하는 것까지).
2. 위 스키마로 영수증 작성 → **5분 내** start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지, "Original ledger changed" 거부 시 우회 금지).
3. min(30분, 세션 잔여기간) 창 내 탭 10회 이내: 상세 튜토리얼 스크린샷 + uiautomator dump. saved.summary/saved.departure 앵커·코치마크 확인. 절대경로를 screen_evidence에 기록.
4. 앱 files/에서 is_multi_day, start_at, saved_local_date, 실패 코드 값 요약 수집(H3~H6 판정 자료). begin 세션이 'create' 단계에서 라운드에 들어가므로, 라운드 중 바인딩 관련 오류 코드가 나오면 그 코드를 그대로 기록할 것 — H3~H6 판정의 핵심 자료다.
5. lease 반납, 회전값 0→0 확인, 상태 JSON 저장. 티켓·임시 파일 삭제가 정책에 막히면 경로만 보고(Claude가 정리 — v7h 잔여 티켓 2건은 이미 정리됨).

## 불변
generate_link·verify·begin 재호출 전부 금지(예산 소진, 세션 유효). 승인 A 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰·키·링크 값 출력 금지. 호스트 파일 작업 막히면 기록만 보고. 완료 판정은 폰 화면 증거로만 — granted만으로 불충분. 실측값 상태 JSON 기록.
