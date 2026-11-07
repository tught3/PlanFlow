# Guide QA bound detail — v7m 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7l 델타. 충돌 시 이 문서가 이긴다.

## CEO 승인 (2026-11-07)
- **refresh_token 갱신 1회**: 세션 파일(v7h verify로 교체된 것)의 refresh_token으로 `POST {SUPABASE_URL}/auth/v1/token?grant_type=refresh_token` 1회. 응답(access_token + 회전된 refresh_token)은 **수신 즉시 파일 write → 검증(access_token·refresh_token 존재, sub==QA UID, 잔여 ≥3500초) → 원자적 교체**(v2 소실 사고 재발 방지 정본 절차). 실패 시 재시도 금지, BLOCKED 보고.
- **begin 재호출 1회**: 갱신된 access token으로. 기대: status='granted'(기존 세션 행이 7일 내라 expires_at 자동 연장). 새 세션 생성이 아니므로 phase는 v7f 당시와 다를 수 있음 — granted이면 event_id/saved_local_date 유무와 무관하게 진행(바인딩은 라운드 중 채워짐, v7i 판정). granted가 아니면 status·reason_code 기록 후 BLOCKED.
- 이후 영수증(v7i 스키마·확보값 그대로: at=현재, uid, 세 ID=3389cdce-…, verified=true, originalLedgerSha256=보존 ledger에서 계산) → 5분 내 라운드 → 화면 증거 → 실측값 수집.

## v7m 실행 절차
1. 큐 lease: SM-S918N + versionCode 198 1대 매칭(설치된 APK는 v7l 것 — SHA256 163BACA3…). lease 직후 serial 지정 회전값 기록, get-state=device 확인.
2. refresh_token 갱신 1회(위 절차 준수). 토큰 값 출력 금지(길이·해시만).
3. begin 1회(granted 확인, 응답 즉시 파일 저장) → 영수증 즉시 작성.
4. 영수증 5분 내 start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지, "Original ledger changed" 거부 시 우회 금지).
5. min(30분, 세션 잔여기간) 창 내 탭 10회 이내: 기대 화면 = 홈 음성입력 버튼 하이라이트 + "눌러서 일정을 추가해보세요 1/2" 코치마크. 스크린샷 + uiautomator dump, 절대경로 screen_evidence 기록. "안내가 잠시 멈췄어요"가 다시 뜨면 dump + run-as로 guide 진단 파일(run-as) 즉시 수집 후 중단 보고(탭 금지).
6. savedDetail 단계 도달 시 saved.summary/saved.departure 앵커 증거 수집. 앱 files/에서 is_multi_day, start_at, saved_local_date, 실패 코드 수집.
7. lease 반납, 회전값 0→0, 상태 JSON 저장. 티켓·임시 파일 삭제가 막히면 경로만 보고(Claude가 정리).

## 불변
refresh 갱신 1회, begin 1회(이번 실행의 마지막 몫). generate_link·verify 재호출 금지. events 재조회 생략(v7f 성공분). 승인 A 원문(2026-11-06 소비분)과 혼동 금지 — 이번은 신규 승인(2026-11-07 옵션 1)이다. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰·키·링크 값 출력 금지. 호스트 파일 작업 막히면 기록만 보고. 완료 판정은 폰 화면 증거로만 — granted만으로 불충분. 실측값 상태 JSON 기록.
