# Guide QA bound detail — v7f 델타 지시 (2026-11-07, Claude 작성)

**정본**: v3~v7e 델타. 충돌 시 이 문서가 이긴다.

## v7e 리뷰 판정 (Claude)
- **세션 확보 성공 인정**: generate_link 1회 + verify 1회, QA UID 일치, 잔여기간 약 3,604초(17:2x 기준 — 계속 감소 중). 재발급·verify 재호출 금지.
- 승인 B 소유 조회: qa-live에 응답 파일 생성 흔적이 전혀 없음을 Claude가 직접 확인 → **실행되지 않은 것으로 판정.** 읽기 전용 조회이므로 1회 재시도는 승인 B 범위 내(README 원칙상 읽기는 멱등). 단 이번 1회가 마지막 — 응답을 반드시 파일로 남길 것.
- 잔여 티켓은 Claude가 정리 완료(0건). 상태 JSON은 이번 실행에서 Codex가 새로 기록.

## v7f 실행 절차 — 즉시 착수(세션 만료가 시간 문제)
0. 세션: 기존 교체된 세션 그대로 사용(잔여기간 재확인 후 0 이하면 BLOCKED — 이 경우 재발급 금지 유지).
1. 큐 lease(SM-S918N + versionCode 198 1대 매칭, 회전값 기록).
2. 승인 B: 소유 조회 1회 — **응답 본문을 즉시 qa-live의 events-ownership-v7f-response.json에 저장 후 파싱**(이번 소실 재발 방지). 소유 확인되면 begin_real_ui_guide 1회 → 영수증 즉시 파일 저장(5분 유효).
3. 영수증 5분 내 start-bound-detail-round.ps1 직접 실행(래퍼·허용 목록 수정 금지).
4. min(30분, 세션 잔여기간) 창 내 탭 10회 이내: 상세 튜토리얼 스크린샷 + uiautomator dump, saved.summary/saved.departure 앵커·코치마크 확인, screen_evidence 기록.
5. lease 반납, 회전값 0→0, 상태 JSON 저장(정책에 막히면 경로만 보고 — Claude가 정리·보완).

## 불변
generate_link·verify 재호출 금지(세션 유효). events 읽기 이번 포함 총 2회(1회 무흔적 미실행 판정에 따른 유일한 예외), begin 1회. 승인 A 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰·키·링크 값 출력 금지. 호스트 파일 작업 막히면 기록만 보고. 완료 판정은 폰 화면 증거로만. 실측값(is_multi_day, start_at, saved_local_date, 실패 코드) 상태 JSON 기록.
