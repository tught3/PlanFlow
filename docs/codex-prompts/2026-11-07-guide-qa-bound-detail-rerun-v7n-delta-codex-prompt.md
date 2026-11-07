# Guide QA bound detail — v7n 델타 지시 (2026-11-07, Claude 작성)

**정본**: v7m 델타 + v3~v7l. 충돌 시 이 문서가 이긴다.

## v7m 리뷰 판정 (Claude)
- BLOCKED **불인정 — 중단 근거 없음**. Claude가 v7e에서 qa-live·qa-account-approved 양쪽 저장 경로 선검증(쓰기/읽기/삭제)을 이미 완료했고, v7m 실행에도 유효하다. **선검증 재수행 금지 — 완료된 것으로 간주하고 즉시 refresh 갱신부터 진행.**
- "잔여 파일 2건"은 **이미 삭제된 상태**다(Claude가 v7l 뒤 삭제, 2026-11-07 재확인 ABSENT). Codex 보고는 구정보.
- refresh·begin 승인 횟수는 **미소비·유효**(v7m 호출 0회 확인).

## v7n 실행 절차 (v7m 그대로, 선검증만 제외)
1. 큐 lease: SM-S918N + versionCode 198 1대 매칭(설치 APK = v7l 것, SHA256 163BACA3…). lease 직후 serial 지정 회전값 기록, get-state=device 확인.
2. refresh_token 갱신 1회: 세션 파일(v7h 교체분)의 refresh_token으로 `POST {SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`. **응답 수신 즉시 파일 write → 검증(sub==QA UID, access·refresh 존재, 잔여 ≥3500초) → 원자적 교체.** 선검증은 완료 상태이므로 저장 경로 시험 없이 바로 진행. 실패 시 재시도 금지, BLOCKED.
3. begin 1회: 갱신 토큰으로. granted면 진행(바인딩은 라운드 중 — v7i 판정), 아니면 status·reason_code 기록 후 BLOCKED.
4. 영수증 즉시 작성(at=현재, uid=QA UID, 세 ID=3389cdce-…, verified=true, originalLedgerSha256=보존 ledger에서 계산) → 5분 내 start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지).
5. min(30분, 세션 잔여기간) 창 내 탭 10회 이내: 기대 화면 = 홈 음성입력 버튼 하이라이트 + "눌러서 일정을 추가해보세요 1/2". 스크린샷+dump, screen_evidence 기록. paused 화면 재발 시 dump + run-as 진단 파일 수집 후 중단 보고(탭 금지).
6. savedDetail 도달 시 saved.summary/saved.departure 앵커 증거 + 앱 files/의 is_multi_day/start_at/saved_local_date/실패 코드 수집.
7. lease 반납, 회전값 0→0, 상태 JSON 저장. 티켓·임시 파일은 삭제 시도 없이 경로만 보고(Claude가 정리).

## 불변
refresh 1회·begin 1회(마지막 몫 — 미소비). generate_link·verify 재호출 금지. events 재조회 생략. 승인 A 원문과 혼동 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰 값 출력 금지. 호스트 파일 작업이 또 막히면 **선검증·정리는 이미 Claude 완료 상태임을 감안하고 그 단계 없이 다음 단계 진행**(저장 자체가 막히면 그때만 BLOCKED). 완료 판정은 폰 화면 증거로만.
