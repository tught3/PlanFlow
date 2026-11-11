# v7s-r15 델타 지시 — 러너로 새 bound 세션 발급 후 연습 진행 (2026-11-12, Claude 작성)

**정본**: v7s-r14 델타. **r14 BLOCKED 판정: 콜드 리스타트만으론 부족 — "deadline passed"는 러너가 만드는 bound 세션 설정(마감시각)이 만료됐다는 뜻. 새 bound 세션은 러너(start-bound-detail-round.ps1) 실행으로만 발급된다. r14에서 러너를 생략한 것이 원인(내 절차 설계 미스).**

## 절차 (r14와 동일하되 1단계가 러너 재실행)
1. 큐 lease → **세션 파일 잔여기간 확인**: ≥1,200초면 refresh 생략(무호출), 미만이면 refresh 1회 필요(승인 없으면 BLOCKED 보고).
2. **러너 재실행(핵심)**: 영수증 7키(at=현재, uid, 세 ID, verified=true, originalLedgerSha256 재계산) → 5분 내 start-bound-detail-round.ps1 실행 → **새 bound 세션 설정 발급 확인**(qa-live에 새 `native-guide-guide<타임스탬프>-bound.json` 생성, logcat -c 후 post-run 덤프).
3. 앱 재기동(필요 시 force-stop→am start) → 포그라운드 확인 → **"deadline passed" 화면이 사라졌는지 확인** → 인트로 진행 → 1/7 홈 마이크 코치마크 확인. 사라지지 않으면 dump+run-as 전문 수집 후 중단 보고.
4. 이하 r14의 연속 진행 동일:
   - 마이크 탭 → 연습 화면 → CEO 발화 "내일 오후 1시에" → 전사 hold → permit → 제출(AI 3회째) → "아니" 단계.
   - CEO 발화 "아니" → 전사 hold → permit → 제출(AI 4회째) → CEO 발화 "오후 2시에 강남역에서 일정" → 전사 hold → permit → 제출(AI 5회째=하드캡) → 생성 확인(강남역 일정·오후 2시·날짜 기록).
   - 2/7 저장(중요→강한 알람→저장, 각 스크린샷) → 3/7 savedDetail → 준비·출발 안내 확인 탭 → 4/7 → 조회 발화(생성 날짜 맞춰 "오늘/내일 일정 보여줘") → 전사 불일치 시 permit 소비 없이 중단 보고 → permit → 제출(마지막 허용) → **5/7(첫 번째=새 일정) 도달이 이번 성공 기준** → CEO 발화 "첫 번째 일정 오후 5시로 변경해줘" → 전사 hold → permit → 제출 시도(6회째 — ai_cap_exceeded 차단 예상, 기록) → 진행 불가 시 5/7까지 증거로 보고(4~5단계 검증 완료).
5. 모달 루틴 유지. 건너뛰기 절대 금지. 각 단계 스크린샷+dump. 단계 간 장시간 공백 금지(만료 재발 방지). 종료 후 files/ 진단 전문(발췌 금지) + aiRequests 최종값 + 새 일정 저장 확인값.
6. lease 반납, 회전값 0→0, 상태 JSON. 잔여 파일 경로만 보고(r14 관련 파일 유지).

## 불변
v7s-r14 불변 전부 유효: begin 앱 자동, generate_link·verify·직접 begin/events 금지, 새 일정 1건(연습 일정), AI 하드캡 5회(6번째 차단 정상), permit 1회씩, 건너뛰기 절대 금지, OS 설정 변경·monkey/kill-server/래퍼 우회/큐 state 편집 금지, 토큰 출력 금지, 완료 판정은 폰 화면 증거로만, CEO 발화 3회 대기 정상. refresh 조건부(1,200초 미만 시 별도 승인). 호스트 파일 막히면 경로 보고(Claude 정리).

보고 형식: 결과 한 줄 / 새 bound 세션 발급 확인 / 도달 단계 / 새 일정 저장 확인값 / 전사·permit·AI 소비(aiRequests 최종값, 하드캡 차단 여부) / screen_evidence 경로 / 진단 요약 / 잔여 경로.
