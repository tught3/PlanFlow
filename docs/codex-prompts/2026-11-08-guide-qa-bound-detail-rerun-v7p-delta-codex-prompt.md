# Guide QA bound detail — v7p 델타 지시 (2026-11-08, Claude 작성)

**정본**: v7o 델타 + v3~v7n. 충돌 시 이 문서가 이긴다.

## v7o 리뷰 판정 (Claude)
PARTIAL 인정. logcat 분석 완료(830줄 전수):
- `ANCHOR_DIAG seq=1~4 step=savedDetail` — 상세 화면 진입·코치마크 대기 오버레이("안내할 실제 화면을 기다리고 있어요") 확인. run=active, errorCode 없음.
- **결정적 단서 부족**: 진단 파일의 anchors 맵은 `home.mic/query.mic/voice.review` 3개만 추적하고 saved.summary/saved.departure는 미포함, guide 맵에는 createdEventId가 없음. 또한 v7o 증거는 run-as 파일의 **발췌(coachmark/phase만)** 였고 전문이 qa-live에 없음.
- 그래서 (a) `state.createdEventId != event.id` vs (b) `_guideReadbackReady=false`(fetchEvent 실패) 판정이 아직 불가.
- 참고: 08:05:21에 `Native guide safety fence denied request`(GroupInstructionInboxService 2건, fatal latch)가 있지만 이는 상세 진입(08:00:59) 이후 발생 — seq=1 시점 게이트 실패의 직접 원인 아님. 다만 **저널의 fence records가 fetchEvent(events GET)가 forwarded 됐는지/denyReason 기록 여부를 그대로 알려준다** — 이것이 이번 라운드의 목표.

## v7p 실행 절차 (서버 호출 0, 앱 미기동, run-as 파일 수집만)
1. 큐 lease(SM-S918N 매칭, 회전값 기록).
2. **앱 실행 금지, 탭 금지** — v7o 라운드(2026-11-08 08:00~08:05)가 남긴 앱 내부 파일을 run-as로 전문 수집:
   - `com.fluxstudio.planflow.guideqa` files/ 아래 2026-11-08T08:00 이후 mtime인 파일 **전부**(특히 `native-guide-guide1108080000-bound.json` 전문, `native-guide-anchor-diagnostics.json` 전문, budget 저널 최신분, guide 진행/readback 파일).
   - shared_prefs 가이드 관련 키 요약(값 중 토큰 제외).
3. 수집 파일을 qa-live/v7p-evidence/에 원본 그대로 저장(발췌 금지 — v7o 실패 원인). 구조 요약 보고: journal의 fence records(read/denyReason/denied 이벤트 전부), guide 상태(step/run/revision/createdEventId 유무는 presence만), anchor diagnostics의 guide 맵.
4. lease 반납, 회전값 0→0, 상태 JSON 저장. 파일 삭제 시도 없이 경로만 보고.

## 불변
서버 호출 0(refresh/begin/generate_link/verify 전부 금지). 앱 UI 조작·앱 재실행 금지. 코드 수정 금지. monkey/kill-server/래퍼 우회/state 편집 금지. 토큰 값 출력 금지(길이·해시만). 호스트 파일 작업 막히면 경로 보고(Claude 정리). Claude가 전문을 받는 즉시 (a)/(b) 판정 후 v7q 코드 수정 지시서를 만든다.
