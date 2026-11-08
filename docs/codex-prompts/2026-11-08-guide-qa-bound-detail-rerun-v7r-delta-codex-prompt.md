# Guide QA bound detail — v7r 최종 검증 라운드 지시 (2026-11-08, Claude 작성)

**정본**: v7q-r2 델타 + v3~v7q. 충돌 시 이 문서가 이긴다. **완료 판정 후보 라운드다.**

## 상태 (Claude)
- 수정 원인(fence group_event_comments fatal latch → fetchEvent 거부)은 v7q에서 optional-background화로 제거됐고, APK v198(SHA256 53F601DB…)이 폰에 설치·확인됨.
- 기대: 상세 화면에서 fetchEvent가 fence를 통과해 200 → `_guideReadbackReady=true` → `saved.summary`/`saved.departure` 앵커·코치마크 렌더 → "안내할 실제 화면을 기다리고 있어요" 대신 실제 코치마크.

## v7r 실행 절차 (v7o 절차와 동일 + 성공 기준 강화)
1. 큐 lease(SM-S918N 매칭, 회전값 기록, get-state=device).
2. refresh_token 갱신 1회(기존 승인 절차: 응답 즉시 파일 write → 검증(sub==QA UID, 잔여 ≥3500초) → 원자적 교체). 실패 시 재시도 금지 BLOCKED.
3. 영수증 작성(7키: at=현재, uid, 세 ID=3389cdce-…, verified=true, originalLedgerSha256=보존 ledger에서 계산) → 5분 내 start-bound-detail-round.ps1 직접 실행. logcat -c 후 버퍼 덤프 방식 수집(post-run, v7o 방식 — 스트리밍은 러너를 막으므로 금지).
4. 라운드: 안내 계속 1회 → 저장 일정 행 1회 탭 → 상세 화면 진입 → **10초 대기** → 스크린샷+uiautomator dump. **saved.summary 코치마크가 뜨면** 안내에 따라 다음 단계(최대 탭 10회 이내)로 saved.departure까지 진행, 각 단계 스크린샷+dump.
5. **성공 기준(이것만이 COMPLETE)**: uiautomator dump에 "안내할 실제 화면을 기다리고 있어요"가 **없고** saved.summary/saved.departure 단계의 실제 코치마크(예: 강조 영역+안내 문구)가 screen_evidence로 확인. 대기 문구가 여전히 뜨면 dump+run-as 진단 파일(fence journal 포함 전문) 수집 후 PARTIAL 보고.
6. 앱 files/ 진단(anchor diagnostics 전문, journal 전문, readback) 재수집 — v7p처럼 원본 그대로, 발췌 금지.
7. lease 반납, 회전값 0→0, 상태 JSON 저장. 티켓·임시 파일 삭제 시도 없이 경로 보고.

## 불변
refresh 1회(이번 라운드 몫), begin은 앱 자동 호출만. generate_link·verify·직접 begin/events 금지. 새 일정·AI 요청 금지. monkey/kill-server/래퍼 우회/큐 state 편집 금지. 토큰·키 값 출력 금지(길이·해시만). 완료 판정은 폰 화면 증거로만. 호스트 파일 작업 막히면 경로 보고(Claude 정리).
