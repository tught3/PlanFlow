# v7s-r12 델타 지시 — 콜드 리스타트로 paused 해소 후 1~7 라운드 (2026-11-11, Claude 작성)

**정본**: v7s-r11 델타. **r11 판정: 진전 실측됨 — begin 200·failed=false·새 세션 부여·errorCode null. 남은 것은 run=paused 뿐이고, 이건 버튼 재탭 대신 콜드 리스타트로 해소한다.**

## Claude 진단
- run=paused + errorCode=null은 런타임 일시정지(suspend: 앱 lifecycle hidden/paused 등) 기록 — resume 탭 후 재 suspend 됐을 가능성. resume 재탭으로 맞잡는 대신, **콜드 리스타트(force-stop → am start)가 가장 확실하다**: cold start의 start()는 begin granted → reconcile → run=active로 재구성한다(v7r 실증: 동일 방식으로 savedDetail/active 복원).
- begin 세션(저널 sessionPresent=true)은 유지된다 — 리스타트가 세션을 새로 만들지 않는다(granted 재사용).

## v7s-r12 실행 절차
1. 큐 lease → **refresh 1회 재갱신**(r11 소비분 대체, 원자적 교체) → 영수증 7키 → 준비.
2. **콜드 리스타트**: `am force-stop com.fluxstudio.planflow.guideqa` → 2초 대기 → resolve-activity → `am start -n <런처>` (monkey 금지) → 포그라운드 확인(mFocusedWindow) → **저널에서 run=active 확인**(run-as).
   - run=active면 → 대기 오버레이/인트로 진행 → 1/7 홈 마이크 코치마크 확인(스크린샷+dump).
   - run=paused 반복 시: 재시도 1회(동일 콜드 리스타트) → 그래도 paused면 저널+dump 수집 후 중단 보고(Claude 판정 — suspend 원인 조사).
3. 1/7부터 v7s-r11의 1~7 흐름 그대로:
   - 마이크 탭 → CEO 발화 "내일 오후 3시 서울역에서 회의" → 전사 hold 확인(dump) → permit 작성 → 제출(AI 3회째) → 확인 화면(내일/오후 3시/서울역/회의) → 2/7(중요→강한 알람→저장, 각 스크린샷) → 3/7 savedDetail → 준비·출발 안내 확인 탭 → 4/7 → CEO 발화 "내일 일정 보여줘" → 전사 hold → permit → 제출(AI 4회) → 5/7(첫 번째=새 일정) → CEO 발화 "첫 번째 일정 오후 5시로 변경해줘" → 전사 hold → permit → 제출(AI 5회째=하드캡 최종) → 6/7(오후 5시 강조) → 실제 저장 탭 → 7/7(3시→5시 실제 변경) → 확인 탭 → 동기화 선택 "동기화 안 함" → 마무리 코치마크.
   - 모달 루틴(외부 캘린더→동기화 안 함) 유지. **모든 건너뛰기 버튼 절대 탭 금지.**
4. 라운드 중 앱 이탈(포그라운드 잃음) 발생 시: back 복귀 후 run 상태 재확인 — paused로 바뀌었으면 이 절차의 콜드 리스타트 1회 재적용(최대 2회) 후 계속.
5. 각 단계 스크린샷+dump(번호 계속). 종료 후 files/ 진단 전문(발췌 금지) + aiRequests 증가분(기대 총 5 = 하드캡) + 새 일정 저장 확인값(제목·날짜·시간).
6. lease 반납, 회전값 0→0, 상태 JSON. 잔여 파일 경로만 보고.

## 불변
v7s-r11 불변 전부 유효: refresh 1회(이번 몫), begin 앱 자동, generate_link·verify·직접 begin/events 금지, 새 일정 1건(CEO 승인분), AI 하드캡 5회, permit은 전사 확인 직후 1회씩, 건너뛰기 절대 금지, OS 설정 변경·monkey/kill-server/래퍼 우회/큐 state 편집 금지, 토큰 출력 금지, 완료 판정은 폰 화면 증거로만, CEO 발화 3회 대기 정상, 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 콜드 리스타트 후 run 상태 / 도달 단계 / 새 일정 저장 확인값 / 전사·permit·AI 소비(aiRequests 최종값) / screen_evidence 경로 / 진단 요약 / 잔여 경로.
