# Guide QA bound detail — v7o 델타 지시 (2026-11-08, Claude 작성)

**정본**: v3~v7n 델타. 충돌 시 이 문서가 이긴다.

## v7n 리뷰 판정 (Claude)
PARTIAL 인정 + 중대 진전: 라운드 시작 → 캘린더 3/7 코치마크 → 저장 일정 행 탭 → **상세 화면 실제 표시**(2026-11-05 14:00, 장소)까지 성공. 서버·세션·바인딩·로컬 복구 전부 동작. 남은 실패는 하나: 상세 화면에서 `saved.summary`/`saved.departure` 앵커가 렌더링되지 않아 코치마크가 "안내할 실제 화면을 기다리고 있어요" 상태로 대기.

## Claude의 코드 진단 (QA 트리 event_detail_screen.dart)
- 앵커는 `_guideAckVisible()`(L395~411)이 true일 때만 렌더(L843, L948). 조건: uid 일치, sessionId 존재, run==active, step==savedDetail, `state.createdEventId == event.id`, `event.userId == state.uid`, `_guideReadbackReady`(L213, fetchEvent 성공 시 true), `!_isLoading`.
- v7n 진단: run=active, step=savedDetail, errorCode=null, sessionPresent=true → 서버 측 조건 충족. **미확정 후보 2개: (a) state.createdEventId != event.id (b) _guideReadbackReady=false(fetchEvent 실패 — 화면은 라우트 인자로 표시됐을 수 있음).**
- 이를 가르는 런타임 증거 필요: logcat.

## v7o 실행 절차 (라운드 재실행 + logcat 수집)
1. 큐 lease(SM-S918N 매칭, 회전값 기록, get-state 확인).
2. **logcat 시작**: `adb -s <serial> logcat -c` 후, 가이드/앱 로그 필터링 수집 시작(예: `logcat -v time | grep -iE "guide|real_ui|anchor|readback|flutter"`) — 파일로 스트리밍 저장(qa-live/v7o-logcat.txt).
3. 앱 실행 → 라운드 진행: begin은 앱이 자동 호출(7일 내 자동 연장, 승인 불필요). 영수증은 v7n 것 재사용 → 5분 내 start-bound-detail-round.ps1 직접 실행.
4. v7n과 동일하게: 안내 계속 1회 → 저장 일정 행 1회 탭 → 상세 화면 진입. **상세 화면 진입 직후 10초 대기**(readback 완료 여부 관찰) → 스크린샷 + uiautomator dump. "안내할 실제 화면을 기다리고 있어요"가 뜨면 그 상태로 dump 1장 추가.
5. 탭 총 10회 이내, min(30분, 세션 잔여기간) 창.
6. logcat 스트리밍 종료 → 파일 저장. run-as로 guide 진단 파일(anchor-diagnostics, guide-run, readback) 재수집.
7. lease 반납, 회전값 0→0, 상태 JSON 저장(막히면 경로 보고 — Claude 정리).

## 불변
서버 호출은 앱 자체 동작만(begin 포함, 기존 라운드 승인 범위). 새 AI 요청·generate_link·verify·직접 begin/events 금지. 코드 수정 금지(이번은 증거 수집 라운드). monkey/kill-server/래퍼 우회/state 편집 금지. 토큰 값 출력 금지. 호스트 파일 작업 막히면 경로만 보고(Claude 정리). logcat에 토큰이 찍힐 수 있으니 공유 시 토큰 문자열 마스킹.
